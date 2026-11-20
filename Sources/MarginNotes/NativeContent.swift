import SwiftUI
import PDFKit
import WebKit
import PencilKit
#if SWIFT_PACKAGE
import MarginCore
#endif

@MainActor struct MathPreview: View {
    let source: String
    var size: Double = 24
    var body: some View {
        switch Result(catching: { try Formula.render(source) }) {
        case .success(let math):
            MathWebView(html: """
                <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
                <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
                <style>html,body{margin:0;background:transparent;color:#1a1c21}body{font-size:\(size)px;min-height:94vh;display:flex;align-items:center;justify-content:center}math{padding:8px;max-width:100%;overflow:auto}</style>
                </head><body>\(math)</body></html>
                """)
        case .failure(let error):
            VStack(alignment: .leading, spacing: 8) { Text(source).font(.system(.body, design: .monospaced)); Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary) }.padding()
        }
    }
}
@MainActor struct MathWebView: View {
    let html: String
    var body: some View { VectorWebSurface { MathNativeWebView(html: html, pageScale: $0) } }
}
final class HTMLState { var html = "" }
#if os(macOS)
@MainActor struct MathNativeWebView: NSViewRepresentable {
    let html: String
    var pageScale: CGFloat = 1
    func makeCoordinator() -> HTMLState { HTMLState() }
    func makeNSView(context: Context) -> WKWebView { WKWebView() }
    func updateNSView(_ view: WKWebView, context: Context) {
        WebVectorScale.apply(pageScale, to: view)
        if context.coordinator.html != html { context.coordinator.html = html; view.loadHTMLString(html, baseURL: nil) }
    }
}
#else
@MainActor struct MathNativeWebView: UIViewRepresentable {
    let html: String
    var pageScale: CGFloat = 1
    func makeCoordinator() -> HTMLState { HTMLState() }
    func makeUIView(context: Context) -> WKWebView { let view = WKWebView(); view.isOpaque = false; view.backgroundColor = .clear; return view }
    func updateUIView(_ view: WKWebView, context: Context) {
        WebVectorScale.apply(pageScale, to: view)
        if context.coordinator.html != html { context.coordinator.html = html; view.loadHTMLString(html, baseURL: nil) }
    }
}
#endif

@MainActor final class PDFState {
    var url: URL?
    func update(_ view: PDFView, url: URL, index: Int, full: Bool) {
        if self.url != url {
            self.url = url; view.document = PDFDocument(url: url)
            view.displayMode = full ? .singlePageContinuous : .singlePage; view.displayDirection = .vertical
            view.displaysPageBreaks = false; view.autoScales = true; view.backgroundColor = .white
        }
        if !full, let document = view.document, document.pageCount > 0,
           let page = document.page(at: min(max(0, index), document.pageCount - 1)), view.currentPage !== page { view.go(to: page) }
        if !full { view.autoScales = true }
    }
}
@MainActor struct PDFPreview: View {
    let url: URL; let index: Int; var full = false
    var body: some View {
        if FileManager.default.fileExists(atPath: url.path) { PDFNativeView(url: url, index: index, full: full) }
        else { ContentUnavailableView("附件尚未下载", systemImage: "icloud.and.arrow.down", description: Text("联网后点击同步。")) }
    }
}
#if os(macOS)
@MainActor struct PDFNativeView: NSViewRepresentable {
    let url: URL; let index: Int; let full: Bool
    func makeCoordinator() -> PDFState { PDFState() }
    func makeNSView(context: Context) -> PDFView { PDFView() }
    func updateNSView(_ view: PDFView, context: Context) { context.coordinator.update(view, url: url, index: index, full: full) }
}
@MainActor final class PDFWindow: NSObject, NSWindowDelegate {
    static let shared = PDFWindow()
    private var windows: [NSWindow] = []
    private var stores: [ObjectIdentifier: AppStore] = [:]
    func open(store: AppStore, noteID: UUID, block: Block) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = block.assetName
        window.contentView = NSHostingView(rootView: AttachmentReader(store: store, noteID: noteID, block: block, onClose: { [weak window] in window?.close() }))
        window.delegate = self; window.isReleasedWhenClosed = false
        stores[ObjectIdentifier(window)] = store
        window.collectionBehavior.insert(.fullScreenPrimary); windows.append(window); window.center(); window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { window.toggleFullScreen(nil) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { stores[ObjectIdentifier(sender)]?.prepareAttachmentNavigation() ?? true }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            stores.removeValue(forKey: ObjectIdentifier(window))?.prepareAttachmentNavigation()
            windows.removeAll { $0 === window }
        }
    }
}
#else
@MainActor struct PDFNativeView: UIViewRepresentable {
    let url: URL; let index: Int; let full: Bool
    func makeCoordinator() -> PDFState { PDFState() }
    func makeUIView(context: Context) -> PDFView { PDFView() }
    func updateUIView(_ view: PDFView, context: Context) { context.coordinator.update(view, url: url, index: index, full: full) }
}
#endif

