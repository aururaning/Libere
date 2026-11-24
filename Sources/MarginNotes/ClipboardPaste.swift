import SwiftUI
import Combine
#if SWIFT_PACKAGE
import MarginCore
#endif

/// Clipboard file copies run independently of the UI and keep their original
/// destination page even if the user navigates while a large copy is pending.
@MainActor final class ClipboardPasteCoordinator: ObservableObject {
    @Published private(set) var pendingCount = 0
    @Published private(set) var status: String?
    private weak var store: AppStore?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var latestStatus = UUID()

    init(store: AppStore) { self.store = store }

    @discardableResult func enqueue(_ inputs: [ClipboardArchive.Input], at point: CGPoint?, noteID: UUID?) -> Bool {
        guard let store, let target = noteID ?? store.selection,
              store.workspace.notes.contains(where: { $0.id == target && !$0.deleted }), !inputs.isEmpty else { return false }
        guard inputs.count <= 5000, point.map({ $0.x.isFinite && $0.y.isFinite }) ?? true else {
            store.message = "一次最多粘贴 5000 个文件，请分批整理。"; return true
        }
        let root = store.repository.root
        // Stable IDs let an already indexed source follow sidebar moves while
        // other files in this same paste are being copied in the background.
        var references: [URL: UUID] = [:]
        let known = Dictionary(store.workspace.notes.flatMap(\.blocks).compactMap { block in
            block.relativeFilePath.map { ($0, block.fileIdentity) }
        }, uniquingKeysWith: { first, _ in first })
        var preparedInputs: [ClipboardArchive.Input] = []
        for input in inputs {
            if case .file(let url) = input, let path = ReferencePath.relative(url, inside: root), let id = known[path] {
                let original = url.standardizedFileURL.resolvingSymlinksInPath()
                references[original] = id; preparedInputs.append(.libraryReference(original))
            } else { preparedInputs.append(input) }
        }
        let archiveInputs = preparedInputs
        let request = UUID(); latestStatus = request
        let rootAccess = root.startAccessingSecurityScopedResource()
        pendingCount += 1; status = "正在归档 \(inputs.count) 个文件…"
        tasks[request] = Task { [weak self] in
            defer { if rootAccess { root.stopAccessingSecurityScopedResource() } }
            guard let self, let store = self.store else { return }
            var completion: String?
            defer {
                self.tasks.removeValue(forKey: request); self.pendingCount -= 1
                if self.pendingCount > 0 { self.status = "仍有 \(self.pendingCount) 批文件正在归档…" }
                else { self.status = completion; self.clearStatusLater(self.latestStatus) }
            }
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try ClipboardArchive.prepare(archiveInputs, libraryRoot: root)
                }.value
                defer { prepared.cleanup() }
                try Task.checkCancellation()
                guard let destination = store.workspace.notes.first(where: { $0.id == target && !$0.deleted }) else {
                    throw NSError(domain: "ClipboardPaste", code: 1, userInfo: [NSLocalizedDescriptionKey: "原目标页面已移入回收站，已取消这次粘贴；外部原文件仍保留。"])
                }
                let location = try self.archiveLocation(for: destination, hasCopies: prepared.entries.contains { !$0.isReference }, store: store)
                var replacements: [URL: URL] = [:]
                if !references.isEmpty {
                    let current = Dictionary(store.workspace.notes.flatMap(\.blocks).compactMap { block -> (UUID, String)? in
                        block.relativeFilePath.map { (block.fileIdentity, $0) }
                    }, uniquingKeysWith: { first, _ in first })
                    for (old, id) in references {
                        if let path = current[id], let url = ReferencePath.resolve(path, inside: root) { replacements[old] = url }
                    }
                }
                if self.latestStatus == request { self.status = "正在添加到目标页面…" }
                let urls = try prepared.install(into: location.url, referenceReplacements: replacements)
                var blocks = try urls.map { try store.indexedBlock(at: $0, validateContents: false) }
                guard !blocks.isEmpty else { return }
                if destination.isFolder {
                    let pages = blocks.map { block -> Note in
                        var page = Note(title: block.assetName, parent: target)
                        page.blocks = [block]
                        if block.reference == nil { page.managedFilePath = block.relativeFilePath }
                        return page
                    }
                    let bindings = location.binding.map { [target: $0] } ?? [:]
                    try store.commitIndexedPages(pages, directoryBindings: bindings, selectInserted: false)
                } else {
                    var y = 0.0
                    for i in blocks.indices { blocks[i].frame.x = 0; blocks[i].frame.y = y; y += blocks[i].visibleFrame.height + 24 }
                    guard try store.appendClipboardBlocks(blocks, at: point, noteID: target, managedDirectoryPath: location.binding) else {
                        throw NSError(domain: "ClipboardPaste", code: 2, userInfo: [NSLocalizedDescriptionKey: "文件已归档到目标页面文件夹，但页面保存未完成。归档文件已保留，请处理保存提示后重试。"])
                    }
                }
                completion = "已添加 \(blocks.count) 个文件"
                if self.latestStatus == request { self.status = completion }
            } catch {
                store.message = error.localizedDescription
                if self.latestStatus == request { self.status = nil }
            }
        }
        return true
    }

    func waitUntilIdle() async {
        while !tasks.isEmpty {
            let pending = Array(tasks.values)
            for task in pending { await task.value }
        }
    }

    private func clearStatusLater(_ request: UUID) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, self.pendingCount == 0, self.latestStatus == request else { return }
            self.status = nil
        }
    }

    private func archiveLocation(for note: Note, hasCopies: Bool, store: AppStore) throws -> (url: URL, binding: String?) {
        let root = store.repository.root
        guard hasCopies else { return (root, nil) }
        if let path = note.managedDirectoryPath {
            guard let url = ReferencePath.resolve(path, inside: root) else { throw FileIndexError.outsideLibrary }
            return (url, nil)
        }
        let parent: String
        if let file = note.managedFilePath { parent = (file as NSString).deletingLastPathComponent }
        else { parent = FileHierarchyTransaction.directoryPath(for: note.parentID, in: store.workspace) }
        let name = WorkspaceDirectories.safeName(note.title) + "__" + note.id.uuidString.prefix(8)
        let base = (parent.isEmpty ? "" : parent + "/") + name
        var path = base, suffix = 2
        // An unowned pre-existing directory is never silently adopted or merged.
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            path = base + " (\(suffix))"; suffix += 1
        }
        guard let url = ReferencePath.resolve(path, inside: root) else { throw FileIndexError.outsideLibrary }
        return (url, path)
    }
}

