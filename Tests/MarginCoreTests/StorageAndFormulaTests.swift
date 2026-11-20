import XCTest
@testable import MarginCore

final class StorageAndFormulaTests: XCTestCase {
    func temporaryRepository() throws -> Repository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try Repository(root: root)
    }
    func testSaveRoundTripIncludesOutboxInkRichTextAndAnchors() throws {
        let repository = try temporaryRepository()
        XCTAssertNil(try repository.load())
        var note = Note(title: "测试"); note.ink = Data([0, 1, 2]); note.touch("Mac")
        var block = Block(.text, frame: Rect(30, 30, 300, 200), text: "格式内容"); block.rtf = Data([3, 4]); note.blocks = [block]
        note.anchors = [AnnotationAnchor(ownerID: block.id, label: "A", u: 1.2, v: 0.3)]
        var workspace = Workspace(notes: [note]); workspace.pending = ["page_\(note.id)"]
        try repository.save(workspace)
        XCTAssertEqual(try repository.load(), workspace)
    }
    func testCorruptFileIsNotOverwrittenAndPreviousSnapshotExists() throws {
        let repository = try temporaryRepository(); let first = Workspace(notes: [Note(title: "first")])
        try repository.save(first); try repository.save(Workspace(notes: [Note(title: "second")]))
        let backup = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: repository.root.appendingPathComponent("workspace.previous.json")))
        XCTAssertEqual(backup, first)
        let corrupt = Data("invalid-json".utf8); try corrupt.write(to: repository.workspaceURL)
        XCTAssertThrowsError(try repository.load()); XCTAssertThrowsError(try repository.save(first))
        XCTAssertEqual(try Data(contentsOf: repository.workspaceURL), corrupt)
    }
    func testAttachmentCreationIsRejectedWithoutWritingAnAsset() throws {
        let repository = try temporaryRepository(); let source = repository.root.appendingPathComponent("test.pdf")
        try Data([1, 2]).write(to: source)
        XCTAssertThrowsError(try repository.copyAsset(source, id: UUID()))
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.assets.path))
        XCTAssertThrowsError(try repository.copyAsset(repository.root.appendingPathComponent("missing"), id: UUID()))
    }
    func testCommonFormulaMathMLAndErrors() throws {
        let examples = ["e^{i\\pi}+1=0", "\\int_0^1 x^2\\,dx=\\frac{1}{3}", "\\sqrt[3]{x}", "\\sum_{n=1}^{N}n", "\\begin{pmatrix}1&2\\\\3&4\\end{pmatrix}"]
        for source in examples { let rendered = try Formula.render(source); XCTAssertTrue(rendered.contains("<math")); XCTAssertFalse(rendered.contains("<script")) }
        XCTAssertThrowsError(try Formula.render("\\frac{x}"))
        XCTAssertThrowsError(try Formula.render("\\unknown{x}"))
        XCTAssertThrowsError(try Formula.render("x}"))
        XCTAssertThrowsError(try Formula.render(String(repeating: "{", count: 60) + "x" + String(repeating: "}", count: 60)))
    }
    func testFormulaTextIsEscapedAndNoRemoteResourcesAdded() throws {
        let rendered = try Formula.render("\\text{<script>alert(1)</script>}")
        XCTAssertTrue(rendered.contains("&lt;script&gt;")); XCTAssertFalse(rendered.contains("<script>"))
        XCTAssertFalse(rendered.contains("https://"))
    }
}
