import AppKit
import SwiftUI
import WebKit

@MainActor private struct UpdateCanvasFixture: View {
    @ObservedObject var store: AppStore
    var body: some View { if let note = store.note { NoteCanvas(store: store, note: note) } }
}
@MainActor private final class DisclosureBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.05, green: 0.4, blue: 0.9, alpha: 1).setFill(); bounds.fill()
    }
}

@MainActor func runUpdate32NativeChecks() async throws -> Int {
    _ = NSApplication.shared
    var count = 0
    func check(_ value: Bool, _ label: String) {
        if !value { FileHandle.standardError.write(Data(("FAILED update32 interface: " + label + "\n").utf8)) }
        precondition(value, label); count += 1
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func wait(_ host: NSView, line: UInt = #line, until ready: () -> Bool) async throws {
        for _ in 0..<250 {
            host.layoutSubtreeIfNeeded()
            if ready() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Interface fixture timed out at call line \(line)")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereUpdate32-" + UUID().uuidString)
    let store = try AppStore(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    store.create(); store.cancelRename(); store.fitToWidth = false
    var text = Block(.text, frame: Rect(100, 100, 420, 240), text: #"矩阵 $\mathbf{A}^\top$，张量 $\mathbf{x}\otimes\mathbf{y}$。"#)
    text.fontSize = 28; text.fontFamily = "Songti SC"
    let other = Block(.text, frame: Rect(650, 100, 300, 180), text: "另一个内容块")
    store.edit { $0.blocks = [text, other]; $0.canvasWidth = 1300; $0.canvasHeight = 1800 }
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: UpdateCanvasFixture(store: store)); window.contentView = host
    defer { window.contentView = nil }
    func canvas() -> CanvasScrollView? { descendants(host).compactMap { $0 as? CanvasScrollView }.first { $0.pointerInteraction === store.canvasPointer } }
    try await wait(host) { canvas() != nil && descendants(host).contains { ($0 as? CanvasInlineButtonControl)?.accessibilityIdentifier() == "block-edit-" + text.id.uuidString } }
    for zoom in [0.5, 1.0, 2.0] {
        store.zoom = zoom
        try await wait(host) { abs((canvas()?.magnification ?? 0)-zoom) < 0.001 }
        let viewport = canvas()!; viewport.reveal(CGRect(x: 70, y: 80, width: 500, height: 100)); host.layoutSubtreeIfNeeded()
        let edit = descendants(host).compactMap { $0 as? CanvasInlineButtonControl }.first { $0.accessibilityIdentifier() == "block-edit-" + text.id.uuidString }!
        let point = edit.convert(CGPoint(x: edit.bounds.midX, y: edit.bounds.midY), to: nil)
        check(SelectionWheel.owns(point, in: window, scroll: viewport) && viewport.pointerArea(at: point, in: window) == nil,
              "Markdown edit/preview buttons retain their own native hit region at zoom \(zoom)")
        edit.performClick(nil)
        try await wait(host) { descendants(host).compactMap { $0 as? NSTextView }.contains { $0.isEditable && $0.string == text.text } }
        let editor = descendants(host).compactMap { $0 as? NSTextView }.first { $0.isEditable && $0.string == text.text }!
        check(editor.font?.pointSize == 28 && editor.font?.fontName.contains("Songti") == true,
              "Markdown editing uses the selected font and size instead of a fixed 20-point cap")
        editor.setSelectedRange(NSRange(location: 0, length: 2))
        store.formatText(.font("Menlo"))
        try await wait(host) { editor.font?.fontName.contains("Menlo") == true }
        check(editor.selectedRange().length == 2, "A font change preserves the active Markdown source selection")
        store.formatText(.font("Songti SC"))
        let preview = descendants(host).compactMap { $0 as? CanvasInlineButtonControl }.first { $0.accessibilityIdentifier() == "block-edit-" + text.id.uuidString }!
        preview.performClick(nil)
        try await wait(host) { store.editingBlockID == nil }
        check(store.note?.blocks.first?.text == text.text, "Switching edit/preview preserves the full LaTeX and Markdown source")
    }
    store.zoom = 0.5
    try await wait(host) { abs((canvas()?.magnification ?? 0)-0.5) < 0.001 }
    let viewport = canvas()!
    viewport.reveal(CGRect(x: 0, y: 0, width: 1000, height: 400)); host.layoutSubtreeIfNeeded()
    func touch(_ point: CGPoint) -> Bool { viewport.selectTouch(at: viewport.paper.convert(point, to: nil), in: window) }
    check(touch(CGPoint(x: 160, y: 170)) && store.blockSelection == text.id, "A direct finger tap selects the actual first block")
    _ = store.canvasPointer.down(at: CGPoint(x: 160, y: 170), area: .body(text.id), clickCount: 1, scale: 0.5)
    check(touch(CGPoint(x: 160, y: 170)) && !store.canvasPointer.isPressed, "A finger tap releases an unfinished pointer capture before selecting")
    check(touch(CGPoint(x: 720, y: 170)) && store.blockSelection == other.id, "A finger tap on another block switches the current selection")
    check(touch(CGPoint(x: 570, y: 310)) && store.blockSelection == nil, "A finger tap on blank paper cancels the selected block")
    let click = viewport.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }.first { $0.allowedTouchTypes == [.direct] }!
    let mouse = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    check(click.delegate?.gestureRecognizer?(click, shouldAttemptToRecognizeWith: mouse) == false, "The touch recognizer does not duplicate mouse or Pencil event routing")
    if #available(macOS 27.0, *) { check(click.isCancellableByScrollGesture, "Finger panning cancels a pending selection tap") }
    store.tool = .ink
    check(!touch(CGPoint(x: 160, y: 170)) && store.blockSelection == nil, "Handwriting mode keeps finger taps out of block-selection and pen input")
    store.tool = .select

    let disclosure = SidebarDisclosureControl(frame: CGRect(x: 0, y: 0, width: 28, height: 30))
    var toggles = 0
    disclosure.configure(pageID: UUID(), title: "选中文件夹", expanded: true, selected: true, active: true) { toggles += 1 }
    let blue = DisclosureBackground(frame: CGRect(x: 0, y: 0, width: 28, height: 30)); blue.addSubview(disclosure)
    let bitmap = blue.bitmapImageRepForCachingDisplay(in: blue.bounds)!
    blue.cacheDisplay(in: blue.bounds, to: bitmap)
    var visibleArrowPixels = 0
    for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
           color.redComponent > 0.9 && color.greenComponent > 0.9 && color.blueComponent > 0.9 { visibleArrowPixels += 1 }
    } }
    check(visibleArrowPixels > 3, "The selected folder arrow is visibly painted above its blue selection background")
    disclosure.performClick(nil); check(toggles == 1, "The selected folder's native disclosure remains clickable")
    disclosure.configure(pageID: UUID(), title: "选中文件夹", expanded: true, selected: true, active: false) { toggles += 1 }
    check(disclosure.contentTintColor == .controlTextColor, "An inactive selection uses the normal readable control tint")

    store.create(folder: true); store.cancelRename(); let folder = store.selection!
    store.create(parent: folder); store.cancelRename(); store.select(folder)
    let libraryWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
    libraryWindow.isReleasedWhenClosed = false
    let libraryHost = NSHostingView(rootView: LibraryView(store: store)); libraryWindow.contentView = libraryHost
    defer { libraryWindow.contentView = nil }
    try await wait(libraryHost) { descendants(libraryHost).compactMap { $0 as? SidebarDisclosureControl }.contains { $0.pageID == folder } }
    if let bitmap = libraryHost.bitmapImageRepForCachingDisplay(in: libraryHost.bounds) {
        libraryHost.cacheDisplay(in: libraryHost.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: ".build/validation/folder-controls-build32.png"))
    }
    print("PASS: \(count) Markdown edit/preview, font, direct-touch selection and folder-control assertions")
    return count
}