extension AppStore {
    @discardableResult func pasteFileURLs(_ urls: [URL], at point: CGPoint? = nil, noteID: UUID? = nil) -> Bool {
        clipboardPastes.enqueue(urls.map(ClipboardArchive.Input.file), at: point, noteID: noteID)
    }
    @discardableResult func pasteClipboardFileData(_ data: Data, suggestedFilename: String, at point: CGPoint? = nil, noteID: UUID? = nil) -> Bool {
        guard !data.isEmpty else { return false }
        return clipboardPastes.enqueue([.data(data, suggestedFilename: suggestedFilename)], at: point, noteID: noteID)
    }
    func revealReferenceSource(_ block: Block) {
        guard let source = block.reference,
              workspace.notes.contains(where: { $0.id == source.noteID && !$0.deleted && $0.blocks.contains(where: { $0.id == source.blockID }) }) else {
            message = "原内容已移动到回收站或删除，当前文件引用仍可使用。"; return
        }
        select(source.noteID)
        guard selection == source.noteID else { return }
        selectBlock(source.blockID); revealBlockID = source.blockID
    }
}

@MainActor struct ClipboardPasteStatusView: View {
    @ObservedObject var coordinator: ClipboardPasteCoordinator
    var body: some View {
        if let status = coordinator.status {
            HStack(spacing: 8) {
                if coordinator.pendingCount > 0 { ProgressView().controlSize(.small) }
                Text(status).font(.system(size: 14))
            }.padding(.horizontal, 14).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule()).padding(16)
                .allowsHitTesting(false).accessibilityIdentifier("clipboard-paste-status")
        }
    }
}
