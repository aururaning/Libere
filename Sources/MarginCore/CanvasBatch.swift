import Foundation

public enum CanvasBatch {
    public enum Alignment: String, CaseIterable { case left, right, top, bottom, horizontalCenter, verticalCenter, horizontalSpacing, verticalSpacing }
    public static func translated(_ selected: Set<UUID>, dx: Double, dy: Double, in note: Note) -> [Block]? {
        guard dx.isFinite, dy.isFinite, !selected.isEmpty else { return nil }
        let anchors = Dictionary(note.anchors.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var affected = selected
        var changed = true
        while changed {
            changed = false
            for block in note.blocks {
                if let id = block.anchorID, let anchor = anchors[id], affected.contains(anchor.ownerID), affected.insert(block.id).inserted { changed = true }
            }
        }
        let blocks = note.blocks.filter { affected.contains($0.id) }
        guard !blocks.isEmpty, !blocks.contains(where: \.locked) else { return nil }
        let inset = note.paper.isContinuous ? 0.0 : CanvasLayout.margin
        let x = min(max(dx, inset - blocks.map(\.frame.x).min()!), note.width - inset - blocks.map(\.frame.maxX).max()!)
        let upperY = note.paper.isContinuous ? Double.greatestFiniteMagnitude : note.paper.height - inset - blocks.map(\.frame.maxY).max()!
        let y = min(max(dy, inset - blocks.map(\.frame.y).min()!), upperY)
        let result = note.blocks.map { original in
            guard affected.contains(original.id) else { return original }
            var block = original; block.frame.x += x; block.frame.y += y
            if selected.contains(block.id), let id = block.anchorID, let anchor = anchors[id], !affected.contains(anchor.ownerID) { block.anchorID = nil }
            return block
        }
        guard result.filter({ affected.contains($0.id) }).allSatisfy({ CanvasLayout.fits($0.frame, paper: note.paper, canvasWidth: note.width) }) else { return nil }
        return result
    }
    public static func aligned(_ selected: Set<UUID>, by alignment: Alignment, in note: Note) -> [Block]? {
        let blocks = note.blocks.filter { selected.contains($0.id) }
        guard blocks.count >= 2, note.ink?.isEmpty != false,
              !blocks.contains(where: { block in block.locked || block.anchorID != nil || note.anchors.contains { $0.ownerID == block.id }
                  || (block.pageAnnotations?.values.contains { $0.ink?.isEmpty == false || !$0.texts.isEmpty } ?? false) }) else { return nil }
        let left = blocks.map(\.frame.x).min()!, right = blocks.map(\.frame.maxX).max()!
        let top = blocks.map(\.frame.y).min()!, bottom = blocks.map(\.frame.maxY).max()!
        var targets = Dictionary(blocks.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        if alignment == .horizontalSpacing || alignment == .verticalSpacing {
            guard blocks.count >= 3 else { return nil }
            let horizontal = alignment == .horizontalSpacing
            let ordered = blocks.sorted { horizontal ? $0.frame.x < $1.frame.x : $0.frame.y < $1.frame.y }
            let length = blocks.reduce(0) { $0 + (horizontal ? $1.frame.width : $1.frame.height) }
            let gap = ((horizontal ? right - left : bottom - top) - length) / Double(blocks.count - 1)
            guard gap >= 0 else { return nil }
            var cursor = horizontal ? left : top
            for block in ordered {
                if horizontal { targets[block.id]!.x = cursor } else { targets[block.id]!.y = cursor }
                cursor += (horizontal ? block.frame.width : block.frame.height) + gap
            }
        } else {
            for block in blocks {
                switch alignment {
                case .left: targets[block.id]!.x = left
                case .right: targets[block.id]!.x = right - block.frame.width
                case .top: targets[block.id]!.y = top
                case .bottom: targets[block.id]!.y = bottom - block.frame.height
                case .horizontalCenter: targets[block.id]!.x = (left + right - block.frame.width) / 2
                case .verticalCenter: targets[block.id]!.y = (top + bottom - block.frame.height) / 2
                default: break
                }
            }
        }
        guard targets.values.allSatisfy({ CanvasLayout.fits($0, paper: note.paper, canvasWidth: note.width) }) else { return nil }
        return note.blocks.map { original in var block = original; if let frame = targets[block.id] { block.frame = frame }; return block }
    }
}
