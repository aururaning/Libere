import Foundation

public enum CanvasLayout {
    public static let margin = 20.0
    public static func clamp(_ r: Rect, to paper: PaperKind, grid: Bool = false, canvasWidth: Double? = nil, minimumHeight: Double = 80) -> Rect {
        let inset = paper.isContinuous ? 0.0 : margin
        let pageWidth = paper.isContinuous ? max(320, canvasWidth ?? paper.width) : paper.width
        let width = min(max(100, r.width), pageWidth - 2 * inset)
        let height = paper.isContinuous ? max(minimumHeight, r.height) : min(max(minimumHeight, r.height), paper.height - 2 * inset)
        func snap(_ n: Double) -> Double { grid ? (n / 8).rounded() * 8 : n }
        let y = max(inset, snap(r.y))
        return Rect(min(max(inset, snap(r.x)), pageWidth - inset - width),
                    paper.isContinuous ? y : min(y, paper.height - inset - height), width, height)
    }
    public static func fits(_ r: Rect, paper: PaperKind, canvasWidth: Double? = nil) -> Bool {
        [r.x, r.y, r.width, r.height].allSatisfy(\.isFinite) && clamp(r, to: paper, canvasWidth: canvasWidth, minimumHeight: Block.collapsedHeight) == r
    }
    public static func vacant(_ size: Rect, paper: PaperKind, occupied: [Rect], canvasWidth: Double? = nil) -> Rect? {
        let first = clamp(size, to: paper, canvasWidth: canvasWidth)
        if !occupied.contains(where: { first.intersects($0, gap: 12) }) { return first }
        // Sweep only candidate edges, not every pixel on a potentially long page.
        let ys = Set([margin] + occupied.map { $0.maxY + 16 }).sorted()
        let xs = Set([margin] + occupied.map { $0.maxX + 16 }).sorted()
        for y in ys { for x in xs {
            let candidate = Rect(x, y, first.width, first.height)
            if fits(candidate, paper: paper, canvasWidth: canvasWidth) && !occupied.contains(where: { candidate.intersects($0, gap: 12) }) { return candidate }
        } }
        return nil
    }
    /// Find the closest free rectangle to the requested annotation position.
    public static func nearestVacant(_ desired: Rect, paper: PaperKind, occupied: [Rect], canvasWidth: Double? = nil) -> Rect? {
        let first = clamp(desired, to: paper, canvasWidth: canvasWidth)
        let pageWidth = paper.isContinuous ? (canvasWidth ?? paper.width) : paper.width
        let xs = Set([first.x, margin, pageWidth - margin - first.width] + occupied.flatMap { [$0.x - first.width - 16, $0.maxX + 16] })
        let ys = Set([first.y, margin] + occupied.flatMap { [$0.y - first.height - 16, $0.maxY + 16] })
        var result: Rect?, distance = Double.infinity
        for y in ys { for x in xs {
            let r = Rect(x, y, first.width, first.height)
            guard fits(r, paper: paper, canvasWidth: canvasWidth), !occupied.contains(where: { r.intersects($0, gap: 12) }) else { continue }
            let d = hypot(x - desired.x, y - desired.y)
            if d < distance || (d == distance && y < (result?.y ?? .infinity)) { result = r; distance = d }
        } }
        return result
    }
    public static func point(_ anchor: AnnotationAnchor, blocks: [Block]) -> (x: Double, y: Double)? {
        guard let owner = blocks.first(where: { $0.id == anchor.ownerID }) else { return nil }
        return (owner.frame.x + owner.frame.width * anchor.u, owner.frame.y + owner.frame.height * anchor.v)
    }
    public static func anchored(_ rect: Rect, at anchor: AnnotationAnchor, blocks: [Block]) -> Rect? {
        guard let p = point(anchor, blocks: blocks) else { return nil }
        return Rect(p.x - (anchor.edge == .trailing ? rect.width : 0), p.y, rect.width, rect.height)
    }
    public static func nearest(to rect: Rect, note: Note, excluding id: UUID? = nil, tolerance: Double, ignoring anchorID: UUID? = nil) -> AnnotationAnchor? {
        var excludedOwners = Set<UUID>()
        if let id {
            let children = attachments(in: note)
            var pending = [id]
            while let owner = pending.popLast() {
                guard excludedOwners.insert(owner).inserted else { continue }
                for link in children[owner] ?? [] { pending.append(note.blocks[link.index].id) }
            }
        }
        let occupied = Set(note.blocks.filter { $0.id != id }.compactMap(\.anchorID))
        return note.anchors.compactMap { a -> (AnnotationAnchor, Double)? in
            guard a.id != anchorID, !excludedOwners.contains(a.ownerID), !occupied.contains(a.id),
                  let target = anchored(rect, at: a, blocks: note.blocks), fits(target, paper: note.paper, canvasWidth: note.width) else { return nil }
            let distance = hypot(rect.x - target.x, rect.y - target.y)
            return distance <= tolerance ? (a, distance) : nil
        }.min(by: { $0.1 < $1.1 })?.0
    }
    private static func attachments(in note: Note) -> [UUID: [(index: Int, anchor: AnnotationAnchor)]] {
        let anchors = Dictionary(note.anchors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [UUID: [(index: Int, anchor: AnnotationAnchor)]] = [:]
        for (index, block) in note.blocks.enumerated() {
            if let id = block.anchorID, let anchor = anchors[id] {
                children[anchor.ownerID, default: []].append((index, anchor))
            }
        }
        return children
    }
    /// Place an entire attached branch in parent-first order. Commit only when all frames fit.
    public static func placing(_ id: UUID, frame: Rect, anchor: AnnotationAnchor?, in note: Note) -> [Block]? {
        guard let root = note.blocks.firstIndex(where: { $0.id == id }), fits(frame, paper: note.paper, canvasWidth: note.width),
              !note.blocks[root].locked || note.blocks[root].frame == frame else { return nil }
        var blocks = note.blocks
        blocks[root].frame = frame
        blocks[root].anchorID = anchor?.id
        let children = attachments(in: note)
        var visited = Set<UUID>()
        var pending = [root]
        while let index = pending.popLast() {
            let owner = blocks[index]
            guard visited.insert(owner.id).inserted, owner.id != anchor?.ownerID else { return nil }
            for link in children[owner.id] ?? [] {
                let child = blocks[link.index]
                guard let target = anchored(child.frame, at: link.anchor, blocks: [owner]),
                      fits(target, paper: note.paper, canvasWidth: note.width), !child.locked || target == child.frame else { return nil }
                blocks[link.index].frame = target
                pending.append(link.index)
            }
        }
        return blocks
    }
    public static func rearranged(_ note: Note) -> [Block]? {
        guard note.ink == nil, note.anchors.isEmpty,
              !note.blocks.contains(where: { $0.locked || ($0.pageAnnotations?.values.contains { $0.ink != nil || !$0.texts.isEmpty } ?? false) }) else { return nil }
        var result: [Block] = []
        for var block in note.blocks.sorted(by: { $0.frame.y == $1.frame.y ? $0.frame.x < $1.frame.x : $0.frame.y < $1.frame.y }) {
            guard let r = vacant(Rect(margin, margin, block.frame.width, block.frame.height), paper: note.paper, occupied: result.map(\.frame), canvasWidth: note.width) else { return nil }
            block.frame = r; result.append(block)
        }
        return result
    }
}
