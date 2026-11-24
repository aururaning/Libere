import SwiftUI
import Combine
#if SWIFT_PACKAGE
import MarginCore
#endif

/// A press owns one target until release. Selection chrome and SwiftUI view updates
/// must not retarget, resize, or cancel a move that started on a different surface.
@MainActor final class CanvasPointerInteraction: ObservableObject {
    enum Area: Equatable {
        case paper, body(UUID), border(UUID), move(UUID), resize(UUID)
        func accepts(_ target: CanvasHitTarget) -> Bool {
            switch (self, target) {
            case (.paper, .paper): return true
            case (.body(let a), .block(let b)), (.border(let a), .block(let b)),
                 (.move(let a), .move(let b)), (.resize(let a), .resize(let b)): return a == b
            default: return false
            }
        }
    }
    struct Preview: Equatable {
        let blockID: UUID
        let frame: Rect
        let resizing: Bool
    }
    private struct Press {
        let noteID: UUID
        let target: CanvasHitTarget
        let start: CGPoint
        let scale: Double
        let frame: Rect?
        let doubleClick: Bool
        let createText: Bool
        var moved = false
        var groupMove = false
        var blockID: UUID? {
            switch target {
            case .block(let id), .move(let id), .resize(let id): return id
            default: return nil
            }
        }
        var resizing: Bool { if case .resize = target { return true }; return false }
    }
    private weak var store: AppStore?
    private var press: Press?
    private var lastClick: (noteID: UUID, target: CanvasHitTarget)?
    @Published private(set) var preview: Preview?
    var isPressed: Bool { press != nil }
    var editingBlockID: UUID? { store?.editingBlockID }
    var pressedBlockID: UUID? { press?.blockID }
    var selectedScrollBlockID: UUID? {
        guard let store, let block = store.block, block.collapsed != true, block.kind != .formula,
              block.kind != .link || block.linkMode == .html || block.linkMode == .browser else { return nil }
        return block.id
    }
    func hit(at point: CGPoint) -> CanvasHitTarget { store?.canvasHit(at: point) ?? .outside }
    func attachment(at point: CGPoint) -> UUID? {
        guard let store, let note = store.note,
              case .block(let id) = CanvasHitTesting.target(x: point.x, y: point.y, in: note, selected: store.blockSelection,
                  zoom: store.zoom, controls: false, anchors: false),
              let block = note.blocks.first(where: { $0.id == id }), block.kind.hasAttachment,
              block.collapsed != true, store.editingBlockID != id else { return nil }
        return id
    }

    init(store: AppStore) { self.store = store }
    #if os(macOS)
    func openMarkdownLink(at point: CGPoint, in window: NSWindow?) -> Bool { store?.openMarkdownLink(at: point, in: window) ?? false }
    #endif

    @discardableResult func down(at point: CGPoint, area: Area, clickCount: Int, scale: Double, extendingSelection: Bool = false) -> Bool {
        cancel()
        guard let store, let note = store.note, store.tool == .select || store.tool == .text,
              scale.isFinite, scale > 0 else { return false }
        // Resolve against the pre-selection geometry, once, in native paper coordinates.
        let target = store.canvasHit(at: point)
        guard area.accepts(target) else { lastClick = nil; return false }
        if extendingSelection, case .block(let id) = target { store.multiSelection.toggle(id); lastClick = nil; return true }
        let groupMove: Bool
        switch target { case .block(let id), .move(let id): groupMove = store.multiSelection.selectedIDs.count > 1 && store.multiSelection.selectedIDs.contains(id)
        default: groupMove = false }
        let doubleClick = clickCount == 2 && lastClick?.noteID == note.id && lastClick?.target == target
        let createText = store.tool == .text
        switch target {
        case .block(let id), .move(let id), .resize(let id):
            if groupMove { store.finishBlockEditing(); store.multiSelection.beginMove() }
            else if store.editingBlockID != id { store.selectBlock(id) }
        case .paper:
            if createText { store.finishBlockEditing() } else if !extendingSelection { store.clearBlockSelection() }
            if !createText { store.multiSelection.beginMarquee(additive: extendingSelection) }
        default: return false
        }
        let id: UUID?
        switch target {
        case .block(let value), .move(let value), .resize(let value): id = value
        default: id = nil
        }
        press = Press(noteID: note.id, target: target, start: point, scale: scale,
                      frame: store.note?.blocks.first(where: { $0.id == id })?.frame,
                      doubleClick: doubleClick, createText: createText, groupMove: groupMove)
        return true
    }

