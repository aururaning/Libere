import AppKit
import WebKit

@MainActor final class MathProbeLoad: NSObject, WKNavigationDelegate {
    var finished = false
    var error: Error?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.error = error; finished = true }
}
/// Offline WebKit regression for generated math; no user windows or UI events.
/// Compile from the project root with the Apple SDK:
/// xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0
///   Sources/MarginCore/*.swift Scripts/MathRenderChecks.swift -o .build/MathRenderChecks
/// Then run .build/MathRenderChecks. Evidence is written under .build/validation.
@main @MainActor struct MathRenderChecks {
    static func main() async {
        do { try await run() }
        catch { fputs("UNVERIFIED: \(error.localizedDescription)\n", stderr); exit(2) }
    }
    static func run() async throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: ".build/validation"), withIntermediateDirectories: true)
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 660, height: 1100), configuration: configuration)
        let delegate = MathProbeLoad(); web.navigationDelegate = delegate
        let source = #"""
        # Markdown 公式回归
        中文行内 $x_i^2+y_i^2$，以及 \(\frac{a+b}{\sqrt{c}}\)。

        $$\sum\limits_{i=1}^{n} x_i = \frac{n(n+1)}{2}$$

        \[\begin{aligned}a&=b+c\\d&=\text{a \& b}\end{aligned}\]

        | 条件概率 | 代码 |
        | --- | --- |
        | $P(A|B)$ | `a|b` |

        _强调中的 $x_i$ 保持完整。_

        希腊标识符 \(\alpha\beta+\mathrm{cm}\)。

        \[\begin{cases}x & \text{if }x>0\\0 & \text{otherwise}\end{cases}\]

        | 运算 | 表达示例 |
        | --- | --- |
        | $\oplus$ / $\bigoplus$ | $\mathbf{h}_i=\bigoplus_{\ell=0}^{L_{\max}}\mathbf{h}_i^{(\ell)}$ |
        | $\odot$ | $\mathbf{g}_i^{\mathrm{dst}}\odot\mathbf{x}$ |
        | $\otimes_{\mathrm{CG}}$ | $\mathbf{h}_i\otimes_{\mathrm{CG}}Y(\hat{\mathbf{r}}_{ij})$ |
        | $(\cdot)^\top$ | $\mathbf{a}^\top\mathbf{b}$ |
        | $(\cdot)^\dagger$ | $\mathbf{B}^\dagger$ |
        """#
        web.loadHTMLString(Markdown.document(source, size: 22), baseURL: nil)
        for _ in 0..<200 where !delegate.finished { try await Task.sleep(nanoseconds: 50_000_000) }
        if let error = delegate.error { throw error }
        guard delegate.finished else { throw NSError(domain: "MathProbe", code: 1, userInfo: [NSLocalizedDescriptionKey:"WebKit fixture load timed out"]) }
        let value = try await web.evaluateJavaScript("""
        (() => ({math:Array.from(document.querySelectorAll('math')).map(e=>({display:e.getAttribute('display'),width:e.getBoundingClientRect().width,height:e.getBoundingClientRect().height,text:e.textContent})), errors:document.querySelectorAll('.math-error').length, tableCells:document.querySelectorAll('td').length, code:document.querySelector('code').textContent}))()
        """) as! [String: Any]
        let math = value["math"] as! [[String:Any]]
        precondition(math.count == 19 && value["errors"] as? Int == 0)
        precondition(value["tableCells"] as? Int == 12 && value["code"] as? String == "a|b")
        for element in math { precondition((element["width"] as! NSNumber).doubleValue > 5 && (element["height"] as! NSNumber).doubleValue > 5) }
        let snapshot = try await web.takeSnapshot(configuration: nil)
        if let tiff = snapshot.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using:.png,properties:[:]) {
            try png.write(to: URL(fileURLWithPath:".build/validation/math-render.png"))
        }
        delegate.finished = false; delegate.error = nil
        web.loadHTMLString(Markdown.document(#"\(\text{if}\)\(\text{if }\)\(\text{ if }\)"#, size: 22), baseURL: nil)
        for _ in 0..<200 where !delegate.finished { try await Task.sleep(nanoseconds: 50_000_000) }
        if let error = delegate.error { throw error }
        guard delegate.finished else { throw NSError(domain: "MathProbe", code: 2, userInfo: [NSLocalizedDescriptionKey:"WebKit spacing fixture load timed out"]) }
        let widths = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('mtext')).map(e=>e.getBoundingClientRect().width)") as! [NSNumber]
        precondition(widths.count == 3 && widths[1].doubleValue > widths[0].doubleValue + 2 && widths[2].doubleValue > widths[1].doubleValue + 2,
                     "Leading and trailing text spaces must have visible width inside MathML")
        var report = value; report["textWidths"] = widths
        let data = try JSONSerialization.data(withJSONObject:report, options:[.prettyPrinted,.sortedKeys])
        try data.write(to: URL(fileURLWithPath:".build/validation/math-render.json"))
        print("PASS: 19 formula layouts plus 3 text-spacing fixtures rendered in WebKit; tensor operators, table/code, inline/display and text spacing preserved")
    }
}
