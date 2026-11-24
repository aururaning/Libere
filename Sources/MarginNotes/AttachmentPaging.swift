import Foundation
import SwiftUI
#if SWIFT_PACKAGE
import MarginCore
#endif

/// A reader page is local to its window; the canvas preview page is stored on the block.
struct AttachmentPagination: Equatable {
    let page: Int
    let pageCount: Int
    init(page: Int, pageCount: Int) {
        self.pageCount = max(0, pageCount)
        self.page = pageCount > 0 ? min(max(0, page), pageCount - 1) : 0
    }
    var hasPrevious: Bool { pageCount > 0 && page > 0 }
    var hasNext: Bool { pageCount > 0 && page < pageCount - 1 }
    var label: String { pageCount > 0 ? "第 \(page + 1) / \(pageCount) 页" : "无可用页面" }
    func moved(by delta: Int) -> Int? {
        guard pageCount > 0, delta != 0 else { return nil }
        let (sum, overflow) = page.addingReportingOverflow(delta)
        let next = overflow ? (delta > 0 ? pageCount - 1 : 0) : min(max(0, sum), pageCount - 1)
        return next == page ? nil : next
    }
}

extension Block {
    var attachmentContentIdentity: String {
        "\(id)-\(kind.rawValue)-\(displayAssetID?.uuidString ?? "")-\(relativeFilePath ?? "")-\(contentRevision?.uuidString ?? "")"
    }
}

@MainActor final class AttachmentReaderNavigation: ObservableObject {
    struct Request: Equatable { let id = UUID(); let page: Int }
    @Published var request: Request?
    var canClose: () -> Bool = { true }
    func show(page: Int) { request = Request(page: max(0, page)) }
}

@MainActor struct ReaderPagePicker: View {
    let page: Int
    let count: Int
    var jump: (Int) -> Void
    @SwiftUI.State private var draft = ""
    @SwiftUI.State private var invalid = false
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 5) {
            Text("第")
            TextField("页码", text: $draft).frame(width: 52).textFieldStyle(.roundedBorder)
                .focused($focused).onSubmit(submit).disabled(count == 0)
                .accessibilityLabel("跳转到页码")
            Text("/ \(count) 页")
            if invalid { Text("1–\(count)").foregroundStyle(.red) }
        }.font(.caption.monospacedDigit())
            .onAppear { draft = String(page + 1) }
            .onChange(of: page) { _, next in draft = String(next + 1); invalid = false }
            .onChange(of: count) { _, _ in draft = String(page + 1); invalid = false }
    }
    private func submit() {
        guard let value = Int(draft.trimmingCharacters(in: .whitespaces)), (1...max(1, count)).contains(value), count > 0 else { invalid = true; return }
        invalid = false; jump(value - 1); focused = false
    }
}

#if os(macOS)
@MainActor final class ReaderPagingKeyView: NSView {
    var enabled = false
    var turn: (Int) -> Void = { _ in }
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
        guard enabled, event.window === window, window?.firstResponder as? NSTextInputClient == nil,
              !(window?.firstResponder is NSControl) else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let delta: Int
        if event.keyCode == 49, flags.isEmpty || flags == .shift { delta = flags == .shift ? -1 : 1 }
        else if flags.isEmpty, [123, 126, 116].contains(event.keyCode) { delta = -1 }
        else if flags.isEmpty, [124, 125, 121].contains(event.keyCode) { delta = 1 }
        else { return false }
        turn(delta); return true
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
@MainActor struct ReaderPagingKeyboard: NSViewRepresentable {
    let enabled: Bool; let turn: (Int) -> Void
    func makeNSView(context: Context) -> ReaderPagingKeyView { ReaderPagingKeyView() }
    func updateNSView(_ view: ReaderPagingKeyView, context: Context) { view.enabled = enabled; view.turn = turn }
}
#else
struct ReaderPagingKeyboard: View { let enabled: Bool; let turn: (Int) -> Void; var body: some View { EmptyView() } }
#endif
