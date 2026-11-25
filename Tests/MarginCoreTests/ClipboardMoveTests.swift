import XCTest
@testable import MarginCore

final class ClipboardMoveTests: XCTestCase {
    private struct Fixture {
        let base: URL
        let root: URL
        let outside: URL
        let receipts: URL
        let page: URL
        let source: URL
        let id = UUID()
        let device = "fixture-device"
        let data = Data((0..<70_003).map { UInt8($0 % 251) })
        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("LibereMoveTests-" + UUID().uuidString)
            root = base.appendingPathComponent("library")
            outside = base.appendingPathComponent("outside")
            receipts = base.appendingPathComponent("receipts")
            page = root.appendingPathComponent("目标页")
            source = outside.appendingPathComponent("原始资料.pdf")
            for url in [root, outside, page] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            try data.write(to: source)
        }
        func prepare(_ sources: [ClipboardMove.Source]? = nil) throws -> ClipboardMove.Prepared {
            try ClipboardMove.prepare(sources ?? [.init(url: source, fileID: id)], libraryRoot: root, deviceID: device, receiptDirectory: receipts)
        }
        func finish(_ move: ClipboardMove.Prepared) throws -> ClipboardMove.FinishResult {
            try move.markCommitted(); return try move.finishSources()
        }
        func cleanup() { try? FileManager.default.removeItem(at: base) }
    }

    func testMoveLeavesSourceUntilDurableCommitAndVerifiedFinish() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let move = try f.prepare(); defer { move.cleanup() }
        XCTAssertEqual(try Data(contentsOf: f.source), f.data)
        let files = try move.install(into: f.page)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].receiptID, move.id)
        XCTAssertEqual(files[0].fileID, f.id)
        XCTAssertEqual(files[0].sourceURL, f.source)
        XCTAssertEqual(files[0].destinationURL, f.page.appendingPathComponent("PDF/原始资料.pdf"))
        XCTAssertEqual(try Data(contentsOf: files[0].destinationURL), f.data)
        XCTAssertEqual(try Data(contentsOf: f.source), f.data)
        XCTAssertThrowsError(try move.finishSources())
        XCTAssertThrowsError(try ClipboardMove.resumeCommitted(receiptID: move.id, libraryRoot: f.root, deviceID: f.device, receiptDirectory: f.receipts))
        let result = try f.finish(move)
        XCTAssertTrue(result.completed); XCTAssertEqual(result.movedCount, 1)
        XCTAssertTrue(result.retainedSources.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.path))
        XCTAssertEqual(try Data(contentsOf: files[0].destinationURL), f.data)
        XCTAssertTrue(try ClipboardMove.pendingReceiptIDs(libraryRoot: f.root, deviceID: f.device, receiptDirectory: f.receipts).isEmpty)
    }

    func testSameNameConflictRejectsWholeBatchBeforeInstallingAnyFile() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let second = f.outside.appendingPathComponent("second.bin"); try Data([2]).write(to: second)
        let category = f.page.appendingPathComponent("其他"); try FileManager.default.createDirectory(at: category, withIntermediateDirectories: true)
        let occupied = category.appendingPathComponent("second.bin"); try Data([9]).write(to: occupied)
        let move = try f.prepare([.init(url: f.source, fileID: f.id), .init(url: second, fileID: UUID())]); defer { move.cleanup() }
        XCTAssertThrowsError(try move.install(into: f.page))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.page.appendingPathComponent("PDF/原始资料.pdf").path))
        XCTAssertEqual(try Data(contentsOf: occupied), Data([9]))
        XCTAssertEqual(try Data(contentsOf: f.source), f.data)
        XCTAssertEqual(try Data(contentsOf: second), Data([2]))
    }

    func testCleanupDoesNotRemoveInstalledDestinationOrOriginal() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let move = try f.prepare(); let files = try move.install(into: f.page)
        move.cleanup(); move.cleanup()
        XCTAssertEqual(try Data(contentsOf: f.source), f.data)
        XCTAssertEqual(try Data(contentsOf: files[0].destinationURL), f.data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".libere-cut-" + move.id.uuidString).path))
        let loaded = try ClipboardMove.loadReceipt(id: move.id, libraryRoot: f.root, deviceID: f.device, receiptDirectory: f.receipts)
        XCTAssertEqual(loaded.phase, .installed)
    }

    func testChangedSourceBeforeInstallIsNeverPublishedOrDeleted() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let move = try f.prepare(); defer { move.cleanup() }
        try Data("new content".utf8).write(to: f.source)
        XCTAssertThrowsError(try move.install(into: f.page))
        XCTAssertEqual(try Data(contentsOf: f.source), Data("new content".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.page.appendingPathComponent("PDF/原始资料.pdf").path))
    }

    func testChangedSourceAfterCommitRetainsBothVersions() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let move = try f.prepare(); defer { move.cleanup() }
        let files = try move.install(into: f.page); try move.markCommitted()
        try Data("edited while moving".utf8).write(to: f.source)
        let result = try move.finishSources()
        XCTAssertFalse(result.completed); XCTAssertEqual(result.retainedSources, [f.source])
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.source), Data("edited while moving".utf8))
        XCTAssertEqual(try Data(contentsOf: files[0].destinationURL), f.data)
    }

    func testChangedDestinationAfterCommitDoesNotAuthorizeSourceDeletion() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let move = try f.prepare(); defer { move.cleanup() }
        let files = try move.install(into: f.page); try move.markCommitted()
        try Data("destination edited".utf8).write(to: files[0].destinationURL)
        let result = try move.finishSources()
        XCTAssertFalse(result.completed)
        XCTAssertEqual(try Data(contentsOf: f.source), f.data)
        XCTAssertEqual(try Data(contentsOf: files[0].destinationURL), Data("destination edited".utf8))
    }

    func testDeleteFailureRestoresClaimedSourceAndRecoveryCanFinish() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let move = try f.prepare(); defer { move.cleanup() }
        let files = try move.install(into: f.page); try move.markCommitted()
        let partial = try move.finishSources { _ in throw CocoaError(.fileWriteNoPermission) }
        XCTAssertFalse(partial.completed); XCTAssertEqual(partial.retainedSources, [f.source])
        XCTAssertEqual(try Data(contentsOf: f.source), f.data)
        XCTAssertEqual(try Data(contentsOf: files[0].destinationURL), f.data)
        XCTAssertEqual(try ClipboardMove.pendingReceiptIDs(libraryRoot: f.root, deviceID: f.device, receiptDirectory: f.receipts), [move.id])
        let finished = try ClipboardMove.resumeCommitted(receiptID: move.id, libraryRoot: f.root, deviceID: f.device, receiptDirectory: f.receipts)
        XCTAssertTrue(finished.completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.path))
    }

    func testDifferentDeviceOrLibraryCannotResumeSourceDeletion() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let move = try f.prepare(); defer { move.cleanup() }
        _ = try move.install(into: f.page); try move.markCommitted()
        let other = f.base.appendingPathComponent("other-library"); try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ClipboardMove.loadReceipt(id: move.id, libraryRoot: f.root, deviceID: "different-device", receiptDirectory: f.receipts))
        XCTAssertThrowsError(try ClipboardMove.resumeCommitted(receiptID: move.id, libraryRoot: other, deviceID: f.device, receiptDirectory: f.receipts))
        XCTAssertEqual(try Data(contentsOf: f.source), f.data)
    }

    func testReceiptsCannotBeStoredInsideTheSyncedLibrary() throws {
        let f = try Fixture(); defer { f.cleanup() }
        XCTAssertThrowsError(try ClipboardMove.prepare([.init(url: f.source, fileID: f.id)], libraryRoot: f.root, deviceID: f.device, receiptDirectory: f.root.appendingPathComponent("receipts")))
        XCTAssertEqual(try Data(contentsOf: f.source), f.data)
    }

    func testCompletedMoveCanUndoAndRedoUsingNewReceipts() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let forward = try f.prepare(); defer { forward.cleanup() }
        let files = try forward.install(into: f.page); XCTAssertTrue(try f.finish(forward).completed)
        let reverse = try ClipboardMove.prepareReverse(receiptID: forward.id, libraryRoot: f.root, deviceID: f.device, receiptDirectory: f.receipts)
        defer { reverse.cleanup() }
        XCTAssertNotEqual(reverse.id, forward.id)
        let reversed = try reverse.installReverse()
        XCTAssertEqual(reversed[0].destinationURL, f.source)
        XCTAssertEqual(try Data(contentsOf: f.source), f.data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[0].destinationURL.path))
        XCTAssertTrue(try f.finish(reverse).completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[0].destinationURL.path))
        let redo = try ClipboardMove.prepareReverse(receiptID: reverse.id, libraryRoot: f.root, deviceID: f.device, receiptDirectory: f.receipts)
        defer { redo.cleanup() }
        let redone = try redo.installReverse(); XCTAssertTrue(try f.finish(redo).completed)
        XCTAssertEqual(redone[0].destinationURL, files[0].destinationURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.path))
        XCTAssertEqual(try Data(contentsOf: files[0].destinationURL), f.data)
    }

    func testUndoUsesLatestOriginalBytesAndNeverRestoresAFullFileSnapshot() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let forward = try f.prepare(); defer { forward.cleanup() }
        let files = try forward.install(into: f.page); _ = try f.finish(forward)
        let edited = Data("edits after the successful move".utf8); try edited.write(to: files[0].destinationURL)
        let reverse = try ClipboardMove.prepareReverse(receiptID: forward.id, libraryRoot: f.root, deviceID: f.device, receiptDirectory: f.receipts)
        defer { reverse.cleanup() }
        _ = try reverse.installReverse(); XCTAssertTrue(try f.finish(reverse).completed)
        XCTAssertEqual(try Data(contentsOf: f.source), edited)
    }

    func testUndoRefusesNewlyOccupiedOriginalLocation() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let forward = try f.prepare(); defer { forward.cleanup() }
        let files = try forward.install(into: f.page); _ = try f.finish(forward)
        try Data("unrelated new original".utf8).write(to: f.source)
        XCTAssertThrowsError(try ClipboardMove.prepareReverse(receiptID: forward.id, libraryRoot: f.root, deviceID: f.device, receiptDirectory: f.receipts))
        XCTAssertEqual(try Data(contentsOf: f.source), Data("unrelated new original".utf8))
        XCTAssertEqual(try Data(contentsOf: files[0].destinationURL), f.data)
    }

    func testUndoDoesNotCreateAReplacementForAnUnavailableOriginFolder() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let forward = try f.prepare(); defer { forward.cleanup() }
        let files = try forward.install(into: f.page); _ = try f.finish(forward)
        try FileManager.default.removeItem(at: f.outside)
        XCTAssertThrowsError(try ClipboardMove.prepareReverse(receiptID: forward.id, libraryRoot: f.root, deviceID: f.device, receiptDirectory: f.receipts))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.outside.path))
        XCTAssertEqual(try Data(contentsOf: files[0].destinationURL), f.data)
    }

    func testPartialReceiptCannotPretendToBeACompleteMoveDuringUndo() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let move = try f.prepare(); defer { move.cleanup() }
        _ = try move.install(into: f.page); try move.markCommitted()
        _ = try move.finishSources { _ in throw CocoaError(.fileWriteNoPermission) }
        XCTAssertThrowsError(try ClipboardMove.prepareReverse(receiptID: move.id, libraryRoot: f.root, deviceID: f.device, receiptDirectory: f.receipts))
        XCTAssertEqual(try Data(contentsOf: f.source), f.data)
    }

    func testRelocatedIndexedSourceIsReboundWithoutScanningFolders() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = f.root.appendingPathComponent("before.txt"); try f.data.write(to: source)
        let move = try f.prepare([.init(url: source, fileID: f.id)]); defer { move.cleanup() }
        let renamed = f.root.appendingPathComponent("after.txt"); try FileManager.default.moveItem(at: source, to: renamed)
        let files = try move.install(into: f.page, sourceReplacements: [source: renamed])
        XCTAssertEqual(files[0].sourceURL, renamed)
        XCTAssertEqual(files[0].destinationURL.lastPathComponent, "after.txt")
        XCTAssertTrue(try f.finish(move).completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
    }

    func testUndoFollowsCurrentIndexedPathByStableFileIdentity() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let forward = try f.prepare(); defer { forward.cleanup() }
        let files = try forward.install(into: f.page); _ = try f.finish(forward)
        let current = f.root.appendingPathComponent("later-name.pdf"); try FileManager.default.moveItem(at: files[0].destinationURL, to: current)
        let reverse = try ClipboardMove.prepareReverse(receiptID: forward.id, libraryRoot: f.root, deviceID: f.device, receiptDirectory: f.receipts, currentSources: [f.id: current])
        defer { reverse.cleanup() }
        _ = try reverse.installReverse(); XCTAssertTrue(try f.finish(reverse).completed)
        XCTAssertEqual(try Data(contentsOf: f.source), f.data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
    }

    func testConcurrentRenameKeepsTheNewFilenameAndItsNewCategory() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let source = f.root.appendingPathComponent("before.py"); try f.data.write(to: source)
        let move = try f.prepare([.init(url: source, fileID: f.id)]); defer { move.cleanup() }
        let renamed = f.root.appendingPathComponent("after.md"); try FileManager.default.moveItem(at: source, to: renamed)
        let file = try move.install(into: f.page, sourceReplacements: [source: renamed])[0]
        XCTAssertEqual(file.destinationURL, f.page.appendingPathComponent("Markdown/after.md"))
        XCTAssertTrue(try f.finish(move).completed)
        XCTAssertEqual(try Data(contentsOf: file.destinationURL), f.data)
    }

    func testSymlinkSourceAndEscapingDestinationAreRejected() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let link = f.outside.appendingPathComponent("alias.pdf"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.source)
        XCTAssertThrowsError(try f.prepare([.init(url: link, fileID: f.id)]))
        let move = try f.prepare(); defer { move.cleanup() }
        try FileManager.default.createSymbolicLink(at: f.page.appendingPathComponent("PDF"), withDestinationURL: f.outside)
        XCTAssertThrowsError(try move.install(into: f.page))
        XCTAssertEqual(try Data(contentsOf: f.source), f.data)
    }

    func testLibraryMetadataCannotBeUsedAsAMoveSourceOrDestination() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let index = f.root.appendingPathComponent("workspace.json"); try Data("index".utf8).write(to: index)
        XCTAssertThrowsError(try f.prepare([.init(url: index, fileID: UUID())]))
        let move = try f.prepare(); defer { move.cleanup() }
        XCTAssertThrowsError(try move.install(into: f.root.appendingPathComponent("Sync")))
        XCTAssertEqual(try Data(contentsOf: index), Data("index".utf8))
    }

    func testSamePathMoveIsANoOpAndDoesNotDeleteTheOriginal() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let parent = f.root.appendingPathComponent("PDF"); try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let source = parent.appendingPathComponent("same.pdf"); try f.data.write(to: source)
        let move = try f.prepare([.init(url: source, fileID: f.id)]); defer { move.cleanup() }
        let files = try move.install(into: f.root)
        XCTAssertTrue(files[0].isNoOp)
        let finished = try f.finish(move)
        XCTAssertTrue(finished.completed); XCTAssertEqual(finished.movedCount, 0)
        XCTAssertEqual(try Data(contentsOf: source), f.data)
    }

    func testDuplicateSourcesKeepTheirFirstOrderAndNoExtraTransferCopies() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let second = f.outside.appendingPathComponent("second.bin"); try Data([2]).write(to: second); let secondID = UUID()
        let move = try f.prepare([.init(url: f.source, fileID: f.id), .init(url: second, fileID: secondID), .init(url: f.source, fileID: UUID())]); defer { move.cleanup() }
        let files = try move.install(into: f.page)
        XCTAssertEqual(files.map(\.fileID), [f.id, secondID])
        XCTAssertEqual(try Data(contentsOf: f.source), f.data)
    }

    func testSourceIdentityReplacementWithIdenticalBytesStillRetainsIt() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let move = try f.prepare(); defer { move.cleanup() }
        _ = try move.install(into: f.page); try move.markCommitted()
        let new = f.outside.appendingPathComponent("replacement"); try f.data.write(to: new)
        try FileManager.default.removeItem(at: f.source); try FileManager.default.moveItem(at: new, to: f.source)
        let result = try move.finishSources()
        XCTAssertFalse(result.completed)
        XCTAssertEqual(try Data(contentsOf: f.source), f.data)
    }

    func testPendingLookupDoesNotEnumerateTheLibrary() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let move = try f.prepare(); defer { move.cleanup() }; _ = try move.install(into: f.page)
        let inaccessible = f.root.appendingPathComponent("unrelated"); try FileManager.default.createDirectory(at: inaccessible, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: inaccessible.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inaccessible.path) }
        XCTAssertEqual(try ClipboardMove.pendingReceiptIDs(libraryRoot: f.root, deviceID: f.device, receiptDirectory: f.receipts), [move.id])
    }

    func testSourceHashDetectsEditsEvenWhenLengthAndModificationTimeAreRestored() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let move = try f.prepare(); defer { move.cleanup() }
        _ = try move.install(into: f.page); try move.markCommitted()
        let date = try FileManager.default.attributesOfItem(atPath: f.source.path)[.modificationDate] as! Date
        let handle = try FileHandle(forWritingTo: f.source)
        try handle.write(contentsOf: Data([99])); try handle.close()
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: f.source.path)
        let result = try move.finishSources()
        XCTAssertFalse(result.completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
        XCTAssertEqual(try Data(contentsOf: f.source).first, 99)
    }

    func testDestinationHashDetectsEditsEvenWhenLengthAndModificationTimeAreRestored() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let move = try f.prepare(); defer { move.cleanup() }
        let file = try move.install(into: f.page)[0]; try move.markCommitted()
        let date = try FileManager.default.attributesOfItem(atPath: file.destinationURL.path)[.modificationDate] as! Date
        let handle = try FileHandle(forWritingTo: file.destinationURL)
        try handle.write(contentsOf: Data([99])); try handle.close()
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.destinationURL.path)
        let result = try move.finishSources()
        XCTAssertFalse(result.completed)
        XCTAssertEqual(try Data(contentsOf: f.source), f.data)
    }

    func testHiddenOrdinaryFileIsArchivedWithoutTreatingItAsLibraryMetadata() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let hidden = f.outside.appendingPathComponent(".gitignore"); try Data("build/".utf8).write(to: hidden)
        let move = try f.prepare([.init(url: hidden, fileID: UUID())]); defer { move.cleanup() }
        let file = try move.install(into: f.page)[0]
        XCTAssertEqual(file.destinationURL.lastPathComponent, ".gitignore")
        XCTAssertTrue(file.destinationURL.path.contains("文本与源码"))
        XCTAssertTrue(try f.finish(move).completed)
    }

    func testRemoteHostFileURLIsNotTreatedAsAnUnrelatedLocalPath() throws {
        let f = try Fixture(); defer { f.cleanup() }
        var components = URLComponents(url: f.source, resolvingAgainstBaseURL: false)!; components.host = "untrusted-host.invalid"
        XCTAssertThrowsError(try f.prepare([.init(url: components.url!, fileID: UUID())]))
        XCTAssertEqual(try Data(contentsOf: f.source), f.data)
    }

    func testCrossVolumeTransferAndReverseKeepVerifiedBytes() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let a = try project.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let b = try f.base.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        guard let a, let b, !a.isEqual(b) else { throw XCTSkip("A second mounted volume is not available in this test environment") }
        let root = project.appendingPathComponent(".build/clipboard-move-volume-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let move = try ClipboardMove.prepare([.init(url: f.source, fileID: f.id)], libraryRoot: root, deviceID: f.device, receiptDirectory: f.receipts)
        defer { move.cleanup() }
        let file = try move.install(into: root.appendingPathComponent("page"))[0]
        XCTAssertEqual(try Data(contentsOf: f.source), f.data)
        try move.markCommitted(); XCTAssertTrue(try move.finishSources().completed)
        XCTAssertEqual(try Data(contentsOf: file.destinationURL), f.data)
        let reverse = try ClipboardMove.prepareReverse(receiptID: move.id, libraryRoot: root, deviceID: f.device, receiptDirectory: f.receipts)
        defer { reverse.cleanup() }
        _ = try reverse.installReverse(); try reverse.markCommitted(); XCTAssertTrue(try reverse.finishSources().completed)
        XCTAssertEqual(try Data(contentsOf: f.source), f.data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.destinationURL.path))
    }
}
