import Foundation

/// Clipboard intake is a one-time archive operation. Existing library originals
/// are referenced, while outside files are copied once and never modified.
public enum ClipboardArchive {
    public enum Input: Sendable {
        case file(URL)
        /// For a path already validated against the caller's active file index.
        /// A sidebar move may remove this old path before background preparation;
        /// install validates the current replacement path before publishing it.
        case libraryReference(URL)
        case data(Data, suggestedFilename: String)
    }

    public enum ArchiveError: LocalizedError {
        case invalidLibrary, unsupportedItem(String), sourceChanged(String)
        case invalidDestination, missingStagedFile
        case installationFailed(message: String, retainedFiles: [URL])

        public var errorDescription: String? {
            switch self {
            case .invalidLibrary: return "资料库文件夹不可用。"
            case .unsupportedItem(let name): return "暂不能粘贴文件夹或文件包：" + name
            case .sourceChanged(let name): return "复制过程中原文件发生变化，请重新粘贴：" + name
            case .invalidDestination: return "归档位置必须是当前资料库内的页面文件夹。"
            case .missingStagedFile: return "粘贴的临时文件已不存在，请重新复制后粘贴。"
            case .installationFailed(let message, let retained):
                return retained.isEmpty ? message : "部分文件已经归档并保留（\(retained.count) 个），尚未全部加入页面：" + message
            }
        }
    }

    public struct Entry: Sendable {
        public let filename: String
        /// The resolved original path; nil for clipboard bytes without a file.
        public let sourceURL: URL?
        public let isReference: Bool
        fileprivate let stagedURL: URL?
    }

    /// Transfer this value from the copy task to the UI task. Call install once,
    /// then cleanup, serially. Cleanup never removes installed files.
    public struct Prepared: Sendable {
        public let entries: [Entry]
        public let libraryRoot: URL
        private let stagingDirectory: URL?
        private let stagingToken: String?

        fileprivate init(entries: [Entry], libraryRoot: URL, stagingDirectory: URL?, stagingToken: String?) {
            self.entries = entries; self.libraryRoot = libraryRoot
            self.stagingDirectory = stagingDirectory; self.stagingToken = stagingToken
        }

        /// Re-resolve the destination at commit time, after a possible sidebar move.
        /// The caller can similarly relocate library references by stable file ID.
        public func install(into destination: URL, referenceReplacements: [URL: URL] = [:]) throws -> [URL] {
            let fm = FileManager.default
            let destination = destination.standardizedFileURL
            try ClipboardArchive.validateDestination(destination, root: libraryRoot)
            // Validate all references/staged files before installing any new file.
            var references: [Int: URL] = [:]
            for (i, entry) in entries.enumerated() {
                if entry.isReference, let source = entry.sourceURL {
                    let url = referenceReplacements[source] ?? source
                    _ = try FileIndexPolicy.path(for: url, inside: libraryRoot)
                    references[i] = url.standardizedFileURL.resolvingSymlinksInPath()
                } else {
                    guard let staged = entry.stagedURL, let directory = stagingDirectory,
                          staged.deletingLastPathComponent() == directory,
                          (try? staged.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map({ $0.isRegularFile == true && $0.isSymbolicLink != true }) == true else {
                        throw ArchiveError.missingStagedFile
                    }
                }
            }
            var result: [URL] = [], installed: [URL] = []
            do {
                for (i, entry) in entries.enumerated() {
                    if let reference = references[i] { result.append(reference); continue }
                    let directory = destination.appendingPathComponent(ClipboardArchive.category(for: entry.filename), isDirectory: true)
                    try ClipboardArchive.validateDestination(directory, root: libraryRoot)
                    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                    try ClipboardArchive.validateDestination(directory, root: libraryRoot)
                    let target = try ClipboardArchive.availableURL(filename: entry.filename, in: directory)
                    // A final validation catches an existing category symlink that
                    // would otherwise redirect the original outside this library.
                    guard ReferencePath.relative(target, inside: libraryRoot) != nil else { throw ArchiveError.invalidDestination }
                    try fm.moveItem(at: entry.stagedURL!, to: target)
                    installed.append(target); result.append(target)
                }
                return result
            } catch {
                // Keep successful archives even if a later rename or index save
                // fails. They are independent originals now, not scratch files.
                throw ArchiveError.installationFailed(message: error.localizedDescription, retainedFiles: installed)
            }
        }

        public func cleanup() {
            guard let directory = stagingDirectory, let token = stagingToken else { return }
            ClipboardArchive.removeOwnedStaging(directory, token: token)
        }
    }

