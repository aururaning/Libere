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
                folderBlockSelection = nil
                let keep = Set(workspace.notes.first(where: { $0.id == newValue })?.blocks.map(\.fileIdentity) ?? [])
                linkSnapshots = linkSnapshots.filter { keep.contains($0.key) }
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
    @Published var folderBlockSelection: UUID?
    @Published var editingBlockID: UUID?
    @Published var interactingBlockID: UUID?
    @Published var draggingBlockID: UUID?
    lazy var canvasPointer = CanvasPointerInteraction(store: self)
    lazy var multiSelection = CanvasMultiSelection(store: self)
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
    struct PurgeRequest: Identifiable { let id = UUID(); let pageIDs: Set<UUID> }
    @Published var purgeRequest: PurgeRequest?
    @Published var movingPageID: UUID?
    @Published var confirmSubtreeDeletion = true {
        didSet { preferences.set(confirmSubtreeDeletion, forKey:"LibereConfirmSubtreeDeletion") }
    }
    @Published var snap = true
    @Published var grid = true
    @Published var search = ""
    @Published var showingQuickSearch = false
    @Published var revealBlockID: UUID?
    @Published var message: String?
    @Published var saveStatus = "已保存到本机"
    @Published var cloudStatus = "本地资料库"
    @Published var formulaEditor: Block?
    @Published var readerBlock: Block?
    @Published var readerInitialPage: Int?
    @Published var fetchingLinks: Set<UUID> = []
    @Published var linkSnapshots: [UUID: Data] = [:]
    @Published var showTrash = false
    @Published var showcaseCatalog: ShowcaseCatalog?
    @Published private(set) var folderOverviewEditingID: UUID?
    private var folderOverviewCheckpointed = false
    private var finishingFolderOverview = false
    let repository: Repository
    let isNewLibrary: Bool
    let directories: WorkspaceDirectories
    lazy var iCloudFiles = ICloudFiles(root: repository.root, preferences: preferences)
    lazy var clipboardPastes = ClipboardPasteCoordinator(store: self)
    lazy var clipboardMoves = ClipboardMoveCoordinator(store: self)
    private var notebookSessions: [String: NotebookSession] = [:]
    private var textSessions: [String: TextFileSession] = [:]
    private var referenceStamps: [String: String] = [:]
    let device: String
    let formatting = TextFormatting()
    var cloud: CloudSync?
    private var saveTask: Task<Void, Never>?
    private var persistedWorkspace: Workspace?
    private var persistedStamp: WorkspaceDiskStamp?
    private struct WorkspaceDiskStamp: Equatable {
        let modified: Date?
        let size: UInt64?
        let inode: UInt64?
    }
    private func diskStamp() -> WorkspaceDiskStamp? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: repository.workspaceURL.path) else { return nil }
        return WorkspaceDiskStamp(modified: values[.modificationDate] as? Date,
                                  size: (values[.size] as? NSNumber)?.uint64Value,
                                  inode: (values[.systemFileNumber] as? NSNumber)?.uint64Value)
    }
    func persistWorkspace(_ value: Workspace) throws {
        if value == persistedWorkspace, let stamp = persistedStamp, diskStamp() == stamp { return }
        try repository.save(value)
        persistedWorkspace = value; persistedStamp = diskStamp()
    }
    private let preferences: UserDefaults
    private var fontUndoGroup: (noteID: UUID, blockID: UUID, revision: UUID, range: NSRange?, date: Date)?
    fileprivate struct HistoryEntry: Codable, Sendable {
        var notes: [Note]
        var selection: UUID?
        var moveReceiptID: UUID?
        init(_ notes: [Note], selection: UUID?, moveReceiptID: UUID? = nil) {
            self.notes = notes; self.selection = selection; self.moveReceiptID = moveReceiptID
        }
        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let old = try? single.decode(Note.self) { self.init([old],selection:old.id); return }
            let c = try decoder.container(keyedBy:CodingKeys.self)
            self.init(try c.decode([Note].self,forKey:.notes),selection:try c.decodeIfPresent(UUID.self,forKey:.selection),
                      moveReceiptID:try c.decodeIfPresent(UUID.self,forKey:.moveReceiptID))
        }
        private enum CodingKeys: String, CodingKey { case notes, selection, moveReceiptID }
    }
    private var undoStack: [HistoryEntry] = []
    private var redoStack: [HistoryEntry] = []
    fileprivate struct History: Codable, Sendable { var undo: [HistoryEntry]; var redo: [HistoryEntry] }
    private var historyURL: URL { repository.root.appendingPathComponent("History-" + device + ".json") }

    struct StartupState: Sendable {
        let repository: Repository
        let workspace: Workspace?
        let directoryIndex: WorkspaceDirectories.Index
        let device: String
        fileprivate let history: History?
        let referenceStamps: [String: String]
        let needsMigration: Bool
    }
    static func deviceIdentifier() -> String {
        if let saved = UserDefaults.standard.string(forKey: "MarginDeviceID") { return saved }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: "MarginDeviceID")
        return value
    }
    /// This is intentionally nonisolated: large JSON decoding and file metadata
    /// reads must finish outside the UI actor before the observable store exists.
    nonisolated static func prepareStartup(root: URL, device: String) throws -> StartupState {
        let repository = try Repository(root: root)
        var workspace = try repository.load()
        try FileHierarchyTransaction.recover(at: root, workspace: workspace)
        let index = WorkspaceDirectories.loadIndex(at: root)
        var needsMigration = false
        if var existing = workspace {
            needsMigration = WorkspaceDirectories(repository: repository, index: index).migrate(&existing)
            workspace = existing
        }
        let historyURL = root.appendingPathComponent("History-" + device + ".json")
        let history = (try? Data(contentsOf: historyURL)).flatMap { try? JSONDecoder().decode(History.self, from: $0) }
        let initial = workspace?.notes.first { !$0.isFolder && !$0.deleted }
        var stamps: [String: String] = [:]
        for path in Set(initial?.blocks.compactMap(\.relativeFilePath) ?? []) {
            if let url = ReferencePath.resolve(path, inside: root) { stamps[path] = referenceStamp(url) }
        }
        return StartupState(repository: repository, workspace: workspace, directoryIndex: index,
                            device: device, history: history, referenceStamps: stamps, needsMigration: needsMigration)
    }

    init(root: URL? = nil, preferences: UserDefaults = .standard, prepared: StartupState? = nil) throws {
        self.preferences = preferences
        confirmSubtreeDeletion = preferences.object(forKey:"LibereConfirmSubtreeDeletion") as? Bool ?? true
        let args = ProcessInfo.processInfo.arguments
        let override = args.firstIndex(of: "--data-dir").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        let directory = root ?? override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MarginNotes")
        let loaded = try prepared ?? Self.prepareStartup(root: directory, device: Self.deviceIdentifier())
        guard loaded.repository.root.standardizedFileURL == directory.standardizedFileURL else { throw StoreError.corrupt }
        isNewLibrary = loaded.workspace == nil
        repository = loaded.repository
        directories = WorkspaceDirectories(repository: repository, index: loaded.directoryIndex)
        if let data = UserDefaults.standard.data(forKey: "MarginInkOptions"), let options = try? JSONDecoder().decode(InkOptions.self, from: data) { inkOptions = options }
        device = loaded.device
        if let existing = loaded.workspace {
            workspace = existing
            // A canceled background load never writes its migration. Commit only
            // after Bootstrap adopts this prepared library on the main actor.
            if loaded.needsMigration { try persistWorkspace(existing) }
        }
        else { workspace = Self.welcome(device); try persistWorkspace(workspace) }
        workspace.enforcePurges()
        if let history = loaded.history {
            undoStack = Array(history.undo.suffix(50)); redoStack = Array(history.redo.suffix(50))
        }
        discardPurgedHistory()
        selection = workspace.notes.first { !$0.isFolder && !$0.deleted }?.id
        if let selection { expandAncestors(of: selection) }
        referenceStamps = loaded.referenceStamps
        persistedWorkspace = workspace; persistedStamp = diskStamp()
        // Index-only libraries never rebuild working directories.
    }
    var note: Note? { workspace.notes.first { $0.id == selection && !$0.deleted } }
    var block: Block? { note?.blocks.first { $0.id == blockSelection } }
    var canUndo: Bool { !undoStack.isEmpty }; var canRedo: Bool { !redoStack.isEmpty }
    func select(_ id: UUID) {
        interactingBlockID = nil
        if let folderID = folderOverviewEditingID, !finishFolderOverviewEditing(noteID: folderID) { return }
        finishBlockEditing()
        if renaming != nil && renaming != id { commitRename() }
        if selection != id { fitToWidth = true; zoom = 1 }
        selection = id; blockSelection = nil; blockKeyboardFocus = false; tool = .select; formatting.clear(); showTrash = false
        expandAncestors(of: id)
        refreshReferencedFiles(noteID: id)
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
        guard let id = renaming else { return }
        if renamePage(id, to: renameDraft) { renaming = nil }
    }
    @discardableResult func renamePage(_ id: UUID, to draft: String) -> Bool {
        guard saveEditors(), let index = workspace.notes.firstIndex(where: { $0.id == id && !$0.deleted }) else { return false }
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { message = "页面名称不能为空。"; return false }
        guard value != workspace.notes[index].title else { return true }
        var next = workspace; next.notes[index].title = value
        var changed: Set<UUID> = [id]
        for (order,sibling) in workspace.children(workspace.notes[index].parentID).enumerated() {
            if let i = next.notes.firstIndex(where:{ $0.id == sibling.id }), next.notes[i].sidebarOrder != order {
                next.notes[i].sidebarOrder = order; changed.insert(sibling.id)
            }
        }
        return commitHierarchy(next, changed: changed, focus: selection)
    }
    func cancelRename() { renaming = nil; renameDraft = "" }
    func setTags(noteID: UUID, tags: [String]) {
        guard let i = workspace.notes.firstIndex(where: { $0.id == noteID && !$0.deleted }) else { return }
        var seen: Set<String> = []
        let cleaned = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard (workspace.notes[i].tags ?? []) != cleaned else { return }
        checkpoint(InkDestination(noteID: noteID)); workspace.notes[i].tags = cleaned
        workspace.notes[i].touch(device); dirty(noteID)
    }
    @discardableResult func beginFolderOverviewEditing(noteID: UUID) -> Bool {
        folderBlockSelection = noteID
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
    func checkpoint() { fontUndoGroup = nil; guard let note else { return }; undoStack.append(HistoryEntry([note],selection:selection)); if undoStack.count > 50 { undoStack.removeFirst() }; redoStack = []; saveHistory() }
    func checkpoint(_ destination: InkDestination) {
        fontUndoGroup = nil
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
              (try? iCloudFiles.requireLocal(url)) != nil,
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
        guard !clipboardMoves.isBusy else { message = "文件移动尚未完成，请稍后撤销。"; return }
        fontUndoGroup = nil; discardPurgedHistory()
        if let id = folderOverviewEditingID, !finishFolderOverviewEditing(noteID: id) { return }
        finishBlockEditing()
        guard saveEditors(), let previous = undoStack.last else { return }
        if let receipt = previous.moveReceiptID {
            clipboardMoves.reverse(ClipboardMoveHistoryPlan(receiptID: receipt, notes: previous.notes, selection: previous.selection, redo: false)); return
        }
        let before = workspace
        var next = workspace
        for note in previous.notes { if let i = next.notes.firstIndex(where: { $0.id == note.id }) { next.notes[i] = restoredVersion(note) } }
        do {
            let paths = Dictionary(previous.notes.flatMap(\.blocks).compactMap { block in block.relativeFilePath.map { (block.fileIdentity, $0) } }, uniquingKeysWith: { a, _ in a })
            let directories = Dictionary(previous.notes.compactMap { note in note.managedDirectoryPath.map { (note.id, $0) } }, uniquingKeysWith: { a, _ in a })
            let changed = try persistHierarchy(next, restoringFilePaths: paths, restoringDirectoryPaths: directories)
            undoStack.removeLast()
            redoStack.append(HistoryEntry(before.notes.filter { changed.contains($0.id) }, selection: selection))
            saveHistory(); restoreSelection(previous.selection)
        } catch { message = error.localizedDescription }
    }
    func redo() {
        guard !clipboardMoves.isBusy else { message = "文件移动尚未完成，请稍后重做。"; return }
        fontUndoGroup = nil; discardPurgedHistory()
        if let id = folderOverviewEditingID, !finishFolderOverviewEditing(noteID: id) { return }
        finishBlockEditing()
        guard saveEditors(), let entry = redoStack.last else { return }
        if let receipt = entry.moveReceiptID {
            clipboardMoves.reverse(ClipboardMoveHistoryPlan(receiptID: receipt, notes: entry.notes, selection: entry.selection, redo: true)); return
        }
        let before = workspace
        var next = workspace
        for note in entry.notes { if let i = next.notes.firstIndex(where: { $0.id == note.id }) { next.notes[i] = restoredVersion(note) } }
        do {
            let paths = Dictionary(entry.notes.flatMap(\.blocks).compactMap { block in block.relativeFilePath.map { (block.fileIdentity, $0) } }, uniquingKeysWith: { a, _ in a })
            let directories = Dictionary(entry.notes.compactMap { note in note.managedDirectoryPath.map { (note.id, $0) } }, uniquingKeysWith: { a, _ in a })
            let changed = try persistHierarchy(next, restoringFilePaths: paths, restoringDirectoryPaths: directories)
            redoStack.removeLast()
            undoStack.append(HistoryEntry(before.notes.filter { changed.contains($0.id) }, selection: selection))
            saveHistory(); restoreSelection(entry.selection)
        } catch { message = error.localizedDescription }
    }
    private func restoreSelection(_ preferred: UUID?) {
        if let preferred, workspace.notes.contains(where: { $0.id == preferred && !$0.deleted }) { select(preferred) }
        else if let first = workspace.children(nil).first { select(first.id) }
        else { selection = nil; blockSelection = nil }
    }
    private func restoredVersion(_ value: Note) -> Note {
        guard let i = workspace.notes.firstIndex(where: { $0.id == value.id }) else { return value }
        var copy = value; copy.blocks = copy.blocks.map(directories.indexed); copy.version = value.version.joined(workspace.notes[i].version); copy.touch(device)
        copy.managedFilePath = workspace.notes[i].managedFilePath
        copy.managedDirectoryPath = workspace.notes[i].managedDirectoryPath
        // Layout undo must not roll a shared file back in only one of its reference locations.
        let files = workspace.notes.flatMap(\.blocks).filter(\.isFilePlugin)
        for index in copy.blocks.indices where copy.blocks[index].isFilePlugin {
            if let latest = files.first(where: { $0.fileIdentity == copy.blocks[index].fileIdentity }) {
                copy.blocks[index].workingAssetID = latest.workingAssetID
                copy.blocks[index].notebookAssetID = latest.notebookAssetID
                copy.blocks[index].contentRevision = latest.contentRevision
                copy.blocks[index].relativeFilePath = latest.relativeFilePath
            }
        }
        return copy
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
    /// One font-panel event changes family and absolute size together. A continuous
    /// gesture coalesces only while this exact note revision remains our last edit.
    func applyFontPanel(family: String, size: Double, now: Date = Date()) {
        guard size.isFinite, let page = note, let block, block.kind == .text else { return }
        if formatting.view != nil, formatting.blockID != block.id { return }
        let size = min(96, max(10, size))
        let chosen = NativeFont(name: family, size: size) ?? NativeFont.systemFont(ofSize: size)
        let existingFont = NativeFont(name: block.fontFamily ?? "", size: block.fontSize) ?? NativeFont.systemFont(ofSize: block.fontSize)
        var changed = existingFont.fontName != chosen.fontName || abs(existingFont.pointSize - chosen.pointSize) > 0.001
        #if os(macOS)
        if !block.usesMarkdown {
            let source = formatting.view?.textStorage.map { NSAttributedString(attributedString: $0) }
                ?? block.rtf.flatMap { try? NSAttributedString(data: $0, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) }
            if let source, source.length > 0 {
                let selected = formatting.view?.selectedRange() ?? NSRange(location: 0, length: 0)
                let range = selected.length > 0 && NSMaxRange(selected) <= source.length ? selected : NSRange(location: 0, length: source.length)
                changed = false
                source.enumerateAttribute(.font, in: range) { value, _, stop in
                    let current = value as? NSFont ?? existingFont
                    if FontPanel.persistedFontName(current) != FontPanel.persistedFontName(chosen) || abs(current.pointSize - chosen.pointSize) > 0.001 { changed = true; stop.pointee = true }
                }
            } else if let current = formatting.view?.typingAttributes[.font] as? NSFont {
                changed = current.fontName != chosen.fontName || abs(current.pointSize - chosen.pointSize) > 0.001
            }
        }
        #endif
        guard changed else { return }
        #if os(macOS)
        let range = block.usesMarkdown ? nil : formatting.view?.selectedRange()
        #else
        let range = block.usesMarkdown ? nil : formatting.view?.selectedRange
        #endif
        let coalesces = fontUndoGroup.map { $0.noteID == page.id && $0.blockID == block.id && $0.revision == page.revision && $0.range == range && (0..<0.6).contains(now.timeIntervalSince($0.date)) } ?? false
        if !coalesces { checkpoint() }
        if block.usesMarkdown {
            editBlock(block.id) { $0.fontFamily = family; $0.fontSize = size }
        } else {
            let before = formatting.beforeChange; formatting.beforeChange = nil
            formatting.apply(.fontStyle(family, size)); formatting.beforeChange = before
            #if os(macOS)
            var data: Data?
            if formatting.view == nil {
                let source = block.rtf.flatMap { try? NSAttributedString(data: $0, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) }
                    ?? NSAttributedString(string: block.text)
                let text = NSMutableAttributedString(attributedString: source)
                text.addAttribute(.font, value: NSFont(name: family, size: size) ?? NSFont.systemFont(ofSize: size), range: NSRange(location: 0, length: text.length))
                data = try? text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            }
            editBlock(block.id) { $0.fontFamily = family; $0.fontSize = size; if let data { $0.rtf = data } }
            #else
            editBlock(block.id) { $0.fontFamily = family; $0.fontSize = size }
            #endif
        }
        if let revision = note?.revision { fontUndoGroup = (page.id, block.id, revision, range, now) }
    }
    /// A font's asynchronous height measurement belongs to the same undo gesture,
    /// but only if no independent edit changed the note in between.
    func continueFontPanelLayout(blockID: UUID, previousRevision: UUID) {
        guard var group = fontUndoGroup, group.noteID == selection, group.blockID == blockID,
              group.revision == previousRevision, let revision = note?.revision else { return }
        group.revision = revision; fontUndoGroup = group
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
        do { try persistWorkspace(workspace); saveStatus = "已保存到本机"; cloud?.enqueue(); return true }
        catch { saveStatus = "保存失败"; message = error.localizedDescription; return false }
    }
    func persistSync() throws { try persistWorkspace(workspace) }
    func create(folder: Bool = false, parent: UUID? = nil) {
        var note = Note(title: folder ? "新文件夹" : "未命名笔记", parent: parent, folder: folder)
        if let first = workspace.children(parent).compactMap(\.sidebarOrder).min() { note.sidebarOrder = first > Int.min ? first - 1 : first }
        let base = FileHierarchyTransaction.directoryPath(for: parent, in: workspace)
        let path = (base.isEmpty ? "" : base + "/") + WorkspaceDirectories.safeName(note.title) + "__" + note.id.uuidString.prefix(8)
        guard let directory = ReferencePath.resolve(path, inside: repository.root) else { message = FileIndexError.outsideLibrary.localizedDescription; return }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { message = error.localizedDescription; return }
        var ancestor = parent, visited: Set<UUID> = []
        while let id = ancestor, visited.insert(id).inserted, let i = workspace.notes.firstIndex(where: { $0.id == id }) {
            if workspace.notes[i].managedDirectoryPath != nil || workspace.notes[i].managedFilePath != nil { break }
            workspace.notes[i].managedDirectoryPath = FileHierarchyTransaction.directoryPath(for: id, in: workspace)
            workspace.notes[i].touch(device); workspace.pending.insert("page_" + id.uuidString)
            ancestor = workspace.notes[i].parentID
        }
        note.managedDirectoryPath = path
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
    func requestPurge(_ id: UUID? = nil) {
        let ids = id.map { workspace.descendants($0) } ?? Set(workspace.notes.filter(\.deleted).map(\.id))
        let deleted = Set(workspace.notes.filter { $0.deleted && ids.contains($0.id) }.map(\.id))
        if !deleted.isEmpty { purgeRequest = PurgeRequest(pageIDs: deleted) }
    }
    @discardableResult func confirmPurge() -> Bool {
        guard let request = purgeRequest else { return false }
        guard purgeTrashed(request.pageIDs) else { return false }
        purgeRequest = nil; return true
    }
    /// Only page/annotation metadata is removed. Indexed original files are never
    /// moved or deleted by this operation, including files owned by purged pages.
    @discardableResult func purgeTrashed(_ requested: Set<UUID>) -> Bool {
        guard saveEditors() else { return false }
        let removed = workspace.notes.filter { $0.deleted && requested.contains($0.id) }
        guard !removed.isEmpty else { return false }
        var next = workspace
        for var page in removed {
            page.touch(device)
            next.mergePurge(PurgedPage(note: page), enforce: false)
            next.pending.insert("page_" + page.id.uuidString)
        }
        next.enforcePurges()
        do {
            try persistWorkspace(next); saveTask?.cancel(); workspace = next
            fontUndoGroup = nil; discardPurgedHistory(); saveHistory()
            do { try purgeHistoricalRecords() }
            catch { message = "页面已清除，但部分旧撤销记录清理失败：" + error.localizedDescription }
            if selection.map(workspace.purgedPageIDs.contains) == true { selection = nil; blockSelection = nil }
            expandedPages.subtract(workspace.purgedPageIDs)
            if renaming.map(workspace.purgedPageIDs.contains) == true { cancelRename() }
            saveStatus = "已保存到本机"; cloud?.enqueue(); return true
        } catch { message = error.localizedDescription; return false }
    }
    func discardPurgedHistory(persist: Bool = false) {
        let purged = workspace.purgedPageIDs
        func filtered(_ entries: [HistoryEntry]) -> [HistoryEntry] {
            entries.compactMap { entry in
                var notes = entry.notes.filter { !purged.contains($0.id) }
                guard !notes.isEmpty else { return nil }
                for i in notes.indices where notes[i].parentID.map(purged.contains) == true { notes[i].parentID = nil }
                return HistoryEntry(notes, selection: entry.selection.flatMap { purged.contains($0) ? nil : $0 }, moveReceiptID: entry.moveReceiptID)
            }
        }
        undoStack = filtered(undoStack); redoStack = filtered(redoStack)
        if persist { saveHistory() }
    }
    private func purgeHistoricalRecords() throws {
        let purged = workspace.purgedPageIDs
        for url in try FileManager.default.contentsOfDirectory(at: repository.root, includingPropertiesForKeys: [.isRegularFileKey])
            where url.lastPathComponent.hasPrefix("History-") && url.pathExtension == "json" {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            var history = try JSONDecoder().decode(History.self, from: Data(contentsOf: url))
            func clean(_ entries: [HistoryEntry]) -> [HistoryEntry] {
                entries.compactMap { entry in
                    var notes = entry.notes.filter { !purged.contains($0.id) }
                    guard !notes.isEmpty else { return nil }
                    for i in notes.indices where notes[i].parentID.map(purged.contains) == true { notes[i].parentID = nil }
                    return HistoryEntry(notes, selection: entry.selection.flatMap { purged.contains($0) ? nil : $0 }, moveReceiptID: entry.moveReceiptID)
                }
            }
            history.undo = clean(history.undo); history.redo = clean(history.redo)
            try Repository.writeAtomically(JSONEncoder().encode(history), to: url)
        }
    }
    @discardableResult private func commitHierarchy(_ candidate: Workspace, changed: Set<UUID>, focus: UUID?) -> Bool {
        guard !clipboardMoves.isBusy else { message = "正在移动文件，请完成后再改名或调整层级。"; return false }
        guard !changed.isEmpty else { return false }
        let before = workspace, previousSelection = selection
        do {
            let affected = try persistHierarchy(candidate)
            undoStack.append(HistoryEntry(before.notes.filter { affected.contains($0.id) }, selection: previousSelection))
            undoStack = Array(undoStack.suffix(50)); redoStack = []; saveHistory()
            restoreSelection(focus); return true
        } catch { message = error.localizedDescription; return false }
    }
    /// Stage renames, save their index, then retire the path-only recovery journal.
    @discardableResult private func persistHierarchy(_ candidate: Workspace, restoringFilePaths: [UUID: String] = [:],
                                                    restoringDirectoryPaths: [UUID: String] = [:]) throws -> Set<UUID> {
        var next = candidate
        let transaction = try FileHierarchyTransaction.plan(from: workspace, to: &next, root: repository.root,
            restoringFilePaths: restoringFilePaths, restoringDirectoryPaths: restoringDirectoryPaths)
        let old = Dictionary(workspace.notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var changed: Set<UUID> = []
        for i in next.notes.indices where old[next.notes[i].id] != next.notes[i] {
            next.notes[i].touch(device); next.pending.insert("page_" + next.notes[i].id.uuidString); changed.insert(next.notes[i].id)
        }
        try transaction.execute(at: repository.root)
        do { try persistWorkspace(next) }
        catch {
            if transaction.hasChanges { try transaction.rollback(at: repository.root) }
            throw error
        }
        saveTask?.cancel(); workspace = next; saveStatus = "已保存到本机"
        if transaction.hasChanges {
            updateActiveFileLocations(transaction.relocated)
            do { try transaction.finish(at: repository.root) }
            catch { message = "文件与索引已保存，移动记录将在下次打开时清理。" }
        }
        cloud?.enqueue(); return changed
    }

    private func updateActiveFileLocations(_ relocated: (String) -> String) {
        for session in notebookSessions.values {
            if let path = ReferencePath.relative(session.workingDirectory, inside: repository.root) {
                session.workingDirectory = repository.root.appendingPathComponent(relocated(path))
            }
        }
        let current = Dictionary(workspace.notes.flatMap(\.blocks).filter(\.isFilePlugin).map { ($0.fileIdentity.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, session) in notebookSessions {
            if let block = current[id], let file = attachmentURL(for: block) { session.workingDirectory = file.deletingLastPathComponent() }
        }
        referenceStamps = Dictionary(referenceStamps.map { (relocated($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    func isCurrentMoveHistory(_ plan: ClipboardMoveHistoryPlan) -> Bool {
        (plan.redo ? redoStack.last : undoStack.last)?.moveReceiptID == plan.receiptID
    }
    func restoringClipboardHistory(_ plan: ClipboardMoveHistoryPlan) throws -> Workspace {
        guard isCurrentMoveHistory(plan) else { throw ClipboardMoveCoordinator.changedHistory }
        var next = workspace
        for note in plan.notes {
            if let index = next.notes.firstIndex(where: { $0.id == note.id }) {
                next.notes[index] = restoredVersion(note)
                next.notes[index].managedFilePath = note.managedFilePath
                next.notes[index].managedDirectoryPath = note.managedDirectoryPath
            }
        }
        return next
    }
    /// Sources cannot be removed until both the index and its undo receipt are
    /// durable. This also commits multi-page block moves as one history entry.
    func commitClipboardWorkspace(_ candidate: Workspace, receiptID: UUID? = nil,
                                  history plan: ClipboardMoveHistoryPlan? = nil,
                                  relocatedPaths: [String: String] = [:]) throws {
        if let plan, !isCurrentMoveHistory(plan) { throw ClipboardMoveCoordinator.changedHistory }
        let before = workspace, oldUndo = undoStack, oldRedo = redoStack
        var next = candidate
        if let receiptID { next.fileMoveTransactionID = receiptID }
        let originals = Dictionary(before.notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var snapshots: [Note] = []
        for i in next.notes.indices where originals[next.notes[i].id] != next.notes[i] {
            if let original = originals[next.notes[i].id] { snapshots.append(original) }
            else {
                var placeholder = next.notes[i]; placeholder.deleted = true; placeholder.deletedAt = Date(); placeholder.trashBatchID = UUID()
                snapshots.append(placeholder)
            }
            next.notes[i].touch(device); next.pending.insert("page_" + next.notes[i].id.uuidString)
        }
        guard !snapshots.isEmpty else { return }
        let reverse = HistoryEntry(snapshots, selection: selection, moveReceiptID: receiptID)
        if let plan {
            if plan.redo { redoStack.removeLast(); undoStack.append(reverse) }
            else { undoStack.removeLast(); redoStack.append(reverse) }
        } else { undoStack.append(reverse); undoStack = Array(undoStack.suffix(50)); redoStack = [] }
        do {
            try persistWorkspace(next)
            do { try Repository.writeAtomically(JSONEncoder().encode(History(undo: undoStack, redo: redoStack)), to: historyURL) }
            catch {
                // No source has been deleted. Restore the metadata if possible;
                // all installed transfer copies are retained for recovery.
                do { try persistWorkspace(before) }
                catch { workspace = next; saveStatus = "撤销记录未保存，原件已保留"; throw error }
                throw error
            }
        } catch { undoStack = oldUndo; redoStack = oldRedo; throw error }
        saveTask?.cancel(); workspace = next; saveStatus = "已保存到本机"
        updateActiveFileLocations { relocatedPaths[$0] ?? $0 }
        #if os(macOS)
        PDFWindow.shared.reconcileReaders(store: self)
        #endif
        cloud?.enqueue()
        if let plan { restoreSelection(plan.selection) }
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
        guard referenceFile(url) else { return }
        if collapsed, let id = blockSelection, block?.collapsed != true { toggleCollapsed(id) }
    }
    func deleteBlock(_ id: UUID) {
        guard let target = note?.blocks.first(where: { $0.id == id }) else { return }
        guard !target.locked else { message = "这个内容块已锁定，请先解锁再删除。"; return }
        finishBlockEditing()
        checkpoint(); edit { note in
            let anchors = Set(note.anchors.filter { $0.ownerID == id }.map(\.id))
            note.blocks.removeAll { $0.id == id }; note.anchors.removeAll { $0.ownerID == id }
            for i in note.blocks.indices where anchors.contains(note.blocks[i].anchorID ?? UUID()) { note.blocks[i].anchorID = nil }
        }; blockSelection = nil; blockKeyboardFocus = false; formatting.clear(); flush()
    }
    func deleteSelectedBlock() {
        guard blockKeyboardFocus, editingBlockID == nil else { return }
        if multiSelection.selectedIDs.count > 1 { multiSelection.delete() }
        else if let id = blockSelection { deleteBlock(id) }
    }
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
    func maintainICloudFiles() async {
        let dirty = Set(textSessions.filter { $0.value.hasUnsavedChanges }.keys)
            .union(notebookSessions.filter { $0.value.hasUnsavedChanges || $0.value.ready || $0.value.busy }.keys)
        let protectLibrary = notebookSessions.values.contains { ($0.ready || $0.busy) && $0.workingDirectory.standardizedFileURL == repository.root.standardizedFileURL }
        let runningDirectories = notebookSessions.values.filter { $0.ready || $0.busy }.compactMap {
            ReferencePath.relative($0.workingDirectory, inside: repository.root).map { $0 + "/" }
        }
        var indexed: Set<String> = [], protected: Set<String> = []
        for page in workspace.notes {
            for block in page.blocks {
                guard let path = block.relativeFilePath else { continue }
                indexed.insert(path)
                if protectLibrary || page.id == selection || dirty.contains(block.fileIdentity.uuidString) || runningDirectories.contains(where: { path.hasPrefix($0) }) {
                    protected.insert(path)
                }
            }
        }
        await iCloudFiles.maintain(indexedPaths: indexed, protectedPaths: protected, isProtected: { [weak self] path in
            guard let self else { return true }
            if self.note?.blocks.contains(where: { $0.relativeFilePath == path }) == true { return true }
            return self.notebookSessions.values.contains { session in
                guard session.ready || session.busy else { return false }
                if session.workingDirectory.standardizedFileURL == self.repository.root.standardizedFileURL { return true }
                guard let directory = ReferencePath.relative(session.workingDirectory, inside: self.repository.root) else { return false }
                return path.hasPrefix(directory + "/")
            }
        })
    }
    func enableCloud() { if cloud == nil { cloud = CloudSync(store: self) }; cloud?.start() }
    var currentPageFileURLs: [URL] {
        var seen: Set<String> = []
        return (note?.blocks ?? []).compactMap { block in
            guard let url = attachmentURL(for: block), seen.insert(url.standardizedFileURL.path).inserted else { return nil }
            return url
        }
    }
    func isICloudFileProtected(_ path: String, includingCurrentPage: Bool = true) -> Bool {
        if note?.blocks.contains(where: { $0.relativeFilePath == path && (includingCurrentPage || $0.id == editingBlockID) }) == true { return true }
        let identities = Set(workspace.notes.flatMap(\.blocks).filter { $0.relativeFilePath == path }.map { $0.fileIdentity.uuidString })
        if identities.contains(where: { textSessions[$0]?.hasUnsavedChanges == true || notebookSessions[$0]?.hasUnsavedChanges == true }) { return true }
        return notebookSessions.values.contains { session in
            guard session.ready || session.busy else { return false }
            if session.workingDirectory.standardizedFileURL == repository.root.standardizedFileURL { return true }
            guard let directory = ReferencePath.relative(session.workingDirectory, inside: repository.root) else { return false }
            return path.hasPrefix(directory + "/")
        }
    }

    func notebookSession(noteID: UUID, blockID: UUID) throws -> NotebookSession {
        guard let note = workspace.notes.first(where: { $0.id == noteID }), let block = note.blocks.first(where: { $0.id == blockID }),
              AttachmentFormat(filename: block.assetName) == .notebook, let url = attachmentURL(for: block) else { throw StoreError.corrupt }
        let key = block.fileIdentity.uuidString
        try iCloudFiles.requireLocal(url)
        if let existing = notebookSessions[key] { return existing }
        let source = try Data(contentsOf: url)
        if let path = block.relativeFilePath { referenceStamps[path] = Self.referenceStamp(url) }
        var expected = AssetFingerprint.sha256(source)
        let directory = url.deletingLastPathComponent()
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
        try iCloudFiles.requireLocal(url)
        if let existing = textSessions[key] { return existing }
        let source = try Data(contentsOf: url)
        if let path = block.relativeFilePath { referenceStamps[path] = Self.referenceStamp(url) }
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
        let actual = try AssetFingerprint.read(url).sha256, incoming = AssetFingerprint.sha256(data)
        guard actual == expected || actual == incoming else {
            let recovery = repository.root.appendingPathComponent("Recoveries", isDirectory: true)
            try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
            let filename = WorkspaceDirectories.safeName((current.assetName as NSString).deletingPathExtension) + "-" + AssetFingerprint.sha256(data).prefix(12) + "." + (current.assetName as NSString).pathExtension
            try Repository.writeAtomically(data, to: recovery.appendingPathComponent(filename))
            throw NSError(domain: "FileEdit", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件已在其他位置修改。本次编辑已另存到资料库的 Recoveries 文件夹，可导出修改稿后重新打开文件。"])
        }
        let revision = UUID()
        if actual != incoming { try Repository.writeAtomically(data, to: url) }
        var updated = workspace
        for page in updated.notes.indices {
            var changed = false
            for index in updated.notes[page].blocks.indices where updated.notes[page].blocks[index].fileIdentity == fileID {
                updated.notes[page].blocks[index] = directories.indexed(updated.notes[page].blocks[index])
                updated.notes[page].blocks[index].contentRevision = revision; changed = true
            }
            if changed { updated.notes[page].touch(device); updated.pending.insert("page_" + updated.notes[page].id.uuidString) }
        }
        try persistWorkspace(updated); workspace = updated; saveStatus = "已保存到本机"; cloud?.enqueue()
        if let path = current.relativeFilePath { referenceStamps[path] = Self.referenceStamp(url) }
    }
    nonisolated private static func referenceStamp(_ url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return "missing" }
        return "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0)"
    }
    func refreshReferencedFiles(noteID: UUID? = nil) {
        // Opening a page should not stat unrelated files throughout the library.
        // Include open editors so an externally changed session cannot linger
        // and block saving/undo on a different page. Explicit full refresh remains
        // available; activation uses the visible scope. Changes reach all aliases.
        let blocks = noteID.map { id in workspace.notes.first { $0.id == id }?.blocks ?? [] }
            ?? workspace.notes.flatMap(\.blocks)
        refreshReferences(in: blocks, includeOpenEditors: noteID != nil)
    }
    func refreshVisibleReferences() {
        refreshReferences(in: note?.blocks ?? [], includeOpenEditors: true)
    }
    private func refreshReferences(in blocks: [Block], includeOpenEditors: Bool) {
        var paths = Set(blocks.compactMap(\.relativeFilePath))
        let openFiles = Set(textSessions.keys).union(notebookSessions.keys)
        if includeOpenEditors, !openFiles.isEmpty {
            for note in workspace.notes {
                for block in note.blocks {
                    if let path = block.relativeFilePath, openFiles.contains(block.fileIdentity.uuidString) { paths.insert(path) }
                }
            }
        }
        for path in paths {
            guard let url = ReferencePath.resolve(path, inside: repository.root) else { continue }
            let stamp = Self.referenceStamp(url), previous = referenceStamps.updateValue(stamp, forKey: path)
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
        try persistWorkspace(candidate)
        workspace = candidate
        if let previous {
            undoStack.append(HistoryEntry([previous],selection:previous.id)); undoStack = Array(undoStack.suffix(50)); redoStack = []; saveHistory()
        }
        saveStatus = "已保存到本机"
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
            note.blocks = note.blocks.map { original in
                guard original.kind.hasAttachment else { return original }
                var block = Block(.text, frame: original.frame,
                    text: "**示例文件：" + original.assetName + "**\n\n请先将资料文件放入资料库文件夹，再用「添加文件索引」选择它。文件只保留原件，索引不会复制文件。")
                block.id = original.id; block.fontSize = 18
                return block
            }
            var deleted = note; deleted.deleted = true; deleted.trashBatchID = catalog.rootID
            placeholders.append(deleted)
            note.touch(device); next.notes.append(note); next.pending.insert("page_" + note.id.uuidString)
        }
        try persistWorkspace(next)
        saveTask?.cancel(); workspace = next
        undoStack.append(HistoryEntry(placeholders, selection: before)); undoStack = Array(undoStack.suffix(50))
        redoStack = []; saveHistory(); saveStatus = "已保存到本机"
        select(catalog.rootID); expandedPages.insert(catalog.rootID); cloud?.enqueue()
    }
    /// Atomically add indexed pages; a single undo trashes only these new pages.
    func commitIndexedPages(_ pages: [Note], directoryBindings: [UUID: String] = [:], selectInserted: Bool = true) throws {
        guard !pages.isEmpty else { return }
        finishBlockEditing()
        guard saveEditors() else { throw CocoaError(.fileWriteUnknown) }
        let incoming = Set(pages.map(\.id)), existing = Set(workspace.notes.map(\.id)).union(workspace.purgedPageIDs)
        guard incoming.count == pages.count, incoming.isDisjoint(with: existing) else { throw StoreError.corrupt }
        let validParents = incoming.union(workspace.notes.filter { !$0.deleted }.map(\.id))
        guard pages.allSatisfy({ $0.parentID == nil || validParents.contains($0.parentID!) }) else { throw StoreError.corrupt }
        var next = workspace, placeholders: [Note] = []
        let priorSelection = selection, batch = UUID()
        for (id, path) in directoryBindings {
            guard let index = next.notes.firstIndex(where: { $0.id == id && !$0.deleted }),
                  ReferencePath.resolve(path, inside: repository.root) != nil else { throw FileIndexError.outsideLibrary }
            if next.notes[index].managedDirectoryPath == nil {
                placeholders.append(next.notes[index]); next.notes[index].managedDirectoryPath = path
                next.notes[index].touch(device); next.pending.insert("page_" + id.uuidString)
            }
        }
        for var page in pages {
            for block in page.blocks {
                if let path = block.relativeFilePath, ReferencePath.resolve(path, inside: repository.root) == nil { throw FileIndexError.outsideLibrary }
            }
            var placeholder = page; placeholder.deleted = true; placeholder.deletedAt = Date(); placeholder.trashBatchID = batch
            placeholders.append(placeholder); page.touch(device); next.notes.append(page)
            next.pending.insert("page_" + page.id.uuidString)
        }
        try persistWorkspace(next); saveTask?.cancel(); workspace = next
        undoStack.append(HistoryEntry(placeholders, selection: priorSelection)); undoStack = Array(undoStack.suffix(50))
        redoStack = []; saveHistory(); saveStatus = "已保存到本机"; cloud?.enqueue()
        if selectInserted, let first = pages.first { select(first.id) }
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
