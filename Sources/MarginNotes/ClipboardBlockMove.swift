import SwiftUI
#if SWIFT_PACKAGE
import MarginCore
#endif

/// Moving a canvas selection preserves its block identities. Other appearances
/// of the same file remain in place; only source links follow the moved owner.
enum ClipboardBlockMove {
    static func validate(_ payload: CanvasClipboard, in workspace: Workspace) throws {
        let ids = Set(payload.blocks.map(\.id))
        guard payload.format == 2, !ids.isEmpty, ids.count == payload.blocks.count, ids.count <= 5000,
              let source = workspace.notes.first(where: { $0.id == payload.noteID && !$0.deleted && !$0.isFolder }),
              ids.isSubset(of: Set(source.blocks.map(\.id))) else {
            throw NSError(domain: "ClipboardMove", code: 3, userInfo: [NSLocalizedDescriptionKey: "原内容已删除或变更，请重新复制后再移动。"])
        }
        guard !source.blocks.contains(where: { ids.contains($0.id) && $0.locked }) else {
            throw NSError(domain: "ClipboardMove", code: 4, userInfo: [NSLocalizedDescriptionKey: "选中内容包含锁定块，请先解锁再移动。"])
        }
    }

    static func apply(_ payload: CanvasClipboard, to target: UUID, at point: CGPoint?, in workspace: inout Workspace) throws -> (noteID: UUID, ids: Set<UUID>) {
        try validate(payload, in: workspace)
        guard let sourceIndex = workspace.notes.firstIndex(where: { $0.id == payload.noteID }),
              let requested = workspace.notes.first(where: { $0.id == target && !$0.deleted }) else { throw StoreError.corrupt }
        let ids = Set(payload.blocks.map(\.id))
        var blocks = workspace.notes[sourceIndex].blocks.filter { ids.contains($0.id) }
        let anchors = workspace.notes[sourceIndex].anchors.filter { ids.contains($0.ownerID) }
        let movedAnchors = Set(anchors.map(\.id))
        let ownedFiles = Set(blocks.filter { $0.reference == nil }.compactMap(\.relativeFilePath))
        var destinationID = target
        if requested.isFolder {
            var child = Note(title: blocks.count == 1 && blocks[0].isFilePlugin ? blocks[0].assetName : "移动的内容", parent: target)
            if blocks.count == 1 && blocks[0].reference == nil { child.managedFilePath = blocks[0].relativeFilePath }
            destinationID = child.id; workspace.notes.append(child)
        }
        let destinationIndex = workspace.notes.firstIndex { $0.id == destinationID }!
        workspace.notes[sourceIndex].blocks.removeAll { ids.contains($0.id) }
        workspace.notes[sourceIndex].anchors.removeAll { movedAnchors.contains($0.id) }
        if sourceIndex != destinationIndex {
            if workspace.notes[sourceIndex].managedFilePath.map(ownedFiles.contains) == true { workspace.notes[sourceIndex].managedFilePath = nil }
            for i in workspace.notes[sourceIndex].blocks.indices where workspace.notes[sourceIndex].blocks[i].anchorID.map(movedAnchors.contains) == true {
                workspace.notes[sourceIndex].blocks[i].anchorID = nil
            }
            for i in blocks.indices where blocks[i].anchorID.map({ !movedAnchors.contains($0) }) == true { blocks[i].anchorID = nil }
        }
        let positioned = try ClipboardPlacement.position(blocks, in: &workspace.notes[destinationIndex], at: point)
        workspace.notes[destinationIndex].blocks += positioned
        workspace.notes[destinationIndex].anchors += anchors
        workspace.notes[destinationIndex].extendCanvasForContent()
        if destinationID != payload.noteID {
            for p in workspace.notes.indices {
                for b in workspace.notes[p].blocks.indices {
                    if var source = workspace.notes[p].blocks[b].reference, source.noteID == payload.noteID, ids.contains(source.blockID) {
                        source.noteID = destinationID; workspace.notes[p].blocks[b].reference = source
                    }
                }
            }
        }
        return (destinationID, ids)
    }
}

extension AppStore {
    #if os(macOS)
    func moveFocused(in window: NSWindow?, pasteboard: NSPasteboard = .general) {
        if pastePagesFocused(in: window, pasteboard: pasteboard, move: true) { return }
        guard isCanvasPasteWindow(window) else { return }
        guard commitTitleEditing(in: window) else { return }
        let point = canvasPastePoint(in: window)
        let changeCount = pasteboard.changeCount
        if let payload = CanvasPasteboardContents.blockData(from: pasteboard) {
            _ = clipboardMoves.moveBlocks(payload, at: point, noteID: selection)
            if let copied = try? JSONDecoder().decode(CanvasClipboard.self, from: payload) {
                Task { [weak self] in
                    guard let self else { return }; await self.clipboardMoves.waitUntilIdle()
                    guard pasteboard.changeCount == changeCount else { return }
                    let ids = Set(copied.blocks.map(\.id))
                    guard let page = self.workspace.notes.first(where: { !$0.deleted && ids.isSubset(of: Set($0.blocks.map(\.id))) }) else { return }
                    let blocks = page.blocks.filter { ids.contains($0.id) }
                    let next = CanvasClipboard(root: copied.root, noteID: page.id, blocks: blocks,
                                               anchors: page.anchors.filter { ids.contains($0.ownerID) })
                    guard let data = try? JSONEncoder().encode(next) else { return }
                    pasteboard.clearContents(); pasteboard.setData(data, forType: CanvasPasteboardContents.canvasBlocks)
                    pasteboard.setString(blocks.map { $0.isFilePlugin ? $0.assetName : $0.text }.joined(separator: "\n"), forType: .string)
                }
            }
            return
        }
        var urls = CanvasPasteboardContents.fileURLs(from: pasteboard)
        if urls.isEmpty, let text = pasteboard.string(forType: .string) {
            urls = CanvasPasteboardContents.textFileURLs(text, libraryRoot: repository.root) ?? []
        }
        guard !urls.isEmpty else { message = "请先复制要移动的文件或内容块，再按 ⌘⌥V。截图等无原路径内容请用 ⌘V。"; return }
        _ = clipboardMoves.moveFiles(urls, at: point, noteID: selection)
        Task { [weak self] in
            guard let self else { return }; await self.clipboardMoves.waitUntilIdle()
            guard pasteboard.changeCount == changeCount, !self.clipboardMoves.lastInstalledFiles.isEmpty else { return }
            pasteboard.clearContents(); pasteboard.writeObjects(self.clipboardMoves.lastInstalledFiles.map { $0.destinationURL as NSURL })
        }
    }
    #endif
    func moveFocused() {
        #if os(macOS)
        moveFocused(in: NSApp.keyWindow ?? NSApp.mainWindow)
        #endif
    }
}
