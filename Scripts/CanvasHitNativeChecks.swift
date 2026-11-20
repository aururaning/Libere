import Foundation
import SwiftUI

@MainActor private final class HitViews { var views: [String: NSView] = [:] }
@MainActor private struct HitProbe: NSViewRepresentable {
    let name: String
    let area: CanvasPointerInteraction.Area
    let registry: HitViews
    func makeNSView(context: Context) -> NSView {
        let view = CanvasPointerView(); view.area = area; view.identifier = NSUserInterfaceItemIdentifier(name)
        registry.views[name] = view; return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

@MainActor func runCanvasHitNativeChecks() async throws -> Int {
    var count = 0
    func check(_ value: Bool, _ name: String) { precondition(value, name); count += 1 }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("libere-hit-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(root: root)
    store.create(); store.cancelRename(); store.snap = false
    let a = Block(.text, frame: Rect(100, 100, 240, 180), text: "A")
    let b = Block(.text, frame: Rect(460, 120, 260, 200), text: "B")
    store.edit { $0.blocks = [a, b]; $0.anchors = []; $0.fitCanvas(width: 900, height: 1000) }
    store.clearBlockSelection()
    store.tapCanvas(at: CGPoint(x: 150, y: 160))
    check(store.blockSelection == a.id && store.editingBlockID == nil, "Coordinates select the actual first block")
    store.tapCanvas(at: CGPoint(x: 530, y: 170))
    check(store.blockSelection == b.id, "Clicking another block cannot be stolen by the previous selection")
    for point in [CGPoint(x: 341, y: 170), CGPoint(x: 400, y: 170), CGPoint(x: 740, y: 500), CGPoint(x: 80, y: 220)] {
        store.selectBlock(a.id); store.tapCanvas(at: point)
        check(store.blockSelection == nil && !store.blockKeyboardFocus, "Blank coordinate clears selection without choosing a nearest block")
    }
    store.tapCanvas(at: CGPoint(x: 150, y: 160), count: 2)
    check(store.editingBlockID == a.id, "Double click edits the block at the pointer")
    store.tapCanvas(at: CGPoint(x: 530, y: 170))
    check(store.editingBlockID == nil && store.blockSelection == b.id, "A different block receives the same click after ending the old editor")
    check(!store.beginBlockDrag(a.id, at: CGPoint(x: 530, y: 170)) && store.draggingBlockID == nil,
          "A misrouted gesture starting on B cannot drag A")
    check(!store.beginBlockDrag(a.id, at: CGPoint(x: 400, y: 170)) && store.draggingBlockID == nil,
          "A gesture starting on blank paper cannot drag a nearby block")
    check(store.beginBlockDrag(a.id, at: CGPoint(x: 150, y: 160)), "A gesture starting inside A can drag A")
    store.finishBlockDrag(b.id)
    check(store.draggingBlockID == a.id && store.blockSelection == a.id, "A stale end callback cannot change another active drag")
    let before = store.note!.blocks
    store.cancelBlockDrag(a.id)
    check(store.draggingBlockID == nil && store.blockKeyboardFocus && store.note!.blocks == before,
          "Cancelled drag releases focus and preserves all frames")
    store.beginBlockEditing(a.id); store.beginBlockDrag(a.id, at: CGPoint(x: 80, y: 112))
    store.cancelBlockDrag(a.id)
    check(store.editingBlockID == a.id && !store.blockKeyboardFocus, "Cancellation during editing keeps the editor usable")
    store.beginBlockDrag(a.id); store.clearBlockSelection(); store.finishBlockDrag(a.id)
    check(store.draggingBlockID == nil && store.blockSelection == nil, "Escape/blank cancellation cannot be resurrected by a late drag end")
    store.selectBlock(a.id); store.editBlock(a.id) { $0.locked = true }
    check(!store.beginBlockDrag(a.id, at: CGPoint(x: 150, y: 160)), "Locked blocks refuse pointer movement")
    store.editBlock(a.id) { $0.locked = false }
    store.tool = .ink; store.tapCanvas(at: CGPoint(x: 150, y: 160))
    check(store.tool == .ink, "Pointer selection does not unexpectedly exit handwriting")
    store.tool = .select; store.selectBlock(a.id)

    // Use the actual SwiftUI placement with AppKit child views, not just Rect arithmetic.
    // This checks the formerly full-canvas container and its empty handle gutter.
    let registry = HitViews()
    let handle = CanvasItemGeometry.moveHandle(for: a.frame, paperWidth: 900, paperHeight: 1000, size: BlockMoveHandle.hitSize)
    let geometry = CanvasItemGeometry(body: a.frame, handle: handle)
    let fixture = AnyView(ZStack(alignment: .topLeading) {
        Color.white.allowsHitTesting(false)
        CanvasItemPlacement(geometry: geometry) {
            HitProbe(name: "a", area: .body(a.id), registry: registry).contextMenu { Button("A") {} }
        } handle: { HitProbe(name: "handle", area: .move(a.id), registry: registry) }.zIndex(1)
        CanvasItemPlacement(geometry: CanvasItemGeometry(body: b.frame)) {
            HitProbe(name: "b", area: .body(b.id), registry: registry).contextMenu { Button("B") {} }
        } handle: { EmptyView() }
    }.frame(width: 900, height: 1000))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let viewport = CanvasScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600)); window.contentView = viewport
    viewport.pointerInteraction = store.canvasPointer
    let pageID = UUID()
    viewport.update(pageID: pageID, size: CGSize(width: 900, height: 1000), zoom: 1, fitting: true, content: fixture)
    viewport.layoutSubtreeIfNeeded(); viewport.host.layoutSubtreeIfNeeded()
    await Task.yield()
    check(registry.views.count == 3, "SwiftUI materializes both bounded blocks and the separate handle")
    for (name, frame) in [("a", a.frame), ("b", b.frame), ("handle", handle)] {
        let view = registry.views[name]!, actual = view.convert(view.bounds, to: viewport.paper)
        check(abs(actual.minX - frame.x) < 0.1 && abs(actual.minY - frame.y) < 0.1
            && abs(actual.width - frame.width) < 0.1 && abs(actual.height - frame.height) < 0.1,
              "Actual SwiftUI/AppKit view bounds agree with the drawing and picking geometry: " + name)
    }
    let shape = CanvasItemHitShape(geometry: geometry).path(in: CGRect(x: 0, y: 0, width: geometry.bounds.width, height: geometry.bounds.height))
    check(!shape.contains(CGPoint(x: 10, y: 100)) && shape.contains(CGPoint(x: 10, y: 10)),
          "SwiftUI's interaction path excludes blank space below the external handle")
    func hitName(_ point: CGPoint) -> String? {
        let windowPoint = viewport.paper.convert(point, to: nil)
        switch viewport.pointerArea(at: windowPoint, in: window) {
        case .body(let id): return id == a.id ? "a" : id == b.id ? "b" : nil
        case .move(let id): return id == a.id ? "handle" : nil
        default: return nil
        }
    }
    func describeHit(_ point: CGPoint) {
        let windowPoint = viewport.paper.convert(point, to: nil)
        let parentPoint = viewport.superview?.convert(windowPoint, from: nil) ?? windowPoint
        let hit = viewport.hitTest(parentPoint)
        var rows = ["HIT DEBUG point=\(point) window=\(windowPoint) parent=\(parentPoint) hit=\(String(describing: hit))",
                    "viewport=\(viewport.frame), \(viewport.bounds) clip=\(viewport.contentView.frame), \(viewport.contentView.bounds)",
                    "paper=\(viewport.paper.frame), \(viewport.paper.bounds) host=\(viewport.host.frame), \(viewport.host.bounds)"]
        for (name, view) in registry.views {
            rows.append("\(name): frame=\(view.frame), bounds=\(view.bounds), point=\(view.convert(windowPoint, from: nil)), parent=\(String(describing: view.superview))")
        }
        FileHandle.standardError.write(Data((rows.joined(separator: "\n") + "\n").utf8))
    }
    for zoom in [0.25, 0.5, 1.0, 2.0, 6.0] {
        viewport.update(pageID: pageID, size: CGSize(width: 900, height: 1000), zoom: zoom, fitting: true, content: fixture)
        viewport.layoutSubtreeIfNeeded(); viewport.host.layoutSubtreeIfNeeded()
        store.zoom = zoom
        for (point, name) in [(CGPoint(x: 120, y: 115), "a"), (CGPoint(x: 500, y: 150), "b"), (CGPoint(x: 80, y: 112), "handle")] {
            let visible = viewport.contentView.bounds.size
            viewport.contentView.scroll(to: NSPoint(x: max(0, point.x - visible.width / 2), y: max(0, point.y - visible.height / 2)))
            viewport.reflectScrolledClipView(viewport.contentView)
            let converted = viewport.paper.convert(viewport.paper.convert(point, to: nil), from: nil)
            check(abs(converted.x - point.x) < 0.01 && abs(converted.y - point.y) < 0.01,
                  "Zoomed/scrolled native window coordinates return to the same paper point")
            if hitName(point) != name { describeHit(point) }
            check(hitName(point) == name, "Native surface routing finds the visible item at zoom \(zoom): \(name)")
            let expected: CanvasHitTarget = name == "a" ? .block(a.id) : name == "b" ? .block(b.id) : .move(a.id)
            check(store.canvasHit(at: converted) == expected, "Native coordinate conversion and semantic target agree")
        }
        let blank = CGPoint(x: 80, y: 220), visible = viewport.contentView.bounds.size
        viewport.contentView.scroll(to: NSPoint(x: max(0, blank.x - visible.width / 2), y: max(0, blank.y - visible.height / 2)))
        viewport.reflectScrolledClipView(viewport.contentView)
        check(hitName(blank) == nil && store.canvasHit(at: blank) == .paper, "Blank gutter remains blank after zoom and scrolling")
    }
    viewport.update(pageID: pageID, size: CGSize(width: 900, height: 1000), zoom: 0.25, fitting: true, content: fixture)
    viewport.didClickDesk = store.clearBlockSelection
    store.beginBlockEditing(a.id)
    let clip = viewport.contentView
    let desk = clip.convert(CGPoint(x: clip.bounds.minX + 8, y: clip.bounds.midY), to: nil)
    check(viewport.handleDeskClick(at: desk, in: window) && store.blockSelection == nil && store.editingBlockID == nil,
          "Clicking the gray desk exits editing and clears the selection")
    store.selectBlock(b.id)
    check(!viewport.handleDeskClick(at: viewport.paper.convert(CGPoint(x: 500, y: 150), to: nil), in: window) && store.blockSelection == b.id,
          "Desk observer does not consume paper clicks")
    let pagesBefore = store.note!.height
    viewport.contentView.scroll(to: NSPoint(x: 0, y: 10000))
    check(store.note!.height == pagesBefore, "Scrolling the native viewport never expands stored paper content")
    window.contentView = nil
    print("PASS: \(count) coordinate selection, bounded SwiftUI/AppKit hit testing, zoom, scrolling and drag cancellation assertions")
    return count
}
