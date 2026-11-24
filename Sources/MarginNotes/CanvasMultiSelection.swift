import SwiftUI
#if SWIFT_PACKAGE
import MarginCore
#endif

@MainActor final class CanvasMultiSelection: ObservableObject {
    private weak var store: AppStore?
    @Published private(set) var ids: Set<UUID> = []
    @Published private(set) var previewFrames: [UUID: Rect] = [:]
    @Published private(set) var marquee: CGRect?
    @Published var showConnections = true {
        didSet { UserDefaults.standard.set(showConnections, forKey: "LibereShowBranchConnections") }
    }
    private var pageID: UUID?
    private var original: Note?
    private var proposed: [Block]?
    private var marqueeBase: Set<UUID> = []
    var updating = false
    init(store: AppStore) {
        self.store = store
        showConnections = UserDefaults.standard.object(forKey: "LibereShowBranchConnections") as? Bool ?? true
    }
    var selectedIDs: Set<UUID> {
        guard let store, let note = store.note else { return [] }
        if pageID == note.id, let active = store.blockSelection, ids.contains(active) { return ids.intersection(note.blocks.map(\.id)) }
        return Set([store.blockSelection].compactMap { $0 })
    }
    func selectOnly(_ id: UUID) { guard !updating else { return }; pageID = store?.selection; if ids != [id] { ids = [id] }; cancelPreview() }
    func clear() { if !ids.isEmpty { ids = [] }; pageID = nil; cancelPreview() }
    func select(_ values: Set<UUID>) {
        guard let store, let note = store.note else { return }
        let values = values.intersection(note.blocks.map(\.id)); updating = true
        if let primary = note.blocks.first(where: { values.contains($0.id) }) { store.selectBlock(primary.id) }
        else { store.clearBlockSelection() }
        updating = false; pageID = note.id; ids = values
    }
    func toggle(_ id: UUID) { var next = selectedIDs; if !next.insert(id).inserted { next.remove(id) }; select(next) }
    func beginMarquee(additive: Bool) { marqueeBase = additive ? selectedIDs : []; pageID = store?.selection }
    func updateMarquee(from start: CGPoint, to end: CGPoint) {
        marquee = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
    func finishMarquee() {
        guard let rect = marquee, let note = store?.note, note.id == pageID else { cancelPreview(); return }
        let selected = Set(note.blocks.filter { block in
            let f = block.visibleFrame; return rect.intersects(CGRect(x: f.x, y: f.y, width: f.width, height: f.height))
        }.map(\.id)).union(marqueeBase)
        marquee = nil; select(selected)
    }
    func beginMove() { original = store?.note; proposed = nil }
    func move(dx: Double, dy: Double) {
        guard let note = original else { return }
        proposed = CanvasBatch.translated(selectedIDs, dx: dx, dy: dy, in: note)
        previewFrames = Dictionary((proposed ?? []).filter { block in note.blocks.first { $0.id == block.id }?.frame != block.frame }.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
    }
    func finishMove() {
        defer { cancelPreview() }
        guard let store, let original, let current = store.note, current.id == original.id else { return }
        guard let proposed else { store.message = "选中组含锁定内容，或无法保持整组和批注的位置，未移动任何内容。"; return }
        guard
              current.blocks == original.blocks, proposed != current.blocks else { return }
        store.checkpoint(); store.edit { $0.blocks = proposed }; store.flush()
    }
    func cancelPreview() { if !previewFrames.isEmpty { previewFrames = [:] }; if marquee != nil { marquee = nil }; original = nil; proposed = nil }
    func lock(_ locked: Bool) {
        guard let store, let note = store.note else { return }; let selected = selectedIDs
        guard note.blocks.contains(where: { selected.contains($0.id) && $0.locked != locked }) else { return }
        store.finishBlockEditing(); store.checkpoint(); store.edit { note in
            for i in note.blocks.indices where selected.contains(note.blocks[i].id) { note.blocks[i].locked = locked }
        }; store.flush()
    }
    func delete() {
        guard let store, let note = store.note else { return }; let selected = selectedIDs
        guard !selected.isEmpty else { return }
        guard !note.blocks.contains(where: { selected.contains($0.id) && $0.locked }) else { store.message = "请先解锁选中的内容，再批量删除。"; return }
        store.finishBlockEditing(); store.checkpoint(); store.edit { note in
            let anchors = Set(note.anchors.filter { selected.contains($0.ownerID) }.map(\.id))
            note.blocks.removeAll { selected.contains($0.id) }; note.anchors.removeAll { anchors.contains($0.id) }
            for i in note.blocks.indices where note.blocks[i].anchorID.map(anchors.contains) == true { note.blocks[i].anchorID = nil }
        }; store.clearBlockSelection(); store.flush()
    }
    func align(_ alignment: CanvasBatch.Alignment) {
        guard let store, let note = store.note else { return }
        guard let blocks = CanvasBatch.aligned(selectedIDs, by: alignment, in: note) else { store.message = "请选中可对齐的普通内容块；手写、锁定或关联批注的位置需手动保留。等距分布至少需要三个不重叠块。"; return }
        guard blocks != note.blocks else { return }
        store.finishBlockEditing(); store.checkpoint(); store.edit { $0.blocks = blocks }; store.flush()
    }
}
