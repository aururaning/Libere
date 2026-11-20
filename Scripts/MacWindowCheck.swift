import AppKit
import WebKit

/// Opt-in for the local build. Inspect only this app's own window and bundled welcome page.
@MainActor enum MacWindowCheck {
    static var fixtureRoot: URL? {
        guard Bundle.main.object(forInfoDictionaryKey: "MarginWindowCheck") as? Bool == true else { return nil }
        return Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("TestData")
    }

    static func observe(store: AppStore) async {
        let args = ProcessInfo.processInfo.arguments
        guard fixtureRoot != nil || (args.contains("--verify-window") && args.contains("--data-dir")) else { return }
        let report = store.repository.root.appendingPathComponent("window-check.json")
        var evidence: [String: Any] = ["bundle": Bundle.main.bundleURL.path,
                                       "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "",
                                       "windowVisible": false, "markdownRendered": false]
        func record() throws { try Repository.writeAtomically(JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]), to: report) }
        let samples = ["check.py", "check.html", "check.ipynb"]
        let expected = Set(store.note?.blocks.map(\.assetName).filter(samples.contains) ?? [])
        var renderedFiles = Set<String>()
        var markdownReady = false
        var strokeCounts: [Int] = []
        let probe = """
        (() => { const text = document.body?.textContent || '';
          const math = document.querySelector('math[display="inline"]');
          if (document.querySelector('strong') && document.querySelector('mark') &&
              text.includes('在同一文字框输入 Markdown') && math && math.getBoundingClientRect().width > 0) return 'markdown';
          if (document.querySelector('pre code')?.textContent.includes("print('画布源码验收')")) return 'check.py';
          if (document.querySelector('h1')?.textContent === '离线网页验收' && !document.body.hasAttribute('data-ran')) return 'check.html';
          if (document.querySelector('h1')?.textContent === '单元格验收' && text.includes('In [3]') &&
              text.includes('已保存的输出') && math) return 'check.ipynb';
          return ''; })()
        """
        for _ in 0..<80 {
            guard !Task.isCancelled else { return }
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.title == AppBrand.name }),
               let content = window.contentView, content.bounds.width > 0 {
                evidence["windowVisible"] = true
                evidence["windowNumber"] = window.windowNumber
                evidence["width"] = content.bounds.width
                evidence["height"] = content.bounds.height
                var pending = [content]
                strokeCounts = []
                while let view = pending.popLast() {
                    if let ink = view as? MacInkView { strokeCounts.append(ink.committedStrokeCount) }
                    if let web = view as? WKWebView,
                       let kind = try? await web.evaluateJavaScript(probe) as? String {
                        if kind == "markdown" { markdownReady = true }
                        else if expected.contains(kind) { renderedFiles.insert(kind) }
                    }
                    pending.append(contentsOf: view.subviews)
                }
            }
            evidence["markdownRendered"] = markdownReady
            evidence["attachmentsRendered"] = renderedFiles.sorted()
            evidence["inkStrokeCounts"] = strokeCounts
            try? record()
            if markdownReady && expected == renderedFiles {
                if Bundle.main.object(forInfoDictionaryKey: "MarginCloseAfterWindowCheck") as? Bool == true { NSApp.terminate(nil) }
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}
