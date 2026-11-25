import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import WebKit
#if SWIFT_PACKAGE
import MarginCore
#endif

struct FileReferenceChoice: Identifiable {
    let noteID: UUID
    let block: Block
    let title: String
    var id: UUID { block.id }
}
private struct LegacyBlockClipboard: Codable { let root: String; let source: FileReference; let block: Block }
struct CanvasClipboard: Codable {
    var format = 2
    let root: String
    let noteID: UUID
    let blocks: [Block]
    let anchors: [AnnotationAnchor]
}

extension AppStore {
    #if os(iOS)
    var currentTextResponder: UIResponder? {
        func find(_ view: UIView) -> UIView? {
            if view.isFirstResponder { return view }
            for child in view.subviews { if let responder = find(child) { return responder } }
            return nil
        }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows where window.isKeyWindow {
            if let responder = find(window), responder is UITextInput { return responder }
        }
        return nil
    }
    #endif
    var webEditorFocused: Bool {
        #if os(macOS)
        var view = NSApp?.keyWindow?.firstResponder as? NSView
        while let current = view { if current is WKWebView { return true }; view = current.superview }
        #endif
        return false
    }
    var referenceChoices: [FileReferenceChoice] {
        var seen: Set<UUID> = []
        return workspace.notes.filter { !$0.deleted }.flatMap { note in
            note.blocks.filter { $0.isFilePlugin }.compactMap { block in
                guard seen.insert(block.fileIdentity).inserted else { return nil }
                return FileReferenceChoice(noteID: note.id, block: block, title: (ReferencePath.title(of: note.id, in: workspace) + [block.assetName]).joined(separator: " / "))
            }
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    func attachmentURL(for block: Block) -> URL? {
        if let path = block.relativeFilePath { return ReferencePath.resolve(path, inside: repository.root) }
        return block.displayAssetID.map { repository.asset($0) }
    }
    func attachmentTitle(_ block: Block, on noteID: UUID?) -> String {
        if let path = block.relativeFilePath { return "我的知识库 / " + path.replacingOccurrences(of: "/", with: " / ") }
        if let source = block.reference, source.noteID != noteID {
            return (["我的知识库"] + ReferencePath.title(of: source.noteID, in: workspace) + [block.assetName]).joined(separator: " / ")
        }
        return block.assetName
    }
    func addReference(_ choice: FileReferenceChoice, asPage: Bool = false) {
        appendReference(choice.block, source: FileReference(noteID: choice.noteID, blockID: choice.block.id), asPage: asPage)
    }
    private func appendReference(_ original: Block, source: FileReference?, asPage: Bool) {
        if asPage {
            create(parent: selection)
            renameDraft = (original.assetName as NSString).deletingPathExtension
            edit { $0.title = renameDraft }
        }
        guard var note, !note.isFolder else { return }
        let desired = Rect(28, 28, original.frame.width, original.frame.height)
        var frame = CanvasLayout.vacant(desired, paper: note.paper, occupied: note.blocks.map(\.frame), canvasWidth: note.width)
        if frame == nil {
            note.paper = note.paper.width > 794 ? .wideContinuous : .continuous
            frame = CanvasLayout.vacant(desired, paper: note.paper, occupied: note.blocks.map(\.frame), canvasWidth: note.width)
        }
        guard let frame else { return }
        var copy = original
        copy.id = UUID(); copy.frame = frame; copy.fileID = original.fileIdentity
        copy.reference = original.reference ?? source; copy.locked = false; copy.anchorID = nil; copy.pageAnnotations = nil
        checkpoint(); edit {
            $0.paper = note.paper; $0.blocks.append(copy)
            if asPage, source == nil, copy.reference == nil, let path = copy.relativeFilePath {
                $0.managedFilePath = path; $0.managedDirectoryPath = nil
            }
        }
        blockSelection = copy.id; blockKeyboardFocus = !asPage; tool = .select; flush()
    }
    func indexedBlock(at url: URL, validateContents: Bool = true) throws -> Block {
        let path = try FileIndexPolicy.path(for: url, inside: repository.root)
        // Register an existing cloud placeholder without reading its bytes. The
        // normal preview validates the document after an explicit download.
        let deferredValidation: Bool
        if validateContents {
            let availability = try ICloudFileSnapshot.read(url)
            deferredValidation = availability.ubiquitous && !availability.local
        } else { deferredValidation = true }
        let kind: BlockKind
        if url.pathExtension.lowercased() == "pdf" {
            if validateContents && !deferredValidation {
                guard let pdf = PDFDocument(url: url), pdf.pageCount > 0, !pdf.isLocked else { throw StoreError.corrupt }
            }
            kind = .pdf
        } else if let format = AttachmentFormat(filename: url.lastPathComponent) {
            if validateContents && !deferredValidation {
                if format == .image { try AttachmentImage.validate(at: url) }
                if format == .notebook { _ = try NotebookDocument(data: Data(contentsOf: url)) }
            }
            kind = .file
        } else { kind = .file }
        let generic = kind == .file && AttachmentFormat(filename: url.lastPathComponent) == nil
        var block = Block(kind, frame: Rect(28, 28, 380, generic ? 260 : 500))
        block.assetName = url.lastPathComponent; block.relativeFilePath = path
        block.fileID = UUID()
        for note in workspace.notes {
            if let original = note.blocks.first(where: { $0.relativeFilePath == path }) {
                block.fileID = original.fileIdentity
                block.reference = original.reference ?? FileReference(noteID: note.id, blockID: original.id)
                break
            }
        }
        return block
    }
    @discardableResult func referenceFile(_ url: URL, asPage: Bool = false) -> Bool {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let block = try indexedBlock(at: url)
            let previous = blockSelection
            appendReference(block, source: nil, asPage: asPage)
            guard blockSelection != previous else { return false }
            refreshReferencedFiles(noteID: selection)
            return true
        } catch { message = error.localizedDescription; return false }
    }
    func copySelectedBlock() { _ = copySelectedBlocks(multiSelection.selectedIDs) }
    func clipboardData(for ids: Set<UUID>) throws -> Data {
        guard let note else { throw StoreError.corrupt }
        let blocks = note.blocks.filter { ids.contains($0.id) }
        guard !blocks.isEmpty else { throw StoreError.corrupt }
        return try JSONEncoder().encode(CanvasClipboard(root: repository.root.standardizedFileURL.resolvingSymlinksInPath().path,
            noteID: note.id, blocks: blocks, anchors: note.anchors.filter { ids.contains($0.ownerID) }))
    }
    @discardableResult func copySelectedBlocks(_ ids: Set<UUID>) -> Bool {
        guard let note, let data = try? clipboardData(for: ids) else { return false }
        let plain = note.blocks.filter { ids.contains($0.id) }.map { $0.isFilePlugin ? ($0.linkURL ?? $0.relativeFilePath ?? $0.assetName) : $0.text }.joined(separator: "\n\n")
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .init("app.libere.canvas-blocks"))
        NSPasteboard.general.setString(plain, forType: .string)
        #else
        UIPasteboard.general.setItems([["app.libere.canvas-blocks":data, UTType.utf8PlainText.identifier:plain]])
        #endif
        return true
    }
    @discardableResult func pasteBlocks(_ data: Data, at point: CGPoint? = nil) -> Bool {
        do {
            let item: CanvasClipboard
            if let current = try? JSONDecoder().decode(CanvasClipboard.self, from: data), current.format == 2 { item = current }
            else {
                let old = try JSONDecoder().decode(LegacyBlockClipboard.self, from: data)
                item = CanvasClipboard(root: old.root, noteID: old.source.noteID, blocks: [old.block], anchors: [])
            }
            let sameRoot = URL(fileURLWithPath: item.root).standardizedFileURL.resolvingSymlinksInPath() == repository.root.standardizedFileURL.resolvingSymlinksInPath()
            var blocks = item.blocks
            guard !blocks.isEmpty, blocks.count <= 5000 else { throw StoreError.corrupt }
            for i in blocks.indices {
                let original = blocks[i]
                if original.relativeFilePath != nil || !original.referencedAssets.isEmpty {
                    guard sameRoot else { throw FileIndexError.outsideLibrary }
                    let current = workspace.notes.first { $0.id == item.noteID }?.blocks.first { $0.id == original.id }
                    let indexed = directories.indexed(current ?? original)
                    guard let path = indexed.relativeFilePath, ReferencePath.resolve(path, inside: repository.root) != nil else { throw FileIndexError.outsideLibrary }
                    blocks[i].relativeFilePath = path; blocks[i].assetName = indexed.assetName
                    blocks[i].assetID = nil; blocks[i].workingAssetID = nil; blocks[i].notebookAssetID = nil
                    blocks[i].fileID = indexed.fileIdentity; blocks[i].contentRevision = indexed.contentRevision
                }
                if original.isFilePlugin {
                    if blocks[i].fileID == nil { blocks[i].fileID = original.fileIdentity }
                }
                blocks[i].reference = sameRoot ? original.reference ?? FileReference(noteID: item.noteID, blockID: original.id) : nil
            }
            if let folder = note, folder.isFolder {
                guard blocks.allSatisfy({ $0.frame.x.isFinite && $0.frame.y.isFinite && $0.frame.width.isFinite && $0.frame.height.isFinite && $0.frame.width > 0 && $0.frame.height > 0 }),
                      Set(blocks.map(\.id)).count == blocks.count else { throw StoreError.corrupt }
                let minX = blocks.map(\.frame.x).min()!, minY = blocks.map(\.frame.y).min()!
                let ids = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, UUID()) })
                let copiedAnchors = item.anchors.filter { ids[$0.ownerID] != nil }
                let anchorIDs = Dictionary(copiedAnchors.map { ($0.id, UUID()) }, uniquingKeysWith: { a, _ in a })
                var page = Note(title: blocks.count == 1 && blocks[0].isFilePlugin ? blocks[0].assetName : "粘贴的内容", parent: folder.id)
                page.blocks = blocks.map { original in
                    var copy = original; copy.id = ids[original.id]!
                    copy.frame.x += 28 - minX; copy.frame.y += 28 - minY
                    copy.anchorID = original.anchorID.flatMap { anchorIDs[$0] }
                    if var annotations = copy.pageAnnotations {
                        for key in Array(annotations.keys) {
                            for i in annotations[key]!.texts.indices { annotations[key]!.texts[i].id = UUID() }
                        }
                        copy.pageAnnotations = annotations
                    }
                    return copy
                }
                page.anchors = copiedAnchors.compactMap { original in
                    guard let id = anchorIDs[original.id], let owner = ids[original.ownerID] else { return nil }
                    var copy = original; copy.id = id; copy.ownerID = owner; return copy
                }
                page.extendCanvasForContent()
                try commitIndexedPages([page], selectInserted: false)
                return true
            }
            return try appendClipboardBlocks(blocks, anchors: item.anchors, at: point)
        } catch { message = error.localizedDescription; return false }
    }
    @discardableResult func appendClipboardBlocks(_ incoming: [Block], anchors: [AnnotationAnchor] = [], at point: CGPoint? = nil, noteID: UUID? = nil,
                                                 managedDirectoryPath: String? = nil) throws -> Bool {
        guard let noteID = noteID ?? selection, let index = workspace.notes.firstIndex(where: { $0.id == noteID && !$0.deleted && !$0.isFolder }), !incoming.isEmpty else { return false }
        if selection == noteID { finishBlockEditing() }
        guard saveEditors() else { return false }
        let previous = workspace.notes[index]; var next = previous
        let positioned = try ClipboardPlacement.position(incoming, in: &next, at: point)
        guard Set(incoming.map(\.id)).count == incoming.count else { throw StoreError.corrupt }
        let ids = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id,UUID()) })
        let keptAnchors = anchors.filter { ids[$0.ownerID] != nil }
        let anchorIDs = Dictionary(keptAnchors.map { ($0.id,UUID()) }, uniquingKeysWith: { first,_ in first })
        let copies = positioned.map { original -> Block in
            var copy = original; copy.id = ids[original.id]!
            copy.anchorID = original.anchorID.flatMap { anchorIDs[$0] }
            if var annotations = copy.pageAnnotations {
                for key in Array(annotations.keys) {
                    for j in annotations[key]!.texts.indices { annotations[key]!.texts[j].id = UUID() }
                }
                copy.pageAnnotations = annotations
            }
            return copy
        }
        next.blocks += copies
        if let managedDirectoryPath, next.managedDirectoryPath == nil {
            guard ReferencePath.resolve(managedDirectoryPath, inside: repository.root) != nil else { throw FileIndexError.outsideLibrary }
            next.managedDirectoryPath = managedDirectoryPath
        }
        next.anchors += keptAnchors.compactMap { original in
            guard let owner = ids[original.ownerID], let id = anchorIDs[original.id] else { return nil }
            var copy = original; copy.id = id; copy.ownerID = owner; return copy
        }
        next.extendCanvasForContent(); next.touch(device)
        var candidate = workspace; candidate.notes[index] = next; candidate.pending.insert("page_" + next.id.uuidString)
        try commitAgentWorkspace(candidate, previous: previous)
        if selection == noteID { multiSelection.select(Set(copies.map(\.id))) }
        return true
    }
    @discardableResult func pasteReference(at point: CGPoint? = nil) -> Bool {
        #if os(macOS)
        let data = NSPasteboard.general.data(forType: .init("app.libere.canvas-blocks")) ?? NSPasteboard.general.data(forType: .init("app.marginnotes.block-reference"))
        #else
        let data = UIPasteboard.general.data(forPasteboardType: "app.libere.canvas-blocks") ?? UIPasteboard.general.data(forPasteboardType: "app.marginnotes.block-reference")
        #endif
        guard let data else { return false }
        _ = pasteBlocks(data, at: point); return true
    }
    @discardableResult func smartPaste(_ text: String, at point: CGPoint? = nil) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        if WebLink.url(value) != nil { insertLink(value, mode: .card, point: point); return true }
        #if os(macOS)
        if let files = CanvasPasteboardContents.textFileURLs(value, libraryRoot: repository.root) {
            return pasteFileURLs(files, at: point, noteID: selection)
        }
        #else
        let file: URL?
        if value.hasPrefix("file://"), let url = URL(string:value), url.isFileURL { file = url }
        else if value.hasPrefix("/") || value.hasPrefix("~/") {
            let candidate = URL(fileURLWithPath:(value as NSString).expandingTildeInPath)
            file = ReferencePath.relative(candidate, inside: repository.root) != nil || FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }
        else { file = nil }
        if let file { return pasteFileURLs([file], at: point, noteID: selection) }
        #endif
        do { return try appendClipboardBlocks([Block(.text,frame:Rect(0,0,360,216),text:text)], at: point) }
        catch { message = error.localizedDescription; return true }
    }
    #if os(macOS)
    /// Reader windows have zoom scroll views too, but only the current note's
    /// main canvas owns this store's pointer interaction object.
    func isCanvasPasteWindow(_ window: NSWindow?) -> Bool {
        guard let window, window.attachedSheet == nil, let root = window.contentView,
              let note, !showTrash else { return false }
        var pending = [root]
        while let view = pending.popLast() {
            if note.isFolder, let owner = view as? LibraryPasteOwnerView, owner.store === self,
               !owner.isHiddenOrHasHiddenAncestor { return true }
            if let canvas = view as? CanvasScrollView, canvas.pointerInteraction === canvasPointer,
               !canvas.isHiddenOrHasHiddenAncestor, !canvas.visibleRect.isEmpty { return true }
            pending.append(contentsOf: view.subviews)
        }
        return false
    }
    func pasteFocused(in window: NSWindow?, pasteboard: NSPasteboard = .general) {
        let canvas = isCanvasPasteWindow(window)
        let point = canvas ? canvasPastePoint(in: window) : nil
        let targetNote = selection
        let responder = window?.firstResponder
        var focusView = responder as? NSView, webFocused = false
        while let view = focusView {
            if view is WKWebView { webFocused = true; break }
            focusView = view.superview
        }
        let textFocused = responder is NSTextView || webFocused
        func nativePaste() {
            _ = NSApp?.sendAction(#selector(NSText.paste(_:)), to: responder, from: nil)
        }
        guard canvas else { nativePaste(); return }
        let payload = CanvasPasteboardContents.blockData(from: pasteboard)
        if let payload {
            guard commitTitleEditing(in: window) else { return }
            // Copying a whole canvas block explicitly preserves its structure and
            // source index, even when an old text view still owns keyboard focus.
            // Native text selections do not contain this private representation.
            _ = pasteBlocks(payload, at: point); return
        }
        let urls = CanvasPasteboardContents.fileURLs(from: pasteboard)
        if !urls.isEmpty { guard commitTitleEditing(in: window) else { return }; _ = pasteFileURLs(urls, at: point, noteID: targetNote); return }
        if payload == nil, let binary = CanvasPasteboardContents.binaryFile(from: pasteboard) {
            guard commitTitleEditing(in: window) else { return }
            _ = pasteClipboardFileData(binary.data, suggestedFilename: binary.suggestedFilename, at: point, noteID: targetNote)
            return
        }
        if textFocused { nativePaste(); return }
        if let text = pasteboard.string(forType: .string) ?? pasteboard.string(forType: .URL), smartPaste(text, at: point) { return }
        if (pasteboard.types ?? []).contains(where: { $0.rawValue.localizedCaseInsensitiveContains("filepromise") || $0.rawValue.localizedCaseInsensitiveContains("promised-file") }) {
            message = "剪贴板尚未提供文件内容或原文件路径，请先完成文件下载或导出后再复制。"
            return
        }
        nativePaste()
    }
    #endif
    func copyFocused() {
        #if os(macOS)
        if NSApp.keyWindow?.firstResponder is NSTextView || webEditorFocused { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil); return }
        #else
        if let responder = currentTextResponder { UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.copy(_:)), to: responder, from: nil, for: nil); return }
        #endif
        if blockKeyboardFocus { copySelectedBlock(); return }
        #if os(macOS)
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        #endif
    }
    func pasteFocused() {
        #if os(macOS)
        pasteFocused(in: NSApp?.keyWindow ?? NSApp?.mainWindow)
        #else
        if let responder = currentTextResponder { UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.paste(_:)), to: responder, from: nil, for: nil); return }
        let point = canvasPastePoint()
        if pasteReference(at: point) { return }
        if let url = UIPasteboard.general.url, url.isFileURL { _ = pasteFileURLs([url], at: point, noteID: selection); return }
        if let text = UIPasteboard.general.string { _ = smartPaste(text, at: point) }
        #endif
    }
    func cutFocused() {
        #if os(macOS)
        if NSApp.keyWindow?.firstResponder is NSTextView || webEditorFocused {
            NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil); return
        }
        #else
        if let responder = currentTextResponder { UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.cut(_:)), to: responder, from: nil, for: nil); return }
        #endif
        if blockKeyboardFocus {
            let ids = multiSelection.selectedIDs
            guard let note, !note.blocks.contains(where: { ids.contains($0.id) && $0.locked }) else { message = "请先解锁选中的内容，再剪切。"; return }
            if copySelectedBlocks(ids) { multiSelection.delete() }
        }
    }
}