    /// Run off the main actor. Only copied outside files or raw clipboard bytes
    /// create staging files; library references do not read any source bytes.
    public static func prepare(_ inputs: [Input], libraryRoot: URL) throws -> Prepared {
        let fm = FileManager.default
        let root = libraryRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard root.isFileURL, (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { throw ArchiveError.invalidLibrary }
        var entries: [Entry] = [], seen: Set<String> = []
        var staging: URL?, token: String?
        func stagingURL() throws -> URL {
            if let staging { return staging }
            let value = UUID().uuidString
            let directory = root.appendingPathComponent(".libere-paste-" + value, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            staging = directory; token = value
            try Data(value.utf8).write(to: directory.appendingPathComponent(".owner"), options: .withoutOverwriting)
            return directory
        }
        do {
            for input in inputs {
                try Task.checkCancellation()
                switch input {
                case .libraryReference(let original):
                    let source = original.standardizedFileURL.resolvingSymlinksInPath()
                    try validateReferenceLocation(source, root: root)
                    guard seen.insert(source.path).inserted else { continue }
                    entries.append(Entry(filename: source.lastPathComponent, sourceURL: source, isReference: true, stagedURL: nil))
                case .file(let original):
                    guard original.isFileURL else { throw ArchiveError.unsupportedItem(original.lastPathComponent) }
                    let accessed = original.startAccessingSecurityScopedResource()
                    defer { if accessed { original.stopAccessingSecurityScopedResource() } }
                    let source = original.standardizedFileURL.resolvingSymlinksInPath()
                    guard seen.insert(source.path).inserted else { continue }
                    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey])
                    guard values.isRegularFile == true, values.isPackage != true else { throw ArchiveError.unsupportedItem(original.lastPathComponent) }
                    if ReferencePath.relative(source, inside: root) != nil {
                        _ = try FileIndexPolicy.path(for: source, inside: root)
                        entries.append(Entry(filename: source.lastPathComponent, sourceURL: source, isReference: true, stagedURL: nil))
                        continue
                    }
                    let filename = safeFilename(original.lastPathComponent)
                    let staged = try stagingURL().appendingPathComponent(UUID().uuidString)
                    try fm.copyItem(at: source, to: staged)
                    try Task.checkCancellation()
                    let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let copied = try staged.resourceValues(forKeys: [.fileSizeKey])
                    guard values.fileSize == after.fileSize, values.contentModificationDate == after.contentModificationDate,
                          copied.fileSize == after.fileSize else { throw ArchiveError.sourceChanged(filename) }
                    entries.append(Entry(filename: filename, sourceURL: source, isReference: false, stagedURL: staged))
                case .data(let data, let name):
                    let filename = safeFilename(name)
                    let staged = try stagingURL().appendingPathComponent(UUID().uuidString)
                    try data.write(to: staged, options: .withoutOverwriting)
                    entries.append(Entry(filename: filename, sourceURL: nil, isReference: false, stagedURL: staged))
                }
            }
            return Prepared(entries: entries, libraryRoot: root, stagingDirectory: staging, stagingToken: token)
        } catch {
            if let staging, let token { removeOwnedStaging(staging, token: token) }
            throw error
        }
    }

