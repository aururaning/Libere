import XCTest
@testable import MarginCore

final class CanvasTests: XCTestCase {
    func testIndependentAnchorsAndTrailingAlignment() throws {
        let pdf = Block(.pdf, frame: Rect(300, 100, 300, 500))
        let left = AnnotationAnchor(ownerID: pdf.id, label: "定义", u: -0.1, v: 0.2, edge: .trailing)
        let right = AnnotationAnchor(ownerID: pdf.id, label: "问题", u: 1.1, v: 0.7)
        let text = Rect(0, 0, 220, 120)
        XCTAssertEqual(CanvasLayout.anchored(text, at: left, blocks: [pdf]), Rect(50, 200, 220, 120))
        XCTAssertEqual(CanvasLayout.anchored(text, at: right, blocks: [pdf]), Rect(630, 450, 220, 120))
    }
    func testSnapUsesVisibleDistanceAndRejectsOccupiedAnchors() throws {
        var note = Note(title: "测试"); note.paper = .landscape
        let pdf = Block(.pdf, frame: Rect(300, 100, 300, 500))
        let anchor = AnnotationAnchor(ownerID: pdf.id, label: "A", u: 1.1, v: 0.2)
        note.blocks = [pdf]; note.anchors = [anchor]
        let near = Rect(638, 208, 220, 120)
        XCTAssertEqual(CanvasLayout.nearest(to: near, note: note, tolerance: 16)?.id, anchor.id)
        XCTAssertNil(CanvasLayout.nearest(to: near, note: note, tolerance: 8))
        var linked = Block(.text, frame: near); linked.anchorID = anchor.id; note.blocks.append(linked)
        XCTAssertNil(CanvasLayout.nearest(to: near, note: note, tolerance: 16))
        XCTAssertEqual(CanvasLayout.nearest(to: near, note: note, excluding: linked.id, tolerance: 16)?.id, anchor.id)
    }
    func testAttachmentTranslationAndResizeTransformAnchors() {
        var pdf = Block(.pdf, frame: Rect(100, 100, 300, 400))
        let anchor = AnnotationAnchor(ownerID: pdf.id, label: "A", u: 1.1, v: 0.5)
        let first = CanvasLayout.anchored(Rect(0, 0, 200, 120), at: anchor, blocks: [pdf])!
        pdf.frame.x += 50; pdf.frame.y += 20
        let second = CanvasLayout.anchored(first, at: anchor, blocks: [pdf])!
        XCTAssertEqual(second.x - first.x, 50); XCTAssertEqual(second.y - first.y, 20)
        pdf.frame.width = 400
        XCTAssertEqual(CanvasLayout.point(anchor, blocks: [pdf])!.x, 590, accuracy: 0.0001)
    }
    func testBoundedPaperRefusesOverflowAndLongPageExpands() {
        let occupied = [Rect(20, 20, 754, 1083)]
        XCTAssertNil(CanvasLayout.vacant(Rect(20, 20, 300, 180), paper: .a4, occupied: occupied))
        XCTAssertNotNil(CanvasLayout.vacant(Rect(20, 20, 300, 180), paper: .continuous, occupied: occupied))
        var note = Note(title: "长页"); note.inkBounds = Rect(10, 2300, 200, 100)
        XCTAssertGreaterThan(note.height, 2400)
    }
    func testNoAutomaticLayoutAfterInkAnchorsOrLock() {
        var note = Note(title: "批注"); note.blocks = [Block(.text, frame: Rect(24, 24, 300, 180))]
        XCTAssertNotNil(CanvasLayout.rearranged(note))
        note.ink = Data([1]); XCTAssertNil(CanvasLayout.rearranged(note)); note.ink = nil
        note.blocks[0].locked = true; XCTAssertNil(CanvasLayout.rearranged(note)); note.blocks[0].locked = false
        note.anchors = [AnnotationAnchor(ownerID: note.blocks[0].id, label: "A", u: 1, v: 0)]
        XCTAssertNil(CanvasLayout.rearranged(note))
    }
    func testHierarchyCannotBeMovedInsideItselfOrDescendant() {
        let a = Note(title: "A", folder: true); let b = Note(title: "B", parent: a.id, folder: true); let c = Note(title: "C", parent: b.id)
        let workspace = Workspace(notes: [a, b, c])
        XCTAssertFalse(workspace.canMove(a.id, to: a.id)); XCTAssertFalse(workspace.canMove(a.id, to: c.id))
        XCTAssertTrue(workspace.canMove(c.id, to: a.id)); XCTAssertTrue(workspace.canMove(b.id, to: nil))
    }
    func testViewportBecomesEditableDocumentSpaceWithoutScalingBlocks() {
        var note = Note(title: "窗口画布")
        let original = Block(.text, frame: Rect(40, 60, 360, 216), text: "保留坐标")
        note.blocks = [original]
        note.fitCanvas(width: 1920, height: 1400)
        XCTAssertEqual(note.width, 1920); XCTAssertGreaterThanOrEqual(note.height, 1400)
        XCTAssertEqual(note.blocks[0], original)
        let rightEdge = Rect(1560, 0, 360, 216)
        XCTAssertTrue(CanvasLayout.fits(rightEdge, paper: note.paper, canvasWidth: note.width))
        XCTAssertEqual(CanvasLayout.vacant(rightEdge, paper: note.paper, occupied: note.blocks.map(\.frame), canvasWidth: note.width), rightEdge)
        note.blocks.append(Block(.text, frame: rightEdge))
        note.fitCanvas(width: 900, height: 700)
        XCTAssertEqual(note.width, 1920, "A smaller window cannot crop existing content")
    }
    func testContentThresholdDoublesBlankSpaceAndDoesNotGrowOnRepeatedReads() {
        var note = Note(title: "只随内容扩展")
        note.canvasHeight = 1200
        note.blocks = [Block(.text, frame: Rect(20, 500, 360, 299))]
        XCTAssertEqual(note.height, 1200)
        note.blocks[0].frame.height = 300
        note.extendCanvasForContent()
        XCTAssertEqual(note.height, 1600)
        XCTAssertEqual(note.height - note.contentBottom, 2 * (1200 - note.contentBottom))
        let saved = note
        for _ in 0..<1000 {
            _ = note.height
            note.extendCanvasForContent()
        }
        XCTAssertEqual(note, saved, "Scrolling/display must not allocate more blank canvas")
        note.blocks.removeAll(); note.extendCanvasForContent()
        XCTAssertEqual(note.height, 1600, "Deleting content must not jump the scroll position")
    }
    func testDeepContentAndInkExtendCanvasWithoutOldVerticalLimit() {
        var note = Note(title: "长资料")
        let distant = Rect(0, 250_000, 360, 216)
        XCTAssertEqual(CanvasLayout.clamp(distant, to: note.paper, canvasWidth: 1800), distant)
        note.blocks = [Block(.text, frame: distant)]
        note.extendCanvasForContent()
        XCTAssertGreaterThan(note.height, distant.maxY * 1.5)
        note.ink = Data([1,2,3]); note.inkBounds = Rect(50, 500_000, 120, 80)
        note.extendCanvasForContent()
        XCTAssertGreaterThan(note.height, 500_080 * 1.5)
        XCTAssertEqual(note.blocks[0].frame, distant); XCTAssertEqual(note.ink, Data([1,2,3]))
        XCTAssertNil(CanvasLayout.rearranged(note))
    }
    func testCanvasDimensionsRoundTripAndLegacyPageStillLoads() throws {
        var note = Note(title: "旧页面")
        var block = Block(.text, frame: Rect(20,20,300,180)); block.fontSize = 18
        note.blocks = [block]
        let legacy = try JSONEncoder().encode(note)
        let restored = try JSONDecoder().decode(Note.self, from: legacy)
        XCTAssertNil(restored.canvasWidth); XCTAssertEqual(restored.blocks[0].fontSize, 18)
        note.fitCanvas(width: 1800, height: 1300)
        XCTAssertEqual(try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(note)), note)
        XCTAssertEqual(Block(.text, frame: Rect(0,0,360,216)).fontSize, 22)
        note.paper = .a4; note.fitCanvas(width: 2000, height: 1800)
        XCTAssertEqual(note.width, 794); XCTAssertEqual(note.height, 1123)
    }
}
