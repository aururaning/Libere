import Foundation

public enum AttachmentFormat: CaseIterable, Sendable {
    case source, markdown, html, notebook, image

    public var extensions: [String] {
        switch self {
        case .source: return ["py", "swift", "js", "ts", "css", "sh", "r", "jl", "c", "h", "cpp", "java", "rs", "go", "sql", "txt", "log", "json", "yaml", "yml", "toml", "xml", "csv", "tsv"]
        case .markdown: return ["md", "markdown"]
        case .html: return ["html", "htm"]
        case .notebook: return ["ipynb"]
        case .image: return ["png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp"]
        }
    }

    public var isTextEditable: Bool {
        switch self {
        case .source, .markdown, .html: return true
        case .notebook, .image: return false
        }
    }

    public init?(filename: String) {
        let ext = (filename as NSString).pathExtension.lowercased()
        guard let match = Self.allCases.first(where: { $0.extensions.contains(ext) }) else { return nil }
        self = match
    }

    public enum PreviewError: LocalizedError {
        case encoding, notebook, image
        public var errorDescription: String? {
            switch self {
            case .encoding: return "无法识别文本编码，请使用 UTF-8 或带字节序标记的 UTF-16。"
            case .notebook: return "无法读取 Notebook 的单元格，请检查文件是否为 Jupyter Notebook v4。"
            case .image: return "图片使用原生预览，不能作为文本打开。"
            }
        }
    }

    public func document(at url: URL) throws -> String {
        guard self != .image else { throw PreviewError.image }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let body: String
        if self == .notebook {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["nbformat"] as? Int == 4, let cells = object["cells"] as? [[String: Any]] else { throw PreviewError.notebook }
            body = cells.map(Self.cell).joined()
        } else {
            let text = try EditableText(data: data).text
            switch self {
            case .source: body = Self.code(text)
            case .markdown: body = Markdown.body(text)
            case .html: body = text
            case .notebook, .image: preconditionFailure()
            }
        }
        return Self.htmlDocument(body)
    }

    public static func outputsDocument(_ outputs: [[String: Any]]) -> String { htmlDocument(outputs.map(output).joined()) }
    public static func htmlDocument(_ body: String) -> String {
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none'">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html{color-scheme:light}body{margin:12px;display:flow-root;color:#23352e;font:15px/1.55 -apple-system,sans-serif;overflow-wrap:anywhere}
        pre,code{font:13px/1.5 ui-monospace,Menlo,monospace}pre{white-space:pre-wrap;tab-size:4}section+section{border-top:1px solid #d8e2dc;margin-top:12px}
        small{color:#486655}blockquote{padding-left:10px;border-left:3px solid #819b88;margin-left:0}img{max-width:100%;height:auto}td,th{padding:3px 7px;border:1px solid #d8e2dc}table{border-collapse:collapse}</style>
        </head><body>\(body)</body></html>
        """
    }

    private static func text(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        return (value as? [String])?.joined()
    }

    private static func code(_ value: String) -> String { "<pre><code>\(Formula.escape(value))</code></pre>" }

    private static func cell(_ cell: [String: Any]) -> String {
        let source = text(cell["source"]) ?? ""
        if cell["cell_type"] as? String == "markdown" { return "<section>\(Markdown.body(source))</section>" }
        guard cell["cell_type"] as? String == "code" else { return "<section>\(code(source))</section>" }
        let count = (cell["execution_count"] as? Int).map(String.init) ?? " "
        let outputs = (cell["outputs"] as? [[String: Any]] ?? []).map(output).joined()
        return "<section><small>In [\(count)]</small>\(code(source))\(outputs)</section>"
    }

    private static func output(_ item: [String: Any]) -> String {
        if let stream = text(item["text"]) { return code(stream) }
        if item["output_type"] as? String == "error" {
            let trace = (item["traceback"] as? [String])?.joined(separator: "\n")
            return code(trace ?? [item["ename"], item["evalue"]].compactMap { $0 as? String }.joined(separator: " · "))
        }
        let mime = item["data"] as? [String: Any] ?? [:]
        if let svg = text(mime["image/svg+xml"]) {
            return "<img alt=\"矢量输出\" src=\"data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString())\">"
        }
        for type in ["image/png", "image/jpeg"] {
            if let encoded = text(mime[type]), let image = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) {
                return "<img alt=\"单元格输出\" src=\"data:\(type);base64,\(image.base64EncodedString())\">"
            }
        }
        if let markdown = text(mime["text/markdown"]) { return Markdown.body(markdown) }
        if let html = text(mime["text/html"]) { return html }
        if let plain = text(mime["text/plain"]) { return code(plain) }
        return "<p>此输出类型暂不能预览。</p>"
    }
}