    public static func category(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "PDF"
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp", "svg", "avif", "ico", "raw", "dng": return "图片"
        case "ipynb": return "Notebook"
        case "py", "pyw": return "Python"
        case "md", "markdown": return "Markdown"
        case "html", "htm", "webarchive", "webloc", "url": return "网页"
        case "csv", "tsv", "json", "yaml", "yml", "toml", "xml", "parquet", "sqlite", "sqlite3", "db", "h5", "hdf5", "feather", "npy", "npz": return "数据"
        case "doc", "docx", "ppt", "pptx", "xls", "xlsx", "pages", "numbers", "key", "rtf", "rtfd", "odt", "ods", "odp", "epub": return "文档"
        case "mp3", "wav", "m4a", "aac", "flac", "ogg", "aiff", "mp4", "mov", "m4v", "avi", "mkv", "webm", "mpeg", "mpg": return "音视频"
        case "zip", "7z", "rar", "gz", "bz2", "xz", "tar", "tgz", "dmg", "iso": return "压缩包"
        default:
            return AttachmentFormat(filename: filename) == .source || ["Makefile", "Dockerfile", ".gitignore"].contains(filename) ? "文本与源码" : "其他"
        }
    }

    private static func safeFilename(_ name: String) -> String {
        let leaf = (name.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        let clean = leaf.components(separatedBy: CharacterSet(charactersIn: ":\0").union(.controlCharacters)).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = clean.isEmpty || clean == "." || clean == ".." ? "粘贴文件" : clean
        let ext = (value as NSString).pathExtension
        guard !ext.isEmpty else { return shortened(value, maxBytes: 240) }
        let suffix = "." + shortened(ext, maxBytes: 40)
        return shortened((value as NSString).deletingPathExtension, maxBytes: 240 - suffix.utf8.count) + suffix
    }

    private static func shortened(_ value: String, maxBytes: Int) -> String {
        var result = value
        while result.utf8.count > maxBytes { result.removeLast() }
        return result
    }

    private static func availableURL(filename: String, in directory: URL) throws -> URL {
        let fm = FileManager.default
        let initial = directory.appendingPathComponent(filename)
        if !fm.fileExists(atPath: initial.path) && (try? initial.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true { return initial }
        let ext = (filename as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        let stem = ext.isEmpty ? filename : (filename as NSString).deletingPathExtension
        for counter in 2...10_000 {
            let counterText = " (\(counter))" + suffix
            let candidate = directory.appendingPathComponent(shortened(stem, maxBytes: max(1, 240 - counterText.utf8.count)) + counterText)
            if !fm.fileExists(atPath: candidate.path) && (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true { return candidate }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    private static func validateDestination(_ destination: URL, root: URL) throws {
        let resolved = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard destination.isFileURL else { throw ArchiveError.invalidDestination }
        if resolved != root {
            guard let path = ReferencePath.relative(resolved, inside: root) else { throw ArchiveError.invalidDestination }
            let parts = path.split(separator: "/"), first = parts.first.map(String.init) ?? ""
            guard !parts.contains(where: { $0.hasPrefix(".") }), !["Assets", "Sync", "Recoveries"].contains(first),
                  path != "Projects/index.json", path != "workspace.json", path != "workspace.previous.json",
                  !(first.hasPrefix("History-") && first.hasSuffix(".json")) else { throw ArchiveError.invalidDestination }
        }
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &directory), !directory.boolValue { throw ArchiveError.invalidDestination }
    }

    /// Same location restrictions as FileIndexPolicy, deliberately without its
    /// existence/regular-file check. install applies the full policy afterwards.
    private static func validateReferenceLocation(_ source: URL, root: URL) throws {
        guard source.isFileURL, let path = ReferencePath.relative(source, inside: root) else { throw FileIndexError.outsideLibrary }
        let first = path.components(separatedBy: "/").first ?? ""
        guard !["Assets", "Sync"].contains(first), path != "Projects/index.json",
              path != "workspace.json", path != "workspace.previous.json",
              !(first.hasPrefix("History-") && first.hasSuffix(".json")), !first.hasPrefix(".") else {
            throw FileIndexError.reservedPath
        }
    }

    private static func removeOwnedStaging(_ directory: URL, token: String) {
        let fm = FileManager.default
        guard directory.lastPathComponent == ".libere-paste-" + token,
              (try? fm.attributesOfItem(atPath: directory.path)[.type]) as? FileAttributeType == .typeDirectory,
              (try? Data(contentsOf: directory.appendingPathComponent(".owner"))) == Data(token.utf8) else { return }
        try? fm.removeItem(at: directory)
    }
}
