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
    func indexedBlock(at url: URL) throws -> Block {
        let path = try FileIndexPolicy.path(for: url, inside: repository.root)
        // Register an existing cloud placeholder without reading its bytes. The
        // normal preview validates the document after an explicit download.
        let availability = try ICloudFileSnapshot.read(url)
        let deferredValidation = availability.ubiquitous && !availability.local
        let kind: BlockKind
        if url.pathExtension.lowercased() == "pdf" {
            if !deferredValidation {
                guard let pdf = PDFDocument(url: url), pdf.pageCount > 0, !pdf.isLocked else { throw StoreError.corrupt }
            }
            kind = .pdf
        } else if let format = AttachmentFormat(filename: url.lastPathComponent) {
            if !deferredValidation {
                if format == .image { try AttachmentImage.validate(at: url) }
                if format == .notebook { _ = try NotebookDocument(data: Data(contentsOf: url)) }
            }
            kind = .file
        } else { throw NSError(domain: "FileIndex", code: 1, userInfo: [NSLocalizedDescriptionKey: "暂不支持这个文件类型。"]) }
        var block = Block(kind, frame: Rect(28, 28, 380, 500))
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
                    blocks[i].reference = sameRoot ? original.reference ?? FileReference(noteID: item.noteID, blockID: original.id) : nil
                }
            }
            return try appendClipboardBlocks(blocks, anchors: item.anchors, at: point)
        } catch { message = error.localizedDescription; return false }
    }
    @discardableResult func appendClipboardBlocks(_ incoming: [Block], anchors: [AnnotationAnchor] = [], at point: CGPoint? = nil, noteID: UUID? = nil) throws -> Bool {
        guard let noteID = noteID ?? selection, let index = workspace.notes.firstIndex(where: { $0.id == noteID && !$0.deleted && !$0.isFolder }), !incoming.isEmpty else { return false }
        if selection == noteID { finishBlockEditing() }
        guard saveEditors() else { return false }
        let previous = workspace.notes[index]; var next = previous
        guard incoming.allSatisfy({ $0.frame.x.isFinite && $0.frame.y.isFinite && $0.frame.width.isFinite && $0.frame.height.isFinite && $0.frame.width > 0 && $0.frame.height > 0 }) else { throw StoreError.corrupt }
        let minX = incoming.map(\.frame.x).min()!, minY = incoming.map(\.frame.y).min()!
        let width = incoming.map(\.frame.maxX).max()! - minX, height = incoming.map(\.frame.maxY).max()! - minY
        let desired = Rect(max(0,point?.x ?? 28), max(0,point?.y ?? 28), width, height)
        var frame = CanvasLayout.vacant(desired, paper: next.paper, occupied: next.blocks.map(\.visibleFrame), canvasWidth: next.width)
        if frame == nil && !next.paper.isContinuous {
            next.paper = next.width > 794 ? .wideContinuous : .continuous
            frame = CanvasLayout.vacant(desired, paper: next.paper, occupied: next.blocks.map(\.visibleFrame), canvasWidth: next.width)
        }
        guard let frame else { message = "页面宽度不足，无法保留这些内容块的完整尺寸。"; return false }
        guard Set(incoming.map(\.id)).count == incoming.count else { throw StoreError.corrupt }
        let ids = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id,UUID()) })
        let keptAnchors = anchors.filter { ids[$0.ownerID] != nil }
        let anchorIDs = Dictionary(keptAnchors.map { ($0.id,UUID()) }, uniquingKeysWith: { first,_ in first })
        let copies = incoming.map { original -> Block in
            var copy = original; copy.id = ids[original.id]!
            copy.frame.x += frame.x - minX; copy.frame.y += frame.y - minY
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
    @discardableResult func pasteReference() -> Bool {
        #if os(macOS)
        let data = NSPasteboard.general.data(forType: .init("app.libere.canvas-blocks")) ?? NSPasteboard.general.data(forType: .init("app.marginnotes.block-reference"))
        #else
        let data = UIPasteboard.general.data(forPasteboardType: "app.libere.canvas-blocks") ?? UIPasteboard.general.data(forPasteboardType: "app.marginnotes.block-reference")
        #endif
        guard let data else { return false }
        _ = pasteBlocks(data); return true
    }
    @discardableResult func smartPaste(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        if WebLink.url(value) != nil { insertLink(value, mode: .card); return true }
        let file: URL?
        if value.hasPrefix("file://"), let url = URL(string:value), url.isFileURL { file = url }
        else if value.hasPrefix("/") || value.hasPrefix("~/") {
            let candidate = URL(fileURLWithPath:(value as NSString).expandingTildeInPath)
            file = ReferencePath.relative(candidate, inside: repository.root) != nil || FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }
        else { file = nil }
        if let file { _ = referenceFile(file); return true }
        do { return try appendClipboardBlocks([Block(.text,frame:Rect(0,0,360,216),text:text)]) }
        catch { message = error.localizedDescription; return true }
    }
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
        if NSApp.keyWindow?.firstResponder is NSTextView || webEditorFocused {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil); return
        }
        #else
        if let responder = currentTextResponder { UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.paste(_:)), to: responder, from: nil, for: nil); return }
        #endif
        if pasteReference() { return }
        #if os(macOS)
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly:true]) as? [URL], !urls.isEmpty {
            _ = indexFileURLs(urls); return
        }
        if let text = NSPasteboard.general.string(forType: .string), smartPaste(text) { return }
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        #else
        if let url = UIPasteboard.general.url, url.isFileURL { _ = indexFileURLs([url]); return }
        if let text = UIPasteboard.general.string { _ = smartPaste(text) }
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
