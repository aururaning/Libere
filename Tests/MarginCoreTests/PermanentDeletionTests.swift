import XCTest
@testable import MarginCore

final class PermanentDeletionTests: XCTestCase {
    func testTrashRecordsOriginAndTimeAndRecoveryClearsThem() throws {
        let folder = Note(title: "项目", folder: true)
        let child = Note(title: "页面", parent: folder.id)
        var workspace = Workspace(notes: [folder, child])
        let ids = workspace.trashSubtree(folder.id)
        XCTAssertEqual(ids, [folder.id, child.id])
        XCTAssertEqual(workspace.notes[1].originalParentPath, "项目")
        XCTAssertNotNil(workspace.notes[1].deletedAt)
        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        XCTAssertEqual(decoded, workspace)
        _ = workspace.recoverSubtree(folder.id)
        XCTAssertTrue(workspace.notes.allSatisfy { !$0.deleted && $0.deletedAt == nil && $0.originalParentPath == nil })
    }
    func testPurgeRemovesContentAndReceiptResultsButKeepsRetryIdentity() throws {
        var page = Note(title: "erase-this-title")
        page.blocks = [Block(.text, frame: Rect(0, 0, 200, 100), text: "erase-this-body")]
        page.ink = Data("erase-this-ink".utf8); page.deleted = true
        var workspace = Workspace(notes: [page])
        let receipt = AgentReceipt(requestID: "request-123", fingerprint: "hash", tool: "create_page",
            result: Data("{\"page\":{\"id\":\"\(page.id)\",\"title\":\"erase-this-title\"}}".utf8))
        workspace.agentReceipts = [receipt]
        workspace.mergePurge(PurgedPage(note: page))
        XCTAssertTrue(workspace.notes.isEmpty)
        XCTAssertEqual(workspace.agentReceipts?.first?.requestID, receipt.requestID)
        XCTAssertEqual(workspace.agentReceipts?.first?.fingerprint, receipt.fingerprint)
        XCTAssertEqual(workspace.agentReceipts?.first?.resultPurged, true)
        XCTAssertTrue(workspace.agentReceipts!.first!.result.isEmpty)
        let encoded = String(data: try JSONEncoder().encode(workspace), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("erase-this"))
        let remote = workspace.purgedPages![page.id.uuidString]!.record
        XCTAssertTrue(remote.deleted && remote.permanentlyDeleted == true && remote.blocks.isEmpty && remote.ink == nil)
        XCTAssertTrue(remote.title.isEmpty)
        var importedRecord = Workspace(notes: [remote]); importedRecord.enforcePurges()
        XCTAssertTrue(importedRecord.notes.isEmpty && importedRecord.purgedPageIDs.contains(page.id))
    }
    func testStaleSaveAndPreviousSnapshotCannotRestorePurgedContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiberePurge-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try Repository(root: root)
        let original = root.appendingPathComponent("original.md"), bytes = Data("source must stay".utf8)
        try bytes.write(to: original)
        var page = Note(title: "private-removed-title")
        page.blocks = [Block(.text, frame: Rect(0,0,200,100), text: "private-removed-body")]
        let stale = Workspace(notes: [page]); try repository.save(stale)
        var next = stale; next.mergePurge(PurgedPage(note: page)); try repository.save(next)
        try repository.save(stale)
        let loaded = try XCTUnwrap(repository.load())
        XCTAssertTrue(loaded.notes.isEmpty); XCTAssertTrue(loaded.purgedPageIDs.contains(page.id))
        for name in ["workspace.json", "workspace.previous.json"] {
            let contents = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(contents.contains("private-removed"), name)
        }
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }
    func testOlderIndexVersionsUpgradeToPurgeAwareFormatWithoutFileCopies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiberePurgeVersion-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try Repository(root: root), directories = WorkspaceDirectories(repository: repository)
        for version in [1, 2] {
            var workspace = Workspace(notes: [Note(title: "旧页")]); workspace.schemaVersion = version
            try repository.save(workspace)
            var loaded = try XCTUnwrap(repository.load())
            XCTAssertTrue(directories.migrate(&loaded)); XCTAssertEqual(loaded.schemaVersion, 3)
            XCTAssertFalse(directories.migrate(&loaded)); XCTAssertEqual(loaded.notes.first?.title, "旧页")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.assets.path))
    }
}
