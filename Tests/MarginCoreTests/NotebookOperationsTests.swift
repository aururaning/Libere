import XCTest
@testable import MarginCore

final class NotebookOperationsTests: XCTestCase {
    func testCellHistorySnapshotKeepsLegacyIdentitiesWithoutChangingLiveJSON() throws {
        let bytes = Data(#"{"nbformat":4,"cells":[{"cell_type":"code","source":"first","metadata":{},"outputs":[]},{"cell_type":"code","source":"second","metadata":{},"outputs":[]}]}"#.utf8)
        let document = try NotebookDocument(data: bytes), before = try document.serialized()
        let restored = try NotebookDocument(data: document.cellHistorySnapshot())
        XCTAssertEqual(restored.cells.map(\.id), document.cells.map(\.id))
        XCTAssertEqual(restored.cells.map(\.source), document.cells.map(\.source))
        XCTAssertEqual(try document.serialized(), before)
        XCTAssertTrue(((try JSONSerialization.jsonObject(with: before) as! [String:Any])["cells"] as! [[String:Any]]).allSatisfy { $0["id"] == nil })
    }
    func testLegacyRuntimeIdentitiesRemainStableWithoutChangingUntouchedJSON() throws {
        let original = Data(#"{"nbformat":4,"cells":[{"cell_type":"code","source":"first","metadata":{},"outputs":[]},{"cell_type":"code","source":"second","metadata":{},"outputs":[]}]}"#.utf8)
        var doc = try NotebookDocument(data: original)
        let ids = doc.cells.map(\.id)
        XCTAssertEqual(doc.cells.map(\.id), ids)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: doc.serialized()) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: original) as? NSDictionary)
        doc.setSource("first edited", at: 0)
        XCTAssertEqual(doc.cells.map(\.id), ids)
        let edited = try JSONSerialization.jsonObject(with: doc.serialized()) as! [String: Any]
        XCTAssertTrue((edited["cells"] as! [[String: Any]]).allSatisfy { $0["id"] == nil })
        doc.moveCell(at: 0, by: 1)
        XCTAssertEqual(doc.cells.map(\.id), Array(ids.reversed()))
        XCTAssertEqual(doc.index(ofCellID: ids[0]), 1)
        let reopened = try NotebookDocument(data: doc.serialized())
        XCTAssertEqual(reopened.cells.map(\.id), doc.cells.map(\.id))
        doc.removeCell(at: 1); XCTAssertNil(doc.index(ofCellID: ids[0]))
        XCTAssertEqual(doc.cells[0].id, ids[1])
    }
    func fixture() throws -> NotebookDocument {
        try NotebookDocument(data: Data(##"{"nbformat":4,"nbformat_minor":5,"metadata":{"custom":"keep"},"cells":[{"cell_type":"code","source":"a=1","metadata":{"tag":"keep"},"custom":{"x":1},"outputs":[],"execution_count":3},{"id":"markdown-id","cell_type":"markdown","source":"# 标题","metadata":{},"attachments":{"image":{"image/png":"AA=="}}}]}"##.utf8))
    }
    func testInsertMoveDeleteKeepCellIdentityAndMetadata() throws {
        var doc = try fixture(); doc.insertCell(at: 1, kind: "markdown")
        let ids = doc.cells.map(\.id)
        XCTAssertEqual(Set(ids).count, 3); XCTAssertEqual(doc.cells[2].id, "markdown-id")
        doc.moveCell(at: 0, by: 2)
        XCTAssertEqual(doc.cells.map(\.id), [ids[1], ids[2], ids[0]])
        let object = try JSONSerialization.jsonObject(with: doc.serialized()) as! [String: Any]
        let cells = object["cells"] as! [[String: Any]]
        XCTAssertEqual((cells[2]["metadata"] as? [String: String])?["tag"], "keep")
        XCTAssertEqual((cells[2]["custom"] as? [String: Int])?["x"], 1)
        doc.removeCell(at: 0); XCTAssertEqual(doc.cells.map(\.id), [ids[2], ids[0]])
        XCTAssertEqual((object["metadata"] as? [String: String])?["custom"], "keep")
    }
    func testConversionAndClearOutputsPreserveSource() throws {
        var doc = try fixture()
        doc.apply("stream", content: ["name": "stdout", "text": "output"], at: 0)
        doc.clearOutputs(at: 0)
        XCTAssertEqual(doc.cells[0].source, "a=1"); XCTAssertTrue(doc.cells[0].outputs.isEmpty); XCTAssertNil(doc.cells[0].executionCount)
        doc.convertCell(at: 0, to: "markdown"); XCTAssertEqual(doc.cells[0].kind, "markdown")
        let id = doc.cells[0].id
        doc.convertCell(at: 0, to: "code")
        XCTAssertEqual(doc.cells[0].id, id); XCTAssertEqual(doc.cells[0].source, "a=1")
        XCTAssertTrue(doc.cells[0].outputs.isEmpty)
    }
    func testDisplayUpdatesFollowMovedCells() throws {
        var doc = try fixture()
        doc.apply("display_data", content: ["data": ["text/plain":"old"], "metadata": [:], "transient":["display_id":"shared"]], at: 0)
        doc.moveCell(at: 0, by: 1)
        doc.apply("update_display_data", content: ["data":["text/plain":"new"], "metadata":[:], "transient":["display_id":"shared"]], at: 1)
        XCTAssertEqual((doc.cells[1].outputs[0]["data"] as? [String: String])?["text/plain"], "new")
    }
    func testOutOfRangeOperationsDoNotMutate() throws {
        var doc = try fixture(); let original = try doc.serialized()
        doc.moveCell(at: 0, by: -1); doc.moveCell(at: 1, by: Int.max)
        doc.removeCell(at: 99); doc.convertCell(at: -1, to: "code"); doc.clearOutputs(at: -1)
        XCTAssertEqual(try doc.serialized(), original)
    }
}
