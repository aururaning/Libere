import SwiftUI
import Combine
#if SWIFT_PACKAGE
import MarginCore
#endif

@MainActor final class TextFileSession: ObservableObject {
    @Published var document: EditableText
    @Published var status = "已保存"
    private var saved: Data
    private let write: (Data) throws -> Void
    private var saveTask: Task<Void, Never>?
    init(data: Data, save: @escaping (Data) throws -> Void) throws {
        document = try EditableText(data: data); saved = data; write = save
    }
    func edit(_ text: String) {
        document.text = text; status = "正在保存…"; saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled { self?.save() }
        }
    }
    @discardableResult func save() -> Bool {
        saveTask?.cancel()
        do {
            let data = try document.serialized()
            if data != saved { try write(data); saved = data }
            status = "已保存"; return true
        } catch { status = "保存失败：" + error.localizedDescription; return false }
    }
}

@MainActor struct TextFileEditor: View {
    @ObservedObject var session: TextFileSession
    let filename: String
    var formatting: TextFormatting? = nil
    var focus: () -> Void = {}
    @ViewState private var exporting = false
    @ViewState private var export: AttachmentExport?
    var body: some View {
        VStack(spacing: 0) {
            SourceEditor(text: Binding(get: { session.document.text }, set: { session.edit($0) }), externalFormatting: formatting, focus: focus).padding(6)
            HStack {
                Text(session.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("导出修改稿") { if let data = try? session.document.serialized() { export = AttachmentExport(data); exporting = true } }
            }.font(.caption).padding(8)
        }.onDisappear { session.save() }
            .fileExporter(isPresented: $exporting, document: export, contentType: .data, defaultFilename: filename) { result in
                if case .failure(let error) = result { session.status = error.localizedDescription }
            }
    }
}

/// Plain source input shares the tested IME/undo path and disables typographic substitutions.
@MainActor struct SourceEditor: View {
    @Binding var text: String
    var externalFormatting: TextFormatting? = nil
    var focus: () -> Void = {}
    @StateObject private var formatting = TextFormatting()
    @ViewState private var identifier = UUID()
    private var block: Block {
        var block = Block(.text, frame: Rect(0,0,380,240), text: text); block.id = identifier; block.fontSize = 14; return block
    }
    var body: some View {
        RichTextEditor(block: block, formatting: externalFormatting ?? formatting, focus: focus, checkpoint: {}) { _, value in text = value }
    }
}

@MainActor struct FileBlockContent: View {
    @ObservedObject var store: AppStore
    let noteID: UUID
    let block: Block
    private var editing: Bool { store.editingBlockID == block.id }
    private var isImage: Bool { AttachmentFormat(filename: block.assetName) == .image }
    @ViewState private var text: TextFileSession?
    @ViewState private var notebook: NotebookSession?
    var body: some View {
        VStack(spacing: 0) {
            if !isImage {
                HStack {
                    Spacer()
                    Button(editing ? "预览" : "编辑") {
                        if editing { store.selectBlock(block.id) }
                        else { prepare(); store.beginBlockEditing(block.id) }
                    }.buttonStyle(.plain).font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
                }
            }
            if editing && store.tool != .ink && !isImage {
                if let notebook { NotebookEditor(session: notebook, filename: block.assetName, compact: true, focus: focus) }
                else if let text { TextFileEditor(session: text, filename: block.assetName, formatting: AttachmentFormat(filename: block.assetName) == .markdown ? store.formatting : nil, focus: focus) }
            } else {
                AttachmentSurface(store: store, noteID: noteID, block: block, page: 0, inkEnabled: store.tool == .ink, resolutionScale: store.zoom)
            }
        }.onChange(of: editing) { _, active in
            if active { prepare() } else { text?.save(); notebook?.save() }
        }
        .onAppear { if editing { prepare() } }
    }
    private func prepare() {
        guard !isImage else { return }
        do {
            if AttachmentFormat(filename: block.assetName) == .notebook { notebook = try store.notebookSession(noteID: noteID, blockID: block.id) }
            else if AttachmentFormat(filename: block.assetName)?.isTextEditable == true { text = try store.textFileSession(noteID: noteID, blockID: block.id) }
        } catch { store.message = error.localizedDescription }
    }
    private func focus() { store.beginBlockEditing(block.id) }
}
