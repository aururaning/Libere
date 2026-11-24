import Foundation

/// Read-only compatibility map for files produced by earlier versions.
public final class WorkspaceDirectories {
    public struct Index: Sendable {
        fileprivate var paths: [String: String]
        fileprivate var sources: [String: String]
    }
    public let root: URL
    private let repository: Repository
    private var paths: [String: String] = [:]
    private var sources: [String: String] = [:]
    public static func loadIndex(at root: URL) -> Index {
        if let data = try? Data(contentsOf: root.appendingPathComponent("Projects/index.json")),
           let object = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            return Index(paths: object["pages"] ?? [:], sources: object["files"] ?? [:])
        }
        return Index(paths: [:], sources: [:])
    }
    public init(repository: Repository, index: Index? = nil) {
        self.repository = repository; root = repository.root.appendingPathComponent("Projects", isDirectory: true)
        let loaded = index ?? Self.loadIndex(at: repository.root)
        paths = loaded.paths; sources = loaded.sources
    }
    public static func safeName(_ value: String) -> String {
        let cleaned = value.components(separatedBy: CharacterSet(charactersIn: "/\\:\0\n\r").union(.controlCharacters)).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "未命名" : cleaned).prefix(72))
    }
    public static func category(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": return "PDF"
        case "ipynb": return "Notebook"
        case "py": return "Python"
        case "html", "htm": return "网页"
        case "md", "markdown": return "Markdown"
        case "csv", "tsv", "json", "yaml", "yml", "toml", "xml": return "数据"
        default: return "文本与源码"
        }
    }
    /// Existing legacy directories remain readable, but page operations never move files.
    public func directory(for noteID: UUID, in workspace: Workspace) -> URL {
        if let path = workspace.notes.first(where: { $0.id == noteID })?.managedDirectoryPath,
           let url = ReferencePath.resolve(path, inside: repository.root) { return url }
        if let path = workspace.notes.first(where: { $0.id == noteID })?.managedFilePath,
           let url = ReferencePath.resolve(path, inside: repository.root) { return url.deletingLastPathComponent() }
        if let path = paths[noteID.uuidString], let url = ReferencePath.resolve(path, inside: root),
           FileManager.default.fileExists(atPath: url.path) { return url }
        return repository.root
    }
    public func notebookURL(for block: Block, noteID: UUID, in workspace: Workspace) -> URL {
        fileURL(for: block, noteID: noteID, in: workspace)
    }
    public func fileURL(for block: Block, noteID: UUID, in workspace: Workspace) -> URL {
        if let path = block.relativeFilePath, let url = ReferencePath.resolve(path, inside: repository.root) { return url }
        if let path = legacyPath(for: block), let url = ReferencePath.resolve(path, inside: repository.root) { return url }
        return repository.root
    }
    public func legacyPath(for block: Block) -> String? {
        guard let id = block.displayAssetID else { return nil }
        // The old index points to the human-readable working file, including external edits.
        // Do not enumerate directories or discard the other old versions.
        for path in sources.keys.sorted() where sources[path] == id.uuidString {
            if let url = ReferencePath.resolve(path, inside: root), FileManager.default.fileExists(atPath: url.path),
               let relative = ReferencePath.relative(url, inside: repository.root) { return relative }
        }
        return ReferencePath.relative(repository.asset(id), inside: repository.root)
    }
    public func indexed(_ block: Block) -> Block {
        guard block.isFilePlugin, block.displayAssetID != nil else { return block }
        var copy = block
        copy.fileID = block.fileIdentity
        copy.relativeFilePath = block.relativeFilePath ?? legacyPath(for: block)
        // A missing legacy file still has a stable relative path and can be restored manually.
        if copy.relativeFilePath != nil {
            copy.assetID = nil; copy.workingAssetID = nil; copy.notebookAssetID = nil
            copy.assetSHA256 = nil; copy.assetByteCount = nil
        }
        return copy
    }
    @discardableResult public func migrate(_ workspace: inout Workspace) -> Bool {
        let legacy = workspace.schemaVersion == 1
        var changed = workspace.schemaVersion != 3
        for page in workspace.notes.indices {
            for index in workspace.notes[page].blocks.indices {
                let before = workspace.notes[page].blocks[index], after = indexed(before)
                if before != after {
                    workspace.notes[page].blocks[index] = after; changed = true
                    workspace.pending.insert("page_" + workspace.notes[page].id.uuidString)
                }
            }
        }
        if legacy { FileHierarchyTransaction.bindExisting(&workspace, legacyDirectories: paths) }
        workspace.schemaVersion = 3
        let previous = workspace.pending
        workspace.pending = workspace.pending.filter { !$0.hasPrefix("asset_") }
        return changed || previous != workspace.pending
    }
    /// Compatibility entry point: indexes never create, mirror, move or rename source files.
    public func synchronize(_ workspace: Workspace) throws {}
}
