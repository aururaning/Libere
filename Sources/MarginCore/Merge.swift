import Foundation

public struct MergeResult: Sendable { public var primary: Note; public var conflict: Note? }
public enum NoteMerge {
    /// Preserve whole concurrent pages. Clock order never depends on device time.
    public static func merge(_ a: Note, _ b: Note) -> MergeResult {
        precondition(a.id == b.id)
        if a.revision == b.revision { var merged = a; merged.version = a.version.joined(b.version); return MergeResult(primary: merged) }
        if a.version != b.version && a.version.includes(b.version) { return MergeResult(primary: a) }
        if a.version != b.version && b.version.includes(a.version) { return MergeResult(primary: b) }
        let aWins = a.revision.uuidString > b.revision.uuidString
        var winner = aWins ? a : b
        let loser = aWins ? b : a
        winner.version = a.version.joined(b.version)
        // A concurrent deletion should not erase an edit. Keep the live page in place.
        if a.deleted != b.deleted {
            winner = a.deleted ? b : a; winner.version = a.version.joined(b.version)
            return MergeResult(primary: winner)
        }
        if a.deleted && b.deleted { return MergeResult(primary: winner) }
        var copy = loser
        // Revisions are unique UUIDs. Reusing the losing revision as copy identity makes retries idempotent.
        copy.id = loser.revision; copy.conflictOf = a.id; copy.parentID = nil
        copy.title += "（冲突副本）"; copy.deleted = false
        return MergeResult(primary: winner, conflict: copy)
    }
}
