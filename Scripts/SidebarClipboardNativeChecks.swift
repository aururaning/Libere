import Foundation
import SwiftUI

@MainActor func runSidebarClipboardNativeChecks() async throws -> Int {
    _ = NSApplication.shared
    var count = 0
    func check(_ value: Bool, _ label: String) {
        if !value { FileHandle.standardError.write(Data(("FAILED sidebar clipboard: " + label + "\n").utf8)) }
        precondition(value, label); count += 1
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereSidebarClipboard-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(root: root)
    store.create(folder: true); store.renameDraft = "源文件夹"; store.commitRename(); let source = store.selection!
    store.create(parent: source); store.renameDraft = "源页面"; store.commitRename(); let page = store.selection!
    store.insert(.text); store.editBlock(store.block!.id) { $0.text = "原始笔记内容" }
    let sourceDirectory = store.directories.directory(for: source, in: store.workspace)
    let file = store.directories.directory(for: page, in: store.workspace).appendingPathComponent("original.txt")
    let bytes = Data("indexed original".utf8); try bytes.write(to: file)
    check(store.referenceFile(file), "Fixture indexes its original file")
    let fileBlock = store.block!, fileID = fileBlock.fileIdentity
    let editor = try store.textFileSession(noteID: page, blockID: fileBlock.id)
    store.create(folder: true, parent: source); store.renameDraft = "子文件夹"; store.commitRename(); let nested = store.selection!
    store.create(parent: nested); store.renameDraft = "孙页面"; store.commitRename(); let grandchild = store.selection!
    store.create(folder: true); store.renameDraft = "目标文件夹"; store.commitRename(); let target = store.selection!
    let targetDirectory = store.directories.directory(for: target, in: store.workspace)

    let pasteboard = NSPasteboard(name: .init("LibereSidebarClipboard-" + UUID().uuidString))
    defer { pasteboard.releaseGlobally() }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: LibraryView(store: store)); window.contentView = host
    defer { window.contentView = nil }
    for _ in 0..<60 {
        host.layoutSubtreeIfNeeded()
        if descendants(host).contains(where: { $0 is SidebarRowHost }) { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    check(descendants(host).compactMap { $0 as? SidebarRowHost }.contains { $0.pageID == source },
          "The actual LibraryView mounts native drag sources on sidebar rows")
    check(descendants(host).compactMap { $0 as? SidebarRowHost }.contains { $0.pageID == nil },
          "The library root is a native drop and paste destination")
    check(store.isLibraryClipboardWindow(window), "The full library window owns structural clipboard commands")
    store.select(source); store.sidebarHasFocus = true
    let region = descendants(host).compactMap { $0 as? SidebarKeyRegion }.first!
    window.makeFirstResponder(descendants(host).compactMap { $0 as? SidebarRowHost }.first { $0.pageID == source })
    let commandX = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 1,
        windowNumber: window.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7)!
    let beforeCommandX = store.workspace
    check(region.handle(commandX) && store.workspace == beforeCommandX,
          "Command-X never cuts a sidebar file, page or folder")

    let originalIDs = store.workspace.liveSubtree(source)
    check(store.copyPage(source, pasteboard: pasteboard), "A folder can be copied from the sidebar")
    let payload = try JSONDecoder().decode(PageClipboard.self, from: pasteboard.data(forType: .init(AppStore.pageClipboardType))!)
    check(Set(payload.pages.map(\.id)) == originalIDs, "The clipboard contains every live child page and folder")
    store.select(target); store.sidebarHasFocus = true
    store.pasteFocused(in: window, pasteboard: pasteboard)
    let copy = store.workspace.children(target).first { $0.sourceNoteID == source }!
    let copiedIDs = store.workspace.liveSubtree(copy.id)
    let copies = store.workspace.notes.filter { copiedIDs.contains($0.id) }
    check(copiedIDs.count == originalIDs.count && copiedIDs.isDisjoint(with: originalIDs),
          "Command-V duplicates the complete subtree with independent page identities")
    let copiedFile = copies.flatMap(\.blocks).first { $0.fileIdentity == fileID }!
    check(copiedFile.relativeFilePath == fileBlock.relativeFilePath && copiedFile.reference?.blockID == fileBlock.id,
          "Copied file pages retain their original path, identity and source link")
    check((try? Data(contentsOf: file)) == bytes && copies.allSatisfy { $0.managedFilePath == nil },
          "Copying never relocates or archives indexed originals")
    let copiedFiles = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.lastPathComponent == "original.txt" }
    check(copiedFiles.count == 1, "Folder copies create no duplicate original file bytes")
    store.undo(); check(store.workspace.notes.filter { copiedIDs.contains($0.id) }.allSatisfy(\.deleted), "One undo removes the copied subtree as a unit")
    store.redo(); check(store.workspace.notes.filter { copiedIDs.contains($0.id) }.allSatisfy { !$0.deleted }, "One redo restores the whole copied subtree")
    store.revealPageSource(copy.id); check(store.selection == source, "Copied folders can jump back to their original page")

    check(store.copyPage(source, pasteboard: pasteboard), "Command-C prepares a folder for Move Here")
    check(FileManager.default.fileExists(atPath: file.path) && store.workspace.notes.first { $0.id == source }?.parentID == nil,
          "Copy alone leaves the source hierarchy and original files in place")
    store.select(target); store.sidebarHasFocus = true
    store.moveFocused(in: window, pasteboard: pasteboard)
    let movedFile = store.attachmentURL(for: store.workspace.notes.first { $0.id == page }!.blocks.first { $0.id == fileBlock.id }!)!
    check(store.workspace.notes.first { $0.id == source }?.parentID == target
          && store.workspace.notes.first { $0.id == grandchild }?.parentID == nested,
          "Move Here moves the original folder without changing descendant identities")
    check(!FileManager.default.fileExists(atPath: sourceDirectory.path)
          && movedFile.path.hasPrefix(targetDirectory.path + "/") && (try? Data(contentsOf: movedFile)) == bytes,
          "Sidebar Move Here physically relocates the managed original directory")
    check(Set(store.workspace.notes.flatMap(\.blocks).filter { $0.fileIdentity == fileID }.compactMap(\.relativeFilePath)).count == 1,
          "Copies outside the moved subtree follow the original's new path")
    editor.edit("edited after sidebar move"); check(editor.save(), "An already-open editor saves to the moved original")
    check((try? String(contentsOf: movedFile, encoding: .utf8)) == "edited after sidebar move", "The active editor uses the relocated index")
    let afterMove = try JSONDecoder().decode(PageClipboard.self, from: pasteboard.data(forType: .init(AppStore.pageClipboardType))!)
    check(afterMove.rootID == source, "A completed move keeps the original page identity on the clipboard")
    store.undo()
    check(FileManager.default.fileExists(atPath: file.path) && (try? String(contentsOf: file, encoding: .utf8)) == "edited after sidebar move",
          "Undo restores the physical folder while preserving latest file edits")
    store.redo(); check(FileManager.default.fileExists(atPath: movedFile.path), "Redo moves the same original folder again")
    store.undo()

    // A durable-history failure must roll back both hierarchy and disk paths.
    let history = root.appendingPathComponent("History-" + store.device + ".json")
    let oldHistory = try Data(contentsOf: history)
    try FileManager.default.removeItem(at: history); try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false)
    let beforeFailure = store.workspace
    let copied = try store.pageClipboardData(source)
    check(!store.pastePageClipboard(copied, into: target, move: true), "A failed undo-record save rejects the whole move")
    check(store.workspace == beforeFailure && FileManager.default.fileExists(atPath: file.path)
          && !FileManager.default.fileExists(atPath: movedFile.path), "Failed moves restore both the original index and its real directory")
    try FileManager.default.removeItem(at: history); try oldHistory.write(to: history)
    store.message = nil

    let beforeCycle = store.workspace
    check(!store.pastePageClipboard(copied, into: grandchild, move: true) && store.workspace == beforeCycle, "Move Here cannot move a folder into its own descendant")
    check(!store.pastePageClipboard(Data("invalid".utf8), into: target), "Invalid clipboard records cannot modify the library")
    let foreign = try PageClipboard(library: "/another-library", rootID: source, workspace: store.workspace)
    check(!store.pastePageClipboard(try JSONEncoder().encode(foreign), into: target), "Cross-library structural payloads never create external references")

    // Plain pages and file-backed pages use the same sidebar clipboard route.
    store.select(page); check(store.copyPage(page, pasteboard: pasteboard), "An ordinary page can be copied")
    store.select(target); store.moveFocused(in: window, pasteboard: pasteboard)
    check(store.workspace.notes.first { $0.id == page }?.parentID == target, "Command-Option-V moves a copied ordinary page")
    store.undo()
    store.select(target); store.sidebarRootSelected = true
    store.pasteFocused(in: window, pasteboard: pasteboard)
    check(store.workspace.children(nil).contains { $0.sourceNoteID == page }, "The library root accepts copied pages through the same paste command")
    print("PASS: \(count) sidebar page/folder clipboard, native row, physical move and durable undo assertions")
    return count
}
