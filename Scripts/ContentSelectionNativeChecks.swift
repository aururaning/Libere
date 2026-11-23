import SwiftUI
@MainActor private struct SelectionCanvasFixture: View {
    @ObservedObject var store: AppStore
    var body: some View { NoteCanvas(store: store, note: store.note!) }
}
@MainActor func runContentSelectionNativeChecks() async throws -> Int {
    var count = 0
    func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereSelection-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(root: root); store.create(); store.cancelRename(); store.fitToWidth = false
    var block = Block(.text, frame: Rect(80, 80, 420, 350), text: "第一行中文🍎\n第二行 $x_1$\n第三行内容\n最后一行")
    block.textFormat = nil
    store.edit { $0.blocks = [block] }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: SelectionCanvasFixture(store: store)); window.contentView = host
    defer { window.contentView = nil; store.flush() }
    func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
    func settle() async throws { for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 20_000_000) } }
    for scale in [0.25, 0.5, 1.0, 2.0, 6.0] {
        store.zoom = scale; store.selectBlock(block.id); try await settle()
        store.selectAllFocused(in: window); try await settle()
        guard let text = descendants(host).compactMap({ $0 as? NSTextView }).first(where: \.isEditable),
              let viewport = descendants(host).compactMap({ $0 as? CanvasScrollView }).first else { preconditionFailure("Missing live editor") }
        check(text.selectedRange() == NSRange(location: 0, length: block.text.utf16.count), "Command A selects the selected block including Unicode at zoom \(scale)")
        check(store.editingBlockID == block.id && store.note!.blocks[0].text == block.text, "All-selection enters editing without modifying the text")
        let target = text.convert(CGPoint(x: 40, y: 35), to: viewport.paper)
        var visible = viewport.contentView.bounds; visible.origin = CGPoint(x: target.x - visible.width/2, y: target.y - visible.height/2)
        viewport.contentView.scroll(to: viewport.contentView.constrainBoundsRect(visible).origin)
        viewport.reflectScrolledClipView(viewport.contentView)
        for y in [12.0, 35.0, 60.0] {
            let point = text.convert(CGPoint(x: 40, y: y), to: nil)
            check(viewport.pointerArea(at: point, in: window) == nil, "The first three text lines are not intercepted as block dragging at zoom \(scale)")
        }
        text.setSelectedRange(NSRange(location: 2, length: 1)); store.selectAllFocused(in: window)
        check(text.selectedRange().length == block.text.utf16.count, "Repeated Command A works in the already-focused editor")
    }
    let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40)); field.string = "仅搜索框"
    host.addSubview(field); window.makeFirstResponder(field); store.selectAllFocused(in: window)
    check(field.selectedRange().length == field.string.utf16.count, "Other focused text fields keep normal native select-all behavior")
    field.removeFromSuperview(); store.selectBlock(block.id); store.selectAllFocused(in: window); store.clearBlockSelection(); try await settle()
    check(store.editingBlockID == nil && store.blockSelection == nil, "A delayed selection cannot resurrect an editor after deselection")
    print("PASS: \(count) selected-content shortcuts and first-line pointer isolation assertions")
    return count
}
