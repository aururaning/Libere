import XCTest
@testable import MarginCore

final class ClipboardPageOwnershipTests: XCTestCase {
    private struct Fixture {
        let repository: Repository
        let workspace: Workspace
        let pageIndex: Int
        let targetID: UUID
        let originals: [String: Data]
        var page: Note { workspace.notes[pageIndex] }
        var root: URL { repository.root }
    }
    private func fixture(companionName: String = "analysis.py__12345678") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereClipboardOwnership-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = try Repository(root: root)
        var source = Note(title: "源项目", folder: true); source.managedDirectoryPath = "源项目"
        var target = Note(title: "目标项目", folder: true); target.managedDirectoryPath = "目标项目"
        var page = Note(title: "analysis.py", parent: source.id)
        page.id = UUID(uuidString: "12345678-1234-4567-8123-123456789ABC")!
        page.managedFilePath = "源项目/analysis.py"
        page.managedDirectoryPath = "源项目/" + companionName
        let archive = page.managedDirectoryPath!
        let contents = [page.managedFilePath!: Data("print('original')\n".utf8),
                        archive + "/pdf/讲义.pdf": Data("pdf original bytes".utf8),
                        archive + "/zip/资料.zip": Data([0, 255, 128, 1]),
                        archive + "/子页/readme.md": Data("nested original".utf8),
                        archive + "/未索引.txt": Data("keep unindexed companion content".utf8)]
        for (path, bytes) in contents {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("目标项目"), withIntermediateDirectories: true)
        try Data("unrelated".utf8).write(to: root.appendingPathComponent("源项目/不相关.txt"))
        func block(_ path: String, _ kind: BlockKind = .file) -> Block {
            var block = Block(kind, frame: Rect(20, 20, 380, 300))
            block.assetName = (path as NSString).lastPathComponent; block.relativeFilePath = path; block.fileID = UUID()
            return block
        }
        page.blocks = [block(page.managedFilePath!), block(archive + "/pdf/讲义.pdf", .pdf), block(archive + "/zip/资料.zip")]
        var child = Note(title: "子页", parent: page.id); child.managedDirectoryPath = archive + "/子页"
        child.blocks = [block(archive + "/子页/readme.md")]
        var aliases = Note(title: "其他页面的引用", parent: target.id)
        aliases.blocks = [page, child].flatMap { owner in owner.blocks.map { original in
            var copy = original; copy.id = UUID(); copy.reference = FileReference(noteID: owner.id, blockID: original.id); return copy
        } }
        let workspace = Workspace(notes: [source, target, page, child, aliases])
        try repository.save(workspace)
        return Fixture(repository: repository, workspace: workspace, pageIndex: 2, targetID: target.id, originals: contents)
    }
    private func verifyFiles(_ fixture: Fixture, mapping: (String) -> String) throws {
        for (path, bytes) in fixture.originals { XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(mapping(path))), bytes) }
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("源项目/不相关.txt")), Data("unrelated".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.repository.assets.path))
    }
    func testRenameMovesPrimaryAndCompanionWithEveryAlias() throws {
        let f = try fixture(); var next = f.workspace
        next.notes[f.pageIndex].title = "新的分析"
        let plan = try FileHierarchyTransaction.plan(from: f.workspace, to: &next, root: f.root)
        XCTAssertEqual(plan.moves.count, 2)
        XCTAssertEqual(next.notes[f.pageIndex].managedFilePath, "源项目/新的分析.py")
        XCTAssertEqual(next.notes[f.pageIndex].managedDirectoryPath, "源项目/新的分析__12345678")
        XCTAssertEqual(next.notes[3].managedDirectoryPath, "源项目/新的分析__12345678/子页")
        try plan.execute(at: f.root); try f.repository.save(next); try plan.finish(at: f.root)
        try verifyFiles(f) { $0.replacingOccurrences(of: "analysis.py__12345678", with: "新的分析__12345678").replacingOccurrences(of: "/analysis.py", with: "/新的分析.py") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(f.page.managedFilePath!).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(f.page.managedDirectoryPath!).path))
        let owners = Dictionary((next.notes[2].blocks + next.notes[3].blocks).map { ($0.fileIdentity, $0.relativeFilePath!) }, uniquingKeysWith: { a, _ in a })
        for alias in next.notes[4].blocks { XCTAssertEqual(alias.relativeFilePath, owners[alias.fileIdentity]) }
        XCTAssertEqual(next.notes[4].blocks[0].assetName, "新的分析.py")
    }
    func testReparentKeepsBothNamesAndMovesTheWholeCompanionDirectory() throws {
        let f = try fixture(); var next = f.workspace
        next.notes[f.pageIndex].parentID = f.targetID
        let plan = try FileHierarchyTransaction.plan(from: f.workspace, to: &next, root: f.root)
        XCTAssertEqual(plan.moves.count, 2)
        XCTAssertEqual(next.notes[f.pageIndex].managedFilePath, "目标项目/analysis.py")
        XCTAssertEqual(next.notes[f.pageIndex].managedDirectoryPath, "目标项目/analysis.py__12345678")
        try plan.execute(at: f.root); try f.repository.save(next); try plan.finish(at: f.root)
        try verifyFiles(f) { $0.replacingOccurrences(of: "源项目/", with: "目标项目/") }
        XCTAssertTrue(next.notes[4].blocks.allSatisfy { $0.relativeFilePath?.hasPrefix("目标项目/") == true })
    }
    func testEitherDestinationConflictPreservesEveryOriginal() throws {
        for directoryConflict in [false, true] {
            let f = try fixture(); var next = f.workspace
            next.notes[f.pageIndex].parentID = f.targetID
            let conflict = f.root.appendingPathComponent(directoryConflict ? "目标项目/analysis.py__12345678" : "目标项目/analysis.py")
            if directoryConflict { try FileManager.default.createDirectory(at: conflict, withIntermediateDirectories: true) }
            let sentinel = directoryConflict ? conflict.appendingPathComponent("keep.txt") : conflict
            try Data("existing destination".utf8).write(to: sentinel)
            let plan = try FileHierarchyTransaction.plan(from: f.workspace, to: &next, root: f.root)
            XCTAssertThrowsError(try plan.execute(at: f.root))
            try verifyFiles(f) { $0 }
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("existing destination".utf8))
            XCTAssertEqual(try f.repository.load(), f.workspace)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".libere-file-moves.json").path))
        }
    }
    func testRollbackRestoresPrimaryCompanionAndIndex() throws {
        let f = try fixture(); var next = f.workspace
        next.notes[f.pageIndex].title = "重命名.py"; next.notes[f.pageIndex].parentID = f.targetID
        let plan = try FileHierarchyTransaction.plan(from: f.workspace, to: &next, root: f.root)
        try plan.execute(at: f.root)
        try FileHierarchyTransaction.recover(at: f.root, workspace: f.repository.load())
        try verifyFiles(f) { $0 }
        XCTAssertEqual(try f.repository.load(), f.workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("目标项目/重命名.py").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("目标项目/重命名.py__12345678").path))
    }
    func testUndoPathPlanRestoresBothOwnersWithoutDoubleStagingTheirChildren() throws {
        let f = try fixture(); var next = f.workspace
        next.notes[f.pageIndex].title = "重命名.py"; next.notes[f.pageIndex].parentID = f.targetID
        let forward = try FileHierarchyTransaction.plan(from: f.workspace, to: &next, root: f.root)
        try forward.execute(at: f.root); try f.repository.save(next); try forward.finish(at: f.root)
        var undo = next
        undo.notes[f.pageIndex].title = f.page.title; undo.notes[f.pageIndex].parentID = f.page.parentID
        let originalPaths = Dictionary(f.workspace.notes.flatMap(\.blocks).map { ($0.fileIdentity, $0.relativeFilePath!) }, uniquingKeysWith: { a, _ in a })
        let backward = try FileHierarchyTransaction.plan(from: next, to: &undo, root: f.root, restoringFilePaths: originalPaths)
        XCTAssertEqual(backward.moves.count, 2, "The directory move carries archive files and must not stage them a second time")
        try backward.execute(at: f.root); try f.repository.save(undo); try backward.finish(at: f.root)
        try verifyFiles(f) { $0 }
        XCTAssertEqual(undo.notes, f.workspace.notes)
    }

    func testFailedArchiveRetrySuffixSurvivesRenameAndUndoBesideRetainedFiles() throws {
        // A failed index save left the first archive in place; retry bound this
        // page to the next available directory rather than adopting that archive.
        let f = try fixture(companionName: "analysis.py__12345678 (2)")
        let retained = f.root.appendingPathComponent("源项目/analysis.py__12345678")
        try FileManager.default.createDirectory(at: retained, withIntermediateDirectories: true)
        let sentinel = retained.appendingPathComponent("earlier-paste.pdf")
        try Data("retained failed paste".utf8).write(to: sentinel)
        var next = f.workspace; next.notes[f.pageIndex].title = "新的分析.py"
        let forward = try FileHierarchyTransaction.plan(from: f.workspace, to: &next, root: f.root)
        XCTAssertEqual(next.notes[f.pageIndex].managedDirectoryPath, "源项目/新的分析.py__12345678 (2)")
        try forward.execute(at: f.root); try f.repository.save(next); try forward.finish(at: f.root)
        var undo = next; undo.notes[f.pageIndex].title = f.page.title
        let paths = Dictionary(f.workspace.notes.flatMap(\.blocks).map { ($0.fileIdentity, $0.relativeFilePath!) }, uniquingKeysWith: { a, _ in a })
        let reverse = try FileHierarchyTransaction.plan(from: next, to: &undo, root: f.root,
            restoringFilePaths: paths, restoringDirectoryPaths: [f.page.id: f.page.managedDirectoryPath!])
        try reverse.execute(at: f.root); try f.repository.save(undo); try reverse.finish(at: f.root)
        try verifyFiles(f) { $0 }
        XCTAssertEqual(undo.notes, f.workspace.notes)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("retained failed paste".utf8))
    }

    func testHistoricalFilePathsCanRecoverAnArbitraryCompanionName() throws {
        let f = try fixture(companionName: "自定义归档名称")
        var next = f.workspace; next.notes[f.pageIndex].title = "新的分析.py"
        let forward = try FileHierarchyTransaction.plan(from: f.workspace, to: &next, root: f.root)
        try forward.execute(at: f.root); try f.repository.save(next); try forward.finish(at: f.root)
        var undo = next; undo.notes[f.pageIndex].title = f.page.title
        let paths = Dictionary(f.workspace.notes.flatMap(\.blocks).map { ($0.fileIdentity, $0.relativeFilePath!) }, uniquingKeysWith: { a, _ in a })
        let reverse = try FileHierarchyTransaction.plan(from: next, to: &undo, root: f.root, restoringFilePaths: paths)
        XCTAssertEqual(undo.notes[f.pageIndex].managedDirectoryPath, "源项目/自定义归档名称")
        XCTAssertEqual(reverse.moves.count, 2)
        try reverse.execute(at: f.root); try f.repository.save(undo); try reverse.finish(at: f.root)
        try verifyFiles(f) { $0 }
    }

    func testEmptyCompanionRestoresExactDirectoryWithoutFileEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereEmptyCompanion-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = try Repository(root: root)
        try Data("main".utf8).write(to: root.appendingPathComponent("main.py"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("自定义空目录"), withIntermediateDirectories: true)
        var page = Note(title: "main.py"); page.managedFilePath = "main.py"; page.managedDirectoryPath = "自定义空目录"
        let before = Workspace(notes: [page]); try repo.save(before)
        var next = before; next.notes[0].title = "renamed.py"
        let forward = try FileHierarchyTransaction.plan(from: before, to: &next, root: root)
        try forward.execute(at: root); try repo.save(next); try forward.finish(at: root)
        var undo = next; undo.notes[0].title = page.title
        let reverse = try FileHierarchyTransaction.plan(from: next, to: &undo, root: root,
            restoringDirectoryPaths: [page.id: "自定义空目录"])
        try reverse.execute(at: root); try repo.save(undo); try reverse.finish(at: root)
        XCTAssertEqual(undo.notes, before.notes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("main.py")), Data("main".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("自定义空目录").path))
    }

    func testDirectoryOnlyPageRestoresUUIDNameAndIgnoresHintsWithoutHierarchyChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereUUIDDirectory-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = try Repository(root: root)
        var page = Note(title: "普通页"); page.managedDirectoryPath = "普通页__" + page.id.uuidString.prefix(8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(page.managedDirectoryPath!), withIntermediateDirectories: true)
        let before = Workspace(notes: [page]); try repo.save(before)
        var unchanged = before
        let ignored = try FileHierarchyTransaction.plan(from: before, to: &unchanged, root: root, restoringDirectoryPaths: [page.id: "不应移动"])
        XCTAssertFalse(ignored.hasChanges); XCTAssertEqual(unchanged, before)
        var next = before; next.notes[0].title = "普通页改名"
        let forward = try FileHierarchyTransaction.plan(from: before, to: &next, root: root)
        XCTAssertEqual(next.notes[0].managedDirectoryPath, "普通页改名")
        try forward.execute(at: root); try repo.save(next); try forward.finish(at: root)
        var undo = next; undo.notes[0].title = page.title
        let reverse = try FileHierarchyTransaction.plan(from: next, to: &undo, root: root, restoringDirectoryPaths: [page.id: page.managedDirectoryPath!])
        try reverse.execute(at: root); try repo.save(undo); try reverse.finish(at: root)
        XCTAssertEqual(undo.notes, before.notes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(page.managedDirectoryPath!).path))
    }
}
