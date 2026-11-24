import SwiftUI

#if os(macOS)
@MainActor final class PageAnnotationPointerView: NSView {
    var borderOnly = false
    var excludesButtons = false
    var select: () -> Void = {}
    var edit: () -> Void = {}
    var preview: (CGSize) -> Void = { _ in }
    var commit: (CGSize) -> Void = { _ in }
    private var start: NSPoint?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(p) else { return nil }
        if excludesButtons && (CGRect(x: max(0, bounds.width - 54), y: 0, width: 54, height: 28).contains(p)
            || CGRect(x: max(0, bounds.width - 34), y: max(0, bounds.height - 34), width: 34, height: 34).contains(p)) { return nil }
        return borderOnly && bounds.insetBy(dx: 6, dy: 6).contains(p) ? nil : self
    }
    override func mouseDown(with event: NSEvent) { start = event.locationInWindow; select() }
    private func delta(_ event: NSEvent) -> CGSize {
        guard let start else { return .zero }
        let a = convert(start, from: nil), b = convert(event.locationInWindow, from: nil)
        return CGSize(width: b.x - a.x, height: b.y - a.y)
    }
    override func mouseDragged(with event: NSEvent) { guard start != nil else { return }; preview(delta(event)) }
    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        let d = delta(event), moved = hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 3
        self.start = nil; preview(.zero)
        if moved { commit(d) } else if event.clickCount > 1 { edit() }
    }
}
@MainActor struct PageAnnotationPointer: NSViewRepresentable {
    var borderOnly = false; var excludesButtons = false
    var select: () -> Void; var edit: () -> Void = {}
    var preview: (CGSize) -> Void; var commit: (CGSize) -> Void
    func makeNSView(context: Context) -> PageAnnotationPointerView { PageAnnotationPointerView() }
    func updateNSView(_ view: PageAnnotationPointerView, context: Context) {
        view.borderOnly = borderOnly; view.excludesButtons = excludesButtons
        view.select = select; view.edit = edit; view.preview = preview; view.commit = commit
    }
}
@MainActor final class PageAnnotationKeyView: NSView {
    var enabled = false
    var clear: () -> Void = {}; var delete: () -> Void = {}
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }
    func handle(_ event: NSEvent) -> Bool {
        guard enabled, event.window === window, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        if event.keyCode == 53 { clear(); return true }
        guard [51,117].contains(event.keyCode), window?.firstResponder as? NSTextInputClient == nil else { return false }
        delete(); return true
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
@MainActor struct PageAnnotationKeyboard: NSViewRepresentable {
    let enabled: Bool; let clear: () -> Void; let delete: () -> Void
    func makeNSView(context: Context) -> PageAnnotationKeyView { PageAnnotationKeyView() }
    func updateNSView(_ view: PageAnnotationKeyView, context: Context) { view.enabled = enabled; view.clear = clear; view.delete = delete }
}
#else
struct PageAnnotationKeyboard: View { let enabled: Bool; let clear: () -> Void; let delete: () -> Void; var body: some View { EmptyView() } }
#endif
