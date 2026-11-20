import SwiftUI
import WebKit
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import MarginCore
#endif

extension AttachmentFormat {
    static var importTypes: [UTType] {
        // System image identifiers remain available without filename registration
        // lookups, including the first run in a restricted process.
        [.pdf, .png, .jpeg, .heic, .heif, .gif, .tiff, .bmp, .webP]
            + allCases.filter { $0 != .image }.flatMap(\.extensions).compactMap { UTType(filenameExtension: $0) }
    }
}

@MainActor struct AttachmentPreview: View {
    let url: URL
    let filename: String
    @ViewState private var result: Result<String, Error>?
    @ViewState private var imageResult: Result<AttachmentImage, Error>?

    var body: some View {
        if !FileManager.default.fileExists(atPath: url.path) {
            ContentUnavailableView("附件尚未下载", systemImage: "icloud.and.arrow.down")
        } else {
            Group {
                if AttachmentFormat(filename: filename) == .image {
                    switch imageResult {
                    case .success(let image):
                        GeometryReader { viewport in
                            let width = max(1, viewport.size.width)
                            ScrollView([.horizontal, .vertical]) {
                                Image(decorative: image.image, scale: 1).resizable().interpolation(.high)
                                    .frame(width: width, height: width * image.size.height / image.size.width)
                                    .accessibilityLabel(filename)
                            }
                        }
                    case .failure(let error): Text(error.localizedDescription).font(.caption).padding()
                    case nil: ProgressView()
                    }
                } else {
                    switch result {
                    case .success(let html): AttachmentWebView(html: html)
                    case .failure(let error): Text(error.localizedDescription).font(.caption).padding()
                    case nil: ProgressView()
                    }
                }
            }.task(id: "\(url.absoluteString)-\(filename)") {
                result = nil; imageResult = nil
                guard let format = AttachmentFormat(filename: filename) else { return }
                if format == .image {
                    let rendered = await Task.detached(priority: .userInitiated) { Result { try AttachmentImage.load(from: url) } }.value
                    if !Task.isCancelled { imageResult = rendered }
                } else {
                    let rendered = await Task.detached(priority: .userInitiated) { Result { try format.document(at: url) } }.value
                    if !Task.isCancelled { result = rendered }
                }
            }
        }
    }
}

@MainActor final class AttachmentNavigation: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var html: String?
    private(set) var measurementID = UUID().uuidString
    var heightChanged: ((CGFloat) -> Void)?
    static let measurementScript = """
    (() => {
      const token = document.querySelector('meta[name="libere-attachment-id"]')?.content;
      if (!token || !document.body) return;
      const report = () => {
        const body = document.body, style = getComputedStyle(body);
        const height = Math.max(body.getBoundingClientRect().height, body.scrollHeight) + parseFloat(style.marginTop || 0) + parseFloat(style.marginBottom || 0);
        window.webkit.messageHandlers.libereAttachmentHeight.postMessage({token, height: Math.ceil(height)});
      };
      new ResizeObserver(report).observe(document.body);
      document.fonts?.ready.then(report); report();
    })();
    """
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let data = message.body as? [String: Any],
              data["token"] as? String == measurementID, let height = data["height"] as? Double,
              height.isFinite, height > 0 else { return }
        heightChanged?(min(100_000, max(240, height)))
    }
    func makeView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "libereAttachmentHeight")
        config.userContentController.addUserScript(WKUserScript(source: Self.measurementScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        #if os(macOS)
        let view = AttachmentContentWebView(frame: .zero, configuration: config)
        #else
        let view = WKWebView(frame: .zero, configuration: config)
        #endif
        view.navigationDelegate = self
        #if os(iOS)
        view.isOpaque = false; view.backgroundColor = .white
        #endif
        return view
    }
    func load(_ document: String, in view: WKWebView) {
        if html != document {
            html = document; measurementID = UUID().uuidString
            view.loadHTMLString(document.replacingOccurrences(of: "</head>", with: "<meta name=\"libere-attachment-id\" content=\"\(measurementID)\"></head>"), baseURL: nil)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let localDocument = action.navigationType == .other && action.targetFrame?.isMainFrame == true
            && action.request.url?.absoluteString == "about:blank"
        decisionHandler(localDocument ? .allow : .cancel)
    }
}

@MainActor struct AttachmentWebView: View {
    let html: String
    var heightChanged: ((CGFloat) -> Void)? = nil
    var body: some View { VectorWebSurface { AttachmentNativeWebView(html: html, heightChanged: heightChanged, pageScale: $0) } }
}
#if os(macOS)
@MainActor final class AttachmentContentWebView: WKWebView {
    var scrollsWithPaper = false
    override func scrollWheel(with event: NSEvent) {
        if scrollsWithPaper {
            var current = superview
            while let view = current {
                if let viewport = view as? CanvasScrollView { viewport.scrollWheel(with: event); return }
                current = view.superview
            }
        }
        super.scrollWheel(with: event)
    }
}
@MainActor struct AttachmentNativeWebView: NSViewRepresentable {
    let html: String
    var heightChanged: ((CGFloat) -> Void)? = nil
    var pageScale: CGFloat = 1
    func makeCoordinator() -> AttachmentNavigation { AttachmentNavigation() }
    func makeNSView(context: Context) -> WKWebView { context.coordinator.makeView() }
    func updateNSView(_ view: WKWebView, context: Context) {
        WebVectorScale.apply(pageScale, to: view)
        (view as? AttachmentContentWebView)?.scrollsWithPaper = heightChanged != nil
        context.coordinator.heightChanged = heightChanged; context.coordinator.load(html, in: view)
    }
}
#else
@MainActor struct AttachmentNativeWebView: UIViewRepresentable {
    let html: String
    var heightChanged: ((CGFloat) -> Void)? = nil
    var pageScale: CGFloat = 1
    func makeCoordinator() -> AttachmentNavigation { AttachmentNavigation() }
    func makeUIView(context: Context) -> WKWebView { context.coordinator.makeView() }
    func updateUIView(_ view: WKWebView, context: Context) {
        view.scrollView.isScrollEnabled = heightChanged == nil
        WebVectorScale.apply(pageScale, to: view)
        context.coordinator.heightChanged = heightChanged; context.coordinator.load(html, in: view)
    }
}
#endif
