import XCTest
@testable import MarginCore

final class MarkdownTests: XCTestCase {
    func testTextAndMathShareOneParagraph() {
        let html = Markdown.body("中文 **结论**：$e^{i\\pi}+1=0$，==重点==。")
        XCTAssertTrue(html.contains("display=\"inline\""))
        XCTAssertTrue(html.contains("<strong>结论</strong>"))
        XCTAssertTrue(html.contains("<mark>重点</mark>"))
    }
    func testBlockMathAndCodeRemainSeparate() {
        XCTAssertTrue(Markdown.body("$$\n\\frac{x}{y}\n$$").contains("<mfrac>"))
        let code = Markdown.body("```latex\n$x$ <script>\n```")
        XCTAssertFalse(code.contains("<math"))
        XCTAssertTrue(code.contains("&lt;script&gt;"))
    }
    func testHTMLAndScriptLinksCannotExecute() {
        let html = Markdown.body("<script>evil()</script> [a](javascript:evil) [b](https://example.com)")
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("href=\"javascript:"))
        XCTAssertTrue(html.contains("href=\"https://example.com\""))
    }
    func testOlderTextBoxesKeepRichTextMode() throws {
        let block = Block(.text, frame: Rect(0, 0, 300, 180), text: "以前的笔记")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(block)) as! [String: Any]
        json.removeValue(forKey: "textFormat")
        let old = try JSONDecoder().decode(Block.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(old.usesMarkdown)
        XCTAssertEqual(old.text, block.text)
    }
}
