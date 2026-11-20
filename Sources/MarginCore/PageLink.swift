import Foundation

/// Stable, library-local links keep a folder directory usable after page renames.
public enum PageLink {
    public static func url(for id: UUID) -> URL { URL(string: "libere://page/\(id.uuidString)")! }
    public static func noteID(in url: URL) -> UUID? {
        guard url.scheme?.lowercased() == "libere", url.host?.lowercased() == "page",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return nil }
        let path = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 2, path[0].isEmpty else { return nil }
        return UUID(uuidString: String(path[1]))
    }
    public static func markdown(title: String, id: UUID) -> String {
        let title = title.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        let escaped = title.reduce(into: "") { result, c in
            if "\\`*_{}[]()#+-.!$|~=".contains(c) { result.append("\\") }
            result.append(c)
        }
        return "[\(escaped)](\(url(for: id).absoluteString))"
    }
}
