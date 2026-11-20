import Foundation

/// Drawing and picking share document coordinates. Empty space is never assigned to
/// the nearest block; the only out-of-frame regions are visible selection controls.
public enum CanvasHitTarget: Equatable, Sendable {
    case outside, paper, block(UUID), move(UUID), resize(UUID), anchor(UUID)
}

public struct CanvasItemGeometry: Equatable, Sendable {
    public static let pdfFooterHeight = 28.0
    public var body: Rect
    public var handle: Rect?
    public init(body: Rect, handle: Rect? = nil) { self.body = body; self.handle = handle }
    public var bounds: Rect {
        guard let handle else { return body }
        let x = min(body.x, handle.x), y = min(body.y, handle.y)
        return Rect(x, y, max(body.maxX, handle.maxX) - x, max(body.maxY, handle.maxY) - y)
    }
    public static func contains(_ frame: Rect, x: Double, y: Double) -> Bool {
        x.isFinite && y.isFinite && x >= frame.x && y >= frame.y && x < frame.maxX && y < frame.maxY
    }
    public func contains(x: Double, y: Double) -> Bool {
        Self.contains(body, x: x, y: y) || handle.map { Self.contains($0, x: x, y: y) } == true
    }
    public static func displayFrame(_ block: Block) -> Rect {
        Rect(block.frame.x, block.frame.y, max(100, block.frame.width),
             block.isFilePlugin && block.collapsed == true ? Block.collapsedHeight : max(80, block.frame.height))
    }
    public static func moveHandle(for frame: Rect, paperWidth: Double, paperHeight: Double, size: Double) -> Rect {
        let gap = 2.0
        let candidates = [Rect(frame.x - size - gap, frame.y, size, size),
                          Rect(frame.x, frame.y - size - gap, size, size),
                          Rect(frame.maxX + gap, frame.y, size, size),
                          Rect(frame.x, frame.maxY + gap, size, size)]
        return candidates.first { $0.x >= 0 && $0.y >= 0 && $0.maxX <= paperWidth && $0.maxY <= paperHeight } ?? candidates[0]
    }
    public static func resizeCorner(for frame: Rect, zoom: Double) -> Rect {
        let length = min(frame.width, frame.height, max(36, 40 / max(0.25, zoom)))
        return Rect(frame.maxX - length, frame.maxY - length, length, length)
    }
    /// PDF navigation owns the entire footer. Keep the resize target and its
    /// visible handle in the preview, including at small sizes and low zoom.
    public static func resizeCorner(for block: Block, frame proposed: Rect? = nil, zoom: Double) -> Rect {
        let frame = proposed ?? displayFrame(block)
        guard block.kind == .pdf else { return resizeCorner(for: frame, zoom: zoom) }
        let preview = Rect(frame.x, frame.y + Block.collapsedHeight, frame.width,
                           max(0, frame.height - Block.collapsedHeight - pdfFooterHeight))
        return resizeCorner(for: preview, zoom: zoom)
    }
}

public enum CanvasHitTesting {
    /// Expanded anchor targets must leave the selected block's controls reachable.
    public static func anchorRegions(_ anchor: AnnotationAnchor, in note: Note, selected: UUID?,
                                     zoom: Double, handleSize: Double = 28) -> [Rect] {
        guard let p = CanvasLayout.point(anchor, blocks: note.blocks) else { return [] }
        let radius = 22 / max(0.25, zoom)
        var regions = [Rect(p.x - radius, p.y - radius, radius * 2, radius * 2)]
        if let block = note.blocks.first(where: { $0.id == selected }) {
            let frame = CanvasItemGeometry.displayFrame(block)
            var exclusions = [CanvasItemGeometry.moveHandle(for: frame, paperWidth: note.width, paperHeight: note.height, size: handleSize)]
            if !block.locked && block.collapsed != true { exclusions.append(CanvasItemGeometry.resizeCorner(for: block, zoom: zoom)) }
            if block.kind == .pdf && block.collapsed != true {
                exclusions.append(Rect(frame.x, frame.maxY - CanvasItemGeometry.pdfFooterHeight,
                                       frame.width, CanvasItemGeometry.pdfFooterHeight))
            }
            if block.anchorID == anchor.id { exclusions.append(frame) }
            for exclusion in exclusions { regions = regions.flatMap { subtract(exclusion, from: $0) } }
        }
        return regions
    }
    private static func subtract(_ cut: Rect, from rect: Rect) -> [Rect] {
        let x = max(rect.x, cut.x), y = max(rect.y, cut.y)
        let right = min(rect.maxX, cut.maxX), bottom = min(rect.maxY, cut.maxY)
        guard x < right && y < bottom else { return [rect] }
        return [Rect(rect.x, rect.y, rect.width, y - rect.y), Rect(rect.x, bottom, rect.width, rect.maxY - bottom),
                Rect(rect.x, y, x - rect.x, bottom - y), Rect(right, y, rect.maxX - right, bottom - y)]
            .filter { $0.width > 0 && $0.height > 0 }
    }
    public static func target(x: Double, y: Double, in note: Note, selected: UUID?, zoom: Double = 1,
                              handleSize: Double = 28, controls: Bool = true, anchors: Bool = true) -> CanvasHitTarget {
        guard CanvasItemGeometry.contains(Rect(0, 0, note.width, note.height), x: x, y: y) else { return .outside }
        let selection = note.blocks.first { $0.id == selected }
        if let selection, controls {
            let frame = CanvasItemGeometry.displayFrame(selection)
            let handle = CanvasItemGeometry.moveHandle(for: frame, paperWidth: note.width, paperHeight: note.height, size: handleSize)
            if CanvasItemGeometry.contains(handle, x: x, y: y) { return .move(selection.id) }
            if !selection.locked && selection.collapsed != true,
               CanvasItemGeometry.contains(CanvasItemGeometry.resizeCorner(for: selection, zoom: zoom), x: x, y: y) { return .resize(selection.id) }
        }
        if anchors {
            for anchor in note.anchors.reversed() where anchor.ownerID == selected || anchor.id == selection?.anchorID {
                if anchorRegions(anchor, in: note, selected: selected, zoom: zoom, handleSize: handleSize)
                    .contains(where: { CanvasItemGeometry.contains($0, x: x, y: y) }) {
                    return .anchor(anchor.id)
                }
            }
        }
        if let selection {
            let frame = CanvasItemGeometry.displayFrame(selection)
            // The selected item is drawn above its siblings, but only within its own frame.
            if CanvasItemGeometry.contains(frame, x: x, y: y) { return .block(selection.id) }
        }
        for block in note.blocks.reversed() where block.id != selected {
            if CanvasItemGeometry.contains(CanvasItemGeometry.displayFrame(block), x: x, y: y) { return .block(block.id) }
        }
        return .paper
    }
}
