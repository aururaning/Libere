import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Explicit clipboard moves use one temporary transfer copy. Sources are only
/// removed after their bytes and destinations have been verified and the caller
/// has durably committed both the workspace and its undo entry. Absolute paths
/// and access bookmarks live only in a device-local receipt directory.
public enum ClipboardMove {
    public struct Source: Sendable {
        public let url: URL
        public let fileID: UUID
        public init(url: URL, fileID: UUID) { self.url = url; self.fileID = fileID }
    }

    public enum MoveError: LocalizedError {
        case invalidLibrary, invalidReceiptDirectory, receiptMismatch, notCommitted, unfinished
        case invalidSource(String), sourceChanged(String), destinationChanged(String), conflict(String), missingParent(String)
        case installationFailed(String, retainedFiles: [URL])
        public var errorDescription: String? {
            switch self {
            case .invalidLibrary: return "资料库文件夹不可用。"
            case .invalidReceiptDirectory: return "移动恢复记录必须保存在此设备的本地目录中。"
            case .receiptMismatch: return "这条移动记录不属于当前设备或资料库，未操作原文件。"
            case .notCommitted: return "页面与撤销记录尚未保存，原文件已保留。"
            case .unfinished: return "上次移动尚未完成，原件与归档文件已保留，请先处理移动提示后再撤销。"
            case .invalidSource(let name): return "只能移动普通原文件，不能移动文件夹、文件包或符号链接：" + name
            case .sourceChanged(let name): return "原文件已变化，未删除原件：" + name
            case .destinationChanged(let name): return "归档文件的校验已变化，未删除原件：" + name
            case .conflict(let name): return "目标已有同名文件，未覆盖：" + name
            case .missingParent(let name): return "原位置的文件夹不可用，未创建替代目录：" + name
            case .installationFailed(let message, let retained):
                return retained.isEmpty ? message : "部分转移文件已保留（\(retained.count) 个），原件尚未删除：" + message
            }
        }
    }

    public struct InstalledFile: Codable, Sendable, Equatable {
        public let receiptID: UUID
        public let fileID: UUID
        public let sourceURL: URL
        public let destinationURL: URL
        public let isNoOp: Bool
    }

    public enum Phase: String, Codable, Sendable { case installing, installed, committed, completed }

    public struct Entry: Codable, Sendable {
        public let fileID: UUID
        public var sourceURL: URL
        public let destinationURL: URL
        public let sha256: String
        public let bytes: Int64
        public let isNoOp: Bool
        public fileprivate(set) var installed: Bool
        public fileprivate(set) var sourceRemoved: Bool
        fileprivate var sourceIdentity: Identity
        fileprivate var destinationIdentity: Identity?
        fileprivate var sourceBookmark: Data?
        fileprivate var sourceParentBookmark: Data?
        fileprivate var destinationParentBookmark: Data?
        fileprivate var quarantineURL: URL?
        fileprivate var installedByThisTransaction: Bool
    }

    public struct Receipt: Codable, Sendable {
        public let version: Int
        public let id: UUID
        public let deviceID: String
        public let libraryRoot: URL
        public let reverseOf: UUID?
        public fileprivate(set) var phase: Phase
        public fileprivate(set) var entries: [Entry]
        public var files: [InstalledFile] {
            entries.map { InstalledFile(receiptID: id, fileID: $0.fileID, sourceURL: $0.sourceURL,
                                       destinationURL: $0.destinationURL, isNoOp: $0.isNoOp) }
        }
    }

    public struct FinishResult: Sendable {
        public let receipt: Receipt
        public let retainedSources: [URL]
        public let errors: [String]
        public var completed: Bool { receipt.phase == .completed }
        public var movedCount: Int { receipt.entries.filter { !$0.isNoOp && $0.sourceRemoved }.count }
    }

