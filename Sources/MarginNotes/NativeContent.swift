import SwiftUI
import PDFKit
import WebKit
import PencilKit
#if SWIFT_PACKAGE
import MarginCore
#endif

#if os(macOS)
@MainActor final class CanvasInlineButtonControl: NSButton {
    var ownerBlockID: UUID?
    var invoke: () -> Void = {}
    // NSButton's bezel alignment insets otherwise expand a nominal 28×36 hit
    // view outside the clipped block header (especially at fractional zoom).
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }
    @objc func performInlineAction(_ sender: Any?) { if isEnabled { invoke() } }
}
@MainActor struct CanvasInlineButton: NSViewRepresentable {
    var title = ""
    var symbol: String? = nil
    let label: String
    let identifier: String
    var ownerBlockID: UUID? = nil
    var enabled = true
    let action: () -> Void
    func makeNSView(context: Context) -> CanvasInlineButtonControl {
        let button = CanvasInlineButtonControl(frame: .zero)
        button.setButtonType(.momentaryPushIn); button.isBordered = false
        button.font = .systemFont(ofSize: 11); button.imagePosition = .imageOnly
        button.target = button; button.action = #selector(CanvasInlineButtonControl.performInlineAction(_:))
        return button
    }
    func updateNSView(_ button: CanvasInlineButtonControl, context: Context) {
        button.title = title; button.ownerBlockID = ownerBlockID
        button.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: label) }
        button.imagePosition = symbol == nil ? .noImage : .imageOnly
        button.imageScaling = .scaleNone
        button.isEnabled = enabled && context.environment.isEnabled
        button.invoke = action; button.toolTip = label
        button.setAccessibilityLabel(label); button.setAccessibilityIdentifier(identifier)
    }
}
#else
@MainActor struct CanvasInlineButton: View {
    var title = ""
    var symbol: String? = nil
    let label: String
    let identifier: String
    var ownerBlockID: UUID? = nil
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Group { if let symbol { Image(systemName: symbol) } else { Text(title).font(.caption2) } }
                .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!enabled).accessibilityLabel(label).accessibilityIdentifier(identifier)
    }
}
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

#if os(macOS)
@MainActor final class PDFWindow: NSObject, NSWindowDelegate {
    static let shared = PDFWindow()
    private struct Key: Hashable { let store: ObjectIdentifier; let note: UUID; let block: UUID }
    private struct Entry { let window: NSWindow; let store: AppStore; let navigation: AttachmentReaderNavigation; let access: Bool }
    private var readers: [Key: Entry] = [:]
    private var enteringFullScreen: Set<Key> = []
    var windowCount: Int { readers.count }
    var presentsWindows = true
    func existingWindow(store: AppStore, noteID: UUID, blockID: UUID) -> NSWindow? {
        readers[Key(store: ObjectIdentifier(store), note: noteID, block: blockID)]?.window
    }
    /// Commit every window-owned input before a block move changes note IDs.
    /// This includes the field editor in a non-key reader, without closing it.
    func prepareReaders(store: AppStore) -> Bool {
        for (key, entry) in readers where key.store == ObjectIdentifier(store) {
            guard windowShouldClose(entry.window) else { return false }
        }
        return true
    }
    /// A moved block keeps its reader window and navigation object. Only the
    /// document binding is replaced; no canvas or shared PDF scale is changed.
    func reconcileReaders(store: AppStore) {
        for (key, entry) in Array(readers) where key.store == ObjectIdentifier(store) {
            guard readers[key]?.window === entry.window else { continue }
            if let note = store.workspace.notes.first(where: { $0.id == key.note && !$0.deleted }),
               let block = note.blocks.first(where: { $0.id == key.block }) {
                entry.window.title = block.assetName
                continue
            }
            guard let note = store.workspace.notes.first(where: { !$0.deleted && $0.blocks.contains(where: { $0.id == key.block }) }),
                  let block = note.blocks.first(where: { $0.id == key.block }) else {
                entry.window.close(); continue
            }
            let moved = Key(store: key.store, note: note.id, block: key.block)
            if let duplicate = readers[moved], duplicate.window !== entry.window { duplicate.window.close() }
            readers.removeValue(forKey: key); readers[moved] = entry
            if enteringFullScreen.remove(key) != nil { enteringFullScreen.insert(moved) }
            entry.window.title = block.assetName
            entry.window.contentView = NSHostingView(rootView: AttachmentReader(store: store, noteID: note.id, block: block,
                navigation: entry.navigation, onClose: { [weak window = entry.window] in window?.close() }))
        }
    }
    func open(store: AppStore, noteID: UUID, block: Block, page: Int? = nil, fullScreen: Bool = false) {
        let key = Key(store: ObjectIdentifier(store), note: noteID, block: block.id)
        if let entry = readers[key] {
            if let page { entry.navigation.show(page: page) }
            if entry.window.isMiniaturized { entry.window.deminiaturize(nil) }
            entry.window.title = block.assetName
            if presentsWindows { entry.window.makeKeyAndOrderFront(nil) }
            if fullScreen { enterFullScreen(entry.window, key: key) }
            return
        }
        let navigation = AttachmentReaderNavigation()
        if let page { navigation.show(page: page) }
        navigation.canClose = { [weak store] in store?.prepareAttachmentNavigation() ?? true }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = block.assetName
        window.contentView = NSHostingView(rootView: AttachmentReader(store: store, noteID: noteID, block: block,
            navigation: navigation, onClose: { [weak window] in window?.close() }))
        window.delegate = self; window.isReleasedWhenClosed = false
        readers[key] = Entry(window: window, store: store, navigation: navigation, access: store.repository.root.startAccessingSecurityScopedResource())
        window.collectionBehavior.insert(.fullScreenPrimary); window.center()
        if presentsWindows { window.makeKeyAndOrderFront(nil) }
        if fullScreen { enterFullScreen(window, key: key) }
    }
    private func enterFullScreen(_ window: NSWindow, key: Key) {
        guard presentsWindows, !window.styleMask.contains(.fullScreen), enteringFullScreen.insert(key).inserted else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.readers[key]?.window === window, window.isVisible,
                  !window.styleMask.contains(.fullScreen) else { self?.enteringFullScreen.remove(key); return }
            window.toggleFullScreen(nil)
        }
    }
    func windowDidEnterFullScreen(_ notification: Notification) { clearFullScreenRequest(notification.object as? NSWindow) }
    func windowDidExitFullScreen(_ notification: Notification) { clearFullScreenRequest(notification.object as? NSWindow) }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { clearFullScreenRequest(window) }
    private func clearFullScreenRequest(_ window: NSWindow?) {
        for (key, entry) in readers where entry.window === window { enteringFullScreen.remove(key) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // The window being closed can be non-key; its pending composition must
        // reach its own editor before the save guard decides whether to close.
        if let text = sender.firstResponder as? NSTextView {
            guard !text.hasMarkedText() || text.isEditable else { return false }
            text.unmarkText(); text.didChangeText()
        }
        return readers.values.first { $0.window === sender }?.navigation.canClose() ?? true
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            // Dispose the reader and its preview lease even when another caller
            // still retains this NSWindow. Save protection has already succeeded.
            window.contentView = nil
            for (key, entry) in readers where entry.window === window {
                if entry.access { entry.store.repository.root.stopAccessingSecurityScopedResource() }
                enteringFullScreen.remove(key); readers.removeValue(forKey: key)
            }
        }
    }
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
