import XCTest
@testable import MarginCore

final class FormulaRenderingTests: XCTestCase {
    func testLinearAlgebraAndTensorExpressionsRenderInsideMarkdownTables() throws {
        let expressions = [
            #"\oplus"#, #"\bigoplus"#, #"\odot"#, #"\otimes"#,
            #"\mathbf{h}_i = \bigoplus_{\ell=0}^{L_{\max}} \mathbf{h}_i^{(\ell)}"#,
            #"\mathbf{g}_i^{\mathrm{dst}} \odot \mathbf{x}"#,
            #"\mathrm{SiLU}(\mathbf{u}) \odot \mathbf{v}"#,
            #"\mathbf{h}_i \otimes_{\mathrm{CG}} Y(\hat{\mathbf{r}}_{ij})"#,
            #"(\cdot)^\top"#, #"\mathbf{a}^\top\mathbf{b}"#,
            #"\mathbf{D}^{-1} = \mathbf{D}^\top"#, #"\mathbf{B}^\dagger"#
        ]
        for expression in expressions { assertMathML(try Formula.render(expression, display: false)) }
        let source = "| 运算 | 表达 |\n|---|---|\n" + expressions.enumerated().map { "| \($0.offset) | $\($0.element)$ |" }.joined(separator: "\n")
        let html = Markdown.body(source)
        XCTAssertFalse(html.contains("math-error")); XCTAssertEqual(count("<math ", in: html), expressions.count)
        XCTAssertEqual(count("<td>", in: html), 2 * expressions.count)
    }

