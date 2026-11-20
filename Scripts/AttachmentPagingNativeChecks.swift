import Foundation
import SwiftUI
import PDFKit

@MainActor func runAttachmentPagingNativeChecks() throws -> Int {
    var count = 0
    func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiberePagingCheck-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(root: root)
    store.create(); store.cancelRename(); store.snap = false
    let noteID = store.selection!
    let pdfURL = root.appendingPathComponent("paging-fixture.pdf")
    func writePDF(pages: Int) throws {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        var media = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = CGContext(consumer: consumer, mediaBox: &media, nil)!
        for index in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor(calibratedWhite: CGFloat(index + 1) / CGFloat(pages + 1), alpha: 1).cgColor)
            context.fill(CGRect(x: 30, y: 40, width: CGFloat(60 + index), height: 80))
            context.endPDFPage()
        }
        context.closePDF()
        try Repository.writeAtomically(data as Data, to: pdfURL)
    }
    try writePDF(pages: 5)
    var pdf = Block(.pdf, frame: Rect(40, 50, 400, 500))
    pdf.assetName = pdfURL.lastPathComponent; pdf.relativeFilePath = pdfURL.lastPathComponent; pdf.fileID = UUID()
    let originalText = PageTextAnnotation(frame: Rect(20, 30, 180, 80), text: "第一页的文字")
    var firstPage = AttachmentPageAnnotations(); firstPage.texts = [originalText]; firstPage.ink = Data([1, 7, 3])
    var secondPage = AttachmentPageAnnotations(); secondPage.texts = [PageTextAnnotation(frame: Rect(40, 50, 170, 70), text: "第二页独立批注")]
    pdf.pageAnnotations = ["0": firstPage, "1": secondPage]
    var sibling = pdf; sibling.id = UUID(); sibling.frame.x = 470; sibling.pageAnnotations = ["0": secondPage]
    store.edit { $0.blocks = [pdf, sibling]; $0.anchors = []; $0.ink = Data([8, 9]); $0.fitCanvas(width: 1000, height: 1200) }
    check(store.flush(), "PDF paging fixture is saved before navigation")
    store.refreshReferencedFiles()
    func current(_ id: UUID? = nil) -> Block {
        store.workspace.notes.first { $0.id == noteID }!.blocks.first { $0.id == (id ?? pdf.id) }!
    }
    func note() -> Note { store.workspace.notes.first { $0.id == noteID }! }

    let empty = AttachmentPagination(page: 20, pageCount: 0)
    check(empty.page == 0 && empty.pageCount == 0 && !empty.hasPrevious && !empty.hasNext,
          "Unavailable documents expose no invalid negative page or enabled navigation")
    check(empty.moved(by: 1) == nil && empty.moved(by: -1) == nil, "Empty PDFs cannot navigate")
    let first = AttachmentPagination(page: -100, pageCount: 5)
    check(first.page == 0 && !first.hasPrevious && first.hasNext && first.moved(by: -1) == nil,
          "Negative saved page clamps to the first page")
    let last = AttachmentPagination(page: Int.max, pageCount: 5)
    check(last.page == 4 && last.hasPrevious && !last.hasNext && last.moved(by: 1) == nil,
          "Stale saved page clamps to the last available page")
    check(first.moved(by: Int.max) == 4 && last.moved(by: Int.min) == 0,
          "Extreme navigation deltas cannot overflow page arithmetic")
    check(store.pdfPageCount(for: pdf) == 5, "Page count is read from the actual PDF")
    check(store.turnPDFPage(noteID: noteID, blockID: pdf.id, by: 1) && current().pdfPage == 1,
          "A next-page action updates the requested PDF")
    check(current().annotations(on: 0) == firstPage && current().annotations(on: 1) == secondPage
          && current(sibling.id) == sibling && note().ink == Data([8, 9]),
          "Navigation retains each page's annotations, other references, and outside handwriting")
    for _ in 0..<12 { _ = store.turnPDFPage(noteID: noteID, blockID: pdf.id, by: 1) }
    check(current().pdfPage == 4, "Rapid repeated next-page actions stop at the real last page")
    let endRevision = note().revision
    check(!store.turnPDFPage(noteID: noteID, blockID: pdf.id, by: 1) && note().revision == endRevision,
          "A last-page click is a no-op without dirtying the note")
    for _ in 0..<12 { _ = store.turnPDFPage(noteID: noteID, blockID: pdf.id, by: -1) }
    check(current().pdfPage == 0, "Rapid previous-page actions stop at zero")
    let startRevision = note().revision
    check(!store.turnPDFPage(noteID: noteID, blockID: pdf.id, by: -1) && note().revision == startRevision,
          "A first-page click does not create a phantom modification")

    store.create(); store.cancelRename()
    let otherNoteID = store.selection!, otherRevision = store.note!.revision
    check(store.turnPDFPage(noteID: noteID, blockID: pdf.id, by: 1) && current().pdfPage == 1
          && store.selection == otherNoteID && store.note!.revision == otherRevision,
          "A reader can turn its own PDF while another note is selected")
    store.select(noteID)
    store.editBlock(pdf.id) { $0.locked = true }
    let locked = current()
    check(!store.turnPDFPage(noteID: noteID, blockID: pdf.id, by: 1) && current() == locked,
          "A locked PDF keeps its canvas preview page and frame fixed")
    let reader = AttachmentPagination(page: locked.pdfPage, pageCount: store.pdfPageCount(for: locked))
    check(reader.moved(by: 1) == 2 && current() == locked,
          "Reading another page locally does not mutate the locked canvas preview")
    let lockedDestination = InkDestination(noteID: noteID, blockID: pdf.id, page: 3)
    store.editPage(lockedDestination) { $0.texts.append(PageTextAnnotation(frame: Rect(30, 40, 200, 80), text: "锁定附件仍可批注")) }
    check(current().annotations(on: 3).texts.count == 1 && current().frame == locked.frame && current().pdfPage == locked.pdfPage,
          "Locked attachments still accept annotations without moving the preview")
    store.editBlock(pdf.id) { $0.locked = false; $0.pdfPage = 0 }

    // Exercise NSTextView's real marked-text state and the actual page annotation save closure.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400)); window.contentView = scroll
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 150)); scroll.documentView = text
    let destination = InkDestination(noteID: noteID, blockID: pdf.id, page: 0)
    var textBlock = Block(.text, frame: originalText.frame, text: originalText.text); textBlock.id = originalText.id
    let editor = RichTextEditor(block: textBlock, formatting: store.formatting,
        focus: { store.blockSelection = pdf.id; store.blockKeyboardFocus = false }, checkpoint: { store.checkpoint(destination) }) { _, value in
        store.editPage(destination) { page in
            if let index = page.texts.firstIndex(where: { $0.id == originalText.id }) { page.texts[index].text = value }
        }
    }
    let coordinator = editor.makeCoordinator(); text.delegate = coordinator; text.string = originalText.text
    window.makeFirstResponder(text); coordinator.activate(text)
    text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
    text.setMarkedText("正在输入中文", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    check(text.hasMarkedText(), "Page annotation IME fixture contains an uncommitted candidate")
    check(store.turnPDFPage(noteID: noteID, blockID: pdf.id, by: 1), "Page turn succeeds after committing the active annotation")
    check(!text.hasMarkedText() && window.firstResponder !== text && current().annotations(on: 0).texts[0].text.contains("正在输入中文"),
          "Navigation commits Chinese composition into the original page before releasing the editor")
    check(current().annotations(on: 1) == secondPage, "A late editor commit cannot land on the newly displayed page")
    let persisted = try store.repository.load()!
    check(persisted.notes.first { $0.id == noteID }!.blocks.first { $0.id == pdf.id }!.annotations(on: 0).texts[0].text.contains("正在输入中文"),
          "The committed IME text is on disk before the page turn returns")
    text.delegate = nil

    // Notebook cells and non-Markdown source files own private formatting state.
    // Destroying their native editor must commit IME without relying on AppStore's
    // formatting pointer or an ordered/key test window.
    var privateSaved: Data?
    let privateSession = try TextFileSession(data: Data("source: ".utf8)) { privateSaved = $0 }
    let privateFormatting = TextFormatting()
    let privateBlock = Block(.text, frame: Rect(0, 0, 400, 150), text: privateSession.document.text)
    let privateEditor = RichTextEditor(block: privateBlock, formatting: privateFormatting, focus: {}, checkpoint: {}) { _, value in
        privateSession.edit(value)
    }
    let privateCoordinator = privateEditor.makeCoordinator()
    let privateScroll = NSScrollView(frame: scroll.frame)
    let privateText = NSTextView(frame: text.frame); privateScroll.documentView = privateText; window.contentView = privateScroll
    privateText.delegate = privateCoordinator; privateText.string = privateBlock.text
    window.makeFirstResponder(privateText); privateCoordinator.activate(privateText)
    privateText.setSelectedRange(NSRange(location: privateText.string.utf16.count, length: 0))
    privateText.setMarkedText("尚未确认的输入", selectedRange: NSRange(location: 7, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    check(privateText.hasMarkedText() && store.formatting.view == nil && privateFormatting.view === privateText,
          "Private source editor has marked text independently of AppStore formatting")
    RichTextEditor.dismantleNSView(privateScroll, coordinator: privateCoordinator)
    check(!privateText.hasMarkedText() && privateSession.document.text == "source: 尚未确认的输入",
          "Dismantling a private source editor commits its composition before destroying the view")
    check(privateSession.save() && privateSaved == Data("source: 尚未确认的输入".utf8),
          "The private editor's complete final text is available to its file save session")
    RichTextEditor.dismantleNSView(privateScroll, coordinator: privateCoordinator)
    check(privateSession.document.text == "source: 尚未确认的输入", "Repeated teardown cannot duplicate committed text")
    privateText.delegate = nil; window.contentView = nil

    // The PDF is a live library reference: reducing and increasing its page count must
    // invalidate cached navigation limits without deleting annotations on other pages.
    let oldRevision = current().contentRevision, annotationsBeforeReplacement = current().pageAnnotations
    try writePDF(pages: 2); store.refreshReferencedFiles()
    check(current().contentRevision != oldRevision && store.pdfPageCount(for: current()) == 2,
          "Replacing a referenced PDF invalidates its revision and page count")
    let shortened = AttachmentPagination(page: 4, pageCount: store.pdfPageCount(for: current()))
    check(shortened.page == 1 && !shortened.hasNext, "A reader on a removed page recovers to the new last page")
    check(current().pageAnnotations == annotationsBeforeReplacement,
          "Source replacement never silently drops stored annotations for temporarily absent pages")
    try writePDF(pages: 7); store.refreshReferencedFiles()
    let enlarged = AttachmentPagination(page: shortened.page, pageCount: store.pdfPageCount(for: current()))
    check(enlarged.pageCount == 7 && enlarged.hasNext && enlarged.moved(by: 1) == 2,
          "Adding pages to a referenced PDF makes the new pages reachable")

    // Make the existing on-disk workspace unreadable to force Repository.save to fail
    // deterministically, independently of filesystem permissions or administrator status.
    check(store.flush(), "Fixture is durable before simulating a write failure")
    let savedWorkspace = try Data(contentsOf: store.repository.workspaceURL)
    try Data("invalid workspace fixture".utf8).write(to: store.repository.workspaceURL)
    let beforeFailure = current(), failureRevision = note().revision
    check(!store.turnPDFPage(noteID: noteID, blockID: pdf.id, by: 1) && current() == beforeFailure && note().revision == failureRevision,
          "A failed pre-navigation save keeps the current PDF page and note revision unchanged")
    check(store.saveStatus == "保存失败", "Navigation preserves the visible save failure status")
    try savedWorkspace.write(to: store.repository.workspaceURL)
    check(store.flush(), "Saving resumes after the simulated storage failure is removed")
    check(!store.turnPDFPage(noteID: UUID(), blockID: pdf.id, by: 1)
          && !store.turnPDFPage(noteID: noteID, blockID: UUID(), by: 1), "Stale note and block IDs cannot affect another attachment")
    var missing = pdf; missing.relativeFilePath = "missing.pdf"
    check(store.pdfPageCount(for: missing) == 0, "A missing PDF has no fabricated page count")
    let reopened = try AppStore(root: root)
    let restored = reopened.workspace.notes.first { $0.id == noteID }!.blocks.first { $0.id == pdf.id }!
    check(restored == current(), "Page selection and every page annotation survive reopening")
    print("PASS: \(count) attachment pagination, PDF replacement, IME, isolation and persistence assertions")
    return count
}
