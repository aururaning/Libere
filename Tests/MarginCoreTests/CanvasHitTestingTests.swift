import XCTest
@testable import MarginCore

final class CanvasHitTestingTests: XCTestCase {
    private func fixture(_ frames: [Rect] = [Rect(100, 100, 240, 180), Rect(460, 120, 260, 200)]) -> Note {
        var note = Note(title: "命中测试")
        note.fitCanvas(width: 900, height: 1000)
        note.blocks = frames.map { Block(.text, frame: $0) }
        return note
    }
    func testEmptyPaperNeverSelectsANearbyBlock() {
        let note = fixture()
        for selection in [nil] + note.blocks.map({ Optional($0.id) }) {
            for y in stride(from: 0.25, to: note.height, by: 23) {
                for x in stride(from: 0.25, to: note.width, by: 19) {
                    let expected = note.blocks.first { CanvasItemGeometry.contains($0.frame, x: x, y: y) }
                    XCTAssertEqual(CanvasHitTesting.target(x: x, y: y, in: note, selected: selection, controls: false, anchors: false),
                                   expected.map { .block($0.id) } ?? .paper, "point \(x), \(y)")
                }
            }
        }
    }
    func testOverlapsFollowVisibleStackingWithoutCoveringOtherExposedBlocks() {
        let note = fixture([Rect(100, 100, 300, 220), Rect(280, 200, 300, 220)])
        let a = note.blocks[0].id, b = note.blocks[1].id
        XCTAssertEqual(CanvasHitTesting.target(x: 310, y: 230, in: note, selected: nil), .block(b))
        XCTAssertEqual(CanvasHitTesting.target(x: 310, y: 230, in: note, selected: a), .block(a))
        XCTAssertEqual(CanvasHitTesting.target(x: 510, y: 340, in: note, selected: a), .block(b))
        XCTAssertEqual(CanvasHitTesting.target(x: 700, y: 500, in: note, selected: a), .paper)
    }
    func testEdgesAreExactAndAdjacentBlocksDoNotShareTheSameBoundary() {
        let note = fixture([Rect(100, 100, 200, 180), Rect(300, 100, 200, 180)])
        XCTAssertEqual(CanvasHitTesting.target(x: 299.9, y: 170, in: note, selected: nil), .block(note.blocks[0].id))
        XCTAssertEqual(CanvasHitTesting.target(x: 300, y: 170, in: note, selected: nil), .block(note.blocks[1].id))
        XCTAssertEqual(CanvasHitTesting.target(x: 500.1, y: 170, in: note, selected: nil), .paper)
        XCTAssertEqual(CanvasHitTesting.target(x: note.width, y: 100, in: note, selected: nil), .outside)
        XCTAssertEqual(CanvasHitTesting.target(x: -0.1, y: 100, in: note, selected: nil), .outside)
        XCTAssertEqual(CanvasHitTesting.target(x: .nan, y: 100, in: note, selected: nil), .outside)
    }
    func testOnlyTheSelectedHandleCanBePickedAndTheGapBelowItIsPaper() {
        let note = fixture(), id = note.blocks[0].id
        XCTAssertEqual(CanvasHitTesting.target(x: 80, y: 110, in: note, selected: id), .move(id))
        XCTAssertEqual(CanvasHitTesting.target(x: 80, y: 170, in: note, selected: id), .paper)
        XCTAssertEqual(CanvasHitTesting.target(x: 80, y: 110, in: note, selected: note.blocks[1].id), .paper)
        XCTAssertEqual(CanvasHitTesting.target(x: 80, y: 110, in: note, selected: id, controls: false), .paper)
        let handle = CanvasItemGeometry.moveHandle(for: Rect(0, 100, 200, 180), paperWidth: 900, paperHeight: 1000, size: 28)
        XCTAssertGreaterThanOrEqual(handle.x, 0)
        XCTAssertLessThan(handle.maxY, 100)
    }
    func testCollapsedFilesDoNotRetainTheirOldPreviewHitArea() {
        var note = fixture([])
        var pdf = Block(.pdf, frame: Rect(100, 100, 300, 600)); pdf.collapsed = true; note.blocks = [pdf]
        XCTAssertEqual(CanvasHitTesting.target(x: 220, y: 120, in: note, selected: nil), .block(pdf.id))
        XCTAssertEqual(CanvasHitTesting.target(x: 220, y: 160, in: note, selected: pdf.id), .paper)
        note.blocks[0].collapsed = false
        XCTAssertEqual(CanvasHitTesting.target(x: 220, y: 160, in: note, selected: nil), .block(pdf.id))
    }
    func testAnchorHitAreasTrackZoomAndOnlyVisibleAnchorsAreActive() {
        var note = fixture([Rect(100, 100, 200, 180)])
        let owner = note.blocks[0]
        let anchor = AnnotationAnchor(ownerID: owner.id, label: "A", u: 3, v: 0.5); note.anchors = [anchor]
        let p = CanvasLayout.point(anchor, blocks: note.blocks)!
        for scale in [0.25, 0.5, 1, 2, 6] {
            XCTAssertEqual(CanvasHitTesting.target(x: p.x + 21 / scale, y: p.y, in: note, selected: owner.id, zoom: scale), .anchor(anchor.id))
            XCTAssertEqual(CanvasHitTesting.target(x: p.x + 23 / scale, y: p.y, in: note, selected: owner.id, zoom: scale), .paper)
        }
        XCTAssertEqual(CanvasHitTesting.target(x: p.x, y: p.y, in: note, selected: nil), .paper)
        XCTAssertEqual(CanvasHitTesting.target(x: p.x, y: p.y, in: note, selected: owner.id, anchors: false), .paper)
    }
    func testResizeTargetsStayInsideSmallBlocksAtEveryZoom() {
        let note = fixture([Rect(200, 200, 100, 80)])
        let block = note.blocks[0]
        for scale in [0.25, 0.5, 1, 2, 6] {
            let corner = CanvasItemGeometry.resizeCorner(for: block.frame, zoom: scale)
            XCTAssertGreaterThanOrEqual(corner.x, block.frame.x)
            XCTAssertGreaterThanOrEqual(corner.y, block.frame.y)
            XCTAssertEqual(CanvasHitTesting.target(x: 299, y: 279, in: note, selected: block.id, zoom: scale), .resize(block.id))
            XCTAssertEqual(CanvasHitTesting.target(x: 301, y: 279, in: note, selected: block.id, zoom: scale), .paper)
        }
    }
    func testPDFResizeTargetLeavesTheWholeFooterAndHeaderClearAtEveryZoom() {
        for frame in [Rect(100, 100, 100, 80), Rect(100, 100, 420, 500)] {
            var note = fixture([])
            let pdf = Block(.pdf, frame: frame); note.blocks = [pdf]
            for zoom in [0.25, 0.5, 1, 2, 6] {
                let corner = CanvasItemGeometry.resizeCorner(for: pdf, zoom: zoom)
                XCTAssertGreaterThan(corner.width, 0)
                XCTAssertGreaterThanOrEqual(corner.x, frame.x)
                XCTAssertGreaterThanOrEqual(corner.y, frame.y + Block.collapsedHeight)
                XCTAssertEqual(corner.maxY, frame.maxY - CanvasItemGeometry.pdfFooterHeight)
                XCTAssertEqual(CanvasHitTesting.target(x: corner.maxX - 1, y: corner.maxY - 1,
                    in: note, selected: pdf.id, zoom: zoom), .resize(pdf.id))
                for x in stride(from: frame.x, to: frame.maxX, by: 3) {
                    for y in [corner.maxY, frame.maxY - 14, frame.maxY - 0.01] {
                        XCTAssertEqual(CanvasHitTesting.target(x: x, y: y, in: note, selected: pdf.id, zoom: zoom),
                                       .block(pdf.id), "The PDF footer must not start a resize at zoom \(zoom)")
                    }
                }
            }
        }
    }
    func testPDFResizeGeometryUsesPreviewFrameAndDoesNotChangeOtherBlockKinds() {
        let frame = Rect(100, 100, 260, 300), preview = Rect(120, 130, 360, 400)
        for kind in [BlockKind.text, .formula, .file, .link] {
            let block = Block(kind, frame: frame)
            XCTAssertEqual(CanvasItemGeometry.resizeCorner(for: block, frame: preview, zoom: 0.5),
                           CanvasItemGeometry.resizeCorner(for: preview, zoom: 0.5))
        }
        let pdf = Block(.pdf, frame: frame)
        XCTAssertEqual(CanvasItemGeometry.resizeCorner(for: pdf, frame: preview, zoom: 1).maxY,
                       preview.maxY - CanvasItemGeometry.pdfFooterHeight)
    }
    func testSelectedPDFPagerWinsOverItsAnchorWithoutExposingCoveredPDFControls() {
        var note = fixture([])
        let pdf = Block(.pdf, frame: Rect(100, 100, 420, 500))
        let anchor = AnnotationAnchor(ownerID: pdf.id, label: "页脚旁批注", u: 402.0 / 420, v: 486.0 / 500)
        note.blocks = [pdf]; note.anchors = [anchor]
        let point = CanvasLayout.point(anchor, blocks: note.blocks)!
        for zoom in [0.25, 0.5, 1, 2, 6] {
            for locked in [false, true] {
                note.blocks[0].locked = locked
                let regions = CanvasHitTesting.anchorRegions(anchor, in: note, selected: pdf.id, zoom: zoom)
                XCTAssertFalse(regions.contains { CanvasItemGeometry.contains($0, x: point.x, y: point.y) })
                XCTAssertEqual(CanvasHitTesting.target(x: point.x, y: point.y, in: note, selected: pdf.id, zoom: zoom), .block(pdf.id))
            }
        }
        var child = Block(.text, frame: Rect(point.x - 20, point.y - 20, 240, 180))
        child.anchorID = anchor.id; note.blocks.append(child)
        XCTAssertEqual(CanvasHitTesting.target(x: point.x, y: point.y, in: note, selected: child.id), .block(child.id),
                       "A selected attached text block still covers a lower PDF footer")
        child.frame = Rect(700, 400, 100, 80); note.blocks[1] = child
        XCTAssertEqual(CanvasHitTesting.target(x: point.x, y: point.y, in: note, selected: child.id), .anchor(anchor.id),
                       "Selecting an attached child does not grant its owner's hidden footer priority")
        note.blocks[0].collapsed = true
        let collapsedPoint = CanvasLayout.point(anchor, blocks: note.blocks)!
        XCTAssertEqual(CanvasHitTesting.target(x: collapsedPoint.x, y: collapsedPoint.y, in: note, selected: pdf.id), .anchor(anchor.id),
                       "A collapsed PDF has no footer exclusion")
    }
    func testAttachedTextRemainsDraggableUnderTheExpandedAnchorTarget() {
        var note = fixture([Rect(100, 100, 240, 360), Rect(500, 200, 240, 180)])
        let owner = note.blocks[0], child = note.blocks[1]
        let anchor = AnnotationAnchor(ownerID: owner.id, label: "批注", u: 400.0 / 240, v: 100.0 / 360)
        note.anchors = [anchor]; note.blocks[1].anchorID = anchor.id
        let handle = CanvasItemGeometry.moveHandle(for: child.frame, paperWidth: note.width, paperHeight: note.height, size: 28)
        for zoom in [0.25, 0.5, 1, 2, 6] {
            let x = handle.x + 14, y = handle.y + 14
            XCTAssertEqual(CanvasHitTesting.target(x: x, y: y, in: note, selected: child.id, zoom: zoom), .move(child.id))
            let regions = CanvasHitTesting.anchorRegions(anchor, in: note, selected: child.id, zoom: zoom)
            XCTAssertFalse(regions.contains { CanvasItemGeometry.contains($0, x: x, y: y) })
            XCTAssertEqual(CanvasHitTesting.target(x: 505, y: 205, in: note, selected: child.id, zoom: zoom), .block(child.id))
            XCTAssertEqual(CanvasHitTesting.target(x: 500, y: 200 - 10 / zoom, in: note, selected: child.id, zoom: zoom), .anchor(anchor.id))
        }
    }
    func testContainerEmptyCornersAreNotPartOfTheItem() {
        let item = CanvasItemGeometry(body: Rect(100, 100, 240, 180), handle: Rect(70, 100, 28, 28))
        XCTAssertTrue(item.contains(x: 80, y: 110)); XCTAssertTrue(item.contains(x: 200, y: 200))
        XCTAssertFalse(item.contains(x: 80, y: 200)); XCTAssertFalse(item.contains(x: 99, y: 110))
        XCTAssertFalse(item.contains(x: 600, y: 600)); XCTAssertLessThan(item.bounds.width, 300)
    }
    func testLockedBlocksCanBeSelectedButHaveNoResizeTarget() {
        var note = fixture(); note.blocks[0].locked = true
        let block = note.blocks[0]
        XCTAssertEqual(CanvasHitTesting.target(x: block.frame.maxX - 1, y: block.frame.maxY - 1, in: note, selected: block.id), .block(block.id))
    }
}
