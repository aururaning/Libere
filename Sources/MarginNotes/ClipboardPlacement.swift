import SwiftUI
#if SWIFT_PACKAGE
import MarginCore
#endif

/// One placement rule for copy, move and file intake. Explicit pointer locations
/// are exact; only a paste without a pointer searches for vacant space.
enum ClipboardPlacement {
    static func position(_ blocks: [Block], in note: inout Note, at point: CGPoint?) throws -> [Block] {
        guard !blocks.isEmpty, blocks.allSatisfy({
            $0.frame.x.isFinite && $0.frame.y.isFinite && $0.frame.maxX.isFinite && $0.frame.maxY.isFinite
                && $0.frame.width > 0 && $0.frame.height > 0
        }), point.map({ $0.x.isFinite && $0.y.isFinite }) ?? true else { throw StoreError.corrupt }
        let x = blocks.map(\.frame.x).min()!, y = blocks.map(\.frame.y).min()!
        let desired = Rect(max(0, point?.x ?? 28), max(0, point?.y ?? 28),
                           blocks.map(\.frame.maxX).max()! - x, blocks.map(\.frame.maxY).max()! - y)
        guard desired.maxX.isFinite, desired.maxY.isFinite else { throw StoreError.corrupt }
        let frame: Rect
        if point != nil {
            frame = desired
            if !note.paper.isContinuous && (frame.maxX > note.width || frame.maxY > note.height) {
                note.paper = note.width > 794 ? .wideContinuous : .continuous
            }
        } else {
            var available = CanvasLayout.vacant(desired, paper: note.paper, occupied: note.blocks.map(\.visibleFrame), canvasWidth: note.width)
            if available == nil && !note.paper.isContinuous {
                note.paper = note.width > 794 ? .wideContinuous : .continuous
                available = CanvasLayout.vacant(desired, paper: note.paper, occupied: note.blocks.map(\.visibleFrame), canvasWidth: note.width)
            }
            guard let available else {
                throw NSError(domain: "ClipboardPlacement", code: 1, userInfo: [NSLocalizedDescriptionKey: "页面宽度不足，无法保留这些内容块的完整尺寸。"])
            }
            frame = available
        }
        return blocks.map { original in
            var copy = original; copy.frame.x += frame.x - x; copy.frame.y += frame.y - y; return copy
        }
    }
}