@MainActor struct FileReferencePicker: View {
    @ObservedObject var store: AppStore
    var asPage = false
    @Environment(\.dismiss) private var dismiss
    @ViewState private var search = ""
    @ViewState private var importing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(asPage ? "引用文件为子页面" : "引用项目中的文件").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            TextField("搜索文件名或来源页面", text: $search).textFieldStyle(.roundedBorder)
            List(store.referenceChoices.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { choice in
                Button {
                    store.addReference(choice, asPage: asPage); dismiss()
                } label: {
                    HStack { FileTypeBadge(block: choice.block); Text(choice.title).lineLimit(2).truncationMode(.head); Spacer(); Image(systemName: "link") }
                }.buttonStyle(.plain).padding(.vertical, 5)
            }
            Button("选择资料库文件夹中的其他文件…") { chooseFile() }
            Text("引用共用同一份文件，编辑内容会同步到所有引用位置。每个位置的批注单独保存。").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 500, idealWidth: 680, minHeight: 420)
            .fileImporter(isPresented: $importing, allowedContentTypes: AttachmentFormat.importTypes) { result in
                if case .success(let url) = result { store.referenceFile(url, asPage: asPage); dismiss() }
            }
    }
    private func chooseFile() {
        #if os(macOS)
        let panel = NSOpenPanel(); panel.allowedContentTypes = AttachmentFormat.importTypes; panel.directoryURL = store.repository.root
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { store.referenceFile(url, asPage: asPage); dismiss() }
        #else
        importing = true
        #endif
    }
}
