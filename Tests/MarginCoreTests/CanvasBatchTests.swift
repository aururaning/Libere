import XCTest
@testable import MarginCore

final class CanvasBatchTests: XCTestCase {
    func testTranslationMovesSelectedBranchesTogetherWithoutChangingInk() throws {
        var note = Note(title: "批量")
        let owner = Block(.file, frame: Rect(40, 60, 200, 300))
        let anchor = AnnotationAnchor(ownerID: owner.id, label: "关联", u: 1.2, v: 0.2, edge: .leading)
        var child = Block(.text, frame: Rect(280, 120, 200, 100)); child.anchorID = anchor.id
        let other = Block(.text, frame: Rect(500, 400, 180, 100))
        note.blocks = [owner, child, other]; note.anchors = [anchor]; note.ink = Data([1,2,3])
        let moved = try XCTUnwrap(CanvasBatch.translated([owner.id], dx: 20, dy: 30, in: note))
        XCTAssertEqual(moved[0].frame, Rect(60,90,200,300)); XCTAssertEqual(moved[1].frame, Rect(300,150,200,100))
        XCTAssertEqual(moved[1].anchorID, anchor.id); XCTAssertEqual(moved[2], other)
        XCTAssertEqual(note.ink, Data([1,2,3])); XCTAssertEqual(note.anchors, [anchor])
        note.blocks[1].locked = true
        XCTAssertNil(CanvasBatch.translated([owner.id], dx: 20, dy: 30, in: note))
    }
    func testGroupClampPreservesOffsetsAndDetachedChildReleasesAnchor() throws {
        var note = Note(title: "边界")
        let parent = Block(.text, frame: Rect(40, 60, 200, 100))
        let anchor = AnnotationAnchor(ownerID: parent.id, label: "关联", u: 1.3, v: 0, edge: .leading)
        var a = Block(.text, frame: Rect(300,60,200,100)); a.anchorID = anchor.id
        let b = Block(.text, frame: Rect(550,300,200,100))
        note.blocks = [parent,a,b]; note.anchors = [anchor]
        let result = try XCTUnwrap(CanvasBatch.translated([a.id,b.id], dx: 200, dy: -200, in: note))
        XCTAssertNil(result[1].anchorID); XCTAssertEqual(result[0],parent)
        XCTAssertEqual(result[2].frame.x - result[1].frame.x,250)
        XCTAssertEqual(result[2].frame.y - result[1].frame.y,240)
        XCTAssertEqual(result[2].frame.maxX,note.width); XCTAssertEqual(result[1].frame.y,0)
    }
    func testAlignmentAndDistributionProtectHandwritingLocksAndAnnotations() throws {
        var note = Note(title: "排列")
        note.blocks = [Block(.text,frame:Rect(40,60,100,100)),Block(.text,frame:Rect(300,200,100,100)),Block(.text,frame:Rect(650,400,100,100))]
        let ids = Set(note.blocks.map(\.id))
        let aligned = try XCTUnwrap(CanvasBatch.aligned(ids,by:.left,in:note))
        XCTAssertEqual(Set(aligned.map(\.frame.x)),[40])
        let spaced = try XCTUnwrap(CanvasBatch.aligned(ids,by:.horizontalSpacing,in:note))
        XCTAssertEqual(spaced[1].frame.x-spaced[0].frame.maxX,spaced[2].frame.x-spaced[1].frame.maxX)
        note.ink = Data([1]); XCTAssertNil(CanvasBatch.aligned(ids,by:.top,in:note)); note.ink = nil
        note.blocks[0].locked = true; XCTAssertNil(CanvasBatch.aligned(ids,by:.top,in:note)); note.blocks[0].locked = false
        note.anchors = [AnnotationAnchor(ownerID:note.blocks[0].id,label:"批注",u:1,v:0,edge:.leading)]
        XCTAssertNil(CanvasBatch.aligned(ids,by:.top,in:note))
    }
}
