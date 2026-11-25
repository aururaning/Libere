import SwiftUI
#if os(macOS)
@MainActor final class LibraryPasteOwnerView: NSView { weak var store: AppStore? }
@MainActor struct LibraryClipboardScope: NSViewRepresentable {
    let store: AppStore
    func makeNSView(context: Context) -> LibraryPasteOwnerView { LibraryPasteOwnerView() }
    func updateNSView(_ view: LibraryPasteOwnerView, context: Context) { view.store = store }
}
extension AppStore {
    func canvasPastePoint(in window: NSWindow? = nil) -> CGPoint? {
        guard let window = window ?? NSApp.keyWindow, let root = window.contentView else { return nil }
        var pending = [root]
        while let view = pending.popLast() {
            if let canvas = view as? CanvasScrollView, canvas.pointerInteraction === canvasPointer,
               !canvas.isHiddenOrHasHiddenAncestor {
                return canvas.clipboardPoint(at: window.convertPoint(fromScreen: NSEvent.mouseLocation), in: window)
            }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }
}
@MainActor final class CanvasKeyView: NSView {
    weak var store: AppStore?
    private var deleteMonitor: Any?
    override var acceptsFirstResponder: Bool { true }
    override func selectAll(_ sender: Any?) { store?.selectAllFocused(in: window) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let deleteMonitor { NSEvent.removeMonitor(deleteMonitor); self.deleteMonitor = nil }
        guard window != nil else { return }
        deleteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return false }
                return self.store?.handleBlockDeleteShortcut(event, in: self.window) == true
            }
            return handled ? nil : event
        }
    }
    deinit { if let deleteMonitor { NSEvent.removeMonitor(deleteMonitor) } }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers?.lowercased() == "a", event.modifierFlags.intersection([.command,.option,.control,.shift]) == .command { selectAll(nil); return }
        if store?.handleBlockDeleteShortcut(event, in: window) == true { return }
        if [51, 117].contains(event.keyCode), event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            store?.deleteSelectedBlock()
        } else if event.keyCode == 53 {
            store?.clearBlockSelection()
        } else { super.keyDown(with: event) }
    }
}
@MainActor struct CanvasKeyboard: NSViewRepresentable {
    @ObservedObject var store: AppStore
    final class Coordinator { var request: UUID? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> CanvasKeyView { let view = CanvasKeyView(); view.store = store; return view }
    func updateNSView(_ view: CanvasKeyView, context: Context) {
        if store.blockKeyboardFocus, context.coordinator.request != store.keyboardFocusRequest {
            context.coordinator.request = store.keyboardFocusRequest
            let request = store.keyboardFocusRequest
            DispatchQueue.main.async {
                if self.store.blockKeyboardFocus && self.store.editingBlockID == nil && self.store.keyboardFocusRequest == request {
                    view.window?.makeFirstResponder(view)
                }
            }
        }
    }
}
#else
extension AppStore { func canvasPastePoint() -> CGPoint? { nil } }
struct LibraryClipboardScope: View { let store: AppStore; var body: some View { EmptyView() } }
struct CanvasKeyboard: View { let store: AppStore; var body: some View { EmptyView() } }
#endif
