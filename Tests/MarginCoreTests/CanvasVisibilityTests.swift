import Foundation
import XCTest
@testable import MarginCore

final class CanvasVisibilityTests: XCTestCase {
    func testLongPageStartsWithNearbyBlocksAndPreservesDocumentOrder() throws {
        let blocks = (0..<300).map { Block(.pdf, frame: Rect(20, Double($0 * 800 + 20), 380, 500)) }
        let original = blocks
        let region = try XCTUnwrap(CanvasVisibility.region(around: Rect(0, 0, 800, 600)))
        let visible = CanvasVisibility.blocks(blocks, in: region)
        XCTAssertEqual(visible.map(\.id), Array(blocks.prefix(2)).map(\.id))
        let pinned = CanvasVisibility.blocks(blocks, in: region, retaining: [blocks[150].id])
        XCTAssertEqual(pinned.map(\.id), [blocks[0].id, blocks[1].id, blocks[150].id])
        XCTAssertEqual(blocks, original)
    }

    func testCollapsedAttachmentUsesItsVisibleFrameAndCanBeRetained() {
        var block = Block(.pdf, frame: Rect(20, 0, 380, 1000))
        let viewport = Rect(0, 450, 800, 200)
        XCTAssertEqual(CanvasVisibility.blocks([block], in: viewport).count, 1)
        block.collapsed = true
        XCTAssertTrue(CanvasVisibility.blocks([block], in: viewport).isEmpty)
        XCTAssertEqual(CanvasVisibility.blocks([block], in: viewport, retaining: [block.id]).first, block)
    }

    func testInvalidViewportIsIgnoredAndCenteredViewportIsSupported() throws {
        for rect in [Rect(0, 0, 0, 600), Rect(0, 0, 800, -1), Rect(.nan, 0, 800, 600), Rect(0, 0, .infinity, 600)] {
            XCTAssertNil(CanvasVisibility.region(around: rect))
        }
        let region = try XCTUnwrap(CanvasVisibility.region(around: Rect(-200, -100, 1200, 800)))
        let block = Block(.text, frame: Rect(20, 20, 200, 100))
        XCTAssertEqual(CanvasVisibility.blocks([block], in: region).first?.id, block.id)
    }
}
