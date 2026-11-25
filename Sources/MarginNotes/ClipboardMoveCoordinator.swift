import SwiftUI
import Combine
#if SWIFT_PACKAGE
import MarginCore
#endif

struct ClipboardMoveHistoryPlan: Sendable {
    let receiptID: UUID
    let notes: [Note]
    let selection: UUID?
    let redo: Bool
}

@MainActor final class ClipboardMoveCoordinator: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var status: String?
    private(set) var lastInstalledFiles: [ClipboardMove.InstalledFile] = []
    private weak var store: AppStore?
    private var task: Task<Void, Never>?
    let receiptDirectory: URL
    static var changedHistory: NSError { NSError(domain: "ClipboardMove", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "等待期间出现了新的操作，请先撤销最近的操作后重试；原文件未删除。"]) }

    init(store: AppStore, receiptDirectory: URL? = nil) {
        self.store = store
        let key = AssetFingerprint.sha256(Data((store.device + "\n" + store.repository.root.standardizedFileURL.path).utf8))
        self.receiptDirectory = receiptDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Libere/ClipboardMoves/" + key, isDirectory: true)
    }

    @discardableResult func moveFiles(_ urls: [URL], at point: CGPoint?, noteID: UUID?, blockMove: CanvasClipboard? = nil) -> Bool {
        guard let store, let target = noteID ?? store.selection, !urls.isEmpty,
              store.workspace.notes.contains(where: { $0.id == target && !$0.deleted }) else { return false }
        guard ready(store) else { return true }
        lastInstalledFiles = []
        let indexed = Dictionary(store.workspace.notes.filter { !$0.deleted }.flatMap(\.blocks).compactMap { block in
            block.relativeFilePath.map { ($0, block.fileIdentity) }
        }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        let sources = urls.compactMap { url -> ClipboardMove.Source? in
            guard url.isFileURL, seen.insert(url.standardizedFileURL.resolvingSymlinksInPath().path).inserted else { return nil }
            let id = ReferencePath.relative(url, inside: store.repository.root).flatMap { indexed[$0] } ?? UUID()
            return ClipboardMove.Source(url: url, fileID: id)
        }
        guard !sources.isEmpty else { return false }
        start("正在校验并移动 \(sources.count) 个文件…", store: store) { coordinator, store in
            let root = store.repository.root, device = store.device, receipts = coordinator.receiptDirectory
            let currentSources = coordinator.currentSources(sources, in: store)
            let prepared = try await Task.detached(priority: .userInitiated) {
                try ClipboardMove.prepare(currentSources, libraryRoot: root, deviceID: device, receiptDirectory: receipts)
            }.value
            defer { prepared.cleanup() }
            try Task.checkCancellation()
            guard let note = store.workspace.notes.first(where: { $0.id == target && !$0.deleted }) else { throw StoreError.corrupt }
            guard coordinator.prepareEditors(store) else { throw CocoaError(.userCancelled) }
            if let blockMove { try ClipboardBlockMove.validate(blockMove, in: store.workspace) }
            let location = try store.clipboardPastes.archiveLocation(for: note, hasCopies: true, store: store)
            let replacements = Dictionary(zip(prepared.entries, coordinator.currentSources(prepared.entries, in: store))
                .filter { $0.0.url != $0.1.url }.map { ($0.0.url, $0.1.url) }, uniquingKeysWith: { a, _ in a })
            let installed = try prepared.install(into: location.url, sourceReplacements: replacements)
            var candidate = store.workspace
            let relocated = try coordinator.relocate(installed, in: &candidate, root: root)
            guard let pageIndex = candidate.notes.firstIndex(where: { $0.id == target && !$0.deleted }) else { throw StoreError.corrupt }
            if let binding = location.binding { candidate.notes[pageIndex].managedDirectoryPath = binding }
            if let blockMove {
                let moved = try ClipboardBlockMove.apply(blockMove, to: target, at: point, in: &candidate)
                try store.commitClipboardWorkspace(candidate, receiptID: prepared.id, relocatedPaths: relocated)
                coordinator.lastInstalledFiles = installed
                if store.selection == moved.noteID { store.multiSelection.select(moved.ids) }
                try prepared.markCommitted()
                let result = try await Task.detached(priority: .userInitiated) { try prepared.finishSources() }.value
                coordinator.report(result, store: store)
                return
            }
            let blocks = try installed.map { file -> Block in
                var block = try store.indexedBlock(at: file.destinationURL, validateContents: false)
                block.fileID = file.fileID
                block.reference = nil
                return block
            }
            var owners: [UUID: FileReference] = [:]
            if candidate.notes[pageIndex].isFolder {
                for block in blocks {
                    var page = Note(title: block.assetName, parent: target); page.blocks = [block]
                    page.managedFilePath = block.relativeFilePath
                    owners[block.fileIdentity] = FileReference(noteID: page.id, blockID: block.id)
                    candidate.notes.append(page)
                }
            } else {
                var arranged = blocks, y = 0.0
                for i in arranged.indices { arranged[i].frame.x = 0; arranged[i].frame.y = y; y += arranged[i].visibleFrame.height + 24 }
                let positioned = try ClipboardPlacement.position(arranged, in: &candidate.notes[pageIndex], at: point)
                candidate.notes[pageIndex].blocks += positioned
                candidate.notes[pageIndex].extendCanvasForContent()
                for block in blocks { owners[block.fileIdentity] = FileReference(noteID: target, blockID: block.id) }
            }
            for p in candidate.notes.indices {
                for b in candidate.notes[p].blocks.indices {
                    let block = candidate.notes[p].blocks[b]
                    if let owner = owners[block.fileIdentity], block.id != owner.blockID {
                        candidate.notes[p].blocks[b].reference = owner
                        if candidate.notes[p].id != owner.noteID && candidate.notes[p].managedFilePath == block.relativeFilePath {
                            candidate.notes[p].managedFilePath = nil
                        }
                    }
                }
            }
            coordinator.status = "正在保存文件位置与撤销记录…"
            try store.commitClipboardWorkspace(candidate, receiptID: prepared.id, relocatedPaths: relocated)
            coordinator.lastInstalledFiles = installed
            if store.selection == target && !note.isFolder { store.multiSelection.select(Set(blocks.map(\.id))) }
            try prepared.markCommitted()
            coordinator.status = "正在完成移动…"
            let result = try await Task.detached(priority: .userInitiated) { try prepared.finishSources() }.value
            coordinator.report(result, store: store)
        }
        return true
    }

    @discardableResult func moveBlocks(_ data: Data, at point: CGPoint?, noteID: UUID?) -> Bool {
        guard let store, let target = noteID ?? store.selection else { return false }
        do {
            let payload = try JSONDecoder().decode(CanvasClipboard.self, from: data)
            guard URL(fileURLWithPath: payload.root).standardizedFileURL.resolvingSymlinksInPath() == store.repository.root.standardizedFileURL.resolvingSymlinksInPath() else { throw FileIndexError.outsideLibrary }
            try ClipboardBlockMove.validate(payload, in: store.workspace)
            let ids = Set(payload.blocks.map(\.id))
            let source = store.workspace.notes.first { $0.id == payload.noteID }!
            let owned = source.blocks.filter { ids.contains($0.id) && $0.kind.hasAttachment && $0.reference == nil }.compactMap(store.attachmentURL)
            if target != payload.noteID, !owned.isEmpty { return moveFiles(owned, at: point, noteID: target, blockMove: payload) }
            guard ready(store) else { return true }
            var candidate = store.workspace
            let moved = try ClipboardBlockMove.apply(payload, to: target, at: point, in: &candidate)
            try store.commitClipboardWorkspace(candidate)
            if store.selection == moved.noteID { store.multiSelection.select(moved.ids) }
            return true
        } catch { store.message = error.localizedDescription; return true }
    }

    func reverse(_ plan: ClipboardMoveHistoryPlan) {
        guard let store, ready(store) else { return }
        start(plan.redo ? "正在重做文件移动…" : "正在撤销文件移动…", store: store) { coordinator, store in
            let root = store.repository.root, device = store.device, receipts = coordinator.receiptDirectory
            let current = Dictionary(store.workspace.notes.filter { !$0.deleted }.flatMap(\.blocks).compactMap { block -> (UUID, URL)? in
                store.attachmentURL(for: block).map { (block.fileIdentity, $0) }
            }, uniquingKeysWith: { a, _ in a })
            let prepared = try await Task.detached(priority: .userInitiated) {
                try ClipboardMove.prepareReverse(receiptID: plan.receiptID, libraryRoot: root, deviceID: device,
                                                 receiptDirectory: receipts, currentSources: current)
            }.value
            defer { prepared.cleanup() }
            guard store.isCurrentMoveHistory(plan), coordinator.prepareEditors(store) else { throw Self.changedHistory }
            var candidate = try store.restoringClipboardHistory(plan)
            let receipt = try ClipboardMove.loadReceipt(id: plan.receiptID, libraryRoot: root, deviceID: device, receiptDirectory: receipts)
            for entry in receipt.entries where ReferencePath.relative(entry.sourceURL, inside: root) == nil {
                guard !candidate.notes.contains(where: { !$0.deleted && $0.blocks.contains { $0.fileIdentity == entry.fileID } }) else {
                    throw NSError(domain: "ClipboardMove", code: 2, userInfo: [NSLocalizedDescriptionKey: "还有页面在引用这个文件，请先撤销后续引用再移出资料库。"])
                }
            }
            // Installation and metadata commit have no actor suspension between
            // them. A later edit cannot be silently overwritten by this undo.
            let installed = try prepared.installReverse()
            let relocated = try coordinator.relocate(installed, in: &candidate, root: root)
            try store.commitClipboardWorkspace(candidate, receiptID: prepared.id, history: plan, relocatedPaths: relocated)
            try prepared.markCommitted()
            let result = try await Task.detached(priority: .userInitiated) { try prepared.finishSources() }.value
            coordinator.report(result, store: store)
        }
    }

    func recoverPending() {
        guard let store, ready(store) else { return }
        start("正在检查未完成的文件移动…", store: store) { coordinator, store in
            let root = store.repository.root, device = store.device, directory = coordinator.receiptDirectory
            let results = try await Task.detached(priority: .userInitiated) { () throws -> [ClipboardMove.FinishResult] in
                var results: [ClipboardMove.FinishResult] = []
                for id in try ClipboardMove.pendingReceiptIDs(libraryRoot: root, deviceID: device, receiptDirectory: directory) {
                    let receipt = try ClipboardMove.loadReceipt(id: id, libraryRoot: root, deviceID: device, receiptDirectory: directory)
                    // An uncommitted copy never authorizes source deletion.
                    if receipt.phase == .committed {
                        results.append(try ClipboardMove.resumeCommitted(receiptID: id, libraryRoot: root, deviceID: device, receiptDirectory: directory))
                    }
                }
                return results
            }.value
            if results.isEmpty { coordinator.status = "没有可继续的已提交移动，未提交原件保持原样。" }
            else { for result in results { coordinator.report(result, store: store) } }
        }
    }

    func waitUntilIdle() async { while let task { await task.value } }

    private func ready(_ store: AppStore) -> Bool {
        guard !isBusy else { store.message = "正在完成上一批文件移动，请稍后再试。"; return false }
        return prepareEditors(store)
    }
    private func prepareEditors(_ store: AppStore) -> Bool {
        #if os(macOS)
        guard PDFWindow.shared.prepareReaders(store: store) else { return false }
        #endif
        store.finishBlockEditing()
        return store.saveEditors()
    }
    private func start(_ text: String, store: AppStore,
                       operation: @escaping @MainActor (ClipboardMoveCoordinator, AppStore) async throws -> Void) {
        isBusy = true; status = text
        let root = store.repository.root, access = root.startAccessingSecurityScopedResource()
        task = Task { [weak self] in
            defer { if access { root.stopAccessingSecurityScopedResource() } }
            guard let self else { return }
            defer { self.isBusy = false; self.task = nil }
            do { try await operation(self, store) }
            catch { store.message = error.localizedDescription; self.status = "移动未完成，原件或归档文件已保留。" }
        }
    }
    private func currentSources(_ sources: [ClipboardMove.Source], in store: AppStore) -> [ClipboardMove.Source] {
        let current = Dictionary(store.workspace.notes.filter { !$0.deleted }.flatMap(\.blocks).compactMap { block -> (UUID, URL)? in
            store.attachmentURL(for: block).map { (block.fileIdentity, $0) }
        }, uniquingKeysWith: { a, _ in a })
        return sources.map { source in
            let url = ReferencePath.relative(source.url, inside: store.repository.root) == nil ? source.url : current[source.fileID] ?? source.url
            return ClipboardMove.Source(url: url, fileID: source.fileID)
        }
    }
    private func relocate(_ files: [ClipboardMove.InstalledFile], in workspace: inout Workspace, root: URL) throws -> [String: String] {
        var paths: [String: String] = [:]
        for file in files {
            let source = ReferencePath.relative(file.sourceURL, inside: root)
            let destination = ReferencePath.relative(file.destinationURL, inside: root)
            if let source, destination == nil {
                guard !workspace.notes.contains(where: { !$0.deleted && $0.blocks.contains { $0.fileIdentity == file.fileID || $0.relativeFilePath == source } }) else {
                    throw NSError(domain: "ClipboardMove", code: 2, userInfo: [NSLocalizedDescriptionKey: "还有页面在引用这个文件，不能将它移出资料库。请先撤销后续引用。"])
                }
            }
            guard let destination else { continue }
            if let source { paths[source] = destination }
            for p in workspace.notes.indices {
                if let source, workspace.notes[p].managedFilePath == source { workspace.notes[p].managedFilePath = destination }
                for b in workspace.notes[p].blocks.indices where workspace.notes[p].blocks[b].fileIdentity == file.fileID || (source != nil && workspace.notes[p].blocks[b].relativeFilePath == source) {
                    workspace.notes[p].blocks[b].relativeFilePath = destination
                    workspace.notes[p].blocks[b].assetName = file.destinationURL.lastPathComponent
                }
            }
        }
        return paths
    }
    private func report(_ result: ClipboardMove.FinishResult, store: AppStore) {
        if result.completed { status = result.movedCount == 0 ? "文件已在目标位置。" : "已移动 \(result.movedCount) 个文件" }
        else {
            status = "移动未全部完成，原件已保留。"
            store.message = (result.errors + result.retainedSources.prefix(3).map { "保留位置：" + $0.path }).joined(separator: "\n")
        }
    }
}

@MainActor struct ClipboardMoveStatusView: View {
    @ObservedObject var coordinator: ClipboardMoveCoordinator
    var body: some View {
        if let status = coordinator.status {
            HStack(spacing: 8) {
                if coordinator.isBusy { ProgressView().controlSize(.small) }
                Text(status).font(.system(size: 14))
                if !coordinator.isBusy { Button("关闭") { coordinator.clearStatus() }.buttonStyle(.plain) }
            }.padding(.horizontal, 14).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule()).padding(16)
                .accessibilityIdentifier("clipboard-move-status")
        }
    }
}

extension ClipboardMoveCoordinator { func clearStatus() { if !isBusy { status = nil } } }
