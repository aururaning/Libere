import SwiftUI
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import MarginCore
#endif

extension UTType { static let marginBackup = UTType(exportedAs: "app.marginnotes.backup", conformingTo: .json) }
struct BackupPayload: Codable { var format = 2; var workspace: Workspace; var assets: [String: Data] }
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.marginBackup] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else { throw StoreError.corrupt }; data = contents
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
extension AppStore {
    func backup() throws -> BackupDocument {
        guard saveEditors(), flush() else { throw StoreError.corrupt }
        return BackupDocument(data: try JSONEncoder().encode(BackupPayload(workspace: workspace, assets: [:])))
    }
    func importBackup(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let payload = try JSONDecoder().decode(BackupPayload.self, from: Data(contentsOf: url))
        guard (1...2).contains(payload.format), (1...3).contains(payload.workspace.schemaVersion) else { throw StoreError.corrupt }
        var incoming = payload.workspace
        for tombstone in (workspace.purgedPages ?? [:]).values { incoming.mergePurge(tombstone, enforce: false) }
        incoming.enforcePurges()
        for p in incoming.notes.indices {
            for b in incoming.notes[p].blocks.indices {
                let original = incoming.notes[p].blocks[b]
                var indexed = directories.indexed(original)
                // Old portable backups can only reuse files already present in this library.
                // Never unpack embedded bytes into attachments or invent a destination.
                if !original.referencedAssets.isEmpty {
                    if let current = workspace.notes.lazy.flatMap(\.blocks).first(where: {
                        $0.fileIdentity == original.fileIdentity && $0.relativeFilePath != nil
                    }) { indexed.relativeFilePath = current.relativeFilePath }
                    guard let path = indexed.relativeFilePath, let file = ReferencePath.resolve(path, inside: repository.root),
                          FileManager.default.fileExists(atPath: file.path) else { throw FileIndexError.indexOnly }
                    if let asset = original.displayAssetID, let bytes = payload.assets[asset.uuidString],
                       try AssetFingerprint.read(file).sha256 != AssetFingerprint.sha256(bytes) { throw StoreError.attachmentMismatch }
                }
                if let path = indexed.relativeFilePath, ReferencePath.resolve(path, inside: repository.root) == nil { throw FileIndexError.outsideLibrary }
                incoming.notes[p].blocks[b] = indexed
            }
        }
        incoming.schemaVersion = 3
        // Merge into a separate value before publishing; imports never replace the entire live library.
        var merged = workspace
        for tombstone in (incoming.purgedPages ?? [:]).values { merged.mergePurge(tombstone, enforce: false) }
        merged.enforcePurges()
        for note in incoming.notes where !merged.purgedPageIDs.contains(note.id) {
            if let i = merged.notes.firstIndex(where: { $0.id == note.id }) {
                let result = NoteMerge.merge(merged.notes[i], note); merged.notes[i] = result.primary
                if let conflict = result.conflict, !merged.notes.contains(where: { $0.id == conflict.id }) { merged.notes.append(conflict) }
            } else { merged.notes.append(note) }
        }
        merged.enforcePurges()
        merged.pending.formUnion(merged.notes.map { "page_" + $0.id.uuidString })
        merged.pending.formUnion(merged.purgedPageIDs.map { "page_" + $0.uuidString })
        try persistWorkspace(merged); workspace = merged; cloud?.enqueue()
        discardPurgedHistory(persist: true)
        if selection == nil || selection.map(merged.purgedPageIDs.contains) == true { selection = workspace.notes.first { !$0.deleted && !$0.isFolder }?.id }
        message = "索引与批注已合并。原文件按相对路径读取，请保留资料库文件夹及其文件。"
    }
}