    fileprivate struct Identity: Codable, Sendable, Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        func sameFileAndContentMetadata(as other: Identity) -> Bool {
            device == other.device && inode == other.inode && size == other.size
                && modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
        }
    }

    fileprivate struct PreparedEntry: Sendable {
        let fileID: UUID
        var sourceURL: URL
        let filename: String
        let stagedURL: URL
        let identity: Identity
        let stagingIdentity: Identity
        let fingerprint: AssetFingerprint
        let sourceBookmark: Data?
        let sourceParentBookmark: Data?
        let fixedDestination: URL?
    }

    /// Methods must be called serially. The object may move between the main
    /// actor and a copy task, and retains source grants for the whole operation.
    public final class Prepared: @unchecked Sendable {
        public let id: UUID
        public let libraryRoot: URL
        public let deviceID: String
        public var entries: [Source] { prepared.map { Source(url: $0.sourceURL, fileID: $0.fileID) } }
        public private(set) var receipt: Receipt?
        private let receiptDirectory: URL
        private let stagingDirectory: URL
        private let reverseOf: UUID?
        private let prepared: [PreparedEntry]
        fileprivate var accessURLs: [URL]
        private var cleaned = false

        fileprivate init(id: UUID, root: URL, deviceID: String, receiptDirectory: URL, staging: URL,
                         prepared: [PreparedEntry], access: [URL], reverseOf: UUID?) {
            self.id = id; libraryRoot = root; self.deviceID = deviceID; self.receiptDirectory = receiptDirectory
            stagingDirectory = staging; self.prepared = prepared; accessURLs = access; self.reverseOf = reverseOf
        }
        deinit { for url in accessURLs { url.stopAccessingSecurityScopedResource() } }

        public func install(into directory: URL, sourceReplacements: [URL: URL] = [:]) throws -> [InstalledFile] {
            guard reverseOf == nil else { throw MoveError.receiptMismatch }
            try validateLibraryDestination(directory, root: libraryRoot, allowRoot: true)
            return try installFiles(prepared.map { item in
                let name = sourceReplacements[item.sourceURL]?.lastPathComponent ?? item.filename
                return directory.appendingPathComponent(ClipboardArchive.category(for: name), isDirectory: true).appendingPathComponent(name)
            },
                                    sourceReplacements: sourceReplacements)
        }

        public func installReverse() throws -> [InstalledFile] {
            guard reverseOf != nil, prepared.allSatisfy({ $0.fixedDestination != nil }) else { throw MoveError.receiptMismatch }
            return try installFiles(prepared.map { $0.fixedDestination! }, sourceReplacements: [:])
        }

        private func installFiles(_ destinations: [URL], sourceReplacements: [URL: URL]) throws -> [InstalledFile] {
            guard !cleaned, receipt == nil else { throw MoveError.receiptMismatch }
            var entries: [Entry] = [], claimed: Set<String> = []
            // Validate the entire batch before publishing even its first file.
            for (item, destination) in zip(prepared, destinations) {
                let source = canonicalLeaf(sourceReplacements[item.sourceURL] ?? item.sourceURL)
                let destination = canonicalLeaf(destination)
                if source != item.sourceURL {
                    guard ReferencePath.relative(source, inside: libraryRoot) != nil,
                          item.identity.sameFileAndContentMetadata(as: try identity(source)) else { throw MoveError.sourceChanged(item.filename) }
                }
                let current = try identity(source)
                let unchanged = source == item.sourceURL ? current == item.identity : current.sameFileAndContentMetadata(as: item.identity)
                guard unchanged else { throw MoveError.sourceChanged(item.filename) }
                let noOp = source == destination
                if reverseOf == nil { try validateLibraryDestination(destination, root: libraryRoot, allowRoot: false) }
                else { try validateReverseDestination(destination) }
                guard claimed.insert(destination.path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw MoveError.conflict(destination.lastPathComponent) }
                if !noOp, exists(destination) { throw MoveError.conflict(destination.lastPathComponent) }
                guard try identity(item.stagedURL) == item.stagingIdentity else { throw MoveError.destinationChanged(item.filename) }
                entries.append(Entry(fileID: item.fileID, sourceURL: source, destinationURL: destination,
                                     sha256: item.fingerprint.sha256, bytes: item.fingerprint.bytes, isNoOp: noOp,
                                     installed: noOp, sourceRemoved: noOp, sourceIdentity: current,
                                     destinationIdentity: noOp ? current : nil, sourceBookmark: source == item.sourceURL ? item.sourceBookmark : bookmark(source),
                                     sourceParentBookmark: source == item.sourceURL ? item.sourceParentBookmark : bookmark(source.deletingLastPathComponent()),
                                     destinationParentBookmark: bookmark(destination.deletingLastPathComponent()),
                                     quarantineURL: nil, installedByThisTransaction: false))
            }
            var value = Receipt(version: 1, id: id, deviceID: deviceID, libraryRoot: libraryRoot, reverseOf: reverseOf, phase: .installing, entries: entries)
            try writeReceipt(value, in: receiptDirectory); try addPending(id, root: libraryRoot, deviceID: deviceID, directory: receiptDirectory)
            receipt = value
            var installed: [URL] = []
            do {
                for i in value.entries.indices where !value.entries[i].isNoOp {
                    let target = value.entries[i].destinationURL
                    if reverseOf == nil {
                        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try validateLibraryDestination(target, root: libraryRoot, allowRoot: false)
                    }
                    try installCopy(prepared[i].stagedURL, at: target, expected: prepared[i].fingerprint, stagingIdentity: prepared[i].stagingIdentity)
                    installed.append(target)
                    value.entries[i].destinationIdentity = try identity(target)
                    value.entries[i].installed = true; value.entries[i].installedByThisTransaction = true
                    try writeReceipt(value, in: receiptDirectory); receipt = value
                }
                value.phase = .installed; try writeReceipt(value, in: receiptDirectory); receipt = value
                return value.files
            } catch {
                receipt = value
                throw MoveError.installationFailed(error.localizedDescription, retainedFiles: installed)
            }
        }

        /// Caller contract: only after workspace and undo history are durable.
        /// Recovery deliberately never infers this local authorization from a
        /// synced workspace marker alone.
        public func markCommitted() throws {
            guard !cleaned, var value = receipt, value.phase == .installed, value.entries.allSatisfy(\.installed) else { throw MoveError.notCommitted }
            value.phase = .committed; try writeReceipt(value, in: receiptDirectory); receipt = value
        }

        public func finishSources(remove: ((URL) throws -> Void)? = nil) throws -> FinishResult {
            guard !cleaned, let value = receipt else { throw MoveError.notCommitted }
            let result = try finish(value, directory: receiptDirectory, remove: remove ?? unlinkClaimedFile)
            receipt = result.receipt; return result
        }

        /// Installed destinations are independent originals and never scratch.
        public func cleanup() {
            guard !cleaned else { return }; cleaned = true
            removeStaging(stagingDirectory, id: id)
            for url in accessURLs { url.stopAccessingSecurityScopedResource() }; accessURLs = []
        }
    }

    public static func prepare(_ sources: [Source], libraryRoot: URL, deviceID: String, receiptDirectory: URL) throws -> Prepared {
        try prepareSources(sources, destinations: nil, libraryRoot: libraryRoot, deviceID: deviceID, receiptDirectory: receiptDirectory, reverseOf: nil)
    }

    public static func prepareReverse(receiptID: UUID, libraryRoot: URL, deviceID: String, receiptDirectory: URL,
                                      currentSources: [UUID: URL] = [:]) throws -> Prepared {
        let value = try loadReceipt(id: receiptID, libraryRoot: libraryRoot, deviceID: deviceID, receiptDirectory: receiptDirectory)
        guard value.phase == .completed else { throw MoveError.unfinished }
        var access: [URL] = []
        defer { for url in access { url.stopAccessingSecurityScopedResource() } }
        let entries = value.entries.filter { !$0.isNoOp }
        var sources: [Source] = [], destinations: [URL] = []
        for item in entries {
            for data in [item.sourceParentBookmark, item.destinationParentBookmark].compactMap({ $0 }) {
                if let url = resolveBookmark(data), url.startAccessingSecurityScopedResource() { access.append(url) }
            }
            let source = currentSources[item.fileID] ?? item.destinationURL
            if currentSources[item.fileID] != nil {
                guard ReferencePath.relative(source, inside: value.libraryRoot) != nil else { throw MoveError.receiptMismatch }
            }
            try validateReverseDestination(item.sourceURL)
            if exists(item.sourceURL) { throw MoveError.conflict(item.sourceURL.lastPathComponent) }
            sources.append(Source(url: source, fileID: item.fileID)); destinations.append(item.sourceURL)
        }
        let prepared = try prepareSources(sources, destinations: destinations, libraryRoot: libraryRoot, deviceID: deviceID,
                                          receiptDirectory: receiptDirectory, reverseOf: receiptID)
        // Retain the parent grants through the reverse installation, not merely
        // while preparing its bytes.
        for url in access { if url.startAccessingSecurityScopedResource() { prepared.accessURLs.append(url) } }
        return prepared
    }

    public static func loadReceipt(id: UUID, libraryRoot: URL, deviceID: String, receiptDirectory: URL) throws -> Receipt {
        let root = try validatedRoot(libraryRoot), directory = try validatedReceiptDirectory(receiptDirectory, root: root)
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeRegular else { throw MoveError.receiptMismatch }
        let value = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
        guard value.version == 1, value.id == id, value.deviceID == deviceID, !deviceID.isEmpty,
              value.libraryRoot == root, Set(value.entries.map(\.fileID)).count == value.entries.count else { throw MoveError.receiptMismatch }
        return value
    }

    /// Reads a tiny local index, never enumerates the library or origin folders.
    public static func pendingReceiptIDs(libraryRoot: URL, deviceID: String, receiptDirectory: URL) throws -> [UUID] {
        let root = try validatedRoot(libraryRoot), directory = try validatedReceiptDirectory(receiptDirectory, root: root)
        return try withReceiptLock(directory) { try readPending(root: root, deviceID: deviceID, directory: directory).ids }
    }

    public static func resumeCommitted(receiptID: UUID, libraryRoot: URL, deviceID: String, receiptDirectory: URL,
                                       remove: ((URL) throws -> Void)? = nil) throws -> FinishResult {
        let value = try loadReceipt(id: receiptID, libraryRoot: libraryRoot, deviceID: deviceID, receiptDirectory: receiptDirectory)
        guard value.phase == .committed || value.phase == .completed else { throw MoveError.notCommitted }
        return try finish(value, directory: receiptDirectory, remove: remove ?? unlinkClaimedFile)
    }

    private static func prepareSources(_ sources: [Source], destinations: [URL]?, libraryRoot: URL, deviceID: String,
                                       receiptDirectory: URL, reverseOf: UUID?) throws -> Prepared {
        let root = try validatedRoot(libraryRoot), directory = try validatedReceiptDirectory(receiptDirectory, root: root)
        guard !deviceID.isEmpty else { throw MoveError.receiptMismatch }
        let id = UUID(), staging = root.appendingPathComponent(".libere-cut-" + id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try Data(id.uuidString.utf8).write(to: staging.appendingPathComponent(".owner"), options: .withoutOverwriting)
        var entries: [PreparedEntry] = [], access: [URL] = [], seen: Set<String> = [], identities: Set<UUID> = []
        do {
            for (i, input) in sources.enumerated() {
                try Task.checkCancellation()
                guard validFileURL(input.url) else { throw MoveError.invalidSource(input.url.lastPathComponent) }
                if input.url.startAccessingSecurityScopedResource() { access.append(input.url) }
                _ = try identity(input.url) // Reject a symbolic-link leaf before resolving its directory.
                let source = input.url.standardizedFileURL.resolvingSymlinksInPath()
                guard seen.insert(source.path).inserted else { continue }
                guard identities.insert(input.fileID).inserted else { throw MoveError.receiptMismatch }
                if ReferencePath.relative(source, inside: root) != nil { _ = try FileIndexPolicy.path(for: source, inside: root) }
                let before = try identity(source), target = staging.appendingPathComponent(UUID().uuidString)
                try FileManager.default.copyItem(at: source, to: target)
                try Task.checkCancellation()
                let stagedBefore = try identity(target)
                let sourceHash = try fingerprint(source), copiedHash = try fingerprint(target), after = try identity(source), stagedAfter = try identity(target)
                guard before == after, stagedBefore == stagedAfter, sourceHash == copiedHash, sourceHash.bytes == before.size else { throw MoveError.sourceChanged(source.lastPathComponent) }
                entries.append(PreparedEntry(fileID: input.fileID, sourceURL: source, filename: source.lastPathComponent,
                    stagedURL: target, identity: after, stagingIdentity: stagedAfter, fingerprint: sourceHash, sourceBookmark: bookmark(input.url),
                    sourceParentBookmark: bookmark(input.url.deletingLastPathComponent()), fixedDestination: destinations?[i]))
            }
            return Prepared(id: id, root: root, deviceID: deviceID, receiptDirectory: directory, staging: staging,
                            prepared: entries, access: access, reverseOf: reverseOf)
        } catch {
            for url in access { url.stopAccessingSecurityScopedResource() }
            removeStaging(staging, id: id); throw error
        }
    }

    private static func finish(_ original: Receipt, directory: URL, remove: (URL) throws -> Void) throws -> FinishResult {
        guard original.phase == .committed || original.phase == .completed else { throw MoveError.notCommitted }
        var value = original, retained: [URL] = [], errors: [String] = []
        for i in value.entries.indices where !value.entries[i].sourceRemoved && !value.entries[i].isNoOp {
            let source = value.entries[i].sourceURL, destination = value.entries[i].destinationURL
            var access: [URL] = []
            for data in [value.entries[i].sourceBookmark, value.entries[i].sourceParentBookmark, value.entries[i].destinationParentBookmark].compactMap({ $0 }) {
                if let url = resolveBookmark(data), url.startAccessingSecurityScopedResource() { access.append(url) }
            }
            defer { for url in access { url.stopAccessingSecurityScopedResource() } }
            do {
                let verifiedDestination = try verifyDestination(value.entries[i])
                let quarantine = value.entries[i].quarantineURL ?? source.deletingLastPathComponent().appendingPathComponent(".libere-cut-remove-" + value.id.uuidString + "-" + String(i))
                if !exists(source) && !exists(quarantine) {
                    // A crash can occur after unlink but before the local receipt
                    // is updated. The verified destination remains authoritative.
                    value.entries[i].sourceRemoved = true
                    try writeReceipt(value, in: directory); continue
                }
                if !exists(quarantine) {
                    let before = try identity(source)
                    guard before.sameFileAndContentMetadata(as: value.entries[i].sourceIdentity) else { throw MoveError.sourceChanged(source.lastPathComponent) }
                    value.entries[i].quarantineURL = quarantine
                    try writeReceipt(value, in: directory)
                    // Exclusive rename claims the exact directory entry. If a
                    // competing writer replaced it, verify the claimed inode
                    // before deletion, and restore it rather than deleting it.
                    try renameExclusive(source, quarantine)
                }
                let claimed = try identity(quarantine)
                guard claimed.sameFileAndContentMetadata(as: value.entries[i].sourceIdentity),
                      try matchesFingerprint(quarantine, value.entries[i]), claimed == (try identity(quarantine)) else { throw MoveError.sourceChanged(source.lastPathComponent) }
                // The target was fully hashed before claiming the source. A
                // final inode/size/mtime/ctime comparison catches any intervening
                // write or replacement without rereading the entire target.
                guard verifiedDestination == (try identity(destination)) else { throw MoveError.destinationChanged(destination.lastPathComponent) }
                try remove(quarantine)
                value.entries[i].sourceRemoved = true; value.entries[i].quarantineURL = nil
                try writeReceipt(value, in: directory)
            } catch {
                if let quarantine = value.entries[i].quarantineURL, exists(quarantine), !exists(source) {
                    do { try renameExclusive(quarantine, source); value.entries[i].quarantineURL = nil }
                    catch { /* Retain the claimed original and its recovery path. */ }
                }
                retained.append(value.entries[i].quarantineURL.flatMap { exists($0) ? $0 : nil } ?? source)
                errors.append(error.localizedDescription)
                try? writeReceipt(value, in: directory)
            }
        }
        if value.entries.allSatisfy(\.sourceRemoved) {
            value.phase = .completed; try writeReceipt(value, in: directory)
            try removePending(value.id, root: value.libraryRoot, deviceID: value.deviceID, directory: directory)
        }
        return FinishResult(receipt: value, retainedSources: retained, errors: errors)
    }

    private static func fingerprint(_ url: URL) throws -> AssetFingerprint { try AssetFingerprint.read(url) }
    private static func matchesFingerprint(_ url: URL, _ entry: Entry) throws -> Bool {
        let value = try fingerprint(url); return value.sha256 == entry.sha256 && value.bytes == entry.bytes
    }
    private static func verifyDestination(_ entry: Entry) throws -> Identity {
        let before = try identity(entry.destinationURL)
        guard let expected = entry.destinationIdentity, before.sameFileAndContentMetadata(as: expected),
              try matchesFingerprint(entry.destinationURL, entry), before == (try identity(entry.destinationURL)) else { throw MoveError.destinationChanged(entry.destinationURL.lastPathComponent) }
        return before
    }
    private static func identity(_ url: URL) throws -> Identity {
        guard validFileURL(url) else { throw MoveError.invalidSource(url.lastPathComponent) }
        var value = stat()
        guard url.path.withCString({ lstat($0, &value) }) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw MoveError.invalidSource(url.lastPathComponent) }
        #if canImport(Darwin)
        return Identity(device: UInt64(bitPattern: Int64(value.st_dev)), inode: UInt64(value.st_ino), size: Int64(value.st_size),
                        modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
                        changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanoseconds: Int64(value.st_ctimespec.tv_nsec))
        #else
        return Identity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino), size: Int64(value.st_size),
                        modifiedSeconds: Int64(value.st_mtim.tv_sec), modifiedNanoseconds: Int64(value.st_mtim.tv_nsec),
                        changedSeconds: Int64(value.st_ctim.tv_sec), changedNanoseconds: Int64(value.st_ctim.tv_nsec))
        #endif
    }
    private static func exists(_ url: URL) -> Bool {
        var value = stat(); return url.path.withCString { lstat($0, &value) } == 0
    }
    private static func validatedRoot(_ url: URL) throws -> URL {
        guard validFileURL(url) else { throw MoveError.invalidLibrary }
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        guard validFileURL(root), (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { throw MoveError.invalidLibrary }
        return root
    }
    private static func validatedReceiptDirectory(_ url: URL, root: URL) throws -> URL {
        guard validFileURL(url) else { throw MoveError.invalidReceiptDirectory }
        let directory = url.standardizedFileURL.resolvingSymlinksInPath()
        guard validFileURL(directory), directory != root, ReferencePath.relative(directory, inside: root) == nil,
              (try? directory.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem != true else { throw MoveError.invalidReceiptDirectory }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try FileManager.default.attributesOfItem(atPath: directory.path)[.type]) as? FileAttributeType == .typeDirectory,
              (try? directory.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem != true else { throw MoveError.invalidReceiptDirectory }
        return directory
    }
    private static func validateLibraryDestination(_ url: URL, root: URL, allowRoot: Bool) throws {
        guard validFileURL(url) else { throw FileIndexError.outsideLibrary }
        let actual = url.standardizedFileURL.resolvingSymlinksInPath()
        if allowRoot && actual == root { return }
        guard let path = ReferencePath.relative(actual, inside: root) else { throw FileIndexError.outsideLibrary }
        let parts = path.split(separator: "/"), first = String(parts.first ?? "")
        let components = allowRoot ? parts : Array(parts.dropLast())
        guard !components.contains(where: { $0.hasPrefix(".") }), !["Assets", "Sync", "Recoveries"].contains(first),
              path != "workspace.json", path != "workspace.previous.json", path != "Projects/index.json",
              !(first.hasPrefix("History-") && first.hasSuffix(".json")) else { throw FileIndexError.reservedPath }
    }
    private static func validateReverseDestination(_ url: URL) throws {
        guard validFileURL(url), (try? url.deletingLastPathComponent().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { throw MoveError.missingParent(url.deletingLastPathComponent().lastPathComponent) }
        if exists(url) { throw MoveError.conflict(url.lastPathComponent) }
    }
    private static func installCopy(_ source: URL, at destination: URL, expected: AssetFingerprint, stagingIdentity: Identity) throws {
        guard !exists(destination) else { throw MoveError.conflict(destination.lastPathComponent) }
        // Forward staging and the classified page folder are normally on the
        // same volume. Rename the verified transfer copy instead of copying its
        // contents again. EXDEV falls back only for our owned scratch file.
        do {
            try renameExclusive(source, destination)
            guard stagingIdentity.sameFileAndContentMetadata(as: try identity(destination)) else { throw MoveError.destinationChanged(destination.lastPathComponent) }
            return
        }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EXDEV) { }
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".libere-cut-install-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        // This transfer may cross a volume on undo. The original source is still
        // retained, and the final target is verified before markCommitted.
        try FileManager.default.copyItem(at: source, to: temp)
        guard try fingerprint(temp) == expected, stagingIdentity == (try identity(source)) else { throw MoveError.destinationChanged(destination.lastPathComponent) }
        try renameExclusive(temp, destination)
    }
    private static func canonicalLeaf(_ url: URL) -> URL {
        guard validFileURL(url) else { return url }
        return url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
    }
    private static func validFileURL(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host?.isEmpty == true || url.host?.lowercased() == "localhost")
    }
    private static func renameExclusive(_ source: URL, _ target: URL) throws {
        #if canImport(Darwin)
        let result = source.path.withCString { from in target.path.withCString { to in renameatx_np(AT_FDCWD, from, AT_FDCWD, to, UInt32(RENAME_EXCL)) } }
        if result != 0 {
            let code = errno
            // macOS's exFAT File System Kit rejects RENAME_EXCL. Foundation's
            // no-overwrite move API supplies the same conflict contract there.
            // Source cleanup only uses this fallback within the same parent;
            // cross-volume copies in installCopy involve owned scratch only.
            if code == ENOTSUP || code == EOPNOTSUPP {
                guard !exists(target) else { throw MoveError.conflict(target.lastPathComponent) }
                try FileManager.default.moveItem(at: source, to: target)
            } else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "文件移动失败，原件已保留：" + source.lastPathComponent])
            }
        }
        #else
        guard !exists(target) else { throw MoveError.conflict(target.lastPathComponent) }
        try FileManager.default.moveItem(at: source, to: target)
        #endif
    }
    private static func unlinkClaimedFile(_ url: URL) throws {
        // Never recursively remove a directory if another process changed the
        // claimed entry after validation. unlink also never follows a symlink.
        guard url.path.withCString({ unlink($0) }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "原件移除未完成，已保留可恢复文件。"])
        }
    }
    private static func bookmark(_ url: URL) -> Data? {
        #if os(macOS)
        return (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        #else
        return try? url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }
    private static func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        #if os(macOS)
        return (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: [.withoutUI], bookmarkDataIsStale: &stale))
        #else
        return try? URL(resolvingBookmarkData: data, options: [.withoutUI], bookmarkDataIsStale: &stale)
        #endif
    }
    private static func removeStaging(_ directory: URL, id: UUID) {
        guard directory.lastPathComponent == ".libere-cut-" + id.uuidString,
              (try? FileManager.default.attributesOfItem(atPath: directory.path)[.type]) as? FileAttributeType == .typeDirectory,
              (try? Data(contentsOf: directory.appendingPathComponent(".owner"))) == Data(id.uuidString.utf8) else { return }
        try? FileManager.default.removeItem(at: directory)
    }
    private static func writeReceipt(_ value: Receipt, in directory: URL) throws {
        let file = directory.appendingPathComponent(value.id.uuidString + ".json")
        if exists(file) {
            guard (try FileManager.default.attributesOfItem(atPath: file.path)[.type]) as? FileAttributeType == .typeRegular,
                  let prior = try? JSONDecoder().decode(Receipt.self, from: Data(contentsOf: file)),
                  prior.id == value.id, prior.deviceID == value.deviceID, prior.libraryRoot == value.libraryRoot else { throw MoveError.receiptMismatch }
        }
        try Repository.writeAtomically(JSONEncoder().encode(value), to: file)
    }

    private struct Pending: Codable { let root: URL; let deviceID: String; var ids: [UUID] }
    private static func pendingURL(root: URL, deviceID: String, directory: URL) -> URL {
        directory.appendingPathComponent("pending-" + AssetFingerprint.sha256(Data((root.path + "\n" + deviceID).utf8)) + ".json")
    }
    private static func readPending(root: URL, deviceID: String, directory: URL) throws -> Pending {
        let url = pendingURL(root: root, deviceID: deviceID, directory: directory)
        guard exists(url) else { return Pending(root: root, deviceID: deviceID, ids: []) }
        guard (try FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeRegular else { throw MoveError.receiptMismatch }
        let value = try JSONDecoder().decode(Pending.self, from: Data(contentsOf: url))
        guard value.root == root, value.deviceID == deviceID else { throw MoveError.receiptMismatch }; return value
    }
    private static func addPending(_ id: UUID, root: URL, deviceID: String, directory: URL) throws {
        try withReceiptLock(directory) {
            var value = try readPending(root: root, deviceID: deviceID, directory: directory)
            if !value.ids.contains(id) { value.ids.append(id) }
            try Repository.writeAtomically(JSONEncoder().encode(value), to: pendingURL(root: root, deviceID: deviceID, directory: directory))
        }
    }
    private static func removePending(_ id: UUID, root: URL, deviceID: String, directory: URL) throws {
        try withReceiptLock(directory) {
            var value = try readPending(root: root, deviceID: deviceID, directory: directory); value.ids.removeAll { $0 == id }
            try Repository.writeAtomically(JSONEncoder().encode(value), to: pendingURL(root: root, deviceID: deviceID, directory: directory))
        }
    }
    private static func withReceiptLock<T>(_ directory: URL, _ body: () throws -> T) throws -> T {
        let path = directory.appendingPathComponent(".lock").path
        let fd = path.withCString { open($0, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600)) }
        guard fd >= 0 else { throw MoveError.invalidReceiptDirectory }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw MoveError.invalidReceiptDirectory }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
