import Foundation
import SwiftUI

@MainActor func runBlockInteractionNativeChecks() throws -> Int {
    var count = 0
    func check(_ value: Bool, _ name: String) { precondition(value, name); count += 1 }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("libere-block-check-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(root: root)
    store.create(); store.cancelRename(); store.snap = false
    let first = Block(.text, frame: Rect(80, 80, 320, 100), text: "第一段文字")
    let second = Block(.text, frame: Rect(460, 80, 280, 120), text: "另一个块")
    store.edit { $0.blocks = [first, second]; $0.anchors = []; $0.ink = Data([1, 2, 3]) }
    let page = store.selection!

    store.selectBlock(first.id)
    check(store.blockKeyboardFocus && store.editingBlockID == nil, "Single selection owns the block keyboard without a text editor")
    store.beginBlockEditing(first.id)
    check(!store.blockKeyboardFocus && store.editingBlockID == first.id, "Explicit editing transfers ownership to text")
    let originalCount = store.note!.blocks.count
    store.deleteSelectedBlock()
    check(store.note!.blocks.count == originalCount, "Delete while editing must never delete a whole block")

    // Exercise actual NSTextView composition and responder resignation, not just model flags.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600)); window.contentView = rootView
    let text = NSTextView(frame: NSRect(x: 80, y: 80, width: 320, height: 100))
    rootView.addSubview(text)
    let editor = RichTextEditor(block: first, formatting: store.formatting, focus: { store.beginBlockEditing(first.id) }, checkpoint: { store.checkpoint() }) { data, value in
        store.editBlock(first.id) { $0.text = value; $0.rtf = data }
    }
    let coordinator = editor.makeCoordinator(); text.delegate = coordinator
    text.string = first.text; window.makeFirstResponder(text); coordinator.activate(text)
    text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
    text.setMarkedText("中文输入", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    check(text.hasMarkedText(), "Native IME fixture has a pending composition")
    store.selectBlock(second.id)
    check(!text.hasMarkedText() && window.firstResponder !== text, "Selecting another block commits IME and removes the old caret")
    check(store.note!.blocks.first { $0.id == first.id }!.text.contains("中文输入"), "Composed Chinese is saved into the original block before selection changes")
    check(store.editingBlockID == nil && store.blockSelection == second.id && store.blockKeyboardFocus, "Another block can immediately receive commands after editing")

    store.beginBlockEditing(first.id); window.makeFirstResponder(text); coordinator.activate(text)
    let boundary = BlockFocusRegion(frame: text.frame); boundary.store = store; boundary.blockID = first.id; rootView.addSubview(boundary)
    // The test window is not ordered on screen, so NSEvent.window has no WindowServer ID.
    // Pass the actual window and its native coordinates through the same observer path.
    boundary.observeClick(at: NSPoint(x: 150, y: 120), in: window)
    check(store.editingBlockID == first.id, "Click inside an active editor keeps editing")
    boundary.moveHandleRect = CGRect(x: -30, y: 0, width: 28, height: 28)
    boundary.observeClick(at: boundary.convert(NSPoint(x: -16, y: 14), to: nil), in: window)
    check(store.editingBlockID == first.id && window.firstResponder === text, "External move handle preserves the active editor and caret")
    text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
    text.setMarkedText("继续编辑", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    let composingRange = text.selectedRange()
    store.beginBlockDrag(first.id)
    store.setFrame(first.id, Rect(100, 90, 320, 100)); store.finishBlockDrag(first.id)
    check(window.firstResponder === text && text.selectedRange() == composingRange, "Dragging during editing retains the native text responder and cursor range")
    check(text.hasMarkedText() && store.editingBlockID == first.id, "Dragging does not interrupt a live Chinese composition")
    store.beginBlockDrag(first.id)
    store.setFrame(first.id, Rect(100, 90, 300, 120), resizing: true); store.finishBlockDrag(first.id)
    check(store.editingBlockID == first.id && window.firstResponder === text, "Resizing during editing also preserves the live editor")
    boundary.observeClick(at: NSPoint(x: 600, y: 400), in: window)
    check(store.editingBlockID == nil && window.firstResponder !== text, "Click outside the block resigns focus even on a non-focusable background")
    check(store.note!.blocks.first { $0.id == first.id }!.text.contains("继续编辑"), "Composition entered before a drag is saved when clicking away")
    check(boundary.hitTest(.zero) == nil, "Focus observer does not swallow the next control's click")
    store.clearBlockSelection()
    check(store.blockSelection == nil && !store.blockKeyboardFocus && store.formatting.view == nil, "Blank canvas clears selection and formatting ownership")

    let keys = CanvasKeyView(frame: .zero); keys.store = store; rootView.addSubview(keys)
    func key(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }
    store.selectBlock(second.id); window.makeFirstResponder(keys); keys.keyDown(with: key(51))
    check(!store.note!.blocks.contains { $0.id == second.id }, "Mac backward Delete removes the selected block")
    store.undo(); check(store.note!.blocks.contains { $0.id == second.id }, "One undo restores the deleted block")
    store.redo(); check(!store.note!.blocks.contains { $0.id == second.id }, "Redo deletes the same block again")
    store.undo(); store.selectBlock(second.id); keys.keyDown(with: key(117))
    check(!store.note!.blocks.contains { $0.id == second.id }, "Forward Delete also removes the selected block")
    store.undo()

    store.beginBlockEditing(first.id); store.beginBlockDrag(first.id)
    check(store.editingBlockID == first.id && !store.blockKeyboardFocus && store.draggingBlockID == first.id, "An editor can be dragged without changing its edit mode or taking keyboard focus")
    let moved = Rect(110, 160, 320, 100)
    store.setFrame(first.id, moved); store.finishBlockDrag(first.id)
    check(store.block!.frame == moved && store.editingBlockID == first.id && !store.blockKeyboardFocus && store.draggingBlockID == nil, "A live editor keeps its editing mode after moving")
    store.selectBlock(first.id); store.beginBlockDrag(first.id); store.finishBlockDrag(first.id)
    check(store.blockKeyboardFocus && store.editingBlockID == nil, "Moving a selected preview restores Delete keyboard routing")

    store.tool = .anchor; store.addAnchor(CGPoint(x: 450, y: 190))
    check(store.tool == .select && store.blockKeyboardFocus && store.note!.anchors.count == 1, "Manual anchor placement is one-shot and leaves blocks draggable")
    store.tool = .anchor; keys.keyDown(with: key(53))
    check(store.tool == .select && store.blockSelection == nil, "Escape leaves manual anchor placement")
    let beforeAnnotation = store.note!
    store.addAnnotation(to: first.id)
    let child = store.block!, anchor = store.note!.anchors.first { $0.id == child.anchorID }!
    check(child.kind == .text && store.editingBlockID == child.id && store.tool == .select, "One annotation action creates a text branch ready to type")
    check(anchor.ownerID == first.id && beforeAnnotation.blocks.allSatisfy { !child.frame.intersects($0.frame, gap: 12) }, "Annotation finds nearby free space and retains its owner")
    let total = store.note!.blocks.count
    store.annotate(anchor)
    check(store.note!.blocks.count == total && store.editingBlockID == child.id, "Opening an existing point edits its text without creating duplicates")
    store.undo()
    check(store.note!.blocks == beforeAnnotation.blocks && store.note!.anchors == beforeAnnotation.anchors, "One undo removes both a newly created annotation and its point")

    // Auto-height changes only this frame; even attached, locked children stay still.
    let owner = store.note!.blocks.first { $0.id == first.id }!
    var lockedChild = Block(.text, frame: Rect(470, 320, 240, 120), text: "固定的批注"); lockedChild.locked = true
    let fixedAnchor = AnnotationAnchor(ownerID: owner.id, label: "固定位置", u: (470 - owner.frame.x) / owner.frame.width,
        v: (320 - owner.frame.y) / owner.frame.height)
    lockedChild.anchorID = fixedAnchor.id
    store.edit { $0.anchors = [fixedAnchor]; $0.blocks.append(lockedChild) }
    let pointBefore = CanvasLayout.point(fixedAnchor, blocks: store.note!.blocks)!
    let inkBefore = store.note!.ink
    store.growTextBlock(owner, contentHeight: 700)
    let grown = store.note!.blocks.first { $0.id == first.id }!
    let pointAfter = CanvasLayout.point(store.note!.anchors[0], blocks: store.note!.blocks)!
    check(grown.frame.height == 730 && grown.frame.width == owner.frame.width && grown.frame.x == owner.frame.x && grown.frame.y == owner.frame.y, "Overflow increases only height, including editor controls")
    check(pointBefore.x == pointAfter.x && abs(pointBefore.y - pointAfter.y) < 0.001, "Automatic growth preserves annotation point coordinates")
    check(store.note!.blocks.first { $0.id == lockedChild.id }! == lockedChild && store.note!.ink == inkBefore, "Automatic growth leaves locked branches and ink byte-identical")
    store.growTextBlock(grown, contentHeight: 100)
    check(store.note!.blocks.first { $0.id == first.id }!.frame == grown.frame, "Deleting text does not unexpectedly shrink a manually sized frame")
    var stale = grown; stale.text = "过期内容"; store.growTextBlock(stale, contentHeight: 1000)
    check(store.note!.blocks.first { $0.id == first.id }!.frame == grown.frame, "Old content layout report cannot change the current frame")
    stale = grown; stale.frame.width += 100; store.growTextBlock(stale, contentHeight: 1000)
    check(store.note!.blocks.first { $0.id == first.id }!.frame == grown.frame, "Old width layout report cannot change the current frame")
    store.growTextBlock(grown, contentHeight: .infinity)
    store.growTextBlock(lockedChild, contentHeight: 1000)
    check(store.note!.blocks.first { $0.id == first.id }!.frame == grown.frame && store.note!.blocks.first { $0.id == lockedChild.id }! == lockedChild, "Invalid heights and locked text cannot grow")
    store.beginBlockDrag(first.id); store.growTextBlock(grown, contentHeight: 1000)
    check(store.block!.frame == grown.frame, "Live resize cannot be interrupted by asynchronous auto-height")
    store.finishBlockDrag(first.id)

    var long = Block(.text, frame: Rect(0, 0, 600, 100), text: String(repeating: "中文自动换行与 English words 混排，", count: 30))
    let wideHeight = TextBlockLayout.height(long); long.frame.width = 180
    let narrowHeight = TextBlockLayout.height(long)
    check(narrowHeight > wideHeight * 2 && narrowHeight.isFinite, "Actual TextKit layout wraps Chinese and Latin when the width narrows")
    long.text += "\n\n"; let withBlankLine = TextBlockLayout.height(long)
    check(withBlankLine > narrowHeight, "Trailing blank lines reserve room for the caret")
    long.text = String(repeating: "长", count: 500)
    check(TextBlockLayout.height(long) > 200, "Unbroken text wraps instead of overflowing horizontally")
    store.beginBlockEditing(first.id); store.tool = .ink
    check(store.editingBlockID == nil && !store.blockKeyboardFocus, "Switching to handwriting releases text focus")
    store.tool = .select; store.beginBlockEditing(first.id)
    store.create(); check(store.editingBlockID == nil && store.selection != page, "Changing page releases the previous editor")
    let edgeBlock = Block(.text, frame: Rect(30, 1000, 300, 80), text: "纸张底部")
    store.edit { $0.paper = .a4; $0.blocks = [edgeBlock] }
    store.growTextBlock(edgeBlock, contentHeight: 1000)
    check(store.note!.paper == .a4 && store.note!.blocks[0].frame.maxY == PaperKind.a4.height - CanvasLayout.margin,
          "Finite paper keeps its chosen boundary instead of moving text off-page or silently changing paper type")
    store.select(page); store.flush()
    let reopened = try AppStore(root: root)
    check(reopened.workspace.notes.first { $0.id == page }!.blocks.first { $0.id == first.id }!.frame.height == grown.frame.height, "Automatic text height survives save and reopen")
    window.contentView = nil
    print("PASS: \(count) block selection, native focus, IME, Delete, annotation and text layout assertions")
    return count
}
