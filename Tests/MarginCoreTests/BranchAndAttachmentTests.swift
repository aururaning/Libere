import XCTest
@testable import MarginCore

final class BranchAndAttachmentTests: XCTestCase {
    private func branch() -> (Note, UUID, UUID, UUID) {
        let root = Block(.formula, frame: Rect(30, 40, 120, 100))
        var child = Block(.text, frame: Rect(210, 90, 120, 90))
        var leaf = Block(.text, frame: Rect(390, 135, 110, 80))
        let first = AnnotationAnchor(ownerID: root.id, label: "一级", u: 1.5, v: 0.5)
        let second = AnnotationAnchor(ownerID: child.id, label: "二级", u: 1.5, v: 0.5)
        let third = AnnotationAnchor(ownerID: leaf.id, label: "三级", u: 0, v: 1)
        child.anchorID = first.id; leaf.anchorID = second.id
        var note = Note(title: "树"); note.paper = .a4
        note.blocks = [leaf, root, child]; note.anchors = [first, second, third]
        return (note, root.id, child.id, leaf.id)
    }

    func testBranchFollowsResizedOwnerEvenInReverseStorageOrder() throws {
        let (note, root, child, leaf) = branch()
        let placed = try XCTUnwrap(CanvasLayout.placing(root, frame: Rect(40, 60, 140, 120), anchor: nil, in: note))
        XCTAssertEqual(placed.first { $0.id == child }?.frame, Rect(250,120,120,90))
        XCTAssertEqual(placed.first { $0.id == leaf }?.frame, Rect(430,165,110,80))
        XCTAssertEqual(placed.map(\.anchorID), note.blocks.map(\.anchorID))
    }
    func testCycleLockAndDistantLeafOverflow() {
        var (note, root, _, leaf) = branch()
        let drop = Rect(390, 215, 120, 100)
        XCTAssertNil(CanvasLayout.nearest(to: drop, note: note, excluding: root, tolerance: 1))
        XCTAssertNil(CanvasLayout.nearest(to: drop, note: note, excluding: leaf, tolerance: 1))
        XCTAssertNil(CanvasLayout.placing(root, frame: drop, anchor: note.anchors.last, in: note))
        XCTAssertNil(CanvasLayout.placing(root, frame: Rect(380,40,120,100), anchor: nil, in: note))
        note.blocks[0].locked = true
        XCTAssertNil(CanvasLayout.placing(root, frame: Rect(40,40,120,100), anchor: nil, in: note))
    }
    private func document(_ name: String, _ source: String) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(source.utf8).write(to: url)
        return try XCTUnwrap(AttachmentFormat(filename: name)).document(at: url)
    }
    func testPythonHTMLMarkdownAndText() throws {
        let py = try document("demo.PY", "print('<标签>')\n  # 中文")
        XCTAssertTrue(py.contains("&lt;标签&gt;")); XCTAssertTrue(py.contains("\n  # 中文"))
        XCTAssertTrue(try document("page.html", "<h1>标题</h1>").contains("<h1>标题</h1>"))
        XCTAssertTrue(try document("readme.md", "**重点** $x^2$").contains("display=\"inline\""))
        XCTAssertTrue(try document("a.csv", "姓名,数量").contains("姓名,数量"))
        XCTAssertNil(AttachmentFormat(filename: "program.exe"))
    }
    func testNotebookCellsAndSavedOutputs() throws {
        let input = #"""
        {"nbformat":4,"cells":[{"cell_type":"markdown","source":["# 中文\n","$x^2$"]},
        {"cell_type":"code","source":"print('<x>')","execution_count":2,"outputs":[
        {"output_type":"stream","text":["第一行\n","第二行"]},{"output_type":"execute_result","data":{"text/plain":"42"}},
        {"output_type":"display_data","data":{"image/png":"aGVsbG8="}}]},{"cell_type":"raw","source":"原文"}]}
        """#
        let page = try document("课程.ipynb", input)
        for expected in ["<h1>中文</h1>", "display=\"inline\"", "In [2]", "&lt;x&gt;", "第一行\n第二行", "42", "data:image/png;base64,", "原文"] {
            XCTAssertTrue(page.contains(expected), expected)
        }
        XCTAssertThrowsError(try document("broken.ipynb", "{}"))
    }
    func testImageFormatsAreRecognizedWithoutBecomingTextEditors() {
        for ext in ["png", "JPG", "JPEG", "heic", "HEIF", "gif", "tif", "TIFF", "bmp", "webp"] {
            XCTAssertEqual(AttachmentFormat(filename: "图片.\(ext)"), .image)
        }
        XCTAssertFalse(AttachmentFormat.image.isTextEditable)
        XCTAssertFalse(AttachmentFormat.notebook.isTextEditable)
        for format in [AttachmentFormat.source, .markdown, .html] { XCTAssertTrue(format.isTextEditable) }
        XCTAssertNil(AttachmentFormat(filename: "image.svg"))
    }
    func testImagePreviewCannotFallThroughToTextDecoding() throws {
        XCTAssertThrowsError(try document("image.png", "This happens to be valid UTF-8")) { error in
            guard case AttachmentFormat.PreviewError.image = error else { return XCTFail("Expected native-image preview routing, got \(error)") }
        }
    }
    func testLegacyPDFAttachmentRemainsReadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try Repository(root: root), id = UUID()
        let file = repo.assets.appendingPathComponent(id.uuidString + ".pdf")
        try Data("old".utf8).write(to: file)
        XCTAssertEqual(repo.asset(id), file)
        XCTAssertEqual(try Data(contentsOf: repo.asset(id)), Data("old".utf8))
    }
}
