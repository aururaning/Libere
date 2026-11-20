import Foundation

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
