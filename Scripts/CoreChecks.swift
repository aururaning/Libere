import Foundation

@main struct CoreChecks {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        var pdf = Block(.pdf, frame: Rect(300, 100, 300, 500))
        let anchor = AnnotationAnchor(ownerID: pdf.id, label: "左批注", u: -0.1, v: 0.2, edge: .trailing)
        check(CanvasLayout.anchored(Rect(0, 0, 220, 120), at: anchor, blocks: [pdf]) == Rect(50, 200, 220, 120), "Trailing anchor")
        pdf.frame.x += 40
        check(CanvasLayout.point(anchor, blocks: [pdf])!.x == 310, "Attachment-relative movement")
        var canvas = Note(title: "Canvas"); canvas.blocks = [pdf]; canvas.anchors = [anchor]
        check(CanvasLayout.nearest(to: Rect(95, 206, 220, 120), note: canvas, tolerance: 12)?.id == anchor.id, "Nearest anchor")
        var text = Block(.text, frame: Rect(90, 200, 220, 120)); text.anchorID = anchor.id; canvas.blocks.append(text)
        check(CanvasLayout.nearest(to: text.frame, note: canvas, tolerance: 20) == nil, "Occupied anchor")
        check(CanvasLayout.vacant(Rect(20, 20, 300, 180), paper: .a4, occupied: [Rect(20, 20, 754, 1083)]) == nil, "Finite page capacity")
        canvas.ink = Data([1, 2]); check(CanvasLayout.rearranged(canvas) == nil, "Preserve annotated layout")
        canvas.inkBounds = Rect(10, 2200, 200, 100); check(canvas.height > 2300, "Long page height")
        let parent = Note(title: "Parent", folder: true); let child = Note(title: "Child", parent: parent.id)
        check(!Workspace(notes: [parent, child]).canMove(parent.id, to: child.id), "Hierarchy cycle prevention")
        var base = Note(title: "Original"); base.touch("seed")
        var a = base; a.title = "Mac"; a.touch("Mac")
        var b = base; b.title = "iPad"; b.ink = Data([3]); b.touch("iPad")
        check(NoteMerge.merge(base, a).primary == a, "Causal update")
        let ab = NoteMerge.merge(a, b), ba = NoteMerge.merge(b, a)
        check(ab.primary == ba.primary && ab.conflict == ba.conflict && ab.conflict != nil, "Concurrent merge convergence")
        check(NoteMerge.merge(ab.primary, a).conflict == nil && NoteMerge.merge(ab.primary, b).conflict == nil, "Idempotent retries")
        a.deleted = true; check(!NoteMerge.merge(a, b).primary.deleted, "Concurrent edit survives deletion")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MarginCoreCheck-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try Repository(root: root)
        var workspace = Workspace(notes: [canvas, b]); workspace.pending = ["page_" + b.id.uuidString]
        try repo.save(workspace)
        let loaded = try repo.load(); check(loaded == workspace, "Workspace round trip")
        try Data("broken".utf8).write(to: repo.workspaceURL)
        var protected = false
        do { try repo.save(workspace) } catch { protected = true }
        check(protected, "Corrupt file preserved")
        for source in ["e^{i\\pi}+1=0", "\\frac{1}{3}", "\\sqrt[3]{x}", "\\begin{pmatrix}1&2\\\\3&4\\end{pmatrix}"] {
            let rendered = try Formula.render(source); check(rendered.contains("<math"), "Formula rendering")
        }
        var rejected = false; do { _ = try Formula.render("\\unsupported{x}") } catch { rejected = true }
        check(rejected, "Unknown LaTeX is explicit")
        let escaped = try Formula.render("\\text{<script>}")
        check(escaped.contains("&lt;script&gt;") && !escaped.contains("<script>"), "Formula escaping")
        let mixed = Markdown.body("中文与 $e^{i\\pi}+1=0$ 混排，**结论** 和 ==重点==。")
        check(mixed.contains("display=\"inline\"") && mixed.contains("<strong>结论</strong>") && mixed.contains("<mark>重点</mark>"), "Inline math and Chinese Markdown")
        let display = Markdown.body("$$\n\\frac{a}{b}\n$$\n下一段")
        check(display.contains("display=\"block\"") && display.contains("<mfrac>") && display.contains("<p>下一段</p>"), "Multiline display math")
        let code = Markdown.body("```latex\n$x$ <script>\n```\n`$y$`")
        check(!code.contains("<math") && code.contains("&lt;script&gt;") && code.contains("<code>$y$</code>"), "Code stays literal")
        let structure = Markdown.body("# 标题\n\n> 引用 $x^2$\n\n- [x] 完成\n- 待办\n\n1. 第一项")
        check(structure.contains("<h1>标题</h1>") && structure.contains("<blockquote>") && structure.contains("☑") && structure.contains("<ol>"), "Markdown blocks")
        let table = Markdown.body("| 条目 | 公式 |\n| --- | --- |\n| A | $x$ |")
        check(table.contains("<table>") && table.contains("<td>A</td>") && table.contains("display=\"inline\""), "Table formulas")
        let hostile = Markdown.body("<script>alert(1)</script> [点击](javascript:evil) [正常](https://example.com)")
        check(!hostile.contains("<script>") && !hostile.contains("href=\"javascript:") && hostile.contains("href=\"https://example.com\""), "Markdown escapes HTML and rejects script links")
        check(!Markdown.body(#"价格 \$20；未闭合 $x"#).contains("<math"), "Escaped and unmatched dollars")
        check(Markdown.body("$\\unsupported{x}$").contains("math-error"), "Unknown math preserves source")
        var markdown = Block(.text, frame: Rect(1, 2, 300, 180), text: "中文 $x_i$ **重点**")
        markdown.fontFamily = "Songti SC"; markdown.fontSize = 26
        let decoder = JSONDecoder(); let encoder = JSONEncoder()
        let roundtrip = try decoder.decode(Block.self, from: encoder.encode(markdown))
        check(roundtrip == markdown && roundtrip.usesMarkdown, "Markdown persistence")
        var oldJSON = try JSONSerialization.jsonObject(with: encoder.encode(markdown)) as! [String: Any]
        oldJSON.removeValue(forKey: "textFormat"); oldJSON.removeValue(forKey: "fontFamily")
        let old = try decoder.decode(Block.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        check(!old.usesMarkdown && old.text == markdown.text, "Legacy rich-text document compatibility")
        let styled = Markdown.document("$x$", size: 26, font: "Songti SC", tint: "yellow")
        check(styled.contains("font-size:26.0px") && styled.contains("Songti SC") && styled.contains("#f5f5f7"), "Markdown frame style")
        print("PASS: \(checks) compiled Swift core assertions")
    }
}
