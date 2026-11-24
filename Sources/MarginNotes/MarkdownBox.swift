import SwiftUI
import WebKit
#if SWIFT_PACKAGE
import MarginCore
#endif

@MainActor struct MarkdownBox: View {
    @ObservedObject var store: AppStore
    let block: Block
    private var editing: Bool { store.editingBlockID == block.id }
    @ViewState private var wikiCompletion: WikiLinkCompletion?
    private var interacting: Bool { store.interactingBlockID == block.id }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                #if os(macOS)
                if editing { Color.clear }
                else { CanvasPointerSurface(area: .body(block.id)) }
                #else
                Color.clear.contentShape(Rectangle())
                    .gesture(SpatialTapGesture(coordinateSpace: .named("note-paper")).onEnded { store.tapCanvas(at: $0.location) })
                #endif
                if block.usesMarkdown && !editing {
                    Button(interacting ? "拖动模式" : "链接交互") {
                        if interacting { store.interactingBlockID = nil }
                        else {
                            if store.blockSelection != block.id { store.selectBlock(block.id, keyboard: false) }
                            store.interactingBlockID = block.id
                        }
                    }.help("链接交互允许直接点击预览链接；拖动模式保留正文拖动。")
                }
                Button(editing ? "预览" : "编辑") {
                    if editing { store.selectBlock(block.id) }
                    else { store.beginBlockEditing(block.id) }
                }
            }.font(.system(size: 11)).buttonStyle(.plain).padding(.horizontal, 10).frame(height: 30)
            if editing || !block.usesMarkdown {
                RichTextEditor(block: block, formatting: store.formatting, focus: { store.beginBlockEditing(block.id) },
                               checkpoint: { store.checkpoint() }, changeStyle: { action in style(action) },
                               editable: editing, requestFocus: editing, measuredHeight: store.growTextBlock,
                               wikiProvider: { query in WikiLinks.candidates(in: store.workspace, query: query, excluding: store.selection) },
                               wikiSelectionChanged: { text, caret in wikiCompletion = WikiLinks.completion(in: text, caretUTF16: caret) }) { rtf, source in
                    store.editBlock(block.id) { $0.text = source; $0.rtf = rtf }
                }
            } else {
                MarkdownWebView(html: Markdown.document(WikiLinks.renderingSource(block.text, in: store.workspace), size: block.fontSize, font: block.fontFamily, tint: block.tint), layoutWidth: block.frame.width, measuredHeight: { width, height in
                    guard abs(width - block.frame.width) < 2 else { return }
                    store.growTextBlock(block, contentHeight: height)
                }, openPage: store.openLinkedPage).allowsHitTesting(interacting)
                    .help("按住 ⌘ 单击打开链接；普通拖动仍移动内容块。输入 [[ 可补全页面引用。")
            }
        }
        #if os(iOS)
        .overlay(alignment: .bottomLeading) {
            if editing, let completion = wikiCompletion {
                let candidates = WikiLinks.candidates(in: store.workspace, query: completion.query, excluding: store.selection, limit: 6)
                if !candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(candidates) { candidate in
                            Button { insertWiki(candidate) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.title).font(.subheadline)
                                    Text(candidate.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }.frame(maxWidth: 360).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(6)
                }
            }
        }
        #endif
        .onChange(of: editing) { _, active in if !active { wikiCompletion = nil } }
    }
    #if os(iOS)
    private func insertWiki(_ candidate: WikiLinkCandidate) {
        guard editing, let view = store.formatting.view, view.markedTextRange == nil,
              let completion = WikiLinks.completion(in: view.text ?? "", caretUTF16: view.selectedRange.location),
              let start = view.position(from: view.beginningOfDocument, offset: completion.range.location),
              let end = view.position(from: start, offset: completion.range.length), let range = view.textRange(from: start, to: end) else { return }
        store.formatting.beforeChange?(); view.replace(range, withText: candidate.markdown)
        view.selectedRange = NSRange(location: completion.range.location + candidate.markdown.utf16.count, length: 0)
        store.formatting.didChange?(); wikiCompletion = nil; view.becomeFirstResponder()
    }
    #endif
    private func style(_ action: TextAction) {
        store.editBlock(block.id) { block in
            switch action {
            case .grow(let step): block.fontSize = min(96, max(10, block.fontSize + step))
            case .font(let name): block.fontFamily = name
            case .fontStyle(let name, let size): block.fontFamily = name; block.fontSize = min(96,max(10,size))
            default: break
            }
        }
    }
}

