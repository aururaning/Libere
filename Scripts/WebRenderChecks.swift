import AppKit
import WebKit

@MainActor final class RenderLoad: NSObject, WKNavigationDelegate {
    var finished = false
    var error: Error?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.error = error; finished = true }
}

/// Offscreen renderer checks for our own generated HTML; no user pages or UI events.
@main @MainActor struct WebRenderChecks {
    static func main() async {
        do { try await run() }
        catch { fputs("UNVERIFIED: \(error.localizedDescription)\n", stderr); exit(2) }
    }
    static func run() async throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x:0,y:0,width:420,height:300), configuration: configuration)
        let load = RenderLoad(); web.navigationDelegate = load
        web.loadHTMLString(Markdown.document("中文文字、English 与 ==荧光标记==。\n\n放大后仍保持原来的换行位置，行内公式 $e^{i\\pi}+1=0$。", size:22), baseURL:nil)
        for _ in 0..<200 where !load.finished { try await Task.sleep(nanoseconds:50_000_000) }
        guard load.finished else { throw NSError(domain:"WebRenderChecks", code:1, userInfo:[NSLocalizedDescriptionKey:"WebKit did not finish loading the renderer fixture"] ) }
        if let error = load.error { throw error }
        let probe = """
        (()=>{const p=document.querySelector('p'),m=document.querySelector('math');const r=p.getBoundingClientRect();
        return {width:r.width,height:r.height,bodyHeight:document.body.scrollHeight,rootHeight:document.documentElement.scrollHeight,
                font:parseFloat(getComputedStyle(p).fontSize),mathWidth:m.getBoundingClientRect().width,
                marks:document.querySelectorAll('mark').length,text:document.body.textContent};})()
        """
        let baseline = try await web.evaluateJavaScript(probe) as! [String:Any]
        var results: [[String:Any]] = [["scale":1,"metrics":baseline]]
        for scale: CGFloat in [2,3,6,1] {
            web.setFrameSize(CGSize(width:420*scale,height:300*scale))
            WebVectorScale.apply(scale, to:web)
            try await Task.sleep(nanoseconds:100_000_000)
            let value = try await web.evaluateJavaScript(probe) as! [String:Any]
            results.append(["scale":scale,"metrics":value])
            precondition(value["text"] as? String == baseline["text"] as? String)
            precondition(value["marks"] as? Int == 1)
            precondition(web.pageZoom == scale)
            for key in ["width", "height", "font", "mathWidth", "bodyHeight"] {
                let original = (baseline[key] as! NSNumber).doubleValue
                let current = (value[key] as! NSNumber).doubleValue
                precondition(abs(original - current) < 1.5, "Zoom must preserve logical layout: \(key)")
            }
        }
        let data = try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys])
        print(String(data:data,encoding:.utf8)!)
        print("PASS: WebKit renders text, Markdown highlights and MathML at 1x/2x/3x/6x without changing logical layout")
    }
}
