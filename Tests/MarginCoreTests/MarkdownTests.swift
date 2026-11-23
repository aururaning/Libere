import XCTest
@testable import MarginCore

final class MarkdownTests: XCTestCase {
    private func count(_ needle: String, in html: String) -> Int { html.components(separatedBy: needle).count - 1 }

    func testInlineDelimitersAndAdjacentFormulas() {
        let html = Markdown.body(#"中文 \(a_i^2 + b_i^2\)，以及 $c_i$ 与 $x$$y$。"#)
        XCTAssertEqual(count("display=\"inline\"", in: html), 4)
        XCTAssertTrue(html.contains("<msubsup>"))
        XCTAssertFalse(html.contains("math-error"))
        XCTAssertFalse(html.contains("<em>"))
    }
    func testDisplayDelimitersOnOneOrMultipleLines() {
        for text in [#"$$\frac{x_i}{y}$$"#, #"\[\frac{x_i}{y}\]"#,
                     "$$\n\\frac{x_i}{y}\n$$", "\\[\n\\frac{x_i}{y}\n\\]"] {
            let html = Markdown.body("前文\n" + text + "\n后文")
            XCTAssertEqual(count("display=\"block\"", in: html), 1, text)
            XCTAssertTrue(html.contains("<mfrac>"), text)
            XCTAssertTrue(html.hasPrefix("<p>前文</p>"), text)
            XCTAssertTrue(html.hasSuffix("<p>后文</p>"), text)
        }
        let suffix = Markdown.body(#"\[x\] 后续 **文字**"#)
        XCTAssertTrue(suffix.hasSuffix("<p> 后续 <strong>文字</strong></p>"))
    }
    func testMathAndCodeDoNotCloseOuterMarkdownEmphasis() {
        let html = Markdown.body(#"_说明 $x_i + y_i$ 结束_ **结果 \(a**b\)** _内含 `x_y` 的文字_"#)
        XCTAssertEqual(count("<em>", in: html), 2)
        XCTAssertEqual(count("<strong>", in: html), 1)
        XCTAssertEqual(count("<math ", in: html), 2)
        XCTAssertTrue(html.contains("<code>x_y</code>"))
        XCTAssertFalse(html.contains("math-error"))
        XCTAssertEqual(Markdown.inline("variable_name_here"), "variable_name_here")
    }
    func testPipesInsideMathCodeAndEscapesDoNotSplitTableCells() {
        let html = Markdown.body(#"| 公式 | 说明 |"# + "\n| --- | --- |\n" + #"| $P(A|B)$ | `a|b` 与 \| 字符 |"#)
        XCTAssertEqual(count("<td>", in: html), 2)
        XCTAssertEqual(count("<math ", in: html), 1)
        XCTAssertTrue(html.contains("<mo>|</mo>"))
        XCTAssertTrue(html.contains("<code>a|b</code> 与 | 字符"))
    }
    func testEscapedMathDelimitersAndCurrencyStayLiteral() {
        XCTAssertEqual(Markdown.inline(#"\$5 和 \$10"#), "$5 和 $10")
        XCTAssertFalse(Markdown.inline("价格 $5，另一项 $10").contains("<math"))
        XCTAssertFalse(Markdown.inline("$x\n正文$").contains("<math"))
        XCTAssertEqual(Markdown.inline(#"\\(不是公式\\)"#), #"\(不是公式\)"#)
        let math = Markdown.body(#"\(\text{价格 \$5}\)"#)
        XCTAssertEqual(count("<math ", in: math), 1)
    }
    func testCodeSpansUseMatchingBacktickRunsAndPreserveMath() {
        XCTAssertEqual(Markdown.inline("``unclosed ` code"), "``unclosed ` code")
        let html = Markdown.inline(#"`` `$x$` 与 \(y\) `` 和 `\` 与 $z$"#)
        XCTAssertTrue(html.contains(#"<code>`$x$` 与 \(y\)</code>"#))
        XCTAssertTrue(html.contains(#"<code>\</code>"#))
        XCTAssertEqual(count("<math ", in: html), 1)
    }
    func testFencedCodeKeepsMathLiteralAcrossShorterFences() {
        for fence in ["````", "~~~~"] {
            let html = Markdown.body(fence + "text\n$x$\n```\n\\[y\\]\n" + fence + "\n$z$")
            XCTAssertEqual(count("<math ", in: html), 1)
            XCTAssertTrue(html.contains("$x$\n```\n\\[y\\]"))
        }
    }
    func testUnclosedDisplayMathDoesNotSwallowFollowingBlocks() {
        for opening in ["$$", "\\["] {
            let html = Markdown.body(opening + "x\n\n# 后续标题\n正文")
            XCTAssertTrue(html.contains("<h1>后续标题</h1>"))
            XCTAssertFalse(html.contains("<math "))
            XCTAssertTrue(html.contains(opening + "x"))
        }
    }
    func testInvalidMathRetainsExactDelimitersAndSafeSource() {
        let html = Markdown.body(#"\(\unsupported{<script>}\)"#)
        XCTAssertTrue(html.contains("math-error"))
        XCTAssertTrue(html.contains(#"\(\unsupported{&lt;script&gt;}\)"#))
        XCTAssertFalse(html.contains("<script>"))
    }
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