    func dragged(to point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite, let store, var current = press else { return }
        guard store.selection == current.noteID, store.tool == .select || (current.createText && store.tool == .text)
        else { cancel(); return }
        let dx = point.x - current.start.x, dy = point.y - current.start.y
        // Keep the threshold in screen points at every canvas zoom.
        guard current.moved || hypot(dx, dy) * current.scale >= 3 else { return }
        current.moved = true; press = current; lastClick = nil
        if case .paper = current.target, !current.createText { store.multiSelection.updateMarquee(from: current.start, to: point); return }
        if current.groupMove { store.multiSelection.move(dx: dx, dy: dy); return }
        guard let id = current.blockID, let initial = current.frame else { return }
        guard store.blockSelection == id, let block = store.note?.blocks.first(where: { $0.id == id }),
              !block.locked, block.frame == initial else { cancel(); return }
        if store.draggingBlockID != id {
            // down() already checked the exact target. A newly visible resize corner
            // must not reinterpret this same press after selection has changed.
            guard store.beginBlockDrag(id) else { cancel(); return }
        }
        let frame = current.resizing
            ? Rect(initial.x, initial.y, max(100, initial.width + dx), max(80, initial.height + dy))
            : Rect(initial.x + dx, initial.y + dy, initial.width, initial.height)
        let next = Preview(blockID: id, frame: frame, resizing: current.resizing)
        if preview != next { preview = next }
    }

    func up(at point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite else { cancel(); return }
        guard press != nil else { return }
        dragged(to: point)
        guard let current = press, let store else { return }
        let final = preview
        press = nil
        guard store.selection == current.noteID else { cancel(); return }
        if current.moved {
            if case .paper = current.target, !current.createText { store.multiSelection.finishMarquee(); return }
            if current.groupMove { store.multiSelection.finishMove(); return }
            if let final, store.draggingBlockID == final.blockID {
                store.setFrame(final.blockID, final.frame, resizing: final.resizing)
                store.finishBlockDrag(final.blockID)
            }
            preview = nil
            return
        }
        lastClick = (current.noteID, current.target)
        switch current.target {
        case .block(let id):
            if current.doubleClick { store.activateBlock(id) }
        case .paper:
            if current.createText || current.doubleClick { store.insert(.text, point: point) }
        default: break
        }
    }

    func cancel() {
        store?.multiSelection.cancelPreview()
        let id = press?.blockID ?? preview?.blockID
        press = nil
        if preview != nil { preview = nil }
        if let id { store?.cancelBlockDrag(id) }
    }
}

#if os(macOS)
/// Only explicit drag surfaces receive mouse input; native editors and inline
/// buttons keep their own event handling. Capture belongs to the stable viewport.
@MainActor final class CanvasPointerView: NSView {
    var area = CanvasPointerInteraction.Area.paper
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return containsPointer(local) ? self : nil
    }
    func containsPointer(_ local: CGPoint) -> Bool {
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(local) else { return false }
        if case .border = area, bounds.insetBy(dx: 8, dy: 8).contains(local) { return false }
        return true
    }
    override func mouseDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control), let viewport = CanvasScrollView.magnificationTarget(from: self),
              viewport.beginPointer(at: event.locationInWindow, in: event.window, area: area, clickCount: event.clickCount, extendingSelection: event.modifierFlags.contains(.shift))
        else { super.mouseDown(with: event); return }
    }
}

@MainActor struct CanvasPointerSurface: NSViewRepresentable {
    let area: CanvasPointerInteraction.Area
    func makeNSView(context: Context) -> CanvasPointerView { CanvasPointerView() }
    func updateNSView(_ view: CanvasPointerView, context: Context) {
        view.area = area
        if case .paper = area { view.setAccessibilityElement(false) }
        else {
            view.setAccessibilityElement(true)
            view.setAccessibilityRole(.group)
            switch area {
            case .move: view.setAccessibilityLabel("移动内容块")
            case .resize: view.setAccessibilityLabel("调整内容块大小")
            default: view.setAccessibilityLabel("内容块")
            }
        }
    }
}
#endif
