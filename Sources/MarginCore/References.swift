import Foundation

public enum FileIndexError: LocalizedError {
    case indexOnly, outsideLibrary, reservedPath, missingFile
    public var errorDescription: String? {
        switch self {
        case .indexOnly: return "资料库只保存文件索引。请先手动把文件放入资料库文件夹，再选择该文件。"
        case .outsideLibrary: return "请选择当前资料库文件夹内的文件；请先手动移动文件，再建立索引。"
        case .reservedPath: return "这个位置用于保存资料库索引，不能作为资料文件添加。"
        case .missingFile: return "找不到这个原文件。请先将文件放回资料库中的原位置。"
        }
    }
}

public enum FileIndexPolicy {
    public static func path(for url: URL, inside root: URL) throws -> String {
        guard let path = ReferencePath.relative(url, inside: root) else { throw FileIndexError.outsideLibrary }
        let first = path.components(separatedBy: "/").first ?? ""
        guard !["Assets", "Sync"].contains(first), path != "Projects/index.json",
              path != "workspace.json", path != "workspace.previous.json",
              !(first.hasPrefix("History-") && first.hasSuffix(".json")), !first.hasPrefix(".") else {
            throw FileIndexError.reservedPath
        }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else { throw FileIndexError.missingFile }
        return path
    }
}

public enum ReferencePath {
    public static func relative(_ url: URL, inside root: URL) -> String? {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(base) else { return nil }
        return String(path.dropFirst(base.count))
    }
    public static func resolve(_ path: String, inside root: URL) -> URL? {
        guard !path.hasPrefix("/"), !path.components(separatedBy: "/").contains("..") else { return nil }
        let url = root.appendingPathComponent(path)
        guard relative(url, inside: root) != nil else { return nil }; return url
    }
    public static func title(of noteID: UUID, in workspace: Workspace) -> [String] {
        var titles: [String] = [], current: UUID? = noteID, visited: Set<UUID> = []
        while let id = current, visited.insert(id).inserted, let note = workspace.notes.first(where: { $0.id == id }) {
            titles.insert(note.title, at: 0); current = note.parentID
        }
        return titles
    }
}
