import SwiftUI
import Combine
import PDFKit
#if SWIFT_PACKAGE
import MarginCore
#endif

enum EditorTool: String, CaseIterable {
    case select, text, ink, anchor
    var title: String { switch self { case .select: return "选择"; case .text: return "文字"; case .ink: return "手写"; case .anchor: return "批注" } }
    var icon: String { switch self { case .select: return "cursorarrow"; case .text: return "textformat"; case .ink: return "pencil.tip"; case .anchor: return "text.bubble" } }
}
@MainActor final class AppStore: ObservableObject {
    @Published var workspace: Workspace
    @Published var selection: UUID? {
        willSet {
            if newValue != selection {
                if let id = folderOverviewEditingID { finishFolderOverviewEditing(noteID: id) }
                canvasPointer.cancel(); finishBlockEditing(); draggingBlockID = nil
            }
        }
    }
    @Published var blockSelection: UUID? {
        willSet {
            if newValue != blockSelection { canvasPointer.cancel() }
            if let editingBlockID, newValue != editingBlockID { finishBlockEditing() }
        }
        didSet { if blockSelection != formatting.blockID { formatting.clear() } }
    }
    @Published var editingBlockID: UUID?
    @Published var draggingBlockID: UUID?
    lazy var canvasPointer = CanvasPointerInteraction(store: self)
    var endingBlockEditing = false
    @Published var blockKeyboardFocus = false
    @Published var keyboardFocusRequest = UUID()
    @Published var tool = EditorTool.select {
        willSet { if newValue != tool { canvasPointer.cancel(); finishBlockEditing(); draggingBlockID = nil } }
    }
    @Published var inkOptions = InkOptions() {
        didSet { if let data = try? JSONEncoder().encode(inkOptions) { UserDefaults.standard.set(data, forKey: "MarginInkOptions") } }
    }
    @Published var zoom = 1.0
    @Published var fitToWidth = true
    @Published var expandedPages: Set<UUID> = []
    @Published var renaming: UUID?
    @Published var renameDraft = ""
    @Published var sidebarHasFocus = false
    @Published var draggingPageID: UUID?
    @Published var pageDropPlacement: PagePlacement?
    struct DeletionRequest: Identifiable { let id: UUID }
    @Published var deletionRequest: DeletionRequest?
    @Published var confirmSubtreeDeletion = true {
        didSet { preferences.set(confirmSubtreeDeletion, forKey:"LibereConfirmSubtreeDeletion") }
    }
    @Published var snap = true
    @Published var grid = true
    @Published var search = ""
    @Published var message: String?
    @Published var saveStatus = "已保存到本机"
    @Published var cloudStatus = "本地资料库"
    @Published var formulaEditor: Block?
    @Published var readerBlock: Block?
    @Published var fetchingLinks: Set<UUID> = []
    @Published var showTrash = false
    @Published var showcaseCatalog: ShowcaseCatalog?
    @Published private(set) var folderOverviewEditingID: UUID?
    private var folderOverviewCheckpointed = false
    private var finishingFolderOverview = false
    let repository: Repository
    let directories: WorkspaceDirectories
    private var notebookSessions: [String: NotebookSession] = [:]
    private var textSessions: [String: TextFileSession] = [:]
    private var referenceStamps: [String: String] = [:]
    let device: String
    let formatting = TextFormatting()
    var cloud: CloudSync?
    private var saveTask: Task<Void, Never>?
    private let preferences: UserDefaults
    private struct HistoryEntry: Codable {
        var notes: [Note]
        var selection: UUID?
        init(_ notes: [Note], selection: UUID?) { self.notes = notes; self.selection = selection }
        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let old = try? single.decode(Note.self) { self.init([old],selection:old.id); return }
            let c = try decoder.container(keyedBy:CodingKeys.self)
            self.init(try c.decode([Note].self,forKey:.notes),selection:try c.decodeIfPresent(UUID.self,forKey:.selection))
        }
        private enum CodingKeys: String, CodingKey { case notes, selection }
    }
    private var undoStack: [HistoryEntry] = []
    private var redoStack: [HistoryEntry] = []
    private struct History: Codable { var undo: [HistoryEntry]; var redo: [HistoryEntry] }
    private var historyURL: URL { repository.root.appendingPathComponent("History-" + device + ".json") }

    init(root: URL? = nil, preferences: UserDefaults = .standard) throws {
        self.preferences = preferences
        confirmSubtreeDeletion = preferences.object(forKey:"LibereConfirmSubtreeDeletion") as? Bool ?? true
        let args = ProcessInfo.processInfo.arguments
        let override = args.firstIndex(of: "--data-dir").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        let directory = root ?? override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MarginNotes")
        repository = try Repository(root: directory)
        directories = WorkspaceDirectories(repository: repository)
        if let data = UserDefaults.standard.data(forKey: "MarginInkOptions"), let options = try? JSONDecoder().decode(InkOptions.self, from: data) { inkOptions = options }
        device = UserDefaults.standard.string(forKey: "MarginDeviceID") ?? UUID().uuidString
        UserDefaults.standard.set(device, forKey: "MarginDeviceID")
        if let existing = try repository.load() { workspace = existing }
        else { workspace = Self.welcome(device); try repository.save(workspace) }
        if let data = try? Data(contentsOf: historyURL), let history = try? JSONDecoder().decode(History.self, from: data) {
            undoStack = Array(history.undo.suffix(50)); redoStack = Array(history.redo.suffix(50))
        }
        selection = workspace.notes.first { !$0.isFolder && !$0.deleted }?.id
        if let selection { expandAncestors(of: selection) }
        try directories.synchronize(workspace)
        refreshReferencedFiles()
    }
    var note: Note? { workspace.notes.first { $0.id == selection && !$0.deleted } }
    var block: Block? { note?.blocks.first { $0.id == blockSelection } }
    var canUndo: Bool { !undoStack.isEmpty }; var canRedo: Bool { !redoStack.isEmpty }
    func select(_ id: UUID) {
        if let folderID = folderOverviewEditingID, !finishFolderOverviewEditing(noteID: folderID) { return }
        finishBlockEditing()
        if renaming != nil && renaming != id { commitRename() }
        if selection != id { fitToWidth = true; zoom = 1 }
        selection = id; blockSelection = nil; blockKeyboardFocus = false; tool = .select; formatting.clear(); showTrash = false
        expandAncestors(of: id)
        refreshReferencedFiles()
    }
    func expandAncestors(of id: UUID) {
        var current = workspace.notes.first { $0.id == id }?.parentID, visited: Set<UUID> = []
        while let parent = current, visited.insert(parent).inserted {
            expandedPages.insert(parent); current = workspace.notes.first { $0.id == parent }?.parentID
        }
    }
    func beginRename(_ id: UUID) {
        if renaming != nil && renaming != id { commitRename() }
        guard let note = workspace.notes.first(where: { $0.id == id && !$0.deleted }) else { return }
        search = ""; selection = id; expandAncestors(of: id); renameDraft = note.title; renaming = id
    }
    func commitRename() {
        guard saveEditors() else { return }
        guard let id = renaming, let index = workspace.notes.firstIndex(where: { $0.id == id }) else { return }
        let value = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !value.isEmpty, value != workspace.notes[index].title else { return }
        var next = workspace; next.notes[index].title = value
        var changed: Set<UUID> = [id]
        for (order,sibling) in workspace.children(workspace.notes[index].parentID).enumerated() {
            if let i = next.notes.firstIndex(where:{ $0.id == sibling.id }), next.notes[i].sidebarOrder != order {
                next.notes[i].sidebarOrder = order; changed.insert(sibling.id)
            }
        }
        commitHierarchy(next,changed:changed,focus:id)
    }
    func cancelRename() { renaming = nil; renameDraft = "" }
    @discardableResult func beginFolderOverviewEditing(noteID: UUID) -> Bool {
        guard workspace.notes.contains(where: { $0.id == noteID && $0.isFolder && !$0.deleted }) else { return false }
        if folderOverviewEditingID == noteID { return true }
        if let current = folderOverviewEditingID, !finishFolderOverviewEditing(noteID: current) { return false }
        finishBlockEditing()
        blockSelection = nil; blockKeyboardFocus = false; sidebarHasFocus = false
        folderOverviewCheckpointed = false; folderOverviewEditingID = noteID
        return true
    }
    @discardableResult func updateFolderOverview(noteID: UUID, text: String) -> Bool {
        guard let index = workspace.notes.firstIndex(where: { $0.id == noteID && $0.isFolder && !$0.deleted }) else { return false }
        guard workspace.notes[index].folderOverview != text else { return true }
        if folderOverviewEditingID != noteID || !folderOverviewCheckpointed {
            checkpoint(InkDestination(noteID: noteID))
            if folderOverviewEditingID == noteID { folderOverviewCheckpointed = true }
        }
        workspace.notes[index].folderOverview = text
        workspace.notes[index].touch(device); dirty(noteID)
        return true
    }
    @discardableResult func finishFolderOverviewEditing(noteID: UUID) -> Bool {
        // A disappearing old view must not release a newer folder's editor.
        guard folderOverviewEditingID == noteID, !finishingFolderOverview else { return true }
        finishingFolderOverview = true
        defer { finishingFolderOverview = false }
        if formatting.blockID == noteID { finishBlockEditing() }
        guard saveEditors(), flush() else { return false }
        folderOverviewEditingID = nil; folderOverviewCheckpointed = false
        return true
    }
    func checkpoint() { guard let note else { return }; undoStack.append(HistoryEntry([note],selection:selection)); if undoStack.count > 50 { undoStack.removeFirst() }; redoStack = []; saveHistory() }
    func checkpoint(_ destination: InkDestination) {
        guard let note = workspace.notes.first(where: { $0.id == destination.noteID }) else { return }
        undoStack.append(HistoryEntry([note],selection:selection)); if undoStack.count > 50 { undoStack.removeFirst() }; redoStack = []; saveHistory()
    }
    private func saveHistory() {
        do { try Repository.writeAtomically(JSONEncoder().encode(History(undo: undoStack, redo: redoStack)), to: historyURL) }
        catch { message = "撤销记录未能保存：" + error.localizedDescription }
    }
    func saveInk(_ data: Data?, bounds: Rect?, to destination: InkDestination) {
        guard let index = workspace.notes.firstIndex(where: { $0.id == destination.noteID && !$0.deleted }) else { return }
        if let blockID = destination.blockID {
            guard let block = workspace.notes[index].blocks.firstIndex(where: { $0.id == blockID }) else { return }
            var pages = workspace.notes[index].blocks[block].pageAnnotations ?? [:]
            var annotations = pages[String(destination.page)] ?? AttachmentPageAnnotations()
            annotations.ink = data; annotations.inkBounds = bounds
            pages[String(destination.page)] = annotations
            workspace.notes[index].blocks[block].pageAnnotations = pages
        } else {
            workspace.notes[index].ink = data; workspace.notes[index].inkBounds = bounds
            workspace.notes[index].extendCanvasForContent()
        }
        workspace.notes[index].touch(device); dirty(destination.noteID)
        // A lifted pen is durable before navigation, backgrounding, or closing the window.
        flush()
    }
    func editPage(_ destination: InkDestination, _ change: (inout AttachmentPageAnnotations) -> Void) {
        guard let index = workspace.notes.firstIndex(where: { $0.id == destination.noteID && !$0.deleted }),
              let block = workspace.notes[index].blocks.firstIndex(where: { $0.id == destination.blockID }) else { return }
        var pages = workspace.notes[index].blocks[block].pageAnnotations ?? [:]
        var page = pages[String(destination.page)] ?? AttachmentPageAnnotations()
        change(&page); pages[String(destination.page)] = page
        workspace.notes[index].blocks[block].pageAnnotations = pages
        workspace.notes[index].touch(device); dirty(destination.noteID)
    }
    @discardableResult func insertPageText(at point: CGPoint, paper: CGSize, destination: InkDestination, clickCount: Int) -> UUID? {
        guard clickCount == 2, point.x.isFinite, point.y.isFinite, paper.width.isFinite, paper.height.isFinite,
              paper.width > 32, paper.height > 32, CGRect(origin: .zero, size: paper).contains(point),
              let note = workspace.notes.first(where: { $0.id == destination.noteID && !$0.deleted }),
              let block = note.blocks.first(where: { $0.id == destination.blockID }), block.kind.hasAttachment,
              !block.annotations(on: destination.page).texts.contains(where: { CanvasItemGeometry.contains($0.frame, x: point.x, y: point.y) }) else { return nil }
        let width = min(200.0, paper.width - 16), height = min(96.0, paper.height - 16)
        let frame = Rect(min(max(8, point.x), paper.width - width - 8), min(max(8, point.y), paper.height - height - 8), width, height)
        let text = PageTextAnnotation(frame: frame)
        checkpoint(destination); editPage(destination) { $0.texts.append(text) }
        return text.id
    }
    func pdfPageCount(for block: Block) -> Int {
        guard block.kind == .pdf, let url = attachmentURL(for: block),
              let document = PDFDocument(url: url), !document.isLocked else { return 0 }
        return document.pageCount
    }
    /// Commit input before the outgoing editor is destroyed, including editors with
    /// their own formatting state (source files and notebook cells).
    @discardableResult func prepareAttachmentNavigation() -> Bool {
        #if os(macOS)
        if let text = NSApp?.keyWindow?.firstResponder as? NSTextView {
            text.unmarkText(); text.didChangeText()
            text.window?.makeFirstResponder(nil)
        }
        #else
        if let text = currentTextResponder as? UITextView {
            text.unmarkText(); text.delegate?.textViewDidChange?(text); text.resignFirstResponder()
        }
        #endif
        finishBlockEditing()
        return saveEditors() && flush()
    }
    @discardableResult func turnPDFPage(noteID: UUID, blockID: UUID, by delta: Int) -> Bool {
        guard let note = workspace.notes.firstIndex(where: { $0.id == noteID && !$0.deleted }),
              let index = workspace.notes[note].blocks.firstIndex(where: { $0.id == blockID }) else { return false }
        let block = workspace.notes[note].blocks[index]
        guard !block.locked,
              let next = AttachmentPagination(page: block.pdfPage, pageCount: pdfPageCount(for: block)).moved(by: delta),
              prepareAttachmentNavigation() else { return false }
        workspace.notes[note].blocks[index].pdfPage = next
        workspace.notes[note].touch(device); dirty(noteID)
        return flush()
    }
    func undo() {
        if let id = folderOverviewEditingID, !finishFolderOverviewEditing(noteID: id) { return }
        finishBlockEditing()
        guard saveEditors(), let previous = undoStack.popLast() else { return }
        let before = workspace
        redoStack.append(HistoryEntry(workspace.notes.filter { n in previous.notes.contains { $0.id == n.id } },selection:selection))
        for note in previous.notes { restoreVersion(note) }
        saveHistory(); flush(); relocateKernelDirectories(from:before,to:workspace); restoreSelection(previous.selection)
    }
    func redo() {
        if let id = folderOverviewEditingID, !finishFolderOverviewEditing(noteID: id) { return }
        finishBlockEditing()
        guard saveEditors(), let next = redoStack.popLast() else { return }
        let before = workspace
        undoStack.append(HistoryEntry(workspace.notes.filter { n in next.notes.contains { $0.id == n.id } },selection:selection))
        for note in next.notes { restoreVersion(note) }
        saveHistory(); flush(); relocateKernelDirectories(from:before,to:workspace); restoreSelection(next.selection)
    }
    private func restoreSelection(_ preferred: UUID?) {
        if let preferred, workspace.notes.contains(where: { $0.id == preferred && !$0.deleted }) { select(preferred) }
        else if let first = workspace.children(nil).first { select(first.id) }
        else { selection = nil; blockSelection = nil }
    }
    private func restoreVersion(_ value: Note) {
        guard let i = workspace.notes.firstIndex(where: { $0.id == value.id }) else { return }
        var copy = value; copy.version = value.version.joined(workspace.notes[i].version); copy.touch(device)
        // Layout undo must not roll a shared file back in only one of its reference locations.
        let files = workspace.notes.flatMap(\.blocks).filter(\.isFilePlugin)
        for index in copy.blocks.indices where copy.blocks[index].isFilePlugin {
            if let latest = files.first(where: { $0.fileIdentity == copy.blocks[index].fileIdentity }) {
                copy.blocks[index].workingAssetID = latest.workingAssetID
                copy.blocks[index].notebookAssetID = latest.notebookAssetID
                copy.blocks[index].contentRevision = latest.contentRevision
            }
        }
        workspace.notes[i] = copy; dirty(copy.id)
    }
    func edit(_ change: (inout Note) -> Void) {
        guard let i = workspace.notes.firstIndex(where: { $0.id == selection }) else { return }
        change(&workspace.notes[i]); workspace.notes[i].extendCanvasForContent()
        workspace.notes[i].touch(device); dirty(workspace.notes[i].id)
    }
    /// Called only for a viewport resize, page change, or explicit fit command — never scrolling.
    func fitCanvasToViewport(_ size: CGSize) {
        guard fitToWidth, size.width > 0, size.height > 0,
              let index = workspace.notes.firstIndex(where: { $0.id == selection }) else { return }
        var fitted = workspace.notes[index]
        fitted.fitCanvas(width: size.width, height: size.height)
        if fitted.canvasWidth != workspace.notes[index].canvasWidth || fitted.canvasHeight != workspace.notes[index].canvasHeight {
            fitted.touch(device); workspace.notes[index] = fitted; dirty(fitted.id)
        }
        let scale = min(6, max(0.25, size.width / fitted.width))
        if abs(zoom - scale) > 0.0001 { zoom = scale }
    }
    func finishCanvasZoom(_ scale: Double) {
        guard scale.isFinite else { return }
        if fitToWidth { fitToWidth = false }
        let value = min(6, max(0.25, scale))
        if abs(zoom - value) > 0.0001 { zoom = value }
    }
    func editBlock(_ id: UUID, _ change: (inout Block) -> Void) {
        edit { note in guard let i = note.blocks.firstIndex(where: { $0.id == id }) else { return }; change(&note.blocks[i]) }
    }
    func formatText(_ action: TextAction) {
        if let block, block.usesMarkdown {
            switch action {
            case .grow(let step):
                checkpoint(); editBlock(block.id) { $0.fontSize = min(96, max(10, $0.fontSize + step)) }; return
            case .font(let name):
                checkpoint(); editBlock(block.id) { $0.fontFamily = name }; return
            default: break
            }
        }
        formatting.apply(action)
    }
    private func dirty(_ id: UUID) {
        workspace.pending.insert("page_" + id.uuidString); saveStatus = "正在保存…"
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }; self?.flush()
        }
    }
    @discardableResult func flush() -> Bool {
        saveTask?.cancel()
        do { try repository.save(workspace); try directories.synchronize(workspace); saveStatus = "已保存到本机"; cloud?.enqueue(); return true }
        catch { saveStatus = "保存失败"; message = error.localizedDescription; return false }
    }
    func persistSync() throws { try repository.save(workspace) }
    func create(folder: Bool = false, parent: UUID? = nil) {
        var note = Note(title: folder ? "新文件夹" : "未命名笔记", parent: parent, folder: folder)
        if let first = workspace.children(parent).compactMap(\.sidebarOrder).min() { note.sidebarOrder = first > Int.min ? first - 1 : first }
        note.touch(device); workspace.notes.append(note); dirty(note.id); select(note.id)
        beginRename(note.id)
    }
    func move(_ id: UUID, to parent: UUID?) {
        placePage(id,at:.inside(parent))
    }
    @discardableResult func placePage(_ id: UUID, at placement: PagePlacement) -> Bool {
        guard saveEditors() else { return false }
        var next = workspace; let changed = next.place(id,at:placement)
        guard !changed.isEmpty else { return false }
        let success = commitHierarchy(next,changed:changed,focus:id)
        if success { search = ""; select(id); expandAncestors(of:id) }
        return success
    }
    func requestTrash(_ id: UUID) {
        guard renaming == nil, saveEditors() else { return }
        let ids = workspace.liveSubtree(id)
        guard !ids.isEmpty else { return }
        if ids.count > 1 && confirmSubtreeDeletion { deletionRequest = DeletionRequest(id:id) }
        else { trash(id) }
    }
    func confirmTrash(suppress: Bool) {
        guard let request = deletionRequest else { return }
        if trash(request.id), suppress { confirmSubtreeDeletion = false }
        deletionRequest = nil
    }
    @discardableResult func trash(_ id: UUID) -> Bool {
        guard saveEditors() else { return false }
        var next = workspace; let ids = next.trashSubtree(id)
        guard !ids.isEmpty else { return false }
        let target = workspace.notes.first { $0.id == id }
        let siblings = workspace.children(target?.parentID).filter { !ids.contains($0.id) }
        let fallback = siblings.first?.id ?? target?.parentID ?? next.children(nil).first?.id
        let focus = selection.map { ids.contains($0) ? fallback : $0 } ?? fallback
        return commitHierarchy(next,changed:ids,focus:focus)
    }
    func recover(_ id: UUID) {
        guard saveEditors() else { return }
        var next = workspace; let ids = next.recoverSubtree(id)
        if commitHierarchy(next,changed:ids,focus:id) { select(id) }
    }
    @discardableResult private func commitHierarchy(_ candidate: Workspace, changed: Set<UUID>, focus: UUID?) -> Bool {
        guard !changed.isEmpty else { return false }
        var next = candidate, changed = changed
        // App-owned page directories move on rename/reparent/trash. Keep cross-page
        // direct file references pointing at the moved file, using the longest path first.
        let before = workspace
        let relocations = directoryRelocations(from:before,to:next)
        for i in next.notes.indices {
            for b in next.notes[i].blocks.indices {
                if let path = next.notes[i].blocks[b].relativeFilePath,
                   let move = relocations.first(where:{ path.hasPrefix($0.0) }) {
                    next.notes[i].blocks[b].relativeFilePath = move.1 + path.dropFirst(move.0.count)
                    changed.insert(next.notes[i].id)
                }
            }
        }
        for i in next.notes.indices where changed.contains(next.notes[i].id) {
            next.notes[i].touch(device); next.pending.insert("page_" + next.notes[i].id.uuidString)
        }
        let previous = HistoryEntry(workspace.notes.filter { changed.contains($0.id) },selection:selection)
        do {
            try repository.save(next); saveTask?.cancel(); workspace = next
            undoStack.append(previous); undoStack = Array(undoStack.suffix(50)); redoStack = []; saveHistory()
            saveStatus = "已保存到本机"
            do { try directories.synchronize(workspace) } catch { message = "资料已保存，目录整理稍后重试：" + error.localizedDescription }
            relocateKernelDirectories(from:before,to:workspace); restoreSelection(focus)
            cloud?.enqueue(); return true
        } catch { message = error.localizedDescription; return false }
    }
    private func directoryRelocations(from old: Workspace, to next: Workspace) -> [(String,String)] {
        old.notes.compactMap { page -> (String,String)? in
            guard next.notes.contains(where:{ $0.id == page.id }),
                  let before = ReferencePath.relative(directories.directory(for:page.id,in:old),inside:repository.root),
                  let after = ReferencePath.relative(directories.directory(for:page.id,in:next),inside:repository.root), before != after else { return nil }
            return (before + "/",after + "/")
        }.sorted { $0.0.count > $1.0.count }
    }
    private func relocateKernelDirectories(from old: Workspace, to next: Workspace) {
        let relocations = directoryRelocations(from:old,to:next)
        for session in notebookSessions.values {
            guard let path = ReferencePath.relative(session.workingDirectory,inside:repository.root),
                  let move = relocations.first(where:{ (path + "/").hasPrefix($0.0) }) else { continue }
            session.workingDirectory = repository.root.appendingPathComponent(move.1 + (path + "/").dropFirst(move.0.count))
        }
    }
    func insert(_ kind: BlockKind, point: CGPoint? = nil, asset: UUID? = nil, name: String = "") {
        guard let note, !note.isFolder else { return }
        let size = Rect(Double(point?.x ?? 28), Double(point?.y ?? 28), kind.hasAttachment || kind == .link ? 380 : 360, kind.hasAttachment || kind == .link ? 500 : kind == .formula ? 140 : 216)
        guard let frame = CanvasLayout.vacant(size, paper: note.paper, occupied: note.blocks.map(\.frame), canvasWidth: note.width) else { message = "这一页空间不足。请切换纵向长页，或新建一页。"; return }
        checkpoint()
        var block = Block(kind, frame: frame, text: kind == .formula ? "\\int_0^1 x^2\\,dx=\\frac{1}{3}" : "")
        block.assetID = asset; block.assetName = name
        if block.isFilePlugin { block.fileID = asset ?? block.id }
        edit { $0.blocks.append(block) }; selectBlock(block.id)
        if kind == .text { beginBlockEditing(block.id) }
        if kind == .formula { formulaEditor = block }
    }
    func importFile(_ url: URL, collapsed: Bool = false) {
        let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let kind: BlockKind
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: url), pdf.pageCount > 0, !pdf.isLocked else { message = "无法读取 PDF，请检查文件或先解除密码。"; return }
            kind = .pdf
        } else {
            guard let format = AttachmentFormat(filename: url.lastPathComponent) else { message = "此文件格式暂不支持。"; return }
            if format == .image {
                do { try AttachmentImage.validate(at: url) }
                catch { message = error.localizedDescription; return }
            }
            kind = .file
        }
        do {
            let id = UUID(); let fingerprint = try repository.copyAsset(url, id: id)
            insert(kind, asset: id, name: url.lastPathComponent)
            if let block = note?.blocks.first(where: { $0.assetID == id }) {
                editBlock(block.id) { $0.assetSHA256 = fingerprint.sha256; $0.assetByteCount = fingerprint.bytes }
                if collapsed { toggleCollapsed(block.id) }
                workspace.pending.insert("asset_" + id.uuidString); flush()
            }
            else { try? FileManager.default.removeItem(at: repository.asset(id)) }
        } catch { message = error.localizedDescription }
    }
    func deleteBlock(_ id: UUID) {
        finishBlockEditing()
        checkpoint(); edit { note in
            let anchors = Set(note.anchors.filter { $0.ownerID == id }.map(\.id))
            note.blocks.removeAll { $0.id == id }; note.anchors.removeAll { $0.ownerID == id }
            for i in note.blocks.indices where anchors.contains(note.blocks[i].anchorID ?? UUID()) { note.blocks[i].anchorID = nil }
        }; blockSelection = nil; blockKeyboardFocus = false; formatting.clear(); flush()
    }
    func deleteSelectedBlock() { if blockKeyboardFocus, editingBlockID == nil, let id = blockSelection { deleteBlock(id) } }
    func undoFocused() {
        #if os(macOS)
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.undoManager?.undo(); return }
        if webEditorFocused { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil); return }
        #else
        if let responder = currentTextResponder { responder.undoManager?.undo(); return }
        #endif
        undo()
    }
    func redoFocused() {
        #if os(macOS)
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.undoManager?.redo(); return }
        if webEditorFocused { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil); return }
        #else
        if let responder = currentTextResponder { responder.undoManager?.redo(); return }
        #endif
        redo()
    }
    func setFrame(_ id: UUID, _ proposed: Rect, resizing: Bool = false) {
        guard let note, let old = note.blocks.first(where: { $0.id == id }), !old.locked else { return }
        var desired = proposed
        if old.isFilePlugin && old.collapsed == true { desired.height = Block.collapsedHeight }
        var frame = CanvasLayout.clamp(desired, to: note.paper, grid: snap && old.kind == .text, canvasWidth: note.width, minimumHeight: old.collapsed == true ? Block.collapsedHeight : 80)
        var anchor: AnnotationAnchor?
        if old.kind == .text {
            if resizing { anchor = note.anchors.first { $0.id == old.anchorID } }
            else if snap { anchor = CanvasLayout.nearest(to: proposed, note: note, excluding: id, tolerance: 20 / zoom, ignoring: old.anchorID) }
            if let a = anchor, let target = CanvasLayout.anchored(frame, at: a, blocks: note.blocks) { frame = target }
        }
        guard let blocks = CanvasLayout.placing(id, frame: frame, anchor: anchor, in: note) else {
            message = "请为整个批注分支留出空间，或先解锁、解除关联。"; return
        }
        checkpoint(); edit { $0.blocks = blocks }
    }
    func addAnchor(_ p: CGPoint) {
        guard let note, let owner = block else { message = "先选中一个内容块，再放置批注点。"; return }
        checkpoint()
        let a = AnnotationAnchor(ownerID: owner.id, label: "批注 \(note.anchors.filter { $0.ownerID == owner.id }.count + 1)",
                                 u: (p.x - owner.frame.x) / owner.frame.width, v: (p.y - owner.frame.y) / owner.frame.height,
                                 edge: p.x < owner.frame.x ? .trailing : .leading)
        edit { $0.anchors.append(a) }; selectBlock(owner.id)
    }
    func annotate(_ anchor: AnnotationAnchor) {
        finishBlockEditing()
        guard let note else { return }
        if let block = note.blocks.first(where: { $0.anchorID == anchor.id }) { beginBlockEditing(block.id); return }
        guard let desired = CanvasLayout.anchored(Rect(0, 0, 220, 150), at: anchor, blocks: note.blocks),
              let owner = note.blocks.first(where: { $0.id == anchor.ownerID }) else { return }
        var paper = note.paper
        var available = CanvasLayout.nearestVacant(desired, paper: paper, occupied: note.blocks.map(\.frame), canvasWidth: note.width)
        if available == nil {
            paper = paper.width > 794 ? .wideContinuous : .continuous
            available = CanvasLayout.nearestVacant(desired, paper: paper, occupied: note.blocks.map(\.frame), canvasWidth: note.width)
        }
        guard let frame = available else { return }
        var adjusted = anchor
        adjusted.u = (frame.x + (anchor.edge == .trailing ? frame.width : 0) - owner.frame.x) / owner.frame.width
        adjusted.v = (frame.y - owner.frame.y) / owner.frame.height
        var block = Block(.text, frame: frame); block.tint = "blue"; block.anchorID = anchor.id
        checkpoint(); edit {
            $0.paper = paper; $0.blocks.append(block)
            if let i = $0.anchors.firstIndex(where: { $0.id == anchor.id }) { $0.anchors[i] = adjusted }
            else { $0.anchors.append(adjusted) }
        }; beginBlockEditing(block.id)
    }
    func changeAnchor(_ id: UUID, edge: AnchorEdge) {
        guard var updated = note, let i = updated.anchors.firstIndex(where: { $0.id == id }) else { return }
        updated.anchors[i].edge = edge
        let anchor = updated.anchors[i]
        if let child = updated.blocks.first(where: { $0.anchorID == id }) {
            guard let frame = CanvasLayout.anchored(child.frame, at: anchor, blocks: updated.blocks),
                  let blocks = CanvasLayout.placing(child.id, frame: frame, anchor: anchor, in: updated) else {
                message = "请为整个批注分支留出空间，或先解锁、解除关联。"; return
            }
            updated.blocks = blocks
        }
        checkpoint(); edit { $0.anchors = updated.anchors; $0.blocks = updated.blocks }
    }
    func removeAnchor(_ id: UUID) {
        checkpoint(); edit { note in note.anchors.removeAll { $0.id == id }
            for i in note.blocks.indices where note.blocks[i].anchorID == id { note.blocks[i].anchorID = nil }
        }
    }
    func changePaper(_ paper: PaperKind) {
        guard let note else { return }
        guard note.blocks.allSatisfy({ CanvasLayout.fits($0.frame, paper: paper, canvasWidth: paper.isContinuous ? note.width : nil) }),
              (note.inkBounds?.maxX ?? 0) <= (paper.isContinuous ? note.width : paper.width),
              paper.isContinuous || (note.inkBounds?.maxY ?? 0) <= paper.height else { message = "现有内容超出目标纸张，请先调整内容，避免裁切。"; return }
        checkpoint(); edit { $0.paper = paper }
    }
    func arrange() {
        guard let note, let blocks = CanvasLayout.rearranged(note) else { message = "已有手写、批注点、锁定内容或纸张空间不足时，请手动调整，保留批注位置。"; return }
        checkpoint(); edit { $0.blocks = blocks }
    }
    func enableCloud() { if cloud == nil { cloud = CloudSync(store: self) }; cloud?.start() }

    func notebookSession(noteID: UUID, blockID: UUID) throws -> NotebookSession {
        guard let note = workspace.notes.first(where: { $0.id == noteID }), let block = note.blocks.first(where: { $0.id == blockID }),
              AttachmentFormat(filename: block.assetName) == .notebook, let url = attachmentURL(for: block) else { throw StoreError.corrupt }
        let key = block.fileIdentity.uuidString
        if let existing = notebookSessions[key] { return existing }
        try directories.synchronize(workspace)
        let source = try Data(contentsOf: url)
        var expected = AssetFingerprint.sha256(source)
        let directory = block.relativeFilePath != nil ? url.deletingLastPathComponent() : directories.directory(for: block.reference?.noteID ?? noteID, in: workspace)
        let session = try NotebookSession(data: source, directory: directory) { [weak self] data in
            guard let self else { throw StoreError.corrupt }
            try self.saveWorkingFile(data, fileID: block.fileIdentity, expected: expected)
            expected = AssetFingerprint.sha256(data)
        }
        notebookSessions[key] = session; return session
    }
    func textFileSession(noteID: UUID, blockID: UUID) throws -> TextFileSession {
        guard let block = workspace.notes.first(where: { $0.id == noteID })?.blocks.first(where: { $0.id == blockID }),
              AttachmentFormat(filename: block.assetName)?.isTextEditable == true,
              let url = attachmentURL(for: block) else { throw StoreError.corrupt }
        let key = block.fileIdentity.uuidString
        if let existing = textSessions[key] { return existing }
        let source = try Data(contentsOf: url)
        var expected = AssetFingerprint.sha256(source)
        let session = try TextFileSession(data: source) { [weak self] data in
            guard let self else { throw StoreError.corrupt }
            try self.saveWorkingFile(data, fileID: block.fileIdentity, expected: expected)
            expected = AssetFingerprint.sha256(data)
        }
        textSessions[key] = session; return session
    }
    func saveWorkingFile(_ data: Data, fileID: UUID, expected: String) throws {
        guard let current = workspace.notes.flatMap(\.blocks).first(where: { $0.fileIdentity == fileID }), let url = attachmentURL(for: current) else { throw StoreError.corrupt }
        guard try AssetFingerprint.read(url).sha256 == expected else {
            let recovery = repository.root.appendingPathComponent("Recoveries", isDirectory: true)
            try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
            let filename = WorkspaceDirectories.safeName((current.assetName as NSString).deletingPathExtension) + "-" + AssetFingerprint.sha256(data).prefix(12) + "." + (current.assetName as NSString).pathExtension
            try Repository.writeAtomically(data, to: recovery.appendingPathComponent(filename))
            throw NSError(domain: "FileEdit", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件已在其他位置修改。本次编辑已另存到资料库的 Recoveries 文件夹，可导出修改稿后重新打开文件。"])
        }
        let snapshot = UUID(), revision = UUID()
        if current.relativeFilePath != nil { try Repository.writeAtomically(data, to: url) }
        else { try Repository.writeAtomically(data, to: repository.asset(snapshot)) }
        var updated = workspace
        for page in updated.notes.indices {
            var changed = false
            for index in updated.notes[page].blocks.indices where updated.notes[page].blocks[index].fileIdentity == fileID {
                if current.relativeFilePath == nil { updated.notes[page].blocks[index].workingAssetID = snapshot }
                updated.notes[page].blocks[index].contentRevision = revision; changed = true
            }
            if changed { updated.notes[page].touch(device); updated.pending.insert("page_" + updated.notes[page].id.uuidString) }
        }
        if current.relativeFilePath == nil { updated.pending.insert("asset_" + snapshot.uuidString) }
        try repository.save(updated); workspace = updated; saveStatus = "已保存到本机"; cloud?.enqueue()
        if let path = current.relativeFilePath { referenceStamps[path] = referenceStamp(url) }
        do { try directories.synchronize(updated) } catch { message = "文件已保存，工作目录整理未完成：" + error.localizedDescription }
    }
    private func referenceStamp(_ url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return "missing" }
        return "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0)"
    }
    func refreshReferencedFiles() {
        for path in Set(workspace.notes.flatMap(\.blocks).compactMap(\.relativeFilePath)) {
            guard let url = ReferencePath.resolve(path, inside: repository.root) else { continue }
            let stamp = referenceStamp(url), previous = referenceStamps.updateValue(stamp, forKey: path)
            guard let previous, previous != stamp else { continue }
            let revision = UUID()
            for page in workspace.notes.indices {
                var changed = false
                for index in workspace.notes[page].blocks.indices where workspace.notes[page].blocks[index].relativeFilePath == path {
                    let key = workspace.notes[page].blocks[index].fileIdentity.uuidString
                    textSessions.removeValue(forKey: key)
                    if let session = notebookSessions.removeValue(forKey: key) { session.stop(); session.status = "源文件已更新，请重新打开编辑器。" }
                    workspace.notes[page].blocks[index].contentRevision = revision; changed = true
                }
                if changed { workspace.notes[page].touch(device); dirty(workspace.notes[page].id) }
            }
        }
    }
    @discardableResult func saveEditors() -> Bool {
        var success = true
        for session in textSessions.values { if !session.save() { success = false } }
        for session in notebookSessions.values { if !session.save() { success = false } }
        if !success { saveStatus = "部分文件尚未保存" }
        return success
    }
    func stopKernels() { saveEditors(); for session in notebookSessions.values { session.stop() } }
    func toggleCollapsed(_ id: UUID) {
        guard saveEditors() else { return }
        guard let note, let block = note.blocks.first(where: { $0.id == id }), !block.locked else { return }
        let collapsing = block.collapsed != true
        let frame = CanvasLayout.clamp(Rect(block.frame.x, block.frame.y, block.frame.width, collapsing ? Block.collapsedHeight : (block.expandedHeight ?? 500)), to: note.paper, canvasWidth: note.width, minimumHeight: collapsing ? Block.collapsedHeight : 80)
        let anchor = note.anchors.first { $0.id == block.anchorID }
        guard let blocks = CanvasLayout.placing(id, frame: frame, anchor: anchor, in: note) else { return }
        checkpoint(); edit { note in
            note.blocks = blocks
            if let i = note.blocks.firstIndex(where: { $0.id == id }) {
                if collapsing { note.blocks[i].expandedHeight = block.frame.height }
                note.blocks[i].collapsed = collapsing
                if !collapsing {
                    // Array order is the persistent back-to-front order used by drawing
                    // and CanvasHitTesting. Reopening raises only this attachment.
                    let expanded = note.blocks.remove(at: i); note.blocks.append(expanded)
                }
            }
        }
        if !collapsing { selectBlock(id) }
    }

    /// The agent prepares a complete snapshot first. Publish only after durable saving.
    func commitAgentWorkspace(_ candidate: Workspace, previous: Note?) throws {
        saveTask?.cancel()
        try repository.save(candidate)
        workspace = candidate
        if let previous {
            undoStack.append(HistoryEntry([previous],selection:previous.id)); undoStack = Array(undoStack.suffix(50)); redoStack = []; saveHistory()
        }
        saveStatus = "已保存到本机"
        do { try directories.synchronize(workspace) }
        catch { message = "资料已保存，工作目录整理稍后重试：" + error.localizedDescription }
        cloud?.enqueue()
    }

    /// Add a self-contained example set without replacing any existing page. A single
    /// undo moves the entire added tree to Trash, and redo restores the same examples.
    func commitShowcase(_ catalog: ShowcaseCatalog) throws {
        finishBlockEditing()
        guard saveEditors() else { throw CocoaError(.fileWriteUnknown) }
        let before = selection
        var next = workspace, placeholders: [Note] = []
        for var note in catalog.backup.workspace.notes {
            guard !next.notes.contains(where: { $0.id == note.id }) else { throw ShowcaseCatalog.ContentError.collision }
            var deleted = note; deleted.deleted = true; deleted.trashBatchID = catalog.rootID
            placeholders.append(deleted)
            note.touch(device); next.notes.append(note); next.pending.insert("page_" + note.id.uuidString)
        }
        next.pending.formUnion(catalog.backup.assets.keys.map { "asset_" + $0 })
        try repository.save(next)
        saveTask?.cancel(); workspace = next
        undoStack.append(HistoryEntry(placeholders, selection: before)); undoStack = Array(undoStack.suffix(50))
        redoStack = []; saveHistory(); saveStatus = "已保存到本机"
        do { try directories.synchronize(workspace) }
        catch { message = "场景已保存，文件目录整理稍后重试：" + error.localizedDescription }
        select(catalog.rootID); expandedPages.insert(catalog.rootID); cloud?.enqueue()
    }

    private static func welcome(_ device: String) -> Workspace {
        var folder = Note(title: "我的知识库", folder: true)
        var note = Note(title: "让想法相遇", parent: folder.id)
        var title = Block(.text, frame: Rect(40, 44, 700, 150), text: "在这里，让想法相遇。\n一张纸，装下文字、公式、资料和手写。\n双击空白处开始记录，也可以先选择文字工具。"); title.fontSize = 23
        var intro = Block(.text, frame: Rect(40, 224, 330, 224), text: "**01 / 文字与公式**\n\n在同一文字框输入 Markdown：$e^{i\\pi}+1=0$。\n\n支持 **加粗**、==荧光标记==、引用与列表。点击编辑开始。"); intro.tint = "blue"
        var math = Block(.formula, frame: Rect(402, 224, 338, 150), text: "e^{i\\pi}+1=0"); math.fontSize = 28
        var ink = Block(.text, frame: Rect(402, 410, 338, 226), text: "02 / 留白给思考\n\niPad 上使用手写工具，在文字和资料之上自由批注。\n\n手写不参与吸附，也不自动重排。"); ink.quote = true; ink.tint = "gray"
        let anchor = Block(.text, frame: Rect(40, 488, 330, 252), text: "03 / 从一个想法展开\n\n选中任意内容块，点击「批注」，在附近直接写下分支。\n\n点击圆点继续编辑；右键内容块也可自定批注点的位置。")
        note.blocks = [title, intro, math, ink, anchor]; folder.touch(device); note.touch(device)
        var result = Workspace(notes: [folder, note]); result.pending = Set(result.notes.map { "page_" + $0.id.uuidString }); return result
    }
}
