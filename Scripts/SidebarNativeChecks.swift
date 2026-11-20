import Foundation
import SwiftUI

@MainActor func runSidebarNativeChecks() throws -> Int {
    var count = 0
    func check(_ value: Bool, _ name: String) { precondition(value,name); count += 1 }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("libere-sidebar-" + UUID().uuidString)
    let suite = "libere-sidebar-check-" + UUID().uuidString
    let defaults = UserDefaults(suiteName:suite)!
    defer { try? FileManager.default.removeItem(at:root); defaults.removePersistentDomain(forName:suite) }
    let store = try AppStore(root:root,preferences:defaults)
    store.create(folder:true); store.renameDraft = "项目 A"; store.commitRename(); let parent = store.selection!
    store.create(parent:parent); store.renameDraft = "页面 B"; store.commitRename(); let child = store.selection!
    store.create(folder:true,parent:child); store.renameDraft = "子目录 C"; store.commitRename(); let nested = store.selection!
    store.create(); store.renameDraft = "外部引用"; store.commitRename(); let outside = store.selection!
    // A direct reference into an app-managed page directory must follow rename/move.
    let folder = store.directories.directory(for:child,in:store.workspace)
    let file = folder.appendingPathComponent("本地资料.md"); try Data("正文".utf8).write(to:file)
    var reference = Block(.file,frame:Rect(20,20,320,480)); reference.assetName = "本地资料.md"
    reference.relativeFilePath = ReferencePath.relative(file,inside:root); reference.fileID = UUID()
    store.edit { $0.blocks.append(reference) }; check(store.flush(),"Reference fixture saves")
    let previousPath = store.note!.blocks[0].relativeFilePath
    let textSession = try store.textFileSession(noteID:outside,blockID:reference.id)
    let notebookFile = root.appendingPathComponent("fixture.ipynb")
    try Data("{\"nbformat\":4,\"cells\":[{\"cell_type\":\"code\",\"source\":\"1+1\",\"outputs\":[],\"metadata\":{}}],\"metadata\":{}}".utf8).write(to:notebookFile)
    store.select(child); store.importFile(notebookFile)
    let notebook = try store.notebookSession(noteID:child,blockID:store.block!.id)
    let originalCWD = notebook.workingDirectory
    store.select(outside)
    check(store.placePage(child,at:.inside(nil)),"Drag reparent commits")
    check(store.workspace.notes.first { $0.id == nested }?.parentID == child,"Nested page retains ownership")
    let refAfter = store.workspace.notes.first { $0.id == outside }!.blocks[0]
    check(refAfter.relativeFilePath != previousPath && FileManager.default.fileExists(atPath:store.attachmentURL(for:refAfter)!.path),"Direct file reference follows directory move")
    check(notebook.workingDirectory != originalCWD && FileManager.default.fileExists(atPath:notebook.workingDirectory.path),"Notebook working directory follows reparent")
    textSession.edit("移动后继续编辑"); check(textSession.save(),"Existing editor saves through moved reference")
    check(try String(contentsOf:store.attachmentURL(for:refAfter)!,encoding:.utf8) == "移动后继续编辑","Moved file receives subsequent text edits")
    store.undo()
    let refUndo = store.workspace.notes.first { $0.id == outside }!.blocks[0]
    check(store.workspace.notes.first { $0.id == child }?.parentID == parent && refUndo.relativeFilePath == previousPath,"One undo restores parent and cross-page reference")
    check(FileManager.default.fileExists(atPath:store.attachmentURL(for:refUndo)!.path),"Undo restores actual working file location")
    check(notebook.workingDirectory.standardizedFileURL == originalCWD.standardizedFileURL,"Undo restores Notebook working directory")
    store.redo(); check(store.workspace.notes.first { $0.id == child }?.parentID == nil,"One redo restores move")
    store.move(child,to:parent)
    check(store.expandedPages.contains(parent) && store.selection == child,"Move selects and reveals new ancestry")
    store.requestTrash(parent)
    check(store.deletionRequest?.id == parent && !store.workspace.notes.first { $0.id == parent }!.deleted,"Subtree deletion asks first")
    store.deletionRequest = nil; check(!store.workspace.notes.first { $0.id == nested }!.deleted,"Cancel leaves subtree intact")
    store.requestTrash(parent); store.confirmTrash(suppress:true)
    check([parent,child,nested].allSatisfy { id in store.workspace.notes.first { $0.id == id }!.deleted },"Confirmed delete includes all descendants")
    check(!store.confirmSubtreeDeletion && !defaults.bool(forKey:"LibereConfirmSubtreeDeletion"),"Suppression preference persists only on confirmation")
    store.undo(); check([parent,child,nested].allSatisfy { id in !store.workspace.notes.first { $0.id == id }!.deleted },"One undo restores complete subtree")
    store.redo(); store.recover(parent)
    check(!store.workspace.notes.first { $0.id == nested }!.deleted && store.workspace.notes.first { $0.id == child }?.parentID == parent,"Trash recovery restores the whole original hierarchy")
    store.requestTrash(child); check(store.deletionRequest == nil && store.workspace.notes.first { $0.id == nested }!.deleted,"Suppressed prompt still deletes as a recoverable group")
    let reopened = try AppStore(root:root,preferences:defaults)
    check(!reopened.confirmSubtreeDeletion && reopened.canUndo,"Preferences and grouped history survive reopen")
    reopened.undo(); check(!reopened.workspace.notes.first { $0.id == nested }!.deleted,"Grouped undo survives reopen")
    reopened.confirmSubtreeDeletion = true; reopened.requestTrash(child)
    check(reopened.deletionRequest != nil,"Prompt can be enabled again")
    reopened.deletionRequest = nil
    // Native key dispatch: only sidebar selection, never a text field or canvas.
    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false
    let region = SidebarKeyRegion(frame:NSRect(x:0,y:0,width:220,height:400)); region.store = reopened; window.contentView = region
    func key(_ code: UInt16,_ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!
    }
    reopened.select(child); reopened.sidebarHasFocus = false
    check(!region.handle(key(51,.command)),"Canvas focus does not delete pages")
    reopened.sidebarHasFocus = true
    check(region.handle(key(36)) && reopened.renaming == child,"Enter starts rename on sidebar selection")
    reopened.renameDraft = "取消的名字"; reopened.cancelRename()
    check(reopened.workspace.notes.first { $0.id == child }?.title == "页面 B","Escape cancel leaves title unchanged")
    reopened.beginRename(child); reopened.renameDraft = "重新命名"; reopened.commitRename()
    check(reopened.note?.title == "重新命名" && reopened.renaming == nil,"Return commit renames and leaves rename mode")
    reopened.undo(); check(reopened.note?.title == "页面 B","Rename is undoable")
    let text = NSTextView(frame:NSRect(x:0,y:0,width:100,height:100)); region.addSubview(text); window.makeFirstResponder(text)
    check(!region.handle(key(51,.command)) && !region.handle(key(36)),"Text editing keeps native Command Delete and Return")
    window.makeFirstResponder(nil); reopened.sidebarHasFocus = true; reopened.select(child)
    check(!region.handle(key(51)) && !region.handle(key(51,[.command,.shift])),"Plain Delete and other modifier combinations do not delete pages")
    check(region.handle(key(51,.command)) && reopened.deletionRequest?.id == child,"Command Delete routes to subtree confirmation")
    window.contentView = nil
    // Legacy v0.6.0 history stores a Note directly; it remains readable.
    let legacyRoot = root.appendingPathComponent("legacy")
    let legacy = try AppStore(root:legacyRoot,preferences:defaults)
    let oldNote = legacy.note!; legacy.edit { $0.title = "修改后" }; legacy.flush()
    struct OldHistory: Encodable { var undo:[Note]; var redo:[Note] }
    try JSONEncoder().encode(OldHistory(undo:[oldNote],redo:[])).write(to:legacyRoot.appendingPathComponent("History-" + legacy.device + ".json"))
    let legacyReload = try AppStore(root:legacyRoot,preferences:defaults); legacyReload.undo()
    check(legacyReload.note?.title == oldNote.title,"Legacy single-note history migrates without losing undo")
    // Explicit root ordering is also respected by the flattened sidebar tree.
    reopened.deletionRequest = nil; reopened.placePage(outside,at:.before(parent))
    let roots = NoteTree.build(reopened.workspace).map(\.id)
    check(roots.firstIndex(of:outside)! < roots.firstIndex(of:parent)!,"Sidebar roots respect drag order")
    print("PASS: \(count) sidebar, hierarchy, reference and shortcut assertions")
    return count
}
