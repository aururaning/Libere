import SwiftUI
#if SWIFT_PACKAGE
import MarginCore
#endif

#if os(macOS)
/// Observes the same mouse event without consuming it. Native web controls keep
/// their focus; an already-selected link never repeatedly ends its editor session.
@MainActor final class InlineSelectionObserver: NSView {
    weak var store: AppStore?
    var blockID = UUID()
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
            return event
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    func observe(_ event: NSEvent) {
        guard let store, let window, event.window === window, let root = window.contentView,
              store.note?.blocks.contains(where: { $0.id == blockID }) == true,
              let scope = SelectionWheel.scope(blockID, in: root),
              scope.visibleRect.contains(scope.convert(event.locationInWindow, from: nil)),
              let hit = root.hitTest(root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow),
              hit === scope || hit.isDescendant(of: scope) else { return }
        store.selectInlineInteraction(blockID)
    }
}
@MainActor struct InlineInteractionSelection: NSViewRepresentable {
    let store: AppStore; let blockID: UUID
    func makeNSView(context: Context) -> InlineSelectionObserver { InlineSelectionObserver() }
    func updateNSView(_ view: InlineSelectionObserver, context: Context) { view.store = store; view.blockID = blockID }
}
#else
@MainActor struct InlineInteractionSelection: View {
    let store: AppStore; let blockID: UUID
    var body: some View { Color.clear.allowsHitTesting(false) }
}
#endif

@MainActor extension AppStore {
    func selectInlineInteraction(_ id: UUID) {
        if blockSelection != id { selectBlock(id, keyboard: false) }
        else { blockKeyboardFocus = false; sidebarHasFocus = false }
    }
}
