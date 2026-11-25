import Foundation
import SwiftUI

@MainActor func runTitleCanvasFocusNativeChecks() async throws -> Int {
    _ = NSApplication.shared
    var count = 0
    func check(_ value: Bool, _ label: String) {
        if !value { FileHandle.standardError.write(Data(("FAILED title focus: " + label + "\n").utf8)) }
        precondition(value, label); count += 1
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereTitleFocus-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(root: root)
    store.create(); store.cancelRename(); store.snap = false; store.fitToWidth = false; store.zoom = 1
    let pageID = store.selection!
    var first = Block(.text, frame: Rect(80,80,300,180), text: "第一段正文")
    var second = Block(.text, frame: Rect(440,80,300,180), text: "第二段正文")
    first.textFormat = nil; second.textFormat = nil
    store.edit { $0.blocks = [first,second]; $0.anchors = []; $0.ink = nil; $0.canvasWidth = 1000; $0.canvasHeight = 3000 }
    check(store.flush(), "The synthetic focus fixture is durable before UI testing")
    let originalDirectory = store.directories.directory(for: pageID, in: store.workspace)
    let originalFile = originalDirectory.appendingPathComponent("keep.txt"), sourceBytes = Data("original bytes".utf8)
    try sourceBytes.write(to: originalFile)
    let window = NSWindow(contentRect: NSRect(x:0,y:0,width:1100,height:760), styleMask:[.titled], backing:.buffered, defer:false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: LibraryView(store: store).frame(width:1100,height:760))
    window.contentView = host
    defer { window.contentView = nil; window.close(); store.flush() }
    func settle() async throws {
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds:5_000_000) }
    }
    try await settle()
    func viewport() -> CanvasScrollView {
        guard let view = descendants(host).compactMap({ $0 as? CanvasScrollView }).first(where: { $0.pointerInteraction === store.canvasPointer }) else {
            preconditionFailure("Missing live note viewport")
        }
        return view
    }
    func titleField() -> CanvasTitleField {
        guard let field = descendants(host).compactMap({ $0 as? CanvasTitleField }).first(where: { !($0 is RenameNameField) && $0.titlePageID == pageID }) else {
            preconditionFailure("Missing real PageTitleField control")
        }
        return field
    }
    func edit(_ field: CanvasTitleField, value: String) -> NSTextView {
        // Asking AppKit to focus an NSTextField which already owns the shared
        // editor ends/restarts that edit. Real typing does not do that; notably a
        // sidebar rename schedules its own initial focus when it appears.
        let alreadyEditing = field.currentEditor().map { window.firstResponder === $0 } ?? false
        check(alreadyEditing || window.makeFirstResponder(field), "The native title/name control accepts keyboard focus")
        guard let editor = field.currentEditor() as? NSTextView else { preconditionFailure("No real shared field editor") }
        editor.string = value; field.stringValue = value
        check(editor.isFieldEditor && window.firstResponder === editor, "A real AppKit shared title field editor owns focus")
        return editor
    }
    @discardableResult func click(_ point: CGPoint, area: CanvasPointerInteraction.Area, count: Int = 1) -> Bool {
        let view = viewport(), native = view.paper.convert(point, to: nil)
        let consumed = view.beginPointer(at: native, in: window, area: area, clickCount: count)
        _ = view.continuePointer(.leftMouseUp, at: native, in: window)
        return consumed
    }
    let blank = CGPoint(x:650,y:350)
    let oldTitle = store.note!.title, field = titleField()
    let titleEditor = edit(field, value: "标题完成后点画布")
    check(click(blank, area:.paper), "A blank-paper click goes through the production pointer hand-off")
    try await settle()
    check(store.note!.title == "标题完成后点画布" && !(field.delegate as! PageTitleField.Coordinator).editing,
          "Clicking blank canvas commits and ends the title edit")
    check(window.firstResponder is CanvasKeyView && window.firstResponder !== titleEditor && store.blockKeyboardFocus,
          "Blank canvas owns real keyboard focus instead of leaving the title caret active")
    let renamedDirectory = store.directories.directory(for: pageID, in: store.workspace)
    check(renamedDirectory != originalDirectory && (try? Data(contentsOf: renamedDirectory.appendingPathComponent("keep.txt"))) == sourceBytes,
          "Blur uses the existing physical rename transaction without changing original bytes")
    store.undo()
    check(store.note!.title == oldTitle && (try? Data(contentsOf: originalFile)) == sourceBytes,
          "One undo reverses the committed title and physical directory")
    try await settle()

    let renamed = titleField()
    _ = edit(renamed, value: "标题完成后选块")
    check(click(CGPoint(x:500,y:130), area:.body(second.id)), "A content-block click follows the title hand-off")
    try await settle()
    check(store.note!.title == "标题完成后选块" && store.blockSelection == second.id && store.editingBlockID == nil,
          "A late title end-editing callback does not clear the newly selected block")
    guard let keys = window.firstResponder as? CanvasKeyView else { preconditionFailure("Selected block has no canvas keyboard") }
    let delete = NSEvent.keyEvent(with:.keyDown, location:.zero, modifierFlags:[], timestamp:0,
        windowNumber:window.windowNumber, context:nil, characters:"", charactersIgnoringModifiers:"", isARepeat:false,keyCode:51)!
    keys.keyDown(with:delete)
    check(!store.note!.blocks.contains(where: { $0.id == second.id }), "The next native Delete reaches the selected block rather than editing the title")
    store.undo()
    check(store.note!.blocks.contains(where: { $0.id == second.id }) && store.note!.title == "标题完成后选块",
          "The block command has its own undo step after the title transaction")

    try await settle(); store.selectBlock(first.id); store.tool = .text
    let imeField = titleField(), imeEditor = edit(imeField, value: store.note!.title)
    let coordinator = imeField.delegate as! PageTitleField.Coordinator, originalParent = coordinator.parent
    var titleCommits = 0
    coordinator.parent = PageTitleField(noteID: originalParent.noteID, title: originalParent.title, commit: { id, draft in
        titleCommits += 1; return originalParent.commit(id,draft)
    }, owner: store)
    imeEditor.setSelectedRange(NSRange(location:0,length:imeEditor.string.utf16.count))
    imeEditor.setMarkedText("中文标题", selectedRange:NSRange(location:4,length:0), replacementRange:imeEditor.selectedRange())
    check(imeEditor.hasMarkedText(), "The title fixture contains a native pending IME composition")
    check(CanvasTitleEditing.commit(in:window, interaction:store.canvasPointer), "The title hand-off commits an IME composition")
    check(!imeEditor.hasMarkedText() && store.note!.title == "中文标题" && titleCommits == 1,
          "Title IME is finalized and persisted exactly once")
    check(store.tool == .text && store.blockSelection == first.id, "A title transaction preserves the pre-click tool and hit geometry")
    coordinator.controlTextDidEndEditing(Notification(name:NSControl.textDidEndEditingNotification,object:imeField))
    check(titleCommits == 1 && store.blockSelection == first.id, "A delayed native end-editing notification is a no-op after hand-off")
    store.tool = .select; store.clearBlockSelection(); try await settle()

    let collision = root.appendingPathComponent("已存在目录")
    try FileManager.default.createDirectory(at:collision,withIntermediateDirectories:true)
    let collisionMarker = collision.appendingPathComponent("unrelated.txt"); try Data("unrelated".utf8).write(to:collisionMarker)
    let beforeFailure = store.workspace, invalidField = titleField()
    let invalidEditor = edit(invalidField,value:"已存在目录")
    check(click(CGPoint(x:130,y:130),area:.body(first.id)), "A rejected title hand-off consumes its canvas click")
    check(store.workspace == beforeFailure && store.blockSelection == nil && !store.canvasPointer.isPressed,
          "A failed title rename does not select or drag a canvas target")
    check(window.firstResponder === invalidEditor && invalidField.stringValue == "已存在目录",
          "A failed rename retains the native title focus and its draft")
    check((try? String(contentsOf:collisionMarker)) == "unrelated", "A destination collision preserves unrelated originals")
    store.message = nil
    _ = (invalidField.delegate as! PageTitleField.Coordinator).control(invalidField, textView:invalidEditor, doCommandBy:#selector(NSResponder.cancelOperation(_:)))
    try await settle()

    store.beginRename(pageID); try await settle()
    guard let sidebar = descendants(host).compactMap({ $0 as? RenameNameField }).first(where: { $0.titlePageID == pageID }) else {
        preconditionFailure("Missing actual sidebar rename control")
    }
    let sidebarEditor = edit(sidebar,value:"侧栏标题完成")
    check(click(CGPoint(x:130,y:130),area:.body(first.id)), "Sidebar title editing can hand off to the same canvas pointer route")
    try await settle()
    check(store.renaming == nil && store.note!.title == "侧栏标题完成" && store.blockSelection == first.id,
          "Sidebar commit completes before selecting the clicked block (renaming=\(String(describing:store.renaming)), title=\(store.note!.title), block=\(String(describing:store.blockSelection)), expected=\(first.id), focus=\(String(describing:window.firstResponder)))")
    check(window.firstResponder is CanvasKeyView && window.firstResponder !== sidebarEditor,
          "Sidebar's shared field editor does not retain or reclaim keyboard focus")
    guard let textKeys = window.firstResponder as? CanvasKeyView else { preconditionFailure("Missing canvas key responder") }
    textKeys.selectAll(nil)
    for _ in 0..<100 {
        host.layoutSubtreeIfNeeded()
        if let editor = window.firstResponder as? NSTextView, !editor.isFieldEditor,
           store.editingBlockID == first.id, editor.selectedRange().length == first.text.utf16.count { break }
        try await Task.sleep(nanoseconds:10_000_000)
    }
    check((window.firstResponder as? NSTextView)?.isFieldEditor == false && store.editingBlockID == first.id,
          "After title exit, the next block text command reaches the real content editor")
    check((window.firstResponder as? NSTextView)?.selectedRange().length == first.text.utf16.count,
          "Native Select All selects the block text, not the prior page title")

    store.finishBlockEditing(); store.beginRename(pageID); host.layoutSubtreeIfNeeded()
    guard let pendingSidebar = descendants(host).compactMap({ $0 as? RenameNameField }).first(where: { $0.titlePageID == pageID }) else {
        preconditionFailure("Missing pending sidebar rename control")
    }
    pendingSidebar.stringValue = "点画布早于自动焦点"
    check(click(blank, area:.paper), "A canvas click can commit a sidebar rename before scheduled initial focus")
    try await settle()
    check(store.renaming == nil && store.note!.title == "点画布早于自动焦点",
          "The pending sidebar draft commits to its captured page")
    check(window.firstResponder is CanvasKeyView && store.blockKeyboardFocus,
          "The old sidebar's scheduled focus cannot steal the keyboard back after the click")

    let other = NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:200),styleMask:[.titled],backing:.buffered,defer:false)
    other.isReleasedWhenClosed = false
    let otherField = CanvasTitleField(frame:NSRect(x:10,y:30,width:300,height:30)); otherField.titleOwner=store
    var unexpected = 0; otherField.finishForCanvas = { unexpected += 1; return true }
    other.contentView!.addSubview(otherField); other.makeFirstResponder(otherField)
    check(store.commitTitleEditing(in:other) && unexpected == 0, "A different window without this library's canvas owner is not touched")
    other.contentView=nil; other.close()
    print("PASS: \(count) native title/sidebar hand-off, IME, conflict and canvas command assertions")
    return count
}
