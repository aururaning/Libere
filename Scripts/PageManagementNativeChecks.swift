import Foundation
import SwiftUI

@MainActor func runPageManagementNativeChecks() async throws -> Int {
    var count = 0
    func check(_ value: Bool, _ label: String) {
        if !value { FileHandle.standardError.write(Data(("FAILED PageManagement: " + label + "\n").utf8)) }
        precondition(value, label); count += 1
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiberePageManagement-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(root: root)
    store.create(folder: true); let folderID = store.selection!; store.cancelRename()
    check(store.renamePage(folderID, to: "原目录"), "Reusable title commit creates the physical folder name")
    let originalDirectory = store.directories.directory(for: folderID, in: store.workspace)
    let file = originalDirectory.appendingPathComponent("source.md"), bytes = Data("原文件内容".utf8)
    try bytes.write(to: file)
    store.create(); store.cancelRename(); let aliasPageID = store.selection!
    store.importFile(file); let fileID = store.block!.id
    let priorPath = store.block!.relativeFilePath
    let textSession = try store.textFileSession(noteID: aliasPageID, blockID: fileID)
    store.select(folderID)
    let control = PageTitleField(noteID: folderID, title: "原目录", commit: { store.renamePage($0, to: $1) })
    let coordinator = control.makeCoordinator()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let field = NSTextField(frame: NSRect(x: 20, y: 60, width: 400, height: 32)); field.stringValue = "原目录"; field.delegate = coordinator
    window.contentView?.addSubview(field); window.makeFirstResponder(field)
    coordinator.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
    guard let editor = field.currentEditor() as? NSTextView else { preconditionFailure("No native title field editor") }
    editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
    editor.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: editor.selectedRange())
    let composing = store.workspace
    coordinator.submit(field)
    check(store.workspace == composing && FileManager.default.fileExists(atPath: originalDirectory.path), "IME candidates do not rename or persist a title")
    editor.unmarkText(); field.stringValue = "中文目录"
    coordinator.submit(field)
    check(store.workspace.notes.first { $0.id == folderID }?.title == "中文目录", "Title submission commits the final composed name")
    let movedFile = store.attachmentURL(for: store.workspace.notes.first { $0.id == aliasPageID }!.blocks.first { $0.id == fileID }!)!
    check(movedFile.path != file.path && (try? Data(contentsOf: movedFile)) == bytes && !FileManager.default.fileExists(atPath: originalDirectory.path), "Title editing moves the original folder and updates cross-page references")
    textSession.edit("移动后继续编辑"); check(textSession.save(), "An already-open editor follows title-driven file relocation")
    store.undo()
    check(store.workspace.notes.first { $0.id == folderID }?.title == "原目录" && store.workspace.notes.first { $0.id == aliasPageID }!.blocks.first { $0.id == fileID }!.relativeFilePath == priorPath,
          "One undo restores title, physical folder and all references")
    check((try? String(contentsOf: file, encoding: .utf8)) == "移动后继续编辑", "Rename undo keeps the latest original-file contents")
    store.select(aliasPageID)
    check(store.renamePage(folderID, to: "迟到标题") && store.selection == aliasPageID,
          "A late old-title commit targets its captured page without stealing the new selection")
    let beforeInvalid = store.workspace
    check(!store.renamePage(folderID, to: " \n ") && store.workspace == beforeInvalid, "Whitespace-only titles are rejected without a transaction")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("冲突目录"), withIntermediateDirectories: true)
    check(!store.renamePage(folderID, to: "冲突目录") && store.workspace == beforeInvalid, "Title destination collisions preserve the original file and note")
    store.showTrash = true; store.select(aliasPageID)
    check(!store.showTrash && store.selection == aliasPageID, "Explicit same-row selection leaves Trash without changing page identity")
    window.contentView = nil

    store.create(); store.cancelRename()
    let text = Block(.text, frame: Rect(20,20,300,200), text: "原文字")
    store.edit { $0.blocks = [text] }; store.selectBlock(text.id)
    store.checkpoint(); store.editBlock(text.id) { $0.text = "保留之前的撤销" }
    let begin = Date()
    for i in 0..<100 { store.applyFontPanel(family: "Menlo", size: 24 + Double(i) / 10, now: begin.addingTimeInterval(Double(i) / 1000)) }
    let styled = store.block!
    store.applyFontPanel(family: "Menlo", size: styled.fontSize, now: begin.addingTimeInterval(1))
    store.undo(); let afterFontUndo = store.note!.blocks.first { $0.id == text.id }!
    check(afterFontUndo.fontSize == text.fontSize && afterFontUndo.fontFamily == text.fontFamily && afterFontUndo.text == "保留之前的撤销",
          "A hundred continuous font changes plus a no-op consume only one undo step")
    store.undo(); check(store.note!.blocks.first { $0.id == text.id }!.text == "原文字", "Font gestures do not push earlier editing out of the bounded undo stack")
    store.selectBlock(text.id); store.applyFontPanel(family: "Menlo", size: 24, now: begin)
    store.checkpoint(); store.editBlock(text.id) { $0.quote = true }
    store.applyFontPanel(family: "Menlo", size: 25, now: begin.addingTimeInterval(0.1)); store.undo()
    check(store.note!.blocks.first { $0.id == text.id }!.quote && store.note!.blocks.first { $0.id == text.id }!.fontSize == 24,
          "An intervening edit ends font coalescing even inside the idle interval")
    store.selectBlock(text.id); store.editBlock(text.id) { $0.locked = true }
    let locked = store.workspace; store.deleteSelectedBlock()
    check(store.workspace == locked && store.blockSelection == text.id, "Delete cannot remove a locked block or create a deletion checkpoint")
    store.editBlock(text.id) { $0.locked = false }; store.deleteSelectedBlock()
    check(!store.note!.blocks.contains { $0.id == text.id }, "Unlocking permits ordinary block deletion")
    store.undo(); check(store.note!.blocks.contains { $0.id == text.id }, "Unlocked deletion remains undoable")

    store.create(); store.cancelRename()
    var rich = Block(.text, frame: Rect(20,20,300,200), text: "富文本内容"); rich.textFormat = nil
    let attributed = NSAttributedString(string: rich.text, attributes: [.font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.systemRed])
    rich.rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    store.edit { $0.blocks = [rich] }; store.selectBlock(rich.id)
    check(store.formatting.view == nil && FontPanel.shared.selectedFont(in: store).pointSize == 36,
          "The font panel reads the rendered RTF font even when block metadata is stale and no editor exists")
    let systemName = NSFont.systemFont(ofSize: 22).fontName
    store.applyFontPanel(family: systemName, size: 22, now: begin)
    let resetRich = try NSAttributedString(data: store.block!.rtf!, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
    check((resetRich.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 22 && resetRich.string == rich.text,
          "A non-editing RTF block can reset its actual font to the nominal metadata size")
    store.applyFontPanel(family: systemName, size: 22, now: begin.addingTimeInterval(1))
    store.undo()
    check(store.note!.blocks.first { $0.id == rich.id }?.rtf == rich.rtf,
          "An actual RTF no-op adds no undo record and the prior full RTF formatting restores in one step")
    store.selectBlock(rich.id)
    store.applyFontPanel(family: "Menlo", size: 25, now: begin.addingTimeInterval(2))
    store.applyFontPanel(family: "Menlo", size: 26, now: begin.addingTimeInterval(2.1))
    store.undo()
    check(store.note!.blocks.first { $0.id == rich.id }?.rtf == rich.rtf,
          "A continuous RTF font gesture coalesces as one operation without an active text editor")

    store.create(); store.cancelRename()
    let growing = Block(.text, frame: Rect(20,20,300,100), text: "字体调整后的长文本")
    store.edit { $0.blocks = [growing] }; store.selectBlock(growing.id)
    store.applyFontPanel(family: "Menlo", size: 30, now: begin)
    store.growTextBlock(store.block!, contentHeight: 420)
    check(store.block!.frame.height > growing.frame.height, "The font regression actually triggers asynchronous-style text height growth")
    store.applyFontPanel(family: "Menlo", size: 31, now: begin.addingTimeInterval(0.1))
    store.undo()
    let growthUndo = store.note!.blocks.first { $0.id == growing.id }!
    check(growthUndo.fontSize == growing.fontSize && growthUndo.frame.height == growing.frame.height,
          "Font change, automatic height growth and another font change undo together")
    store.selectBlock(growing.id)
    store.applyFontPanel(family: "Menlo", size: 30, now: begin.addingTimeInterval(2))
    store.editBlock(growing.id) { $0.quote = true }
    store.growTextBlock(store.block!, contentHeight: 420)
    store.applyFontPanel(family: "Menlo", size: 31, now: begin.addingTimeInterval(2.1)); store.undo()
    let independentUndo = store.note!.blocks.first { $0.id == growing.id }!
    check(independentUndo.quote && independentUndo.fontSize == 30 && independentUndo.frame.height > growing.frame.height,
          "Height continuation cannot merge across an independent intervening note revision")

    let purgeRoot = root.appendingPathComponent("purge")
    let purge = try AppStore(root: purgeRoot)
    let source = purgeRoot.appendingPathComponent("keep.md"); try Data("原文件必须保留".utf8).write(to: source)
    purge.create(); purge.cancelRename(); let pageID = purge.selection!
    purge.edit { $0.title = "待永久清除" }; purge.importFile(source)
    purge.edit { $0.blocks.append(Block(.text, frame: Rect(420,20,300,200), text: "purged-secret-body")) }
    let oldPage = purge.note!
    purge.workspace.agentReceipts = [AgentReceipt(requestID: "purged-request", fingerprint: "sha", tool: "create_page", result: Data("{\"page\":{\"id\":\"\(pageID)\",\"title\":\"purged-secret-body\"}}".utf8))]
    let oldBackup = try purge.backup(); let backupURL = root.appendingPathComponent("old.marginbackup"); try oldBackup.data.write(to: backupURL)
    check(purge.trash(pageID), "The purge fixture first enters the recoverable Trash")
    let deleted = purge.workspace.notes.first { $0.id == pageID }!
    check(deleted.deletedAt != nil && deleted.originalParentPath != nil, "Trash records deletion date and original location")
    struct OldHistory: Encodable { var undo: [Note]; var redo: [Note] }
    try JSONEncoder().encode(OldHistory(undo: [oldPage], redo: [])).write(to: purgeRoot.appendingPathComponent("History-other-device.json"))
    purge.requestPurge(pageID); purge.purgeRequest = nil
    check(purge.workspace.notes.contains { $0.id == pageID }, "Canceling permanent deletion leaves the recoverable record intact")
    purge.requestPurge(pageID); check(purge.confirmPurge(), "Confirmed permanent deletion removes only page records")
    check(!purge.workspace.notes.contains { $0.id == pageID } && purge.workspace.purgedPageIDs.contains(pageID), "A durable tombstone blocks the purged page identity")
    purge.undo(); purge.redo()
    check(!purge.workspace.notes.contains { $0.id == pageID }, "Undo and redo cannot resurrect purged content")
    check(try String(contentsOf: source, encoding: .utf8) == "原文件必须保留", "Purging a page never deletes or rewrites its original file")
    check(purge.workspace.agentReceipts?.first?.resultPurged == true && purge.workspace.agentReceipts!.first!.result.isEmpty,
          "Purge clears cached Agent content while retaining the retry identity")
    for url in try FileManager.default.contentsOfDirectory(at: purgeRoot, includingPropertiesForKeys: nil)
        where url.lastPathComponent.hasPrefix("History-") || url.lastPathComponent == "workspace.previous.json" {
        check(!(try String(contentsOf: url, encoding: .utf8)).contains("purged-secret-body"), "Old recovery and undo snapshots no longer retain purged page text")
    }
    try purge.importBackup(backupURL)
    check(!purge.workspace.notes.contains { $0.id == pageID }, "Importing an older index cannot restore a permanently purged page")
    let reopened = try AppStore(root: purgeRoot); reopened.undo()
    check(!reopened.workspace.notes.contains { $0.id == pageID } && reopened.workspace.schemaVersion == 3,
          "Purge protection and format version survive restarting the application")
    print("PASS: \(count) title transactions, Trash safety, locked deletion and font history assertions")
    return count
}
