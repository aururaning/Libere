import Foundation
import SwiftUI
import WebKit

@MainActor private struct AttachmentWheelFixture: View {
    let block: Block
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white.overlay { CanvasPointerSurface(area: .paper) }
            BlockScrollScope(id: block.id) { CanvasViewport(pageID: block.id, size: CGSize(width: 400, height: 1400), zoom: 1, fitting: false,
                didZoom: { _ in }, content: AnyView(Color.white.frame(width: 400, height: 1400)), attachmentBlockID: block.id) }
                .frame(width: 400, height: 240)
                .overlay { CanvasPointerSurface(area: .body(block.id)) }
                .offset(x: 100, y: 100)
        }.frame(width: 900, height: 1800)
    }
}

@MainActor func runAttachmentInteractionNativeChecks() async throws -> Int {
    var count = 0
    func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereAttachmentCheck-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(root: root)
    store.create(); store.cancelRename(); store.snap = false; store.fitToWidth = false
    var pdf = Block(.pdf, frame: Rect(40, 40, 400, 500)); pdf.locked = true; pdf.pdfPage = 1
    var existing = AttachmentPageAnnotations()
    let short = PageTextAnnotation(frame: Rect(20, 30, 180, 42), text: "同一页内批注")
    existing.texts = [short]; existing.ink = Data([4, 5, 6])
    pdf.pageAnnotations = ["1": existing]
    store.edit { $0.blocks = [pdf]; $0.anchors = []; $0.ink = Data([1, 2, 3]); $0.fitCanvas(width: 900, height: 1800) }
    let destination = InkDestination(noteID: store.selection!, blockID: pdf.id, page: 1)
    let paper = CGSize(width: 600, height: 800), position = CGPoint(x: 310, y: 240)
    check(store.insertPageText(at: position, paper: paper, destination: destination, clickCount: 1) == nil,
          "One click on a page never inserts a text annotation")
    let created = store.insertPageText(at: position, paper: paper, destination: destination, clickCount: 2)
    check(created != nil && store.note!.blocks[0].annotations(on: 1).texts.count == 2,
          "A double click inserts one annotation even on a locked PDF")
    check(store.note!.blocks[0].frame == pdf.frame && store.note!.blocks[0].pdfPage == 1
          && store.note!.blocks[0].annotations(on: 1).ink == existing.ink && store.note!.ink == Data([1, 2, 3]),
          "Text annotation leaves the locked frame, preview page and both ink layers fixed")
    check(store.insertPageText(at: position, paper: paper, destination: destination, clickCount: 2) == nil,
          "Double clicking an existing annotation cannot create a duplicate underneath")
    check(store.insertPageText(at: CGPoint(x: -1, y: 100), paper: paper, destination: destination, clickCount: 2) == nil,
          "Only an actual point on the document accepts insertion")
    store.undo()
    check(store.note!.blocks[0].annotations(on: 1).texts == [short], "One undo removes only the new page annotation")

    // Real native web view geometry is identical in inline/read/text modes; controls
    // do not add a 30-point header or inflate a saved short annotation to 80 points.
    for enabled in [false, true] {
        for scale in [0.5, 1.0, 2.0] {
            let view = NSHostingView(rootView: PageTextCard(store: store, destination: destination, annotation: short,
                editing: enabled, selection: .constant(enabled ? short.id : nil), paper: paper, scale: scale)
                .frame(width: 600, height: 800, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading))
            view.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
            view.layoutSubtreeIfNeeded(); await Task.yield(); view.layoutSubtreeIfNeeded()
            let web = descendants(view).compactMap { $0 as? WKWebView }.first!
            let rect = web.convert(web.bounds, to: view)
            check(abs(rect.width / scale - 180) < 0.1 && abs(rect.height / scale - 42) < 0.1,
                  "Saved annotation size stays exact in mode \(enabled), scale \(scale)")
        }
    }

    // Expanding modifies the same persistent array order that drawing/picking use.
    var first = Block(.file, frame: Rect(100, 100, 400, 36)); first.collapsed = true; first.expandedHeight = 400
    var second = Block(.file, frame: Rect(120, 110, 400, 36)); second.collapsed = true; second.expandedHeight = 400
    let cover = Block(.text, frame: Rect(130, 140, 300, 200), text: "原先在上层的文字")
    store.edit { $0.blocks = [first, second, cover]; $0.anchors = [] }
    store.toggleCollapsed(first.id)
    check(store.note!.blocks.last?.id == first.id && store.blockSelection == first.id, "First expanded file is raised above existing content")
    store.toggleCollapsed(second.id); store.clearBlockSelection()
    check(store.note!.blocks.suffix(2).map(\.id) == [first.id, second.id]
          && store.canvasHit(at: CGPoint(x: 200, y: 200)) == .block(second.id), "Most recently expanded file wins both draw and hit order")
    let order = store.note!.blocks.map(\.id)
    store.toggleCollapsed(first.id); store.toggleCollapsed(first.id); store.clearBlockSelection()
    check(store.note!.blocks.last?.id == first.id && store.canvasHit(at: CGPoint(x: 200, y: 200)) == .block(first.id),
          "Reopening an older file raises it again")
    store.undo(); store.clearBlockSelection()
    check(store.note!.blocks.map(\.id) == order && store.note!.blocks.first { $0.id == first.id }!.collapsed == true,
          "Undo restores both collapsed state and previous stacking order")
    store.redo(); store.clearBlockSelection(); store.flush()
    let reopened = try AppStore(root: root)
    check(reopened.workspace.notes.first { $0.id == store.selection }!.blocks.last?.id == first.id,
          "File stacking order survives application restart")

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let viewport = CanvasScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600)); window.contentView = viewport
    viewport.pointerInteraction = store.canvasPointer
    func layout() async { await Task.yield(); viewport.layoutSubtreeIfNeeded(); viewport.host.layoutSubtreeIfNeeded() }
    func show(_ point: CGPoint) -> CGPoint {
        let size = viewport.contentView.bounds.size
        viewport.contentView.scroll(to: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
        viewport.reflectScrolledClipView(viewport.contentView)
        return viewport.paper.convert(point, to: nil)
    }
    var file = Block(.file, frame: Rect(100, 100, 400, 240)); file.assetName = "long.py"
    store.edit { $0.blocks = [file]; $0.anchors = [] }
    store.selectBlock(file.id)
    for scale in [0.25, 0.5, 1.0, 2.0, 6.0] {
        store.zoom = scale
        viewport.update(pageID: store.selection!, size: CGSize(width: 900, height: 1800), zoom: scale, fitting: true,
                        content: AnyView(AttachmentWheelFixture(block: file)))
        await layout()
        let point = show(CGPoint(x: 300, y: 220))
        let inner = descendants(viewport.host).compactMap { $0 as? CanvasScrollView }.first { $0.attachmentBlockID == file.id }!
        inner.contentView.scroll(to: .zero); inner.reflectScrolledClipView(inner.contentView)
        let outerOrigin = viewport.contentView.bounds.origin
        let handled = viewport.routeAttachmentScroll(at: point, in: window, delta: CGSize(width: 0, height: -40), precise: true)
        check(handled && inner.contentView.bounds.minY > 0 && viewport.contentView.bounds.origin == outerOrigin,
              "Wheel reaches the attachment through its selection overlay, not the main canvas, at \(scale)")
        check(abs(inner.contentView.bounds.minY * scale - 40) < 1,
              "Precise wheel deltas stay in screen units at \(scale)")
        check(store.note!.blocks[0].frame == file.frame && store.blockSelection == file.id,
              "Scrolling never moves, edits or changes the selected attachment")
        check(!inner.allowsMagnification && CanvasScrollView.magnificationTarget(from: inner.host) === viewport,
              "Inline wheel container preserves the outer canvas pinch target")
    }
    let selectedInner = descendants(viewport.host).compactMap { $0 as? CanvasScrollView }.first { $0.attachmentBlockID == file.id }!
    selectedInner.contentView.scroll(to: CGPoint(x: 0, y: 100_000)); selectedInner.reflectScrolledClipView(selectedInner.contentView)
    let blankPoint = show(CGPoint(x: 600, y: 300)), outerBeforeBoundary = viewport.contentView.bounds.origin
    check(viewport.routeAttachmentScroll(at: blankPoint, in: window, delta: CGSize(width: 0, height: -40), precise: true)
          && viewport.contentView.bounds.origin == outerBeforeBoundary,
          "A selected block consumes wheel input at its bottom even when the pointer is on blank canvas")
    store.beginBlockEditing(file.id)
    check(viewport.routeAttachmentScroll(at: blankPoint, in: window, delta: CGSize(width: 0, height: 40), precise: true)
          && viewport.contentView.bounds.origin == outerBeforeBoundary,
          "Editing does not release selected-block wheel ownership to the outer page")
    store.clearBlockSelection(); store.edit { $0.blocks.append(cover) }
    let hoverPoint = show(CGPoint(x: 200, y: 200)), innerBefore = selectedInner.contentView.bounds.origin
    check(viewport.routeAttachmentScroll(at: hoverPoint, in: window, delta: CGSize(width: 0, height: -40), precise: true)
          && selectedInner.contentView.bounds.origin == innerBefore,
          "With no selection the page owns the wheel, including above a scrollable attachment")

    var owner = Block(.text, frame: Rect(50, 50, 250, 300), text: "Owner"); owner.textFormat = nil
    var child = Block(.text, frame: Rect(480, 180, 260, 180), text: "Attached"); child.textFormat = nil
    let anchor = AnnotationAnchor(ownerID: owner.id, label: "批注", u: 430.0 / 250, v: 130.0 / 300)
    child.anchorID = anchor.id
    for scale in [0.25, 0.5, 1.0, 2.0, 6.0] {
        store.edit { $0.blocks = [owner, child]; $0.anchors = [anchor] }; store.selectBlock(child.id); store.zoom = scale
        viewport.update(pageID: store.selection!, size: CGSize(width: 900, height: 1800), zoom: scale, fitting: true,
                        content: AnyView(NoteCanvas(store: store, note: store.note!).paper))
        await layout()
        let handle = CanvasItemGeometry.moveHandle(for: child.frame, paperWidth: 900, paperHeight: 1800, size: BlockMoveHandle.hitSize)
        let p = CGPoint(x: handle.x + handle.width / 2, y: handle.y + handle.height / 2)
        let start = show(p)
        check(viewport.pointerArea(at: start, in: window) == .move(child.id), "Actual selected attached block handle routes above the anchor at \(scale)")
        check(viewport.beginPointer(at: start, in: window, area: .move(child.id), clickCount: 1), "Attached handle begins dragging immediately")
        let end = viewport.paper.convert(CGPoint(x: p.x, y: p.y + 100), to: nil)
        viewport.continuePointer(.leftMouseDragged, at: end, in: window); viewport.continuePointer(.leftMouseUp, at: end, in: window)
        check(store.note!.blocks[1].frame.y == child.frame.y + 100 && store.note!.blocks[1].anchorID == nil && store.note!.blocks[0] == owner,
              "Dragging away releases the snap without moving the original owner")
        store.undo(); check(store.note!.blocks[1] == child, "One undo restores both the position and attachment")
    }
    store.snap = true
    store.setFrame(child.id, Rect(child.frame.x, child.frame.y + 10, child.frame.width, child.frame.height))
    check(store.note!.blocks[1].anchorID == nil && store.note!.blocks[1].frame.y != child.frame.y,
          "A short intentional move releases the previous anchor instead of snapping straight back")
    store.setFrame(child.id, child.frame)
    check(store.note!.blocks[1].anchorID == anchor.id && store.note!.blocks[1].frame == child.frame,
          "A detached block can still be deliberately snapped back to the same point")
    window.contentView = nil
    print("PASS: \(count) attachment wheel, annotation, anchor control and expansion stacking assertions")
    return count
}
