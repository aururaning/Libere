import Foundation

/// Original files move together with their sidebar owners. The journal contains
/// paths only; no source-file snapshots or mirrors are produced.
public struct FileHierarchyTransaction: Codable {
    public struct Move: Codable, Equatable {
        public var source: String
        public var destination: String
        var staging: String
    }
    public let id: UUID
    public var moves: [Move]
    public var directories: [String]
    private static let journalName = ".libere-file-moves.json"

    public static func commonDirectory(_ paths: [String]) -> String? {
        guard let first = paths.first else { return nil }
        var result = Array(first.split(separator: "/").dropLast())
        for path in paths.dropFirst() {
            let parts = Array(path.split(separator: "/").dropLast())
            result = Array(zip(result, parts).prefix { $0 == $1 }.map { $0.0 })
        }
        return result.isEmpty ? nil : result.joined(separator: "/")
    }
    /// Infer existing archive ownership from indexes, without opening the files.
    public static func bindExisting(_ workspace: inout Workspace, legacyDirectories: [String: String] = [:]) {
        var own: [UUID: [String]] = [:], children: [UUID: [UUID]] = [:]
        var claimed: Set<String> = []
        for note in workspace.notes {
            if let parent = note.parentID { children[parent, default: []].append(note.id) }
            for block in note.blocks where block.reference == nil {
                if let path = block.relativeFilePath, claimed.insert(path).inserted { own[note.id, default: []].append(path) }
            }
        }
        var memo: [UUID: [String]] = [:]
        func files(_ id: UUID, seen: Set<UUID>) -> [String] {
            if let cached = memo[id] { return cached }
            guard !seen.contains(id) else { return [] }
            var seen = seen; seen.insert(id)
            let result = (own[id] ?? []) + (children[id] ?? []).flatMap { files($0, seen: seen) }
            memo[id] = result; return result
        }
        var usedDirectories: Set<String> = []
        let lookup = Dictionary(workspace.notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func depth(_ id: UUID) -> Int {
            var cursor: UUID? = id, visited: Set<UUID> = []
            while let next = cursor, visited.insert(next).inserted { cursor = lookup[next]?.parentID }
            return visited.count
        }
        for i in workspace.notes.indices.sorted(by: { depth(workspace.notes[$0].id) < depth(workspace.notes[$1].id) }) {
            let note = workspace.notes[i]
            if let path = note.managedDirectoryPath { usedDirectories.insert(path); continue }
            if note.managedFilePath != nil { continue }
            let direct = own[note.id] ?? []
            if !note.isFolder, direct.count == 1,
               note.blocks.count == 1 || note.title == (direct[0] as NSString).lastPathComponent {
                workspace.notes[i].managedFilePath = direct[0]; continue
            }
            let paths = files(note.id, seen: [])
            if let common = commonDirectory(paths), usedDirectories.insert(common).inserted {
                workspace.notes[i].managedDirectoryPath = common
            } else if paths.isEmpty, let old = legacyDirectories[note.id.uuidString] {
                workspace.notes[i].managedDirectoryPath = "Projects/" + old
            }
        }
    }
    public static func directoryPath(for id: UUID?, in workspace: Workspace) -> String {
        let lookup = Dictionary(workspace.notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var cursor = id, components: [String] = [], seen: Set<UUID> = []
        while let next = cursor, seen.insert(next).inserted, let note = lookup[next] {
            if let directory = note.managedDirectoryPath { return ([directory] + components).joined(separator: "/") }
            if let file = note.managedFilePath { return ([((file as NSString).deletingLastPathComponent)] + components).filter { !$0.isEmpty }.joined(separator: "/") }
            components.insert(WorkspaceDirectories.safeName(note.title), at: 0); cursor = note.parentID
        }
        return components.joined(separator: "/")
    }
    private static func joined(_ base: String, _ name: String) -> String { base.isEmpty ? name : base + "/" + name }
    private static func rewrite(_ path: String, with moves: [Move]) -> String {
        guard let move = moves.sorted(by: { $0.source.count > $1.source.count }).first(where: { path == $0.source || path.hasPrefix($0.source + "/") }) else { return path }
        return move.destination + path.dropFirst(move.source.count)
    }
    public static func plan(from before: Workspace, to candidate: inout Workspace, root: URL, restoringFilePaths: [UUID: String] = [:]) throws -> Self {
        let id = UUID(), lookup = Dictionary(before.notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var moves: [Move] = [], directories: Set<String> = []
        func add(_ source: String, _ destination: String) {
            guard source != destination, !moves.contains(where: { $0.source == source }) else { return }
            let stage = ".libere-move-" + UUID().uuidString
            moves.append(Move(source: source, destination: destination, staging: stage))
        }
        let changed = candidate.notes.filter { note in
            guard let old = lookup[note.id] else { return false }
            return old.title != note.title || old.parentID != note.parentID
        }
        for note in changed {
            guard let old = lookup[note.id] else { continue }
            let name = WorkspaceDirectories.safeName(note.title)
            if let file = old.managedFilePath {
                let parent = old.parentID == note.parentID ? (file as NSString).deletingLastPathComponent : directoryPath(for: note.parentID, in: candidate)
                let ext = (file as NSString).pathExtension
                let filename = old.title == note.title ? (file as NSString).lastPathComponent
                    : (name as NSString).pathExtension.isEmpty && !ext.isEmpty ? name + "." + ext : name
                add(file, joined(parent, filename))
            } else {
                let parent = old.parentID == note.parentID && old.managedDirectoryPath != nil
                    ? (old.managedDirectoryPath! as NSString).deletingLastPathComponent : directoryPath(for: note.parentID, in: candidate)
                let directoryName = old.title == note.title ? old.managedDirectoryPath.map { ($0 as NSString).lastPathComponent } ?? name : name
                let target = joined(parent, directoryName)
                if let source = old.managedDirectoryPath, FileManager.default.fileExists(atPath: root.appendingPathComponent(source).path) { add(source, target) }
                else {
                    guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(target).path) else {
                        throw NSError(domain: "FileHierarchy", code: 1, userInfo: [NSLocalizedDescriptionKey: "目标位置已存在同名文件夹：" + target])
                    }
                    directories.insert(target)
                }
                let ids = before.descendants(note.id)
                let owned = before.notes.filter { ids.contains($0.id) }.flatMap(\.blocks)
                    .filter { $0.reference == nil }.compactMap(\.relativeFilePath)
                let childDirectories = before.notes.filter { $0.id != note.id && ids.contains($0.id) }
                    .compactMap(\.managedDirectoryPath).filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
                // Including directory entries themselves keeps their names in the
                // relative layout when a virtual category acquires a real folder.
                let common = commonDirectory(owned + childDirectories)
                for path in Set(childDirectories) {
                    if let source = old.managedDirectoryPath, path.hasPrefix(source + "/"), moves.contains(where: { $0.source == source }) { continue }
                    let suffix = common.map { String(path.dropFirst($0.count + 1)) } ?? (path as NSString).lastPathComponent
                    add(path, joined(target, suffix))
                }
                for path in Set(owned) {
                    if let source = old.managedDirectoryPath, path.hasPrefix(source + "/"), moves.contains(where: { $0.source == source }) { continue }
                    let suffix = common.map { String(path.dropFirst($0.count + 1)) } ?? (path as NSString).lastPathComponent
                    add(path, joined(target, suffix))
                }
                if let i = candidate.notes.firstIndex(where: { $0.id == note.id }) { candidate.notes[i].managedDirectoryPath = target }
            }
        }
        // Undo restores exact original locations, including loose files that were
        // gathered into a page directory by the forward operation.
        if !changed.isEmpty, !restoringFilePaths.isEmpty {
            for block in before.notes.flatMap(\.blocks) {
                guard let source = block.relativeFilePath, let destination = restoringFilePaths[block.fileIdentity] else { continue }
                moves.removeAll { $0.source == source }
                add(source, destination)
            }
        }
        // A moved directory carries its descendants; do not stage its children twice.
        moves = moves.filter { move in !moves.contains { other in
            other.source != move.source && move.source.hasPrefix(other.source + "/")
                && move.destination == other.destination + move.source.dropFirst(other.source.count)
        } }
        for move in moves {
            guard !move.destination.hasPrefix(move.source + "/"),
                  ReferencePath.resolve(move.source, inside: root) != nil,
                  ReferencePath.resolve(move.destination, inside: root) != nil else { throw FileIndexError.outsideLibrary }
        }
        for i in candidate.notes.indices {
            if let path = candidate.notes[i].managedDirectoryPath { candidate.notes[i].managedDirectoryPath = rewrite(path, with: moves) }
            if let path = candidate.notes[i].managedFilePath { candidate.notes[i].managedFilePath = rewrite(path, with: moves) }
            for b in candidate.notes[i].blocks.indices {
                if let path = candidate.notes[i].blocks[b].relativeFilePath {
                    let next = rewrite(path, with: moves)
                    candidate.notes[i].blocks[b].relativeFilePath = next
                    if path != next { candidate.notes[i].blocks[b].assetName = (next as NSString).lastPathComponent }
                }
            }
        }
        for move in moves { directories.insert((move.destination as NSString).deletingLastPathComponent) }
        if !moves.isEmpty || !directories.isEmpty { candidate.fileMoveTransactionID = id }
        return Self(id: id, moves: moves, directories: directories.filter { !$0.isEmpty }.sorted())
    }
    public var hasChanges: Bool { !moves.isEmpty || !directories.isEmpty }
    public func execute(at root: URL) throws {
        guard hasChanges else { return }
        let fm = FileManager.default
        var targets: Set<String> = []
        for move in moves {
            let source = root.appendingPathComponent(move.source), target = root.appendingPathComponent(move.destination)
            guard fm.fileExists(atPath: source.path) else { throw FileIndexError.missingFile }
            let sourceID = (try? source.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
            let targetID = (try? target.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
            let sameEntry = sourceID != nil && targetID != nil && sourceID!.isEqual(targetID!)
            guard targets.insert(move.destination.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  !fm.fileExists(atPath: target.path) || sameEntry else {
                throw NSError(domain: "FileHierarchy", code: 1, userInfo: [NSLocalizedDescriptionKey: "目标位置已存在同名文件或文件夹：" + move.destination + "。请先改名，原文件尚未移动。"])
            }
        }
        guard !fm.fileExists(atPath: root.appendingPathComponent(Self.journalName).path) else { throw StoreError.corrupt }
        try Repository.writeAtomically(JSONEncoder().encode(self), to: root.appendingPathComponent(Self.journalName))
        do {
            for move in moves.sorted(by: { $0.source.count > $1.source.count }) {
                try fm.moveItem(at: root.appendingPathComponent(move.source), to: root.appendingPathComponent(move.staging))
            }
            // Install a parent directory before adding independently indexed files
            // beneath it; creating that destination too early would block rename.
            for move in moves.sorted(by: { $0.destination.split(separator: "/").count < $1.destination.split(separator: "/").count }) {
                let destination = root.appendingPathComponent(move.destination)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: root.appendingPathComponent(move.staging), to: destination)
            }
            for path in directories {
                guard let url = ReferencePath.resolve(path, inside: root) else { throw FileIndexError.outsideLibrary }
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
        } catch { try rollback(at: root); throw error }
    }
    public func rollback(at root: URL) throws {
        let fm = FileManager.default
        for move in moves {
            guard [move.source, move.destination, move.staging].allSatisfy({ ReferencePath.resolve($0, inside: root) != nil }) else { throw FileIndexError.outsideLibrary }
        }
        // Separate files out of their completed destination directories first,
        // then restore parents before children. This also handles partial staging.
        for move in moves.sorted(by: { $0.destination.count > $1.destination.count }) {
            let source = root.appendingPathComponent(move.source), staged = root.appendingPathComponent(move.staging), destination = root.appendingPathComponent(move.destination)
            guard !fm.fileExists(atPath: staged.path), fm.fileExists(atPath: destination.path) else { continue }
            if fm.fileExists(atPath: source.path) {
                let a = (try? source.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
                let b = (try? destination.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
                guard a != nil && b != nil && a!.isEqual(b!) else { throw StoreError.attachmentMismatch }
            }
            try fm.moveItem(at: destination, to: staged)
        }
        for move in moves.sorted(by: { $0.source.count < $1.source.count }) {
            let source = root.appendingPathComponent(move.source), staged = root.appendingPathComponent(move.staging)
            guard fm.fileExists(atPath: staged.path) else { continue }
            guard !fm.fileExists(atPath: source.path) else { throw StoreError.attachmentMismatch }
            try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: staged, to: source)
        }
        try finish(at: root)
    }
    public func finish(at root: URL) throws {
        let url = root.appendingPathComponent(Self.journalName)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    public static func recover(at root: URL, workspace: Workspace?) throws {
        let journal = root.appendingPathComponent(journalName)
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        let transaction = try JSONDecoder().decode(Self.self, from: Data(contentsOf: journal))
        if workspace?.fileMoveTransactionID == transaction.id { try transaction.finish(at: root) }
        else { try transaction.rollback(at: root) }
    }
    public func relocated(_ path: String) -> String { Self.rewrite(path, with: moves) }
}
