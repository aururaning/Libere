import SwiftUI
import WebKit
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import MarginCore
#endif

extension AttachmentFormat {
    static var importTypes: [UTType] {
        // Eligibility is a regular-file/path policy, not a preview-format list.
        // Directories remain rejected by FileIndexPolicy and file-picker options.
        [.data]
    }
}

struct GenericFileDescriptor: Equatable {
    let filename: String
    var kind: String {
        let ext = (filename as NSString).pathExtension
        return ext.isEmpty ? "文件" : ext.uppercased() + " 文件"
    }
}

/// An index for an unsupported format never feeds its bytes to a text decoder or
/// launches an application merely because its card became visible.
@MainActor struct GenericFilePreview: View {
    let url: URL
    let filename: String
    var openFile: ((URL) -> Void)? = nil
    private var descriptor: GenericFileDescriptor { GenericFileDescriptor(filename: filename.isEmpty ? url.lastPathComponent : filename) }
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text(descriptor.filename).font(.headline).lineLimit(3).multilineTextAlignment(.center)
            Text(descriptor.kind).font(.caption).foregroundStyle(.secondary)
            Text("此格式可通过系统应用打开。").font(.caption).foregroundStyle(.secondary)
            #if os(macOS)
            Button("打开原文件", action: openOriginal).buttonStyle(.borderedProminent)
                .accessibilityIdentifier("generic-file-open")
            #else
            ShareLink(item: url) { Label("用其他应用打开", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent)
            #endif
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("generic-file-preview")
    }
    func openOriginal() {
        guard url.isFileURL else { return }
        if let openFile { openFile(url); return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #endif
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
