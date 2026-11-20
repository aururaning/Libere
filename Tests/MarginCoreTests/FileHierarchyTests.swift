import XCTest
@testable import MarginCore

final class FileHierarchyTests: XCTestCase {
    private func fixture() throws -> (Repository, Workspace, UUID, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereFileMoves-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = try Repository(root: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("项目/子目录"), withIntermediateDirectories: true)
        try Data("原始内容\n".utf8).write(to: root.appendingPathComponent("项目/子目录/a.md"))
        try Data("未索引文件".utf8).write(to: root.appendingPathComponent("项目/同目录.txt"))
        var folder = Note(title: "项目", folder: true); folder.managedDirectoryPath = "项目"
        var page = Note(title: "a.md", parent: folder.id); page.managedFilePath = "项目/子目录/a.md"
        var block = Block(.file, frame: Rect(20,20,300,300)); block.relativeFilePath = page.managedFilePath; block.assetName = "a.md"; block.fileID = UUID()
        page.blocks = [block]
        var alias = Note(title: "别处的引用"), copy = block
        copy.id = UUID(); copy.reference = FileReference(noteID: page.id, blockID: block.id); alias.blocks = [copy]
        let workspace = Workspace(notes: [folder, page, alias]); try repository.save(workspace)
        return (repository, workspace, folder.id, page.id)
    }
    func testFolderRenameMovesOriginalsAndEveryReferenceWithoutCopies() throws {
        let (repo, before, folderID, _) = try fixture()
        var next = before; next.notes[0].title = "重命名"
        let plan = try FileHierarchyTransaction.plan(from: before, to: &next, root: repo.root)
        try plan.execute(at: repo.root); try repo.save(next); try plan.finish(at: repo.root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("项目").path))
        XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent("重命名/子目录/a.md")), Data("原始内容\n".utf8))
        XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent("重命名/同目录.txt")), Data("未索引文件".utf8))
        XCTAssertEqual(Set(next.notes.flatMap(\.blocks).compactMap(\.relativeFilePath)), ["重命名/子目录/a.md"])
        XCTAssertEqual(next.notes.first { $0.id == folderID }?.managedDirectoryPath, "重命名")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.assets.path))
        var undo = next; undo.notes[0].title = "项目"
        let reverse = try FileHierarchyTransaction.plan(from: next, to: &undo, root: repo.root)
        try reverse.execute(at: repo.root); try repo.save(undo); try reverse.finish(at: repo.root)
        XCTAssertEqual(undo.notes.flatMap(\.blocks), before.notes.flatMap(\.blocks))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("项目/子目录/a.md").path))
    }
    func testFileRenameAndReparentUpdateAliasesAndPreserveExtension() throws {
        let (repo, before, _, pageID) = try fixture()
        var target = Note(title: "目标", folder: true); target.managedDirectoryPath = "目标"
        var next = before; next.notes.append(target)
        let i = next.notes.firstIndex { $0.id == pageID }!
        next.notes[i].title = "中文文件"; next.notes[i].parentID = target.id
        let plan = try FileHierarchyTransaction.plan(from: before, to: &next, root: repo.root)
        try plan.execute(at: repo.root); try repo.save(next); try plan.finish(at: repo.root)
        XCTAssertEqual(next.notes[i].managedFilePath, "目标/中文文件.md")
        XCTAssertTrue(next.notes.flatMap(\.blocks).allSatisfy { $0.relativeFilePath == "目标/中文文件.md" && $0.assetName == "中文文件.md" })
        XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent("目标/中文文件.md")), Data("原始内容\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("项目/子目录/a.md").path))
    }
    func testDestinationConflictDoesNotMoveOrOverwriteEitherFile() throws {
        let (repo, before, _, _) = try fixture()
        try Data("另一份文件".utf8).write(to: repo.root.appendingPathComponent("项目/子目录/b.md"))
        var next = before; next.notes[1].title = "b.md"
        let plan = try FileHierarchyTransaction.plan(from: before, to: &next, root: repo.root)
        XCTAssertThrowsError(try plan.execute(at: repo.root))
        XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent("项目/子目录/a.md")), Data("原始内容\n".utf8))
        XCTAssertEqual(try Data(contentsOf: repo.root.appendingPathComponent("项目/子目录/b.md")), Data("另一份文件".utf8))
        XCTAssertEqual(try repo.load(), before)
    }
    func testInterruptedMoveRollsBackUnlessItsIndexWasCommitted() throws {
        let (repo, before, _, _) = try fixture()
        var next = before; next.notes[0].title = "新位置"
        let plan = try FileHierarchyTransaction.plan(from: before, to: &next, root: repo.root)
        try plan.execute(at: repo.root)
        try FileHierarchyTransaction.recover(at: repo.root, workspace: repo.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("项目/子目录/a.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("新位置").path))
        try plan.execute(at: repo.root); try repo.save(next)
        try FileHierarchyTransaction.recover(at: repo.root, workspace: repo.load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("新位置/子目录/a.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("项目").path))
    }
    func testVirtualCategoryMovesOnlyItsIndexedFiles() throws {
        let (repo, original, _, _) = try fixture()
        var before = original
        before.notes[0].managedDirectoryPath = nil
        var next = before; next.notes[0].title = "分类"
        let plan = try FileHierarchyTransaction.plan(from: before, to: &next, root: repo.root)
        try plan.execute(at: repo.root); try repo.save(next); try plan.finish(at: repo.root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("分类/a.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("项目/同目录.txt").path))
        XCTAssertEqual(next.notes[2].blocks[0].relativeFilePath, "分类/a.md")
    }
}
