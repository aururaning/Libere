import SwiftUI
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import MarginCore
#endif

extension UTType { static let marginBackup = UTType(exportedAs: "app.marginnotes.backup", conformingTo: .json) }
struct BackupPayload: Codable { var format = 1; var workspace: Workspace; var assets: [String: Data] }
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
        guard saveEditors() else { throw NSError(domain: "Backup", code: 1, userInfo: [NSLocalizedDescriptionKey: "部分文件有未解决的保存冲突。请先处理文件编辑区中的提示，再导出完整备份。"]) }
        guard flush() else { throw StoreError.corrupt }
        var snapshot = workspace
        var external: [UUID: (UUID, Data)] = [:]
        for page in snapshot.notes.indices {
            for index in snapshot.notes[page].blocks.indices {
                let block = snapshot.notes[page].blocks[index]
                guard block.relativeFilePath != nil, let url = attachmentURL(for: block) else { continue }
                if external[block.fileIdentity] == nil { external[block.fileIdentity] = (UUID(), try Data(contentsOf: url)) }
                let (asset, bytes) = external[block.fileIdentity]!
                snapshot.notes[page].blocks[index].relativeFilePath = nil
                snapshot.notes[page].blocks[index].assetID = asset
                snapshot.notes[page].blocks[index].assetSHA256 = AssetFingerprint.sha256(bytes)
                snapshot.notes[page].blocks[index].assetByteCount = Int64(bytes.count)
            }
        }
        let referenced = Set(snapshot.notes.flatMap(\.blocks).flatMap(\.referencedAssets))
        var assets: [String: Data] = [:]
        for (_, item) in external { assets[item.0.uuidString] = item.1 }
        for id in referenced where assets[id.uuidString] == nil { assets[id.uuidString] = try Data(contentsOf: repository.asset(id)) }
        return BackupDocument(data: try JSONEncoder().encode(BackupPayload(workspace: snapshot, assets: assets)))
    }
    func importBackup(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let payload = try JSONDecoder().decode(BackupPayload.self, from: Data(contentsOf: url))
        guard payload.format == 1, payload.workspace.schemaVersion == 1 else { throw StoreError.corrupt }
        let required = Set(payload.workspace.notes.flatMap(\.blocks).flatMap(\.referencedAssets))
        guard required.allSatisfy({ payload.assets[$0.uuidString] != nil }) else { throw StoreError.corrupt }
        for block in payload.workspace.notes.flatMap(\.blocks) {
            if let id = block.assetID, let digest = block.assetSHA256, let data = payload.assets[id.uuidString],
               AssetFingerprint.sha256(data) != digest { throw StoreError.attachmentMismatch }
        }
        for id in required {
            let destination = repository.asset(id)
            if let bytes = payload.assets[id.uuidString] {
                if FileManager.default.fileExists(atPath: destination.path) {
                    guard try AssetFingerprint.read(destination).sha256 == AssetFingerprint.sha256(bytes) else { throw StoreError.attachmentMismatch }
                } else { try Repository.writeAtomically(bytes, to: destination) }
            }
        }
        // Merge into a separate value before publishing; imports never replace the entire live library.
        var merged = workspace
        for note in payload.workspace.notes {
            if let i = merged.notes.firstIndex(where: { $0.id == note.id }) {
                let result = NoteMerge.merge(merged.notes[i], note); merged.notes[i] = result.primary
                if let conflict = result.conflict, !merged.notes.contains(where: { $0.id == conflict.id }) { merged.notes.append(conflict) }
            } else { merged.notes.append(note) }
        }
        merged.pending.formUnion(merged.notes.map { "page_" + $0.id.uuidString })
        merged.pending.formUnion(required.map { "asset_" + $0.uuidString })
        try repository.save(merged); workspace = merged; try directories.synchronize(workspace); cloud?.enqueue()
        if selection == nil { selection = workspace.notes.first { !$0.deleted && !$0.isFolder }?.id }
        message = "备份已合并到资料库。并行修改会保留为冲突副本。"
    }
}
