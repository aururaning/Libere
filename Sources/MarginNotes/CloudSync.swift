import Foundation
import CloudKit
#if SWIFT_PACKAGE
import MarginCore
#endif

@MainActor final class CloudSync: CKSyncEngineDelegate {
    weak var store: AppStore?
    private var engine: CKSyncEngine?
    private var starting = false
    private var busy = false
    private var paused = false
    private let zone = CKRecordZone(zoneName: "MarginNotesV1")
    private var cache: [String: CKRecord] = [:]
    init(store: AppStore) { self.store = store }
    private func url(_ name: String) -> URL { store!.repository.sync.appendingPathComponent(name) }
    private func id(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zone.zoneID) }

    func start() {
        guard engine == nil, !starting, let store else { return }
        let enabled = (Bundle.main.object(forInfoDictionaryKey: "MarginCloudEnabled") as? String) == "YES"
        guard enabled, let identifier = Bundle.main.object(forInfoDictionaryKey: "MarginCloudContainer") as? String, !identifier.isEmpty else {
            store.cloudStatus = "当前为本地版本"
            store.message = "在 Xcode 配置 Apple 开发团队和 iCloud 容器后，使用 MarginNotes-iCloud 方案运行。详见工程中的 ICLOUD.md。"
            return
        }
        starting = true; store.cloudStatus = "正在连接 iCloud…"
        Task {
            defer { starting = false }
            do {
                try FileManager.default.createDirectory(at: store.repository.sync, withIntermediateDirectories: true)
                let container = CKContainer(identifier: identifier)
                guard try await container.accountStatus() == .available else { store.cloudStatus = "请先登录 iCloud"; return }
                let account = (try await container.userRecordID()).recordName
                let pinURL = url("account.txt")
                if FileManager.default.fileExists(atPath: pinURL.path) {
                    let old = try String(contentsOf: pinURL, encoding: .utf8)
                    guard old == account else {
                        paused = true; store.cloudStatus = "账号变化，同步已暂停"
                        store.message = "这份资料库属于另一个 iCloud 账号。本机内容已保留，请切回原账号继续同步。"; return
                    }
                }
                try Repository.writeAtomically(Data(account.utf8), to: pinURL)
                var state: CKSyncEngine.State.Serialization?
                if FileManager.default.fileExists(atPath: url("engine.json").path) {
                    state = try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: Data(contentsOf: url("engine.json")))
                }
                var config = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: state, delegate: self)
                // Foreground/manual synchronization is explicit in this MVP.
                config.automaticallySync = false
                let engine = CKSyncEngine(config); self.engine = engine; paused = false
                engine.state.add(pendingDatabaseChanges: [.saveZone(zone)])
                UserDefaults.standard.set(true, forKey: "MarginCloudEnabled")
                enqueue(); await refresh()
            } catch { report(error) }
        }
    }
    func enqueue() {
        guard !paused, let engine, let store else { return }
        engine.state.add(pendingRecordZoneChanges: store.workspace.pending.sorted().map { .saveRecord(id($0)) })
        if !store.workspace.pending.isEmpty { store.cloudStatus = "待同步 \(store.workspace.pending.count) 项" }
    }
    func refresh() async {
        guard !paused, !busy else { return }
        guard let engine, let store else { start(); return }
        guard store.flush() else { return }
        busy = true; store.cloudStatus = "正在同步…"; defer { busy = false }
        do {
            // Send also creates a pending custom zone before the first fetch.
            enqueue(); try await engine.sendChanges()
            try await engine.fetchChanges()
            enqueue(); try await engine.sendChanges()
            if store.workspace.pending.isEmpty { store.cloudStatus = "iCloud 已同步" }
        } catch { report(error) }
    }
    private func cacheRecord(_ record: CKRecord) throws {
        let name = record.recordID.recordName
        cache[name] = record
        let coder = NSKeyedArchiver(requiringSecureCoding: true); record.encodeSystemFields(with: coder); coder.finishEncoding()
        try Repository.writeAtomically(coder.encodedData, to: url(name + ".record"))
    }
    private func record(_ name: String, type: String) -> CKRecord {
        if let cached = cache[name] { return cached.copy() as! CKRecord }
        if let data = try? Data(contentsOf: url(name + ".record")), let coder = try? NSKeyedUnarchiver(forReadingFrom: data) {
            coder.requiresSecureCoding = true; let value = CKRecord(coder: coder); coder.finishDecoding()
            if let value { cache[name] = value; return value.copy() as! CKRecord }
        }
        return CKRecord(recordType: type, recordID: id(name))
    }
    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard !paused, let store else { return nil }
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        var records: [CKRecord] = []
        for change in pending.prefix(100) {
            guard case .saveRecord(let recordID) = change else { continue }
            let name = recordID.recordName
            do {
                if name.hasPrefix("page_"), let uuid = UUID(uuidString: String(name.dropFirst(5))), let note = store.workspace.purgedPages?[uuid.uuidString]?.record ?? store.workspace.notes.first(where: { $0.id == uuid }) {
                    let record = self.record(name, type: "MarginPage")
                    // Unique immutable files avoid mutating a payload while CloudKit is reading it.
                    let payload = url(name + "_" + UUID().uuidString + ".payload")
                    try Repository.writeAtomically(JSONEncoder().encode(note), to: payload)
                    record["payload"] = CKAsset(fileURL: payload)
                    record["revision"] = note.revision.uuidString as CKRecordValue
                    record["vector"] = try JSONEncoder().encode(note.version) as CKRecordValue
                    records.append(record)
                } else if name.hasPrefix("asset_") {
                    syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    store.workspace.pending.remove(name)
                }
            } catch { pause(error); return nil }
        }
        return records.isEmpty ? nil : CKSyncEngine.RecordZoneChangeBatch(recordsToSave: records, atomicByZone: false)
    }
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard let store, !paused else { return }
        do {
            switch event {
            case .stateUpdate(let state):
                try store.persistSync()
                try Repository.writeAtomically(JSONEncoder().encode(state.stateSerialization), to: url("engine.json"))
            case .accountChange(let change):
                switch change.changeType {
                case .signIn: break
                case .signOut, .switchAccounts:
                    paused = true; store.cloudStatus = "账号变化，同步已暂停"
                    store.message = "本机内容已保留。请使用原 iCloud 账号重新启动应用。"
                @unknown default: break
                }
            case .fetchedRecordZoneChanges(let changes):
                for modification in changes.modifications { try receive(modification.record) }
                if !changes.deletions.isEmpty {
                    // App deletions are versioned tombstones; administrative deletions need explicit recovery.
                    paused = true; store.cloudStatus = "云端记录被移除，同步暂停"
                    store.message = "检测到云端记录被直接删除，本机副本已保留。请先导出备份再检查云端容器。"
                }
                try store.persistSync(); enqueue()
            case .sentRecordZoneChanges(let sent):
                for saved in sent.savedRecords {
                    try cacheRecord(saved)
                    let name = saved.recordID.recordName
                    if name.hasPrefix("page_"), let uuid = UUID(uuidString: String(name.dropFirst(5))),
                       let current = store.workspace.purgedPages?[uuid.uuidString]?.record ?? store.workspace.notes.first(where: { $0.id == uuid }),
                       let vectorData = saved["vector"] as? Data,
                       let vector = try? JSONDecoder().decode(VersionVector.self, from: vectorData) {
                        if current.revision.uuidString == saved["revision"] as? String && current.version == vector { store.workspace.pending.remove(name) }
                    } else if name.hasPrefix("asset_") { store.workspace.pending.remove(name) }
                    if let asset = saved["payload"] as? CKAsset, let payload = asset.fileURL,
                       payload.deletingLastPathComponent().standardizedFileURL == store.repository.sync.standardizedFileURL { try? FileManager.default.removeItem(at: payload) }
                }
                for failure in sent.failedRecordSaves {
                    if failure.error.code == .serverRecordChanged, let server = failure.error.serverRecord {
                        let downloaded = try await syncEngine.database.record(for: server.recordID)
                        try receive(downloaded)
                    }
                    else if failure.error.code == .zoneNotFound { syncEngine.state.add(pendingDatabaseChanges: [.saveZone(zone)]) }
                    else { report(failure.error) }
                }
                try store.persistSync(); enqueue()
            case .fetchedDatabaseChanges(let changes):
                if changes.deletions.contains(where: { $0.zoneID == zone.zoneID }) { paused = true; store.cloudStatus = "云端资料库被移除，同步暂停" }
            case .sentDatabaseChanges(let changes): for failed in changes.failedZoneSaves { report(failed.error) }
            case .didFetchRecordZoneChanges(let fetched): if let error = fetched.error { report(error) }
            default: break
            }
        } catch { pause(error) }
    }
    private func receive(_ record: CKRecord) throws {
        guard let store else { return }
        let name = record.recordID.recordName
        if record.recordType == "MarginPage" {
            guard let asset = record["payload"] as? CKAsset, let payload = asset.fileURL else { throw StoreError.corrupt }
            var remote = try JSONDecoder().decode(Note.self, from: Data(contentsOf: payload))
            guard name == "page_" + remote.id.uuidString else { throw StoreError.corrupt }
            if remote.permanentlyDeleted == true {
                guard store.saveEditors() else { throw CocoaError(.fileWriteUnknown) }
                store.workspace.mergePurge(PurgedPage(note: remote, date: remote.deletedAt ?? remote.modifiedAt))
                store.discardPurgedHistory(persist: true)
                try cacheRecord(record); return
            }
            if store.workspace.purgedPageIDs.contains(remote.id) {
                store.workspace.pending.insert(name)
                try cacheRecord(record); return
            }
            remote.blocks = remote.blocks.map(store.directories.indexed)
            if let index = store.workspace.notes.firstIndex(where: { $0.id == remote.id }) {
                let result = NoteMerge.merge(store.workspace.notes[index], remote)
                store.workspace.notes[index] = result.primary
                if result.primary != remote { store.workspace.pending.insert(name) }
                if let copy = result.conflict, !store.workspace.notes.contains(where: { $0.id == copy.id }) {
                    store.workspace.notes.append(copy); store.workspace.pending.insert("page_" + copy.id.uuidString)
                    store.message = "检测到同一页被同时修改，两个版本均已保留。请查看根目录的「冲突副本」。"
                }
            } else { store.workspace.notes.append(remote) }
        } // Legacy file payloads are not downloaded into index-only libraries.

        try cacheRecord(record)
    }
    private func report(_ error: Error) { store?.cloudStatus = "同步未完成"; store?.message = "iCloud：\(error.localizedDescription)" }
    private func pause(_ error: Error) { paused = true; report(error); store?.cloudStatus = "同步已暂停，本机内容保留" }
}
