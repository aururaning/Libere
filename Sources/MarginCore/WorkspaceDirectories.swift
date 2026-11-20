import Foundation

/// Human-readable working files mirror the page hierarchy; immutable originals stay in Assets.
public final class WorkspaceDirectories {
    public let root: URL
    private let repository: Repository
    private var paths: [String: String] = [:]
    private var sources: [String: String] = [:]
    public init(repository: Repository) {
        self.repository = repository; root = repository.root.appendingPathComponent("Projects", isDirectory: true)
        if let data = try? Data(contentsOf: root.appendingPathComponent("index.json")),
           let object = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            paths = object["pages"] ?? [:]; sources = object["files"] ?? [:]
        }
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
    public func directory(for noteID: UUID, in workspace: Workspace) -> URL {
        var chain: [Note] = [], current: UUID? = noteID, visited: Set<UUID> = []
        while let id = current, visited.insert(id).inserted, let note = workspace.notes.first(where: { $0.id == id }) {
            chain.insert(note, at: 0); current = note.parentID
        }
        var directory = root
        if chain.contains(where: \.deleted) { directory.appendPathComponent("回收站", isDirectory: true) }
        for note in chain { directory.appendPathComponent(Self.safeName(note.title) + "__" + note.id.uuidString.prefix(8), isDirectory: true) }
        return directory
    }
    public func notebookURL(for block: Block, noteID: UUID, in workspace: Workspace) -> URL {
        fileURL(for: block, noteID: noteID, in: workspace)
    }
    public func fileURL(for block: Block, noteID: UUID, in workspace: Workspace) -> URL {
        directory(for: noteID, in: workspace).appendingPathComponent("文件/" + Self.category(block.assetName), isDirectory: true)
            .appendingPathComponent(filename(block))
    }
    private func filename(_ block: Block) -> String {
        let ext = (block.assetName as NSString).pathExtension
        let name = Self.safeName((block.assetName as NSString).deletingPathExtension)
        return name + "__" + block.id.uuidString.prefix(8) + (ext.isEmpty ? "" : "." + ext)
    }
    public func synchronize(_ workspace: Workspace) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let ordered = workspace.notes.sorted { directory(for: $0.id, in: workspace).pathComponents.count < directory(for: $1.id, in: workspace).pathComponents.count }
        for note in ordered {
            let destination = directory(for: note.id, in: workspace)
            let relative = String(destination.path.dropFirst(root.path.count + 1))
            if let old = paths[note.id.uuidString], old != relative {
                let source = root.appendingPathComponent(old)
                if fm.fileExists(atPath: source.path) && !fm.fileExists(atPath: destination.path) {
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: source, to: destination)
                    for (id, path) in paths where path == old || path.hasPrefix(old + "/") { paths[id] = relative + path.dropFirst(old.count) }
                    for key in Array(sources.keys) where key.hasPrefix(old + "/") { sources[relative + key.dropFirst(old.count)] = sources.removeValue(forKey: key) }
                }
            }
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            paths[note.id.uuidString] = relative
            for block in note.blocks where block.isFilePlugin && block.reference == nil && block.relativeFilePath == nil {
                guard let original = block.assetID else { continue }
                let category = Self.category(block.assetName)
                let path = relative + "/文件/" + category + "/" + filename(block)
                try mirror(block.displayAssetID ?? original, to: path)
                if block.displayAssetID != original { try mirror(original, to: relative + "/原件/" + category + "/" + filename(block)) }
            }
        }
        let data = try JSONEncoder().encode(["pages": paths, "files": sources])
        let index = root.appendingPathComponent("index.json")
        if (try? Data(contentsOf: index)) != data { try Repository.writeAtomically(data, to: index) }
    }
    private func mirror(_ id: UUID, to path: String) throws {
        let fm = FileManager.default, target = root.appendingPathComponent(path), source = repository.asset(id)
        guard fm.fileExists(atPath: source.path) else { return }
        if sources[path] == id.uuidString && fm.fileExists(atPath: target.path) { return }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) {
            // Keep externally edited working files before advancing an app-owned snapshot.
            if let prior = sources[path], let old = UUID(uuidString: prior),
               (try? AssetFingerprint.read(target)) == (try? AssetFingerprint.read(repository.asset(old))) {
                try Repository.writeAtomically(Data(contentsOf: source), to: target)
            } else if try AssetFingerprint.read(target) != AssetFingerprint.read(source) {
                let preserved = target.deletingPathExtension().appendingPathExtension("external-" + UUID().uuidString.prefix(8) + "." + target.pathExtension)
                try fm.moveItem(at: target, to: preserved)
                try fm.copyItem(at: source, to: target)
            }
        } else { try fm.copyItem(at: source, to: target) }
        sources[path] = id.uuidString
    }
}
