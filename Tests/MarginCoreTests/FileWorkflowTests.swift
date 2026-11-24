import XCTest
@testable import MarginCore

final class FileWorkflowTests: XCTestCase {
    func testOpeningAndSynchronizingIndexNeverCreatesMirrors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereIndex-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try Repository(root: root), directories = WorkspaceDirectories(repository: repository)
        let workspace = Workspace(notes: [Note(title: "目录", folder: true)])
        try repository.save(workspace); try directories.synchronize(workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.assets.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directories.root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.sync.path))
        XCTAssertEqual(try repository.load(), workspace)
    }

    func testIndexRejectsOutsideReservedMissingAndSymlinkEscapes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereIndexPolicy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try Repository(root: root)
        let source = root.appendingPathComponent("中文.md"); try Data("正文".utf8).write(to: source)
        XCTAssertEqual(try FileIndexPolicy.path(for: source, inside: root), "中文.md")
        XCTAssertThrowsError(try FileIndexPolicy.path(for: root.appendingPathComponent("missing.md"), inside: root))
        XCTAssertThrowsError(try FileIndexPolicy.path(for: repository.workspaceURL, inside: root))
        let link = root.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.deletingLastPathComponent())
        XCTAssertThrowsError(try FileIndexPolicy.path(for: link.appendingPathComponent("anything.md"), inside: root))
    }

    func testNotebookPreservesMetadataAndAllMimeDataWhileEditing() throws {
        let original = Data(##"{"nbformat":4,"nbformat_minor":5,"metadata":{"kernelspec":{"name":"python3"},"custom":[1,"中文"]},"unknown":{"keep":true},"cells":[{"id":"a","cell_type":"code","source":["x=1\n","x"],"execution_count":7,"metadata":{"custom":"yes"},"outputs":[{"output_type":"display_data","data":{"image/png":"AAECAw==","text/plain":"unchanged","application/custom":{"a":42}},"metadata":{"width":9999}}]},{"cell_type":"markdown","source":"# 原文","metadata":{},"attachments":{"photo":{"image/png":"AAECAw=="}}}] }"##.utf8)
        var document = try NotebookDocument(data: original)
        document.setSource("x=2\nx", at: 0); document.setSource("# 可编辑", at: 1)
        let root = try JSONSerialization.jsonObject(with: document.serialized()) as! NSDictionary
        let before = try JSONSerialization.jsonObject(with: original) as! NSDictionary
        XCTAssertEqual(root["metadata"] as? NSDictionary, before["metadata"] as? NSDictionary)
        XCTAssertEqual(root["unknown"] as? NSDictionary, before["unknown"] as? NSDictionary)
        let cells = root["cells"] as! [NSDictionary], prior = before["cells"] as! [NSDictionary]
        XCTAssertEqual(cells[0]["outputs"] as? NSArray, prior[0]["outputs"] as? NSArray)
        XCTAssertEqual(cells[1]["attachments"] as? NSDictionary, prior[1]["attachments"] as? NSDictionary)
        XCTAssertEqual(document.cells[1].source, "# 可编辑")
    }
    func testJupyterStreamsClearAndCrossCellDisplayUpdate() throws {
        var doc = try NotebookDocument(data: Data(##"{"nbformat":4,"cells":[{"cell_type":"code","source":"","outputs":[]},{"cell_type":"code","source":"","outputs":[]}]}"##.utf8))
        doc.beginExecution(at: 0)
        doc.apply("stream", content: ["name":"stdout", "text":"甲"], at: 0)
        doc.apply("stream", content: ["name":"stdout", "text":"乙"], at: 0)
        XCTAssertEqual(doc.cells[0].outputs.count, 1); XCTAssertEqual(doc.cells[0].outputs[0]["text"] as? String, "甲乙")
        doc.apply("clear_output", content: ["wait":true], at: 0)
        XCTAssertEqual(doc.cells[0].outputs.count, 1)
        doc.apply("display_data", content: ["data":["text/html":"old"], "metadata":[:], "transient":["display_id":"shared"]], at: 0)
        doc.apply("update_display_data", content: ["data":["text/html":"new"], "metadata":[:], "transient":["display_id":"shared"]], at: 1)
        XCTAssertEqual((doc.cells[0].outputs[0]["data"] as? [String:String])?["text/html"], "new")
        XCTAssertNil(doc.cells[0].outputs[0]["transient"])
        doc.apply("execute_reply", content: ["execution_count":4], at: 0)
        XCTAssertEqual(doc.cells[0].executionCount, 4)
        doc.beginExecution(at: 0)
        XCTAssertTrue(doc.cells[0].outputs.isEmpty); XCTAssertNil(doc.cells[0].executionCount)
    }
    func testTextEncodingAndUnchangedBytes() throws {
        let examples: [(Data, String.Encoding)] = [(Data([0xEF,0xBB,0xBF]), .utf8), (Data([0xFF,0xFE]), .utf16LittleEndian), (Data([0,0,0xFE,0xFF]), .utf32BigEndian)]
        for (bom, encoding) in examples {
            let bytes = bom + "原文🍎\r\n".data(using: encoding)!
            var doc = try EditableText(data: bytes)
            XCTAssertEqual(try doc.serialized(), bytes)
            doc.text += "第二行"
            XCTAssertEqual(try doc.serialized(), bom + doc.text.data(using: encoding)!)
        }
        XCTAssertThrowsError(try EditableText(data: Data([0xFF, 0xAB, 0xCD])))
    }
    func testLegacyFilesBecomeIndexesWithoutCopyingOrDiscardingVersions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereLegacy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try Repository(root: root)
        try FileManager.default.createDirectory(at: repo.assets, withIntermediateDirectories: true)
        let original = UUID(), edited = UUID()
        try Data("原件".utf8).write(to: repo.asset(original)); try Data("编辑版".utf8).write(to: repo.asset(edited))
        let working = root.appendingPathComponent("Projects/项目/工作稿.md")
        try FileManager.default.createDirectory(at: working.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("外部更新".utf8).write(to: working)
        let index = ["files": ["项目/工作稿.md": edited.uuidString], "pages": [String:String]()]
        try JSONEncoder().encode(index).write(to: root.appendingPathComponent("Projects/index.json"))
        var block = Block(.file, frame: Rect(20,20,380,500)); block.assetID = original; block.workingAssetID = edited; block.assetName = "工作稿.md"
        var page = Note(title: "页面"); page.blocks = [block]
        var workspace = Workspace(notes: [page]); workspace.schemaVersion = 1
        let dirs = WorkspaceDirectories(repository: repo)
        XCTAssertTrue(dirs.migrate(&workspace))
        let result = workspace.notes[0].blocks[0]
        XCTAssertEqual(result.relativeFilePath, "Projects/项目/工作稿.md")
        XCTAssertEqual(result.fileIdentity, block.fileIdentity); XCTAssertTrue(result.referencedAssets.isEmpty)
        XCTAssertEqual(try Data(contentsOf: repo.asset(original)), Data("原件".utf8))
        XCTAssertEqual(try Data(contentsOf: repo.asset(edited)), Data("编辑版".utf8))
        XCTAssertEqual(try Data(contentsOf: working), Data("外部更新".utf8))
        XCTAssertFalse(dirs.migrate(&workspace))
        XCTAssertEqual(workspace.schemaVersion, 3)
    }
    func testReferencesStayWithinChosenRootAndFollowPageNames() {
        let root = URL(fileURLWithPath: "/tmp/my-library")
        XCTAssertEqual(ReferencePath.relative(root.appendingPathComponent("项目/文件.py"), inside: root), "项目/文件.py")
        XCTAssertNil(ReferencePath.relative(URL(fileURLWithPath: "/tmp/my-library-other/file.py"), inside: root))
        XCTAssertNil(ReferencePath.resolve("../outside.py", inside: root))
        XCTAssertNil(ReferencePath.resolve("/tmp/outside.py", inside: root))
        let folder = Note(title: "项目"), page = Note(title: "子页", parent: folder.id)
        XCTAssertEqual(ReferencePath.title(of: page.id, in: Workspace(notes:[folder,page])), ["项目","子页"])
    }
    func testNearestAnnotationAvoidsObstaclesAndExtendsWidePage() throws {
        let occupied = [Rect(300,100,300,400)]
        let result = try XCTUnwrap(CanvasLayout.nearestVacant(Rect(620,120,220,150), paper: .continuous, occupied: occupied))
        XCTAssertFalse(occupied.contains { result.intersects($0, gap:12) })
        XCTAssertTrue(CanvasLayout.fits(result, paper: .continuous))
        var page = Note(title: "宽幅"); page.paper = .wideContinuous; page.blocks = [Block(.text, frame:Rect(850,1800,220,150))]
        XCTAssertGreaterThan(page.height, 1950); XCTAssertEqual(page.paper.width, 1123)
    }
    func testLinkModesAndURLValidation() throws {
        XCTAssertNotNil(WebLink.url(" https://example.org/a?q=1 "))
        for value in ["javascript:alert(1)","file:///tmp/a","https://user:password@example.org","https://example.org/not a url"] { XCTAssertNil(WebLink.url(value)) }
        var block = Block(.link, frame: Rect(20,20,380,500)); block.linkURL = "https://example.org"; block.linkMode = .browser; block.collapsed = true
        let result = try JSONDecoder().decode(Block.self, from: JSONEncoder().encode(block))
        XCTAssertEqual(result, block)
    }
}
