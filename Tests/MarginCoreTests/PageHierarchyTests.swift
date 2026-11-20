import XCTest
@testable import MarginCore

final class PageHierarchyTests: XCTestCase {
    func tree() -> (Workspace,UUID,UUID,UUID,UUID) {
        let a = Note(title:"项目",folder:true), b = Note(title:"页面",parent:a.id), c = Note(title:"子目录",parent:b.id,folder:true), d = Note(title:"另一个项目",folder:true)
        return (Workspace(notes:[a,b,c,d]),a.id,b.id,c.id,d.id)
    }
    func testMovingParentPreservesSubtreeContentAndInk() {
        var (w,a,b,c,d) = tree(); w.notes[1].ink = Data([1,2]); w.notes[1].blocks = [Block(.text,frame:Rect(10,10,300,100),text:"正文")]
        let child = w.notes[1], nested = w.notes[2]
        XCTAssertFalse(w.place(a,at:.inside(d)).isEmpty)
        XCTAssertEqual(w.notes[0].parentID,d); XCTAssertEqual(w.notes[1],child); XCTAssertEqual(w.notes[2],nested)
        XCTAssertTrue(w.descendants(d).isSuperset(of:[a,b,c,d]))
    }
    func testRejectsCyclesMissingDeletedAndSelfDrops() {
        var (w,a,b,c,_) = tree(); let before = w
        for move in [PagePlacement.inside(a),.inside(c),.before(a),.after(c)] {
            XCTAssertFalse(w.canPlace(a,at:move)); XCTAssertTrue(w.place(a,at:move).isEmpty); XCTAssertEqual(w,before)
        }
        XCTAssertFalse(w.canMove(UUID(),to:nil)); XCTAssertFalse(w.canMove(b,to:UUID()))
        w.notes[1].deleted = true; XCTAssertFalse(w.canMove(b,to:nil))
    }
    func testSiblingBeforeAfterAndRootOrderPersistsAfterEdits() throws {
        var (w,a,b,_,d) = tree()
        w.place(d,at:.after(a))
        w.place(b,at:.before(a)); XCTAssertEqual(w.children(nil).map(\.id),[b,a,d])
        w.place(a,at:.after(d)); XCTAssertEqual(w.children(nil).map(\.id),[b,d,a])
        w.notes[0].title = "改名"; w.notes[0].touch("test")
        XCTAssertEqual(w.children(nil).map(\.id),[b,d,a])
        let decoded = try JSONDecoder().decode(Workspace.self,from:JSONEncoder().encode(w))
        XCTAssertEqual(decoded.children(nil).map(\.id),[b,d,a])
    }
    func testDroppingInsideSameParentMovesToEndAndKeepsDenseOrder() {
        var (w,a,b,_,d) = tree()
        w.place(d,at:.inside(a)); w.place(b,at:.inside(a))
        XCTAssertEqual(w.children(a).map(\.id),[d,b]); XCTAssertEqual(w.children(a).compactMap(\.sidebarOrder),[0,1])
    }
    func testTrashAndRestoreBatchKeepsHierarchyAndEarlierTrashDeleted() {
        var (w,a,b,c,_) = tree()
        var earlier = Note(title:"之前已删",parent:a); earlier.deleted = true; w.notes.append(earlier)
        XCTAssertEqual(w.trashSubtree(a),[a,b,c]); XCTAssertEqual(Set(w.notes.prefix(3).compactMap(\.trashBatchID)).count,1)
        XCTAssertEqual(w.recoverSubtree(a),[a,b,c]); XCTAssertEqual(w.notes[1].parentID,a); XCTAssertEqual(w.notes[2].parentID,b)
        XCTAssertTrue(w.notes.last!.deleted); XCTAssertTrue(w.notes.prefix(3).allSatisfy { !$0.deleted && $0.trashBatchID == nil })
    }
    func testRecoverChildOfDeletedParentMakesIndependentRoot() {
        var (w,a,b,c,_) = tree(); w.trashSubtree(a)
        XCTAssertEqual(w.recoverSubtree(b),[b,c]); XCTAssertNil(w.notes[1].parentID); XCTAssertTrue(w.notes[0].deleted)
        XCTAssertEqual(w.notes[2].parentID,b)
    }
    func testLegacyPagesWithoutOrderingAndTrashBatchStillLoad() throws {
        let (w,_,_,_,_) = tree()
        let data = try JSONEncoder().encode(w)
        let restored = try JSONDecoder().decode(Workspace.self,from:data)
        XCTAssertEqual(restored,w); XCTAssertNil(restored.notes[0].sidebarOrder); XCTAssertNil(restored.notes[0].trashBatchID)
    }
    func testMoveTargetsExcludeWholeSubtreeAndDeletedPages() {
        var (w,a,b,c,d) = tree()
        var removed = Note(title:"已删除",parent:d); removed.deleted = true; w.notes.append(removed)
        XCTAssertEqual(w.moveTargets(for:a).map(\.id),[d])
        XCTAssertEqual(w.moveTargets(for:b).map(\.id),[a,d])
        XCTAssertTrue(w.moveTargets(for:removed.id).isEmpty)
        XCTAssertTrue(w.moveTargets(for:UUID()).isEmpty)
        for source in [a,b,c,d] {
            XCTAssertEqual(w.moveTargets(for:source).map(\.id),w.notes.filter { !$0.deleted && w.canMove(source,to:$0.id) }.map(\.id))
        }
    }
    func testLargeLibraryTargetsAndDescendantsRemainCycleSafe() {
        let root = Note(title:"资料库",folder:true), outside = Note(title:"其他项目",folder:true)
        var pages = [root,outside], parent = root.id
        for index in 0..<2000 {
            let page = Note(title:"资料 \(index)",parent:parent)
            pages.append(page); parent = page.id
        }
        var w = Workspace(notes:pages)
        XCTAssertEqual(w.descendants(root.id).count,2001)
        XCTAssertEqual(w.moveTargets(for:root.id).map(\.id),[outside.id])
        w.notes[0].parentID = parent
        XCTAssertEqual(w.descendants(root.id).count,2001)
        XCTAssertEqual(w.moveTargets(for:root.id).map(\.id),[outside.id])
    }
}
