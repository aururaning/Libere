import SwiftUI
#if os(macOS)
@MainActor final class CanvasKeyView: NSView {
    weak var store: AppStore?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
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
struct CanvasKeyboard: View { let store: AppStore; var body: some View { EmptyView() } }
#endif
