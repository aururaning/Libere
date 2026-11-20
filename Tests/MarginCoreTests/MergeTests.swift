import XCTest
@testable import MarginCore

final class MergeTests: XCTestCase {
    func testCausalUpdateWinsEvenWithWrongClock() {
        var old = Note(title: "旧"); old.touch("Mac")
        var new = old; new.title = "新"; new.touch("iPad"); new.modifiedAt = .distantPast
        XCTAssertEqual(NoteMerge.merge(old, new).primary, new)
        XCTAssertEqual(NoteMerge.merge(new, old).primary, new)
    }
    func testConcurrentEditsPreserveBothVersionsAndConverge() throws {
        var a = Note(title: "共同起点"); a.touch("seed")
        var b = a
        a.title = "Mac 修改"; a.touch("Mac")
        b.title = "iPad 修改"; b.ink = Data([7, 8]); b.touch("iPad")
        let ab = NoteMerge.merge(a, b), ba = NoteMerge.merge(b, a)
        XCTAssertEqual(ab.primary, ba.primary); XCTAssertEqual(ab.conflict, ba.conflict)
        let conflict = try XCTUnwrap(ab.conflict)
        XCTAssertEqual(Set([ab.primary.title, conflict.title.replacingOccurrences(of: "（冲突副本）", with: "")]), Set([a.title, b.title]))
        XCTAssertTrue(ab.primary.version.includes(a.version)); XCTAssertTrue(ab.primary.version.includes(b.version))
        XCTAssertNil(NoteMerge.merge(ab.primary, a).conflict)
        XCTAssertNil(NoteMerge.merge(ab.primary, b).conflict)
        XCTAssertTrue(ab.primary.ink == b.ink || conflict.ink == b.ink)
    }
    func testSameRevisionJoinsVectorInsteadOfLosingCausality() {
        var a = Note(title: "A"); a.touch("A")
        var b = a; b.version.tick("B")
        XCTAssertEqual(NoteMerge.merge(a, b).primary.version, b.version)
    }
    func testConcurrentDeletePreservesLiveEditAndCausalDeleteWins() {
        var base = Note(title: "base"); base.touch("seed")
        var deleted = base; deleted.deleted = true; deleted.touch("Mac")
        var edited = base; edited.title = "新内容"; edited.touch("iPad")
        XCTAssertFalse(NoteMerge.merge(deleted, edited).primary.deleted)
        XCTAssertEqual(NoteMerge.merge(edited, deleted).primary.title, "新内容")
        var later = edited; later.deleted = true; later.touch("iPad")
        XCTAssertTrue(NoteMerge.merge(edited, later).primary.deleted)
    }
}
