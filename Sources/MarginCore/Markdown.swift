import Foundation

/// Offline Markdown and math renderer. Raw HTML is always escaped; no remote scripts or assets are loaded.
public enum Markdown {
    public static func body(_ source: String) -> String {
        return blocks(source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"), depth: 0)
    }
    public static func document(_ source: String, size: Double = 18, font: String? = nil, tint: String = "paper") -> String {
        let family: String
        switch font {
        case "Songti SC": family = "'Songti SC',serif"
        case "PingFang SC": family = "'PingFang SC',sans-serif"
        case "Menlo": family = "Menlo,monospace"
        default:
            if let font, font != "system", !font.isEmpty {
                let safe = String(font.unicodeScalars.filter { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_")).contains($0) })
                family = "'\(safe)',sans-serif"
            } else { family = "-apple-system,BlinkMacSystemFont,sans-serif" }
        }
        let background: String
        switch tint { case "gray", "yellow": background = "#f5f5f7"; case "blue", "green": background = "#ebf2ff"; default: background = "#fff" }
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <style>
        html,body{margin:0;background:\(background);color:#1a1c21}body{font-family:\(family);font-size:\(min(96,max(10,size)))px;line-height:1.65;padding:12px;overflow-wrap:anywhere}
        p{margin:0 0 .75em}p:last-child{margin-bottom:0}h1,h2,h3,h4,h5,h6{line-height:1.3;margin:.65em 0 .4em}h1{font-size:1.7em}h2{font-size:1.4em}h3{font-size:1.2em}
        ul,ol{padding-left:1.5em;margin:.5em 0}li{margin:.2em 0}blockquote{margin:.6em 0;padding:.25em .8em;border-left:3px solid #2657c7;background:#ebf2ff}
        mark{background:#ffed9a;padding:0 .1em}code,pre{font-family:Menlo,monospace;font-size:.88em;background:#f0f1f3;border-radius:4px}code{padding:.1em .25em}pre{padding:10px;overflow-x:auto;white-space:pre;overflow-wrap:normal}pre code{padding:0;background:none}
        math[display=inline]{font-size:1.05em}math[display=block]{margin:.7em 0;max-width:100%;overflow-x:auto}.math-error{color:#4b5563;font-family:Menlo,monospace;border-bottom:1px dotted #4b5563}
        table{border-collapse:collapse;max-width:100%;font-size:.9em;margin:.6em 0}th,td{border:1px solid #d5d9e0;padding:5px 8px}th{background:#f0f2f6}a{color:#2657c7}hr{border:0;border-top:1px solid #d5d9e0;margin:1em 0}.task{list-style:none;margin-left:-1.1em}
        #libere-content{display:flow-root;min-width:0}
        </style></head><body><div id="libere-content">\(body(source))</div></body></html>
        """
    }
    private static func math(_ source: String, display: Bool) -> String {
        do { return try Formula.render(source, display: display) }
        catch { return "<span class=\"math-error\" title=\"\(Formula.escape(error.localizedDescription))\">\(Formula.escape((display ? "$$" : "$") + source + (display ? "$$" : "$")))</span>" }
    }
    private static func heading(_ line: String) -> (Int, String)? {
        let marks = line.prefix { $0 == "#" }.count
        guard (1...6).contains(marks), line.dropFirst(marks).first == " " else { return nil }
        return (marks, String(line.dropFirst(marks + 1)))
    }
    private static func listItem(_ line: String) -> (ordered: Bool, text: String)? {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("- ") || text.hasPrefix("* ") || text.hasPrefix("+ ") { return (false, String(text.dropFirst(2))) }
        let digits = text.prefix { $0.isNumber }.count
        if digits > 0, text.count > digits + 1 {
            let suffix = text.dropFirst(digits)
            if suffix.hasPrefix(". ") || suffix.hasPrefix(") ") { return (true, String(suffix.dropFirst(2))) }
        }
        return nil
    }
    private static func tableCells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }; if value.hasSuffix("|") { value.removeLast() }
        return value.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    private static func isTableRule(_ line: String) -> Bool {
        let cells = tableCells(line)
        return !cells.isEmpty && cells.allSatisfy { cell in
            let plain = cell.replacingOccurrences(of: ":", with: "")
            return plain.count >= 3 && plain.allSatisfy { $0 == "-" }
        }
    }
    private static func isBoundary(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || heading(t) != nil || listItem(t) != nil || t.hasPrefix(">") || t.hasPrefix("```") || t.hasPrefix("$$") || ["---","***","___"].contains(t)
    }
    private static func blocks(_ lines: [String], depth: Int) -> String {
        guard depth < 12 else { return "<p>\(Formula.escape(lines.joined(separator: "\n")))</p>" }
        var html = ""; var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { i += 1; continue }
            if line.hasPrefix("```") {
                i += 1; var code: [String] = []
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(lines[i]); i += 1 }
                if i < lines.count { i += 1 }
                html += "<pre><code>\(Formula.escape(code.joined(separator: "\n")))</code></pre>"; continue
            }
            if line.hasPrefix("$$") {
                var content = String(line.dropFirst(2)); i += 1
                if let end = content.range(of: "$$") {
                    html += math(String(content[..<end.lowerBound]), display: true)
                    let rest = String(content[end.upperBound...]); if !rest.isEmpty { html += "<p>\(inline(rest))</p>" }
                } else {
                    var closed = false
                    while i < lines.count {
                        if let end = lines[i].range(of: "$$") {
                            content += "\n" + String(lines[i][..<end.lowerBound]); let rest = String(lines[i][end.upperBound...]); i += 1
                            html += math(content, display: true)
                            if !rest.isEmpty { html += "<p>\(inline(rest))</p>" }; closed = true; break
                        }
                        content += "\n" + lines[i]; i += 1
                    }
                    if !closed { html += "<p>\(Formula.escape("$$" + content))</p>" }
                }
                continue
            }
            if let (level, text) = heading(line) { html += "<h\(level)>\(inline(text))</h\(level)>"; i += 1; continue }
            if ["---", "***", "___"].contains(line) { html += "<hr>"; i += 1; continue }
            if line.hasPrefix(">") {
                var quote: [String] = []
                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var text = String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()); if text.hasPrefix(" ") { text.removeFirst() }
                    quote.append(text); i += 1
                }
                html += "<blockquote>\(blocks(quote, depth: depth + 1))</blockquote>"; continue
            }
            if let item = listItem(line) {
                let tag = item.ordered ? "ol" : "ul"; html += "<\(tag)>"
                while i < lines.count, let row = listItem(lines[i]), row.ordered == item.ordered {
                    let t = row.text
                    if t.hasPrefix("[ ] ") || t.lowercased().hasPrefix("[x] ") {
                        html += "<li class=\"task\">\(t.lowercased().hasPrefix("[x]") ? "☑" : "☐") \(inline(String(t.dropFirst(4))))</li>"
                    } else { html += "<li>\(inline(t))</li>" }
                    i += 1
                }
                html += "</\(tag)>"; continue
            }
            if i + 1 < lines.count, line.contains("|"), isTableRule(lines[i + 1]) {
                let columns = tableCells(line); html += "<table><thead><tr>" + columns.map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>"; i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    let cells = tableCells(lines[i]); html += "<tr>" + (0..<columns.count).map { "<td>\(inline($0 < cells.count ? cells[$0] : ""))</td>" }.joined() + "</tr>"; i += 1
                }
                html += "</tbody></table>"; continue
            }
            var paragraph = [lines[i]]; i += 1
            while i < lines.count && !isBoundary(lines[i]) {
                if i + 1 < lines.count && lines[i].contains("|") && isTableRule(lines[i + 1]) { break }
                paragraph.append(lines[i]); i += 1
            }
            html += "<p>\(inline(paragraph.joined(separator: "\n")))</p>"
        }
        return html
    }
    public static func inline(_ source: String) -> String { inline(source, depth: 0) }
    private static func inline(_ source: String, depth: Int) -> String {
        guard depth < 12 else { return Formula.escape(source) }
        let chars = Array(source); var i = 0; var result = ""
        func matches(_ token: String, _ at: Int) -> Bool {
            let part = Array(token); return at + part.count <= chars.count && Array(chars[at..<(at + part.count)]) == part
        }
        func closing(_ token: String, from start: Int) -> Int? {
            var j = start
            while j < chars.count {
                if chars[j] == "\\" { j += 2; continue }
                if matches(token, j) { return j }; j += 1
            }
            return nil
        }
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count, "\\`*_{}[]()#+-.!$|~=".contains(chars[i + 1]) {
                result += Formula.escape(String(chars[i + 1])); i += 2; continue
            }
            if chars[i] == "`" {
                let token = matches("``", i) ? "``" : "`"
                if let end = closing(token, from: i + token.count) { result += "<code>\(Formula.escape(String(chars[(i + token.count)..<end])))</code>"; i = end + token.count; continue }
            }
            if chars[i] == "$" {
                let token = matches("$$", i) ? "$$" : "$"
                if let end = closing(token, from: i + token.count), end > i + token.count {
                    result += math(String(chars[(i + token.count)..<end]), display: token.count == 2); i = end + token.count; continue
                }
            }
            if chars[i] == "[", let labelEnd = closing("](", from: i + 1), let urlEnd = closing(")", from: labelEnd + 2) {
                let label = String(chars[(i + 1)..<labelEnd]), link = String(chars[(labelEnd + 2)..<urlEnd])
                if let url = URL(string: link), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") || PageLink.noteID(in: url) != nil {
                    result += "<a href=\"\(Formula.escape(link))\" rel=\"noreferrer\">\(inline(label, depth: depth + 1))</a>"
                } else { result += inline(label, depth: depth + 1) }
                i = urlEnd + 1; continue
            }
            var formatted = false
            for (token, tag) in [("**","strong"),("__","strong"),("~~","del"),("==","mark"),("*","em"),("_","em")] {
                if matches(token, i), let end = closing(token, from: i + token.count), end > i + token.count {
                    result += "<\(tag)>\(inline(String(chars[(i + token.count)..<end]), depth: depth + 1))</\(tag)>"; i = end + token.count; formatted = true; break
                }
            }
            if formatted { continue }
            result += chars[i] == "\n" ? "<br>" : Formula.escape(String(chars[i])); i += 1
        }
        return result
    }
}
