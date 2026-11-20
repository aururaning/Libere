import Foundation

public enum PagePlacement: Equatable, Sendable {
    case inside(UUID?), before(UUID), after(UUID)
}

public extension Workspace {
    func destination(for placement: PagePlacement) -> (parent: UUID?, sibling: UUID?)? {
        switch placement {
        case .inside(let parent):
            guard parent == nil || notes.contains(where: { $0.id == parent && !$0.deleted }) else { return nil }
            return (parent,nil)
        case .before(let sibling), .after(let sibling):
            guard let target = notes.first(where: { $0.id == sibling && !$0.deleted }) else { return nil }
            return (target.parentID,sibling)
        }
    }
    func canPlace(_ id: UUID, at placement: PagePlacement) -> Bool {
        guard let target = destination(for:placement), target.sibling != id else { return false }
        return canMove(id,to:target.parent)
    }
    /// Move a subtree by changing only its root's parent. Explicit sibling order
    /// keeps later edits/renames from undoing the user's chosen sidebar order.
    @discardableResult mutating func place(_ id: UUID, at placement: PagePlacement) -> Set<UUID> {
        guard canPlace(id,at:placement), let target = destination(for:placement),
              let index = notes.firstIndex(where: { $0.id == id }) else { return [] }
        let previous = notes
        let oldParent = notes[index].parentID
        var ordered = children(target.parent).map(\.id).filter { $0 != id }
        let insertion: Int
        switch placement {
        case .inside: insertion = ordered.count
        case .before(let sibling): insertion = ordered.firstIndex(of:sibling) ?? ordered.count
        case .after(let sibling): insertion = (ordered.firstIndex(of:sibling).map { $0 + 1 }) ?? ordered.count
        }
        ordered.insert(id,at:insertion)
        notes[index].parentID = target.parent
        func renumber(_ ids: [UUID], notes: inout [Note]) {
            let positions = Dictionary(uniqueKeysWithValues:ids.enumerated().map { ($1,$0) })
            for i in notes.indices { if let order = positions[notes[i].id] { notes[i].sidebarOrder = order } }
        }
        if oldParent != target.parent { renumber(children(oldParent).map(\.id),notes:&notes) }
        renumber(ordered,notes:&notes)
        return Set(notes.indices.filter { notes[$0] != previous[$0] }.map { notes[$0].id })
    }
    func liveSubtree(_ id: UUID) -> Set<UUID> {
        var ids: Set<UUID> = [], pending = [id]
        while let next = pending.popLast() {
            guard !ids.contains(next), notes.contains(where: { $0.id == next && !$0.deleted }) else { continue }
            ids.insert(next); pending += children(next).map(\.id)
        }
        return ids
    }
    @discardableResult mutating func trashSubtree(_ id: UUID) -> Set<UUID> {
        let ids = liveSubtree(id), batch = UUID()
        for i in notes.indices where ids.contains(notes[i].id) { notes[i].deleted = true; notes[i].trashBatchID = batch }
        return ids
    }
    @discardableResult mutating func recoverSubtree(_ id: UUID) -> Set<UUID> {
        guard let root = notes.first(where: { $0.id == id && $0.deleted }) else { return [] }
        let descendants = descendants(id)
        let ids = Set(notes.filter { $0.id == id || (root.trashBatchID != nil && $0.deleted && $0.trashBatchID == root.trashBatchID && descendants.contains($0.id)) }.map(\.id))
        for i in notes.indices where ids.contains(notes[i].id) {
            notes[i].deleted = false; notes[i].trashBatchID = nil
            if let parent = notes[i].parentID, !ids.contains(parent), !notes.contains(where: { $0.id == parent && !$0.deleted }) {
                notes[i].parentID = nil
            }
        }
        return ids
    }
}
