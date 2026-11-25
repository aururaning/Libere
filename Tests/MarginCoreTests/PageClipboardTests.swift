import XCTest
@testable import MarginCore

final class PageClipboardTests: XCTestCase {
    func fixture() -> Workspace {
        var folder = Note(title: "项目", folder: true); folder.managedDirectoryPath = "项目"
        var page = Note(title: "资料", parent: folder.id)
        page.managedFilePath = "项目/original.pdf"; page.ink = Data([1, 2, 3])
        var pdf = Block(.pdf, frame: Rect(100, 120, 300, 400))
        pdf.fileID = UUID(); pdf.relativeFilePath = page.managedFilePath; pdf.assetName = "original.pdf"; pdf.locked = true
        let anchor = AnnotationAnchor(ownerID: pdf.id, label: "说明", u: 1, v: 0)
        var text = Block(.text, frame: Rect(450, 120, 220, 100), text: "解释"); text.anchorID = anchor.id
        page.blocks = [pdf, text]; page.anchors = [anchor]
        var nested = Note(title: "子目录", parent: folder.id, folder: true)
        var child = Note(title: "推导", parent: nested.id); child.blocks = [Block(.formula, frame: Rect(10, 20, 300, 100), text: "x^2")]
        folder.folderOverview = PageLink.markdown(title: page.title, id: page.id)
        nested.folderOverview = PageLink.markdown(title: child.title, id: child.id)
        return Workspace(notes: [folder, page, nested, child, Note(title: "目的地", folder: true)])
    }
    func testCopiesWholeSubtreeWithSharedOriginalsAndIndependentRecords() throws {
        let workspace = fixture(), before = workspace, target = workspace.notes[4].id
        let payload = try PageClipboard(library: "/library", rootID: workspace.notes[0].id, workspace: workspace)
        let copies = try payload.copies(into: target, in: workspace)
        XCTAssertEqual(copies.count, 4); XCTAssertEqual(workspace, before)
        XCTAssertTrue(Set(copies.map(\.id)).isDisjoint(with: workspace.notes.map(\.id)))
        let root = copies.first!, page = copies.first { $0.title == "资料" }!
        XCTAssertEqual(root.parentID, target); XCTAssertEqual(page.parentID, root.id)
        XCTAssertEqual(page.ink, workspace.notes[1].ink)
        XCTAssertEqual(page.blocks[0].frame, workspace.notes[1].blocks[0].frame)
        XCTAssertTrue(page.blocks[0].locked)
        XCTAssertEqual(page.blocks[0].fileIdentity, workspace.notes[1].blocks[0].fileIdentity)
        XCTAssertEqual(page.blocks[0].relativeFilePath, "项目/original.pdf")
        XCTAssertEqual(page.blocks[0].reference, FileReference(noteID: workspace.notes[1].id, blockID: workspace.notes[1].blocks[0].id))
        XCTAssertTrue(copies.allSatisfy { $0.managedDirectoryPath == nil && $0.managedFilePath == nil })
        XCTAssertEqual(root.sourceNoteID, workspace.notes[0].id)
    }
    func testRewritesSubtreeLinksAndAnchorIdentities() throws {
        let workspace = fixture()
        let copies = try PageClipboard(library: "/library", rootID: workspace.notes[0].id, workspace: workspace).copies(into: nil, in: workspace)
        let page = copies.first { $0.title == "资料" }!, nested = copies.first { $0.title == "子目录" }!, child = copies.first { $0.title == "推导" }!
        XCTAssertTrue(copies[0].folderOverview!.contains(PageLink.url(for: page.id).absoluteString))
        XCTAssertTrue(nested.folderOverview!.contains(PageLink.url(for: child.id).absoluteString))
        XCTAssertEqual(child.parentID, nested.id)
        XCTAssertNotEqual(page.anchors[0].id, workspace.notes[1].anchors[0].id)
        XCTAssertEqual(page.anchors[0].ownerID, page.blocks[0].id)
        XCTAssertEqual(page.blocks[1].anchorID, page.anchors[0].id)
    }
    func testUsesCurrentIndexedPathAfterOriginalMoves() throws {
        var workspace = fixture()
        let payload = try PageClipboard(library: "/library", rootID: workspace.notes[0].id, workspace: workspace)
        workspace.notes[1].blocks[0].relativeFilePath = "moved/latest.pdf"
        workspace.notes[1].blocks[0].assetName = "latest.pdf"
        let copies = try payload.copies(into: workspace.notes[4].id, in: workspace)
        let file = copies.first { $0.title == "资料" }!.blocks[0]
        XCTAssertEqual(file.relativeFilePath, "moved/latest.pdf"); XCTAssertEqual(file.assetName, "latest.pdf")
    }
    func testNamesCopiesWithoutReplacingSiblingsAndKeepsOriginalSource() throws {
        var workspace = fixture()
        let payload = try PageClipboard(library: "/library", rootID: workspace.notes[0].id, workspace: workspace)
        let first = try payload.copies(into: nil, in: workspace)
        XCTAssertEqual(first[0].title, "项目 副本")
        workspace.notes += first
        let second = try payload.copies(into: nil, in: workspace)
        XCTAssertEqual(second[0].title, "项目 副本 2")
        let recopy = try PageClipboard(library: "/library", rootID: first[0].id, workspace: workspace)
            .copies(into: workspace.notes[4].id, in: workspace)
        XCTAssertEqual(recopy[0].sourceNoteID, workspace.notes[0].id)
        XCTAssertEqual(recopy.first { $0.title == "资料" }!.blocks[0].reference?.noteID, workspace.notes[1].id)
    }
    func testOnlyLiveDescendantsAreCaptured() throws {
        var workspace = fixture(); workspace.notes[3].deleted = true
        let payload = try PageClipboard(library: "/library", rootID: workspace.notes[0].id, workspace: workspace)
        XCTAssertEqual(payload.pages.count, 3)
        XCTAssertEqual(workspace.notes[0].deleted, false)
        XCTAssertThrowsError(try PageClipboard(library: "/library", rootID: workspace.notes[3].id, workspace: workspace))
    }
    func testRejectsSelfDescendantAndMissingDestinations() throws {
        let workspace = fixture(), root = workspace.notes[0].id
        let payload = try PageClipboard(library: "/library", rootID: root, workspace: workspace)
        for parent in [root, workspace.notes[1].id, workspace.notes[3].id, UUID()] {
            XCTAssertThrowsError(try payload.copies(into: parent, in: workspace))
        }
    }
    func testRejectsDisconnectedOrDuplicateClipboardRecords() throws {
        let workspace = fixture()
        let payload = try PageClipboard(library: "/library", rootID: workspace.notes[0].id, workspace: workspace)
        let bytes = try JSONEncoder().encode(payload)
        for invalid in ["duplicate", "cycle", "version"] {
            var data = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            var pages = data["pages"] as! [[String: Any]]
            if invalid == "duplicate" { pages.append(pages[0]) }
            if invalid == "cycle" { pages[1]["parentID"] = pages[1]["id"] }
            if invalid == "version" { data["format"] = 99 }
            data["pages"] = pages
            let decoded = try JSONDecoder().decode(PageClipboard.self, from: JSONSerialization.data(withJSONObject: data))
            XCTAssertThrowsError(try decoded.copies(into: nil, in: workspace))
        }
    }
    func testClipboardAndLegacyPageCodableCompatibility() throws {
        let workspace = fixture()
        let payload = try PageClipboard(library: "/library", rootID: workspace.notes[0].id, workspace: workspace)
        let decoded = try JSONDecoder().decode(PageClipboard.self, from: JSONEncoder().encode(payload))
        XCTAssertEqual(decoded.pages, payload.pages); XCTAssertEqual(decoded.rootID, payload.rootID)
        let note = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(workspace.notes[0]))
        XCTAssertNil(note.sourceNoteID)
    }
}
