import XCTest
@testable import MarginCore

final class PageAnnotationTests: XCTestCase {
    func testPagesOutsideInkAndExternalBranchesSurviveRoundTrip() throws {
        var pdf = Block(.pdf, frame: Rect(20, 20, 300, 400))
        var first = AttachmentPageAnnotations(), second = AttachmentPageAnnotations()
        first.ink = Data([1, 2, 3]); second.ink = Data([4, 5, 6])
        first.texts = [PageTextAnnotation(frame: Rect(10, 30, 160, 90), text: "第一页")]
        second.texts = [PageTextAnnotation(frame: Rect(80, 40, 160, 90), text: "第二页")]
        pdf.pageAnnotations = ["0": first, "1": second]
        let anchor = AnnotationAnchor(ownerID: pdf.id, label: "页外", u: 1.1, v: 0.5)
        var external = Block(.text, frame: Rect(350, 220, 220, 150), text: "保持原位")
        external.anchorID = anchor.id
        var note = Note(title: "分层批注"); note.ink = Data([7, 8, 9]); note.blocks = [pdf, external]; note.anchors = [anchor]
        note.blocks[0].pdfPage = 1
        let decoded = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(note))
        XCTAssertEqual(decoded.blocks[0].annotations(on: 0), first)
        XCTAssertEqual(decoded.blocks[0].annotations(on: 1), second)
        XCTAssertEqual(decoded.blocks[0].annotations(on: 2), AttachmentPageAnnotations())
        XCTAssertEqual(decoded.blocks[1], external)
        XCTAssertEqual(decoded.anchors, [anchor])
        XCTAssertEqual(decoded.ink, Data([7, 8, 9]))
    }
    func testOldBlocksWithoutPageAnnotationsStillLoad() throws {
        let old = Block(.pdf, frame: Rect(20, 20, 300, 400))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "pageAnnotations")
        let decoded = try JSONDecoder().decode(Block.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.pageAnnotations)
        XCTAssertEqual(decoded.annotations(on: 0), AttachmentPageAnnotations())
    }
    func testPageInkPreventsAutomaticRearrangement() {
        var file = Block(.file, frame: Rect(20, 20, 300, 400))
        var page = AttachmentPageAnnotations(); page.ink = Data([1])
        file.pageAnnotations = ["0": page]
        var note = Note(title: "保留批注"); note.blocks = [file]
        XCTAssertNil(CanvasLayout.rearranged(note))
    }
}
