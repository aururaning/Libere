import SwiftUI
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import MarginCore
#endif

@MainActor extension AppStore {
    /// Adds only indexes. The destination is captured before asynchronous provider
    /// loading so changing pages during a Finder drop cannot redirect the files.
    @discardableResult func indexFileURLs(_ urls: [URL], at point: CGPoint? = nil, noteID: UUID? = nil) -> Bool {
        guard let target = noteID ?? selection,
              let destination = workspace.notes.first(where: { $0.id == target && !$0.deleted }), !urls.isEmpty else { return false }
        do {
            var seen: Set<String> = [], indexed: [Block] = []
            for url in urls {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let block = try indexedBlock(at: url)
                guard let path = block.relativeFilePath, seen.insert(path).inserted else { continue }
                indexed.append(block)
            }
            guard !indexed.isEmpty else { return false }
            if destination.isFolder {
                let pages = indexed.map { block -> Note in
                    var page = Note(title: block.assetName, parent: target)
                    page.blocks = [block]
                    if block.reference == nil { page.managedFilePath = block.relativeFilePath }
                    return page
                }
                try commitIndexedPages(pages)
            } else {
                var y = 0.0
                for i in indexed.indices { indexed[i].frame.y = y; y += indexed[i].visibleFrame.height + 24 }
                _ = try appendClipboardBlocks(indexed, at: point, noteID: target)
            }
            return true
        } catch { message = error.localizedDescription; return false }
    }
    @discardableResult func indexDroppedFiles(providers: [NSItemProvider], at point: CGPoint? = nil, noteID: UUID? = nil) -> Bool {
        let providers = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !providers.isEmpty, let target = noteID ?? selection else { return false }
        let batch = FileDropBatch(store: self, noteID: target, point: point, count: providers.count)
        for (index, provider) in providers.enumerated() {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                let url: URL?
                if let value = item as? URL { url = value }
                else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let text = item as? String { url = URL(string: text) }
                else { url = nil }
                Task { @MainActor in batch.receive(url, error: error, index: index) }
            }
        }
        return true
    }
}

@MainActor private final class FileDropBatch {
    weak var store: AppStore?
    let noteID: UUID
    let point: CGPoint?
    var urls: [Int: URL] = [:]
    var remaining: Int
    var failure: String?
    init(store: AppStore, noteID: UUID, point: CGPoint?, count: Int) {
        self.store = store; self.noteID = noteID; self.point = point; remaining = count
    }
    func receive(_ url: URL?, error: Error?, index: Int) {
        if let url, url.isFileURL { urls[index] = url }
        else { failure = error?.localizedDescription ?? "拖入内容不是有效的原文件路径。" }
        remaining -= 1
        guard remaining == 0, let store else { return }
        if let failure { store.message = failure; return }
        _ = store.indexFileURLs(urls.keys.sorted().compactMap { urls[$0] }, at: point, noteID: noteID)
    }
}
