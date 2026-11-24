import SwiftUI

#if os(macOS)
@MainActor final class SourceInputHost: NSView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    var editable = true
    var run: (() -> Void)?
    var wantsFocus = false
    var request: UUID?
    private var appliedRequest: UUID?
    private var monitor: Any?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); host.sizingOptions = []; addSubview(host) }
    required init?(coder: NSCoder) { fatalError() }
    func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        for child in view.subviews { if let text = textView(in: child) { return text } }
        return nil
    }
    override func layout() { super.layout(); host.frame = bounds; applyState() }
    func applyState() {
        guard let text = textView(in: host) else { return }
        text.isEditable = editable; text.isSelectable = true
        if wantsFocus, editable, window != nil, let request, request != appliedRequest {
            appliedRequest = request
            DispatchQueue.main.async { [weak self, weak text] in
                guard let self, let text, self.wantsFocus, self.editable, self.request == request else { return }
                self.window?.makeFirstResponder(text)
                text.scrollRangeToVisible(text.selectedRange())
            }
        }
    }
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
        guard editable, let run, event.window === window,
              [36, 76].contains(event.keyCode), event.modifierFlags.intersection([.command, .shift, .option, .control]) == .shift,
              let text = window?.firstResponder as? NSTextView, text.isDescendant(of: self) else { return false }
        text.unmarkText(); text.didChangeText(); run(); return true
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
@MainActor struct SourceInputSurface<Content: View>: NSViewRepresentable {
    var editable: Bool
    var wantsFocus: Bool
    var request: UUID?
    var run: (() -> Void)?
    @ViewBuilder var content: () -> Content
    func makeNSView(context: Context) -> SourceInputHost { SourceInputHost(frame: .zero) }
    func updateNSView(_ view: SourceInputHost, context: Context) {
        view.editable = editable; view.wantsFocus = wantsFocus; view.request = request; view.run = run
        view.host.rootView = AnyView(content()); view.host.frame = view.bounds
        view.applyState(); view.needsLayout = true
    }
}
#else
@MainActor final class SourceInputController: UIViewController {
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    var editable = true; var wantsFocus = false; var request: UUID?; var run: (() -> Void)?
    private var applied: UUID?
    override func loadView() {
        view = UIView(); view.backgroundColor = .clear
        addChild(host); view.addSubview(host.view); host.didMove(toParent: self)
        host.view.backgroundColor = .clear; host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }
    func textView(_ view: UIView) -> UITextView? {
        if let text = view as? UITextView { return text }
        for child in view.subviews { if let text = textView(child) { return text } }; return nil
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); host.view.frame = view.bounds; applyState() }
    func applyState() {
        guard isViewLoaded, let text = textView(host.view) else { return }
        text.isEditable = editable; text.isSelectable = true
        if wantsFocus, editable, view.window != nil, let request, request != applied {
            applied = request; text.becomeFirstResponder(); text.scrollRangeToVisible(text.selectedRange)
        }
    }
    override var keyCommands: [UIKeyCommand]? {
        guard editable, run != nil else { return nil }
        let key = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(runNext))
        key.wantsPriorityOverSystemBehavior = true; return [key]
    }
    @objc private func runNext() {
        guard editable, let text = textView(host.view), text.isFirstResponder else { return }
        text.unmarkText(); text.delegate?.textViewDidChange?(text); run?()
    }
}
@MainActor struct SourceInputSurface<Content: View>: UIViewControllerRepresentable {
    var editable: Bool; var wantsFocus: Bool; var request: UUID?; var run: (() -> Void)?
    @ViewBuilder var content: () -> Content
    func makeUIViewController(context: Context) -> SourceInputController { SourceInputController() }
    func updateUIViewController(_ controller: SourceInputController, context: Context) {
        controller.loadViewIfNeeded(); controller.editable = editable; controller.wantsFocus = wantsFocus
        controller.request = request; controller.run = run; controller.host.rootView = AnyView(content())
        controller.applyState(); controller.view.setNeedsLayout()
    }
}
#endif
