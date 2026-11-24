import Foundation
import SwiftUI

@MainActor private struct PointerCanvasFixture: View {
    @ObservedObject var store: AppStore
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white.overlay { CanvasPointerSurface(area: .paper) }
            ForEach(store.note!.blocks) { block in
                BlockCard(store: store, block: block).zIndex(store.blockSelection == block.id ? 1 : 0)
            }
        }.frame(width: 900, height: 1000).coordinateSpace(name: "note-paper")
    }
}

@MainActor func runCanvasPointerNativeChecks() async throws -> Int {
    var count = 0
    func check(_ value: Bool, _ name: String) { precondition(value, name); count += 1 }
    func near(_ actual: Rect?, _ expected: Rect) -> Bool {
        guard let actual else { return false }
        return abs(actual.x - expected.x) < 0.000001 && abs(actual.y - expected.y) < 0.000001
            && abs(actual.width - expected.width) < 0.000001 && abs(actual.height - expected.height) < 0.000001
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("libere-pointer-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(root: root)
    store.create(); store.cancelRename(); store.snap = false
    var a = Block(.text, frame: Rect(100, 100, 240, 180), text: "A")
    var b = Block(.text, frame: Rect(460, 120, 260, 200), text: "B")
    a.textFormat = nil; b.textFormat = nil // Exercise real AppKit editors without starting WebKit.
    func reset() {
        store.clearBlockSelection(); store.zoom = 1
        store.edit { $0.blocks = [a, b]; $0.anchors = []; $0.ink = Data([1, 2, 3]); $0.fitCanvas(width: 900, height: 1000) }
    }
    reset()
    let pointer = store.canvasPointer
    let start = CGPoint(x: 150, y: 170)
    check(pointer.down(at: start, area: .body(a.id), clickCount: 1, scale: 1), "Body starts a native press")
    check(store.blockSelection == a.id && store.editingBlockID == nil && pointer.preview == nil,
          "Selection is synchronous on mouse-down, without waiting for mouse-up or double-click timeout")
    pointer.up(at: start)
    check(store.blockKeyboardFocus && store.note!.blocks == [a, b], "Single click preserves frames and owns Delete")
    pointer.down(at: start, area: .body(a.id), clickCount: 2, scale: 1)
    check(store.editingBlockID == nil, "Second press remains draggable until release")
    pointer.up(at: start)
    check(store.editingBlockID == a.id, "Same-block second click enters editing")
    reset()
    pointer.down(at: start, area: .body(a.id), clickCount: 1, scale: 1); pointer.up(at: start)
    pointer.down(at: CGPoint(x: 500, y: 180), area: .body(b.id), clickCount: 2, scale: 1)
    pointer.up(at: CGPoint(x: 500, y: 180))
    check(store.blockSelection == b.id && store.editingBlockID == nil, "Two rapid clicks on different blocks do not edit the second")

    for selected in [false, true] {
        reset(); if selected { store.selectBlock(a.id) }
        pointer.down(at: start, area: .body(a.id), clickCount: 1, scale: 1)
        pointer.dragged(to: CGPoint(x: 510, y: 190))
        check(store.draggingBlockID == a.id && store.blockSelection == a.id && pointer.preview?.blockID == a.id,
              "Crossing B keeps A captured, whether A started selected or unselected")
        check(store.note!.blocks == [a, b], "Live drag does not write the document on each sample")
        pointer.up(at: CGPoint(x: 530, y: 210))
        check(store.note!.blocks[0].frame == Rect(480, 140, 240, 180) && store.note!.blocks[1] == b,
              "Release commits the captured block using the final paper-coordinate delta")
        check(pointer.preview == nil && !pointer.isPressed && store.draggingBlockID == nil && store.blockKeyboardFocus,
              "Release clears capture and restores keyboard ownership")
        store.undo(); check(store.note!.blocks == [a, b], "One undo reverses the whole drag")
        store.redo(); check(store.note!.blocks[0].frame == Rect(480, 140, 240, 180), "One redo replays the drag")
    }
    reset()
    let corner = CGPoint(x: 330, y: 270)
    pointer.down(at: corner, area: .body(a.id), clickCount: 1, scale: 1)
    pointer.dragged(to: CGPoint(x: 350, y: 290)); pointer.up(at: CGPoint(x: 350, y: 290))
    check(store.note!.blocks[0].frame == Rect(120, 120, 240, 180),
          "New selection's resize corner cannot reinterpret a move that began on an unselected body")
    reset(); store.selectBlock(a.id)
    pointer.down(at: corner, area: .resize(a.id), clickCount: 1, scale: 1)
    pointer.dragged(to: CGPoint(x: 370, y: 300)); pointer.up(at: CGPoint(x: 370, y: 300))
    check(store.note!.blocks[0].frame == Rect(100, 100, 280, 210), "Existing resize handle resizes without moving the origin")

    for scale in [0.25, 0.5, 1.0, 2.0, 6.0] {
        reset(); store.zoom = scale
        pointer.down(at: start, area: .body(a.id), clickCount: 1, scale: scale)
        pointer.dragged(to: CGPoint(x: start.x + 2 / scale, y: start.y))
        check(pointer.preview == nil, "Two screen points of click jitter do not begin dragging at zoom \(scale)")
        pointer.dragged(to: CGPoint(x: start.x + 5 / scale, y: start.y))
        check(near(pointer.preview?.frame, Rect(100 + 5 / scale, 100, 240, 180)), "Drag distance stays in paper units at zoom \(scale)")
        pointer.cancel()
        check(store.note!.blocks == [a, b] && store.draggingBlockID == nil, "Cancellation never commits a preview")
    }
    reset(); store.beginBlockEditing(a.id)
    pointer.down(at: CGPoint(x: 80, y: 112), area: .move(a.id), clickCount: 1, scale: 1)
    pointer.dragged(to: CGPoint(x: 100, y: 142)); pointer.up(at: CGPoint(x: 100, y: 142))
    check(store.editingBlockID == a.id && !store.blockKeyboardFocus && store.note!.blocks[0].frame == Rect(120, 130, 240, 180),
          "External-handle drag preserves edit mode")
    reset(); store.editBlock(a.id) { $0.locked = true }
    pointer.down(at: start, area: .body(a.id), clickCount: 1, scale: 1)
    pointer.dragged(to: CGPoint(x: 250, y: 270)); pointer.up(at: CGPoint(x: 250, y: 270))
    check(store.blockSelection == a.id && store.note!.blocks[0].frame == a.frame && pointer.preview == nil,
          "Locked blocks select immediately but never move")
    reset()
    check(!pointer.down(at: CGPoint(x: 500, y: 180), area: .body(a.id), clickCount: 1, scale: 1), "Misrouted surface cannot select its own wrong block")
    check(!pointer.down(at: CGPoint(x: 400, y: 180), area: .body(a.id), clickCount: 1, scale: 1), "Blank paper cannot be grabbed by a nearby surface")
    store.selectBlock(a.id)
    pointer.down(at: CGPoint(x: 400, y: 180), area: .paper, clickCount: 1, scale: 1)
    check(store.blockSelection == nil && store.editingBlockID == nil, "Blank paper clears selection on down")
    pointer.dragged(to: start); pointer.up(at: start)
    check(store.note!.blocks == [a, b] && store.multiSelection.selectedIDs.contains(a.id), "Marquee starting on blank selects crossed blocks without moving them")
    for action in ["selection", "tool", "escape"] {
        reset(); pointer.down(at: start, area: .body(a.id), clickCount: 1, scale: 1)
        pointer.dragged(to: CGPoint(x: 200, y: 200))
        if action == "selection" { store.selectBlock(b.id) }
        else if action == "tool" { store.tool = .ink }
        else { store.clearBlockSelection() }
        pointer.up(at: CGPoint(x: 250, y: 230))
        check(!pointer.isPressed && pointer.preview == nil && store.note!.blocks == [a, b], "\(action) cancels capture; late release cannot resurrect it")
    }
    reset(); pointer.down(at: start, area: .body(a.id), clickCount: 1, scale: 1)
    store.growTextBlock(a, contentHeight: 500)
    check(store.note!.blocks[0].frame == a.frame, "Async text measurement cannot change geometry during a pending press")
    pointer.cancel()

    // Exercise actual BlockCard surfaces and native window conversion, not just the model.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let viewport = CanvasScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600)); window.contentView = viewport
    viewport.pointerInteraction = pointer
    let fixture = AnyView(PointerCanvasFixture(store: store))
    func layout() async {
        await Task.yield()
        viewport.layoutSubtreeIfNeeded(); viewport.host.layoutSubtreeIfNeeded()
    }
    func show(_ point: CGPoint) -> CGPoint {
        let size = viewport.contentView.bounds.size
        viewport.contentView.scroll(to: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
        viewport.reflectScrolledClipView(viewport.contentView)
        return viewport.paper.convert(point, to: nil)
    }
    for scale in [0.25, 0.5, 1.0, 2.0, 6.0] {
        reset(); store.zoom = scale
        viewport.update(pageID: store.selection!, size: CGSize(width: 900, height: 1000), zoom: scale, fitting: true, content: fixture)
        await layout()
        for (point, expected) in [(start, CanvasPointerInteraction.Area.body(a.id)),
                                  (CGPoint(x: 500, y: 180), .body(b.id)), (CGPoint(x: 400, y: 180), .paper)] {
            let actual = viewport.pointerArea(at: show(point), in: window)
            check(actual == expected, "Rendered BlockCard routes the exact target at zoom \(scale): \(String(describing: actual))")
        }
        let down = show(start)
        check(viewport.beginPointer(at: down, in: window, area: .body(a.id), clickCount: 1), "Native window coordinates begin a press")
        await layout() // Selection introduces external handles and repositions the hosting subtree.
        let end = CGPoint(x: start.x + 60 / scale, y: start.y + 25 / scale)
        viewport.continuePointer(.leftMouseDragged, at: viewport.paper.convert(end, to: nil), in: window)
        await layout() // Live movement updates the original surface's bounds.
        viewport.continuePointer(.leftMouseUp, at: viewport.paper.convert(end, to: nil), in: window)
        check(near(store.note!.blocks[0].frame, Rect(100 + 60 / scale, 100 + 25 / scale, 240, 180)) && store.note!.blocks[1] == b,
              "Native capture survives selection, view movement, magnification and scrolling at \(scale)")
    }
    reset(); store.selectBlock(a.id)
    viewport.update(pageID: store.selection!, size: CGSize(width: 900, height: 1000), zoom: 1, fitting: true, content: fixture)
    await layout()
    check(viewport.pointerArea(at: show(CGPoint(x: 80, y: 112)), in: window) == .move(a.id), "Selected external handle has an exact native surface")
    check(viewport.pointerArea(at: show(CGPoint(x: 80, y: 200)), in: window) == .paper, "Empty gutter below handle stays blank")
    check(viewport.pointerArea(at: show(corner), in: window) == .resize(a.id), "Resize corner is independently routed")
    check(viewport.pointerArea(at: show(CGPoint(x: 315, y: 115)), in: window) == nil, "Inline edit button is not intercepted by the drag router")
    check(viewport.pointerArea(at: show(CGPoint(x: 200, y: 115)), in: window) == .body(a.id), "Text block header can be dragged")
    store.beginBlockEditing(a.id); await layout()
    check(viewport.pointerArea(at: show(start), in: window) == nil, "Native editor keeps text selection and cursor clicks")
    check(viewport.pointerArea(at: show(CGPoint(x: 102, y: 170)), in: window) == nil, "Editing margins remain available for text selection")
    check(viewport.pointerArea(at: show(CGPoint(x: 80, y: 112)), in: window) == .move(a.id), "The external handle remains draggable while editing")
    store.selectBlock(a.id); await layout()
    viewport.beginPointer(at: show(start), in: window, area: .body(a.id), clickCount: 1)
    viewport.continuePointer(.leftMouseDragged, at: viewport.paper.convert(CGPoint(x: 200, y: 190), to: nil), in: window)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    check(!pointer.isPressed && pointer.preview == nil && store.note!.blocks == [a, b], "Losing window focus cancels without committing")
    window.contentView = nil
    print("PASS: \(count) immediate pointer selection, captured dragging, native surfaces and cancellation assertions")
    return count
}
