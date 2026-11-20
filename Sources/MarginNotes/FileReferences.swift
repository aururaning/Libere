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
private struct BlockClipboard: Codable { let root: String; let source: FileReference; let block: Block }

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
        let kind: BlockKind
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: url), pdf.pageCount > 0, !pdf.isLocked else { throw StoreError.corrupt }
            kind = .pdf
        } else if let format = AttachmentFormat(filename: url.lastPathComponent) {
            if format == .image { try AttachmentImage.validate(at: url) }
            if format == .notebook { _ = try NotebookDocument(data: Data(contentsOf: url)) }
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
    func copySelectedBlock() {
        guard let block, block.isFilePlugin, let noteID = selection,
              let data = try? JSONEncoder().encode(BlockClipboard(root: repository.root.path, source: FileReference(noteID: noteID, blockID: block.id), block: block)) else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .init("app.marginnotes.block-reference"))
        NSPasteboard.general.setString(block.linkURL ?? block.assetName, forType: .string)
        #else
        UIPasteboard.general.setItems([["app.marginnotes.block-reference": data, UTType.utf8PlainText.identifier: block.linkURL ?? block.assetName]])
        #endif
    }
    @discardableResult func pasteReference() -> Bool {
        #if os(macOS)
        let data = NSPasteboard.general.data(forType: .init("app.marginnotes.block-reference"))
        #else
        let data = UIPasteboard.general.data(forPasteboardType: "app.marginnotes.block-reference")
        #endif
        guard let data, let item = try? JSONDecoder().decode(BlockClipboard.self, from: data) else { return false }
        if let current = workspace.notes.first(where: { $0.id == item.source.noteID })?.blocks.first(where: { $0.id == item.source.blockID }) {
            appendReference(current, source: item.source, asPage: false)
        } else if item.root == repository.root.path {
            appendReference(item.block, source: item.source, asPage: false)
        } else { message = "这份引用来自另一个资料库，请在原资料库中粘贴，请先把原文件手动放入当前资料库再建立索引。" }
        return true
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
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
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
        if blockKeyboardFocus, let block, block.isFilePlugin { copySelectedBlock(); deleteBlock(block.id) }
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