@MainActor final class MarkdownNavigation: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var html = ""
    var measurementID = UUID().uuidString
    private var layoutWidth: Double?
    var measuredHeight: ((Double, Double) -> Void)?
    var openPage: ((UUID) -> Void)?
    @discardableResult func openPageLink(_ url: URL) -> Bool {
        guard let id = PageLink.noteID(in: url), let openPage else { return false }
        openPage(id); return true
    }
    static let measurementScript = """
    (() => {
      const content = document.getElementById('libere-content');
      const token = document.querySelector('meta[name="libere-layout-id"]')?.content;
      if (!content || !token) return;
      let queued = false;
      const report = () => {
        if (queued) return; queued = true;
        requestAnimationFrame(() => {
          queued = false;
          window.webkit.messageHandlers.libereHeight.postMessage({token,
            width: document.body.getBoundingClientRect().width,
            height: Math.ceil(content.getBoundingClientRect().height + 24)});
        });
      };
      window.libereMeasure = report;
      new ResizeObserver(report).observe(content);
      document.fonts?.ready.then(report); report();
    })();
    """
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let data = message.body as? [String: Any],
              data["token"] as? String == measurementID,
              let width = data["width"] as? Double, let height = data["height"] as? Double,
              width.isFinite, height.isFinite else { return }
        measuredHeight?(width, height)
    }
    func configure() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "libereHeight")
        config.userContentController.addUserScript(WKUserScript(source: Self.measurementScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        return config
    }
    func update(_ view: WKWebView, html: String, width: Double?, report: ((Double, Double) -> Void)?) {
        measuredHeight = report
        if self.html != html {
            self.html = html; measurementID = UUID().uuidString
            let page = html.replacingOccurrences(of: "</head>", with: "<meta name=\"libere-layout-id\" content=\"\(measurementID)\"></head>")
            view.loadHTMLString(page, baseURL: nil)
        } else if layoutWidth != width, report != nil {
            // A drag can finish at the already-rendered width. Request one fresh report
            // after the stored frame catches up, even if ResizeObserver has no new event.
            view.evaluateJavaScript("window.libereMeasure?.()", completionHandler: nil)
        }
        layoutWidth = width
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url, PageLink.noteID(in: url) != nil {
            openPageLink(url); decisionHandler(.cancel)
        } else if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
           ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
            decisionHandler(.cancel)
        } else { decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel) }
    }
}
@MainActor struct MarkdownWebView: View {
    let html: String
    var layoutWidth: Double? = nil
    var measuredHeight: ((Double, Double) -> Void)? = nil
    var openPage: ((UUID) -> Void)? = nil
    var body: some View { VectorWebSurface { MarkdownNativeWebView(html: html, pageScale: $0, layoutWidth: layoutWidth, measuredHeight: measuredHeight, openPage: openPage) } }
}
#if os(macOS)
@MainActor struct MarkdownNativeWebView: NSViewRepresentable {
    let html: String
    var pageScale: CGFloat = 1
    var layoutWidth: Double? = nil
    var measuredHeight: ((Double, Double) -> Void)? = nil
    var openPage: ((UUID) -> Void)? = nil
    func makeCoordinator() -> MarkdownNavigation { MarkdownNavigation() }
    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: context.coordinator.configure()); view.navigationDelegate = context.coordinator; return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.openPage = openPage
        WebVectorScale.apply(pageScale, to: view)
        context.coordinator.update(view, html: html, width: layoutWidth, report: measuredHeight)
    }
}
#else
@MainActor struct MarkdownNativeWebView: UIViewRepresentable {
    let html: String
    var pageScale: CGFloat = 1
    var layoutWidth: Double? = nil
    var measuredHeight: ((Double, Double) -> Void)? = nil
    var openPage: ((UUID) -> Void)? = nil
    func makeCoordinator() -> MarkdownNavigation { MarkdownNavigation() }
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: context.coordinator.configure()); view.navigationDelegate = context.coordinator; view.isOpaque = false; view.backgroundColor = .clear; return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.openPage = openPage
        WebVectorScale.apply(pageScale, to: view)
        context.coordinator.update(view, html: html, width: layoutWidth, report: measuredHeight)
    }
}
#endif
