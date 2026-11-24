import XCTest
@testable import MarginCore

final class ClipboardArchiveTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private var outside: URL!
    private var page: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardArchiveTests-" + UUID().uuidString, isDirectory: true)
        root = base.appendingPathComponent("Library", isDirectory: true)
        outside = base.appendingPathComponent("Outside", isDirectory: true)
        page = root.appendingPathComponent("Current page", isDirectory: true)
        for directory in [root!, outside!, page!] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: base) }

    private func file(_ name: String, in directory: URL? = nil, bytes: Data = Data("original".utf8)) throws -> URL {
        let url = (directory ?? outside).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }
    private var scratch: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix(".libere-paste-") }
    }

    func testOutsideFileIsCopiedOnceThenInstalledWithoutChangingOriginal() throws {
        let bytes = Data((0..<65_536).map { UInt8($0 % 251) })
        let source = try file("a document.pdf", bytes: bytes)
        let originalDate = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let prepared = try ClipboardArchive.prepare([.file(source)], libraryRoot: root)
        defer { prepared.cleanup() }
        XCTAssertEqual(prepared.entries.count, 1)
        XCTAssertFalse(prepared.entries[0].isReference)
        XCTAssertEqual(scratch.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: page.appendingPathComponent("PDF").path))
        let installed = try prepared.install(into: page)
        XCTAssertEqual(installed, [page.appendingPathComponent("PDF/a document.pdf")])
        XCTAssertEqual(try Data(contentsOf: installed[0]), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, originalDate)
        prepared.cleanup()
        XCTAssertTrue(scratch.isEmpty)
        XCTAssertEqual(try Data(contentsOf: installed[0]), bytes)
    }

    func testLibraryReferenceDoesNotCopyOrRequireReadableContents() throws {
        let source = try file("reference.unknown", in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path) }
        let prepared = try ClipboardArchive.prepare([.file(source)], libraryRoot: root)
        defer { prepared.cleanup() }
        XCTAssertTrue(prepared.entries[0].isReference)
        XCTAssertEqual(prepared.entries[0].sourceURL, source.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertTrue(scratch.isEmpty)
        let destination = page.appendingPathComponent("Not created")
        XCTAssertEqual(try prepared.install(into: destination), [source])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDuplicateSourceURLsAreRemovedAndInputOrderIsPreserved() throws {
        let a = try file("a.py"), b = try file("b.docx")
        let prepared = try ClipboardArchive.prepare([.file(a), .file(b), .file(a)], libraryRoot: root)
        defer { prepared.cleanup() }
        XCTAssertEqual(prepared.entries.map(\.filename), ["a.py", "b.docx"])
        XCTAssertEqual(try prepared.install(into: page).map { $0.lastPathComponent }, ["a.py", "b.docx"])
    }

    func testRawClipboardDataAndFilenameTraversalAreArchivedUnderPage() throws {
        let bytes = Data([0, 1, 2, 3, 255])
        let prepared = try ClipboardArchive.prepare([.data(bytes, suggestedFilename: "../../截图.png")], libraryRoot: root)
        defer { prepared.cleanup() }
        XCTAssertNil(prepared.entries[0].sourceURL)
        let installed = try prepared.install(into: page)
        XCTAssertEqual(installed[0], page.appendingPathComponent("图片/截图.png"))
        XCTAssertEqual(try Data(contentsOf: installed[0]), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("截图.png").path))
    }

    func testFilenameConflictsPreserveEveryExistingAndNewFile() throws {
        let original = try file("same.pdf", in: page.appendingPathComponent("PDF"), bytes: Data("existing".utf8))
        let a = try file("same.pdf", in: outside.appendingPathComponent("A"), bytes: Data("first".utf8))
        let b = try file("same.pdf", in: outside.appendingPathComponent("B"), bytes: Data("second".utf8))
        let prepared = try ClipboardArchive.prepare([.file(a), .file(b)], libraryRoot: root)
        defer { prepared.cleanup() }
        let installed = try prepared.install(into: page)
        XCTAssertEqual(installed.map(\.lastPathComponent), ["same (2).pdf", "same (3).pdf"])
        XCTAssertEqual(try Data(contentsOf: original), Data("existing".utf8))
        XCTAssertEqual(try Data(contentsOf: installed[0]), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: installed[1]), Data("second".utf8))
    }

    func testArbitraryAndExtensionlessFilesHaveUsableCategories() throws {
        let names = ["a.ipynb", "b.md", "c.html", "d.json", "e.docx", "f.mp4", "g.zip", "h.swift", "custom.xyz", "LICENSE"]
        let urls = try names.map { try file($0) }
        let prepared = try ClipboardArchive.prepare(urls.map(ClipboardArchive.Input.file), libraryRoot: root)
        defer { prepared.cleanup() }
        let installed = try prepared.install(into: page)
        XCTAssertEqual(installed.map { $0.deletingLastPathComponent().lastPathComponent }, ["Notebook", "Markdown", "网页", "数据", "文档", "音视频", "压缩包", "文本与源码", "其他", "其他"])
        XCTAssertEqual(installed.map(\.lastPathComponent), names)
    }

    func testDirectoriesAndPackagesAreRejectedAndOwnStagingIsCleaned() throws {
        let folder = outside.appendingPathComponent("a folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ClipboardArchive.prepare([.data(Data([1]), suggestedFilename: "first.png"), .file(folder)], libraryRoot: root))
        XCTAssertTrue(scratch.isEmpty)
        let package = outside.appendingPathComponent("example.app")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ClipboardArchive.prepare([.file(package)], libraryRoot: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
    }

    func testOutsideDestinationAndEscapingCategorySymlinkAreRejected() throws {
        let prepared = try ClipboardArchive.prepare([.data(Data([4]), suggestedFilename: "photo.png")], libraryRoot: root)
        defer { prepared.cleanup() }
        XCTAssertThrowsError(try prepared.install(into: outside))
        let escape = page.appendingPathComponent("图片")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
        XCTAssertThrowsError(try prepared.install(into: page))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("photo.png").path))
    }

    func testReservedDestinationsAndReservedLibrarySourceAreRejected() throws {
        for reserved in ["Assets", "Sync", "Recoveries", ".hidden", "workspace.json", "History-test.json", "Projects/index.json"] {
            let prepared = try ClipboardArchive.prepare([.data(Data([4]), suggestedFilename: "one.txt")], libraryRoot: root)
            XCTAssertThrowsError(try prepared.install(into: root.appendingPathComponent(reserved)), reserved)
            prepared.cleanup()
        }
        let index = try file("workspace.json", in: root)
        XCTAssertThrowsError(try ClipboardArchive.prepare([.file(index)], libraryRoot: root))
        XCTAssertTrue(scratch.isEmpty)
    }

    func testExternalSymlinkCopiesTargetBytesRatherThanEscapingLink() throws {
        let bytes = Data("real content".utf8), target = try file("actual.txt", bytes: Data("real content".utf8))
        let link = outside.appendingPathComponent("copied-name.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let prepared = try ClipboardArchive.prepare([.file(link)], libraryRoot: root)
        defer { prepared.cleanup() }
        let installed = try prepared.install(into: page)[0]
        XCTAssertEqual(installed.lastPathComponent, "copied-name.txt")
        XCTAssertEqual(try Data(contentsOf: installed), bytes)
        XCTAssertNotEqual(try installed.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
        XCTAssertEqual(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
    }

    func testLibrarySymlinkEscapingRootIsCopiedIntoLibrary() throws {
        let source = try file("outside.txt")
        let link = root.appendingPathComponent("outside-link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let prepared = try ClipboardArchive.prepare([.file(link)], libraryRoot: root)
        defer { prepared.cleanup() }
        XCTAssertFalse(prepared.entries[0].isReference)
        let installed = try prepared.install(into: page)[0]
        XCTAssertNotNil(ReferencePath.relative(installed, inside: root))
        XCTAssertEqual(try Data(contentsOf: installed), try Data(contentsOf: source))
    }

    func testReferenceRelocationAndDestinationMoveBetweenPhases() throws {
        let source = try file("reference.txt", in: root)
        let prepared = try ClipboardArchive.prepare([.file(source), .data(Data([8]), suggestedFilename: "new.pdf")], libraryRoot: root)
        defer { prepared.cleanup() }
        let relocated = root.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: source, to: relocated)
        let newPage = root.appendingPathComponent("Moved page")
        try FileManager.default.moveItem(at: page, to: newPage)
        let installed = try prepared.install(into: newPage, referenceReplacements: [prepared.entries[0].sourceURL!: relocated])
        XCTAssertEqual(installed, [relocated, newPage.appendingPathComponent("PDF/new.pdf")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: page.path))
    }

    func testReferenceReplacementCannotEscapeLibrary() throws {
        let source = try file("inside.txt", in: root), other = try file("outside.txt")
        let prepared = try ClipboardArchive.prepare([.file(source)], libraryRoot: root)
        defer { prepared.cleanup() }
        XCTAssertThrowsError(try prepared.install(into: page, referenceReplacements: [prepared.entries[0].sourceURL!: other]))
    }

    func testCapturedLibraryReferenceSurvivesMoveBeforePreparation() throws {
        let old = try file("old-name.txt", in: root), moved = root.appendingPathComponent("new-name.txt")
        let external = try file("outside.pdf")
        try FileManager.default.moveItem(at: old, to: moved)
        let prepared = try ClipboardArchive.prepare([.file(external), .libraryReference(old)], libraryRoot: root)
        defer { prepared.cleanup() }
        XCTAssertTrue(prepared.entries[1].isReference)
        XCTAssertEqual(prepared.entries[1].sourceURL, old)
        let installed = try prepared.install(into: page, referenceReplacements: [old: moved])
        XCTAssertEqual(installed, [page.appendingPathComponent("PDF/outside.pdf"), moved])
        XCTAssertEqual(try Data(contentsOf: moved), Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testMissingCapturedReferenceStillRequiresValidReplacementAtInstall() throws {
        let missing = root.appendingPathComponent("moved-before-prepare.txt")
        let prepared = try ClipboardArchive.prepare([.data(Data([1]), suggestedFilename: "new.pdf"), .libraryReference(missing)], libraryRoot: root)
        defer { prepared.cleanup() }
        XCTAssertThrowsError(try prepared.install(into: page))
        XCTAssertFalse(FileManager.default.fileExists(atPath: page.appendingPathComponent("PDF/new.pdf").path))
        XCTAssertThrowsError(try ClipboardArchive.prepare([.file(missing)], libraryRoot: root), "Ordinary .file must retain its existence requirement")
    }

    func testCapturedReferenceRejectsOutsideAndReservedLocationsWithoutExistence() throws {
        XCTAssertThrowsError(try ClipboardArchive.prepare([.libraryReference(outside.appendingPathComponent("missing.txt"))], libraryRoot: root))
        for path in ["Assets/missing.pdf", "Sync/missing.txt", "workspace.json", "workspace.previous.json", "History-device.json", "Projects/index.json", ".hidden/missing.txt"] {
            XCTAssertThrowsError(try ClipboardArchive.prepare([.libraryReference(root.appendingPathComponent(path))], libraryRoot: root), path)
        }
        XCTAssertTrue(scratch.isEmpty)
    }

    func testPartialInstallFailureKeepsSuccessfulArchiveForRecovery() throws {
        _ = try file("图片", in: page)
        let prepared = try ClipboardArchive.prepare([.data(Data([1]), suggestedFilename: "first.pdf"), .data(Data([2]), suggestedFilename: "second.png")], libraryRoot: root)
        do {
            _ = try prepared.install(into: page)
            XCTFail("Expected destination conflict")
        } catch ClipboardArchive.ArchiveError.installationFailed(_, let retainedFiles) {
            XCTAssertEqual(retainedFiles, [page.appendingPathComponent("PDF/first.pdf")])
        }
        prepared.cleanup()
        XCTAssertEqual(try Data(contentsOf: page.appendingPathComponent("PDF/first.pdf")), Data([1]))
        XCTAssertTrue(scratch.isEmpty)
        XCTAssertEqual(try Data(contentsOf: page.appendingPathComponent("图片")), Data("original".utf8))
    }

    func testLongUnicodeFilenameRetainsExtensionAndSafeLength() throws {
        let prepared = try ClipboardArchive.prepare([.data(Data([1]), suggestedFilename: String(repeating: "资料", count: 80) + ".pdf")], libraryRoot: root)
        defer { prepared.cleanup() }
        let installed = try prepared.install(into: page)[0]
        XCTAssertEqual(installed.pathExtension, "pdf")
        XCTAssertLessThanOrEqual(installed.lastPathComponent.utf8.count, 240)
        XCTAssertEqual(installed.deletingLastPathComponent().lastPathComponent, "PDF")
    }
}
