import Foundation
import SwiftUI

@MainActor func runFolderOverviewNativeChecks() throws -> Int {
    var count = 0
    func check(_ value: Bool, _ name: String) { precondition(value, name); count += 1 }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereFolderCheck-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(root: root)
    store.create(folder: true); store.cancelRename(); let first = store.selection!
    store.create(folder: true); store.cancelRename(); let second = store.selection!
    store.create(parent: first); store.cancelRename(); let child = store.selection!
    func folder(_ id: UUID) -> Note { store.workspace.notes.first { $0.id == id }! }
    store.select(first)
    let unchanged = folder(first)
    check(store.beginFolderOverviewEditing(noteID: first), "A live folder can edit its introduction")
    check(store.finishFolderOverviewEditing(noteID: first) && folder(first) == unchanged,
          "Opening and closing an unchanged introduction leaves its default and revision untouched")
    check(!store.beginFolderOverviewEditing(noteID: child) && !store.updateFolderOverview(noteID: child, text: "wrong"),
          "A folder introduction cannot overwrite an ordinary canvas page")
    store.beginFolderOverviewEditing(noteID: first)
    store.updateFolderOverview(noteID: first, text: "## 课程\n- 课堂笔记")
    store.updateFolderOverview(noteID: first, text: "## 课程\n- 课堂笔记\n\n## 论文\n- 阅读资料")
    let firstText = folder(first).folderOverview!
    check(folder(first).summary.contains("课堂笔记") && store.finishFolderOverviewEditing(noteID: first),
          "Written folder text is searchable and saved")
    store.undo()
    check(folder(first).folderOverview == nil, "One undo restores the whole editing session's original introduction")
    store.redo()
    check(folder(first).folderOverview == firstText, "Redo restores the complete classification text")
    store.select(second)
    store.updateFolderOverview(noteID: first, text: "跨选择更新原文件夹")
    check(store.selection == second && folder(first).folderOverview == "跨选择更新原文件夹" && folder(second).folderOverview == nil,
          "Explicit folder identity prevents a delayed callback from writing into another selection")
    store.undo(); check(folder(first).folderOverview == firstText, "An independent explicit update is undoable")
    store.beginFolderOverviewEditing(noteID: first); store.updateFolderOverview(noteID: first, text: "")
    store.finishFolderOverviewEditing(noteID: first)
    check(folder(first).folderOverview == "", "An explicitly cleared introduction stays empty instead of restoring a default")
    store.beginFolderOverviewEditing(noteID: second)
    store.finishFolderOverviewEditing(noteID: first)
    check(store.folderOverviewEditingID == second, "An old view disappearing cannot end a newer folder editor")
    store.finishFolderOverviewEditing(noteID: second)

    // Commit real Chinese marked text against the outgoing folder's stable identity.
    store.select(first); store.beginFolderOverviewEditing(noteID: first)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame: window.contentView!.bounds); window.contentView = scroll
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300)); scroll.documentView = text
    var block = Block(.text, frame: Rect(0, 0, 500, 300), text: "")
    block.id = first; block.textFormat = .markdown
    let editor = RichTextEditor(block: block, formatting: store.formatting, focus: {}, checkpoint: {}) { _, value in
        store.updateFolderOverview(noteID: first, text: value)
    }
    let coordinator = editor.makeCoordinator(); text.delegate = coordinator
    window.makeFirstResponder(text); coordinator.activate(text)
    text.setMarkedText("中文分类", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    check(text.hasMarkedText() && folder(first).folderOverview == "", "IME candidates remain pending before navigation")
    store.select(second)
    check(!text.hasMarkedText() && folder(first).folderOverview == "中文分类" && folder(second).folderOverview == nil
          && store.selection == second && store.folderOverviewEditingID == nil,
          "Switching folders commits composition to the original folder and releases its editor")
    check(try store.repository.load()!.notes.first { $0.id == first }!.folderOverview == "中文分类",
          "The outgoing folder's Chinese composition is durable before navigation returns")
    text.delegate = nil; window.contentView = nil

    store.beginFolderOverviewEditing(noteID: second); store.updateFolderOverview(noteID: second, text: "待保存")
    store.flush()
    let saved = try Data(contentsOf: store.repository.workspaceURL)
    try Data("invalid workspace".utf8).write(to: store.repository.workspaceURL)
    check(!store.finishFolderOverviewEditing(noteID: second) && store.folderOverviewEditingID == second,
          "A save failure keeps the editor session and its unsaved content available")
    try saved.write(to: store.repository.workspaceURL)
    check(store.finishFolderOverviewEditing(noteID: second), "A folder can finish editing after saving becomes available again")
    let backup = try store.backup(), backupURL = root.appendingPathComponent("folder.marginbackup")
    try backup.data.write(to: backupURL)
    let restored = try AppStore(root: root.appendingPathComponent("Restored"))
    try restored.importBackup(backupURL)
    check(restored.workspace.notes.first { $0.id == first }?.folderOverview == "中文分类"
          && restored.workspace.notes.first { $0.id == second }?.folderOverview == "待保存",
          "A complete backup preserves independent folder introductions")
    let reopened = try AppStore(root: root)
    check(reopened.workspace.notes.first { $0.id == first }?.folderOverview == "中文分类",
          "Folder text survives restarting the library")
    if let i = store.workspace.notes.firstIndex(where: { $0.id == second }) { store.workspace.notes[i].deleted = true }
    check(!store.beginFolderOverviewEditing(noteID: second) && !store.updateFolderOverview(noteID: second, text: "discard"),
          "Deleted folders do not accept hidden edits")

    let catalogURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/MarginNotes/Resources/Showcase.json")
    let catalog = try JSONDecoder().decode(ShowcaseCatalog.self, from: Data(contentsOf: catalogURL))
    try store.installShowcaseIfNeeded(catalog: catalog)
    store.beginFolderOverviewEditing(noteID: catalog.rootID)
    store.updateFolderOverview(noteID: catalog.rootID, text: "# 我的工作分类\n\n" + PageLink.markdown(title: "课程", id: catalog.scenarios[0].pageID))
    store.finishFolderOverviewEditing(noteID: catalog.rootID)
    let custom = folder(catalog.rootID).folderOverview
    check(try !store.installShowcaseIfNeeded(catalog: catalog) && folder(catalog.rootID).folderOverview == custom,
          "Reopening the showcase does not overwrite a customized folder introduction")
    print("PASS: \(count) folder introduction sessions, IME, history, backup, persistence and showcase assertions")
    return count
}