    func testLargeTensorOperatorsKeepTheirLimitsAndIdentifierStyle() throws {
        for name in ["bigoplus", "bigotimes", "bigodot", "biguplus", "bigsqcup", "bigvee", "bigwedge"] {
            let result = try Formula.render("\\" + name + #"_{i=0}^{n} x_i"#)
            XCTAssertTrue(result.contains("<munderover>")); XCTAssertTrue(result.contains("largeop=\"true\"")); assertMathML(result)
        }
        XCTAssertTrue(try Formula.render(#"\ell+\hbar"#).contains("<mi>ℓ</mi>"))
    }

    func testAdditionalFontOperatorAndRelationCommands() throws {
        for source in [#"\argmax_x \log p(x)"#, #"\mathfrak{g} \oplus \mathscr{F}"#,
                       #"a \preceq b \parallel c \mapsto d"#, #"A \setminus B \subseteq C"#,
                       #"\vartheta \thinspace \varrho \enspace \varsigma"#, #"\tr(A)+\rank(B)+\diag(C)"#] {
            assertMathML(try Formula.render(source))
        }
    }

    private func count(_ token: String, in text: String) -> Int { text.components(separatedBy: token).count - 1 }
    private func assertMathML(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(XMLParser(data: Data(text.utf8)).parse(), "Malformed MathML: " + text, file: file, line: line)
    }

    func testDollarAndBackslashDelimitersProduceTheSameFormula() throws {
        let source = #"\frac{x_i^2}{\sqrt{y}}"#
        for wrapped in [source, "$" + source + "$", "$$" + source + "$$", #"\("# + source + #"\)"#, #"\["# + source + #"\]"#] {
            XCTAssertEqual(try Formula.render(wrapped, display: false), try Formula.render(source, display: false))
        }
    }

    func testLimitModifiersKeepScriptsAttachedToTheirOperator() throws {
        let forced = try Formula.render(#"\sum\limits_{i=1}^{n} x_i"#, display: false)
        XCTAssertTrue(forced.contains(#"<munderover><mo movablelimits="false" largeop="true">∑</mo>"#))
        XCTAssertFalse(forced.contains("<mrow/>")); assertMathML(forced)
        let side = try Formula.render(#"\sum\nolimits_{i=1}^{n} x_i"#)
        XCTAssertTrue(side.contains(#"<msubsup><mo movablelimits="true" largeop="true">∑</mo>"#))
        assertMathML(side)
        XCTAssertTrue(try Formula.render(#"\lim_{x\to0} x"#).contains("<munder><mo movablelimits="))
        XCTAssertTrue(try Formula.render(#"\int_0^1 x\,dx"#).contains("<msubsup><mo>∫</mo>"))
    }

    func testGreekLettersAreAdjacentIdentifiersRatherThanSpacedOperators() throws {
        let math = try Formula.render(#"\alpha\beta+\Gamma\Delta"#, display: false)
        XCTAssertTrue(math.contains("<mi>α</mi><mi>β</mi><mo>+</mo>"))
        XCTAssertTrue(math.contains(#"<mi mathvariant="normal">Γ</mi><mi mathvariant="normal">Δ</mi>"#))
        XCTAssertFalse(math.contains("<mo>α</mo>")); assertMathML(math)
    }

    func testDisplayStyleDirectivesAreScopedAndNotEmptyScriptTargets() throws {
        let math = try Formula.render(#"\textstyle a + {\displaystyle \sum_{i=1}^n i} + b"#, display: false)
        XCTAssertTrue(math.contains(#"<mstyle displaystyle="false" scriptlevel="0">"#))
        XCTAssertTrue(math.contains(#"<mstyle displaystyle="true" scriptlevel="0">"#))
        XCTAssertTrue(math.contains("</mstyle></mrow><mo>+</mo><mi>b</mi>"))
        assertMathML(math)
    }

    func testInvisibleFenceDoesNotRenderADot() throws {
        let math = try Formula.render(#"\left.\frac{df}{dx}\right|_{x=0}"#)
        XCTAssertFalse(math.contains("<mo>.</mo>"))
        XCTAssertTrue(math.contains(#"<mo fence="true" stretchy="true">|</mo>"#)); assertMathML(math)
        XCTAssertTrue(try Formula.render("x.y").contains("<mo>.</mo>"))
    }

    func testCommonFontsAccentsAndStackedAnnotations() throws {
        for source in [#"\mathsf{ABC}+\mathtt{x}+\boldsymbol{\alpha}"#,
                       #"\underline{x}+\widehat{AB}+\widetilde{xy}"#,
                       #"\overset{a}{=}\underset{b}{x}"#,
                       #"\sum_{\substack{i=1\\i\ne j}}^n x_i"#,
                       #"\operatorname*{arg max}_{x} f(x)"#,
                       #"a\iff b\implies c\land d"#] {
            assertMathML(try Formula.render(source))
        }
        XCTAssertTrue(try Formula.render(#"x\!y"#).contains(#"width="-0.1667em""#))
    }

    func testAlignedAndCasesRespectEscapedOrGroupedSeparators() throws {
        let aligned = try Formula.render(#"\begin{aligned}x&=\text{a \& b}\\y&=2\\\end{aligned}"#)
        XCTAssertEqual(count("<mtr>", in: aligned), 2)
        XCTAssertEqual(count("<mtd>", in: aligned), 4)
        XCTAssertTrue(aligned.replacingOccurrences(of: "\u{00A0}", with: " ").contains(">a &amp; b</mtext>"))
        XCTAssertTrue(aligned.contains(#"columnalign="right left""#)); assertMathML(aligned)
        let cases = try Formula.render(#"\begin{cases}x & \text{if x>0}\\0 & \text{otherwise}\\\end{cases}"#)
        XCTAssertEqual(count("<mtr>", in: cases), 2)
        XCTAssertTrue(cases.contains(#"columnalign="left""#)); assertMathML(cases)
    }

    func testEscapedTextStaysLiteralAndUnsafeHTMLStaysEscaped() throws {
        let math = try Formula.render(#"\text{\{x\} costs \$5 \& <script>}"#)
        XCTAssertTrue(math.replacingOccurrences(of: "\u{00A0}", with: " ").contains(">{x} costs $5 &amp; &lt;script&gt;</mtext>"))
        XCTAssertFalse(math.contains("<script>")); assertMathML(math)
    }

    func testMathTextPreservesDeliberateLeadingAndTrailingWhitespace() throws {
        let math = try Formula.render(#"\text{ if }x + \text{a  b}"#)
        XCTAssertTrue(math.contains("<mtext>\u{00A0}if\u{00A0}</mtext>"))
        XCTAssertTrue(math.contains("<mtext>a\u{00A0}\u{00A0}b</mtext>"))
        assertMathML(math)
    }

    func testMalformedOrExcessivelyNestedFormulasStillFailClearly() {
        for source in [#"x^2^3"#, #"x_i_j"#, #"\unknown{x}"#, #"\frac{x}"#,
                       #"\begin{aligned}x&=1"#, String(repeating: #"\substack{"#, count: 60) + "x" + String(repeating: "}", count: 60)] {
            XCTAssertThrowsError(try Formula.render(source), source)
        }
    }
}