#if os(iOS)
@MainActor final class ScopedCanvasView: PKCanvasView {
    var excludedRects: [CGRect] = []
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        excludedRects.contains(where: { $0.contains(point) }) ? nil : super.hitTest(point, with: event)
    }
}
@MainActor struct InkOverlay: UIViewRepresentable {
    let data: Data?; let enabled: Bool
    var options = InkOptions()
    var excludedRects: [CGRect] = []
    let begin: () -> Void
    let save: (Data?, Rect?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> ScopedCanvasView {
        let view = ScopedCanvasView(); view.backgroundColor = .clear; view.isOpaque = false; view.isScrollEnabled = false
        view.pinchGestureRecognizer?.isEnabled = false
        view.drawingPolicy = .pencilOnly; view.tool = options.tool
        if let data, let drawing = try? PKDrawing(data: data) { view.drawing = drawing }
        context.coordinator.last = data; context.coordinator.lastOptions = options
        view.delegate = context.coordinator; return view
    }
    func updateUIView(_ view: ScopedCanvasView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self; view.excludedRects = excludedRects
        view.pinchGestureRecognizer?.isEnabled = false
        if !enabled && coordinator.usingTool { coordinator.persist(view); coordinator.usingTool = false }
        if !coordinator.usingTool && coordinator.last != data {
            coordinator.updating = true
            view.drawing = data.flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
            coordinator.last = data; coordinator.updating = false
        }
        if coordinator.lastOptions != options { view.tool = options.tool; coordinator.lastOptions = options }
        view.isUserInteractionEnabled = enabled
        if !enabled {
            coordinator.picker.setVisible(false, forFirstResponder: view); coordinator.picker.removeObserver(view)
            if view.isFirstResponder { view.resignFirstResponder() }
        }
    }
    static func dismantleUIView(_ view: ScopedCanvasView, coordinator: Coordinator) {
        coordinator.persist(view)
        coordinator.picker.setVisible(false, forFirstResponder: view); coordinator.picker.removeObserver(view)
    }
    @MainActor final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: InkOverlay; var active: InkOverlay?
        var last: Data?; var lastOptions: InkOptions?; var updating = false; var usingTool = false
        var firstStroke = 0
        let picker = PKToolPicker()
        init(_ parent: InkOverlay) { self.parent = parent }
        func canvasViewDidBeginUsingTool(_ view: PKCanvasView) {
            active = parent; usingTool = true; firstStroke = view.drawing.strokes.count
            parent.begin()
            picker.addObserver(view); view.becomeFirstResponder(); picker.setVisible(true, forFirstResponder: view)
        }
        func canvasViewDidEndUsingTool(_ view: PKCanvasView) { usingTool = false; persist(view) }
        func canvasViewDrawingDidChange(_ view: PKCanvasView) {
            guard !updating, !usingTool else { return }
            persist(view)
        }
        func persist(_ view: PKCanvasView) {
            guard !updating else { return }
            let target = active ?? parent
            var drawing = view.drawing
            if !target.excludedRects.isEmpty && drawing.strokes.count > firstStroke {
                let mask = UIBezierPath()
                for rect in InkClip.areas(in: view.bounds, excluding: target.excludedRects) { mask.append(UIBezierPath(rect: rect)) }
                var strokes = drawing.strokes
                for i in firstStroke..<strokes.count {
                    let old = strokes[i]
                    strokes[i] = PKStroke(ink: old.ink, path: old.path, transform: old.transform, mask: mask, randomSeed: old.randomSeed)
                }
                drawing = PKDrawing(strokes: strokes)
                updating = true; view.drawing = drawing; updating = false
                firstStroke = strokes.count
            }
            let data = drawing.strokes.isEmpty ? nil : drawing.dataRepresentation()
            guard last != data else { return }; last = data
            let b = drawing.bounds
            target.save(data, b.isNull || b.isEmpty ? nil : Rect(b.minX, b.minY, b.width, b.height))
        }
    }
}
#else
@MainActor struct InkOverlay: View {
    let data: Data?; let enabled: Bool
    var options = InkOptions()
    var excludedRects: [CGRect] = []
    let begin: () -> Void; let save: (Data?, Rect?) -> Void
    var body: some View {
        MacInkOverlay(data: data, enabled: enabled, options: options, excludedRects: excludedRects, begin: begin, save: save)
    }
}
#endif
