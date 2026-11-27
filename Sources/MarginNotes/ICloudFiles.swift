import SwiftUI
import Darwin
#if SWIFT_PACKAGE
import MarginCore
#endif

/// Access history belongs to this Mac, not to the indexed library or the
/// preferences database. All decoding, encoding and file I/O uses one queue.
final class ICloudAccessMetadata: @unchecked Sendable {
    let url: URL
    private let preferences: UserDefaults
    private let legacyKey: String
    private let queue = DispatchQueue(label: "Libere.iCloudAccessMetadata", qos: .utility)
    private var loaded: [String: Date]?
    private var persisted: [String: Date] = [:]
    private var legacyData: Data?

    init(identity: String, preferences: UserDefaults, directory: URL? = nil) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Libere/Metadata", isDirectory: true)
        url = directory.appendingPathComponent(identity + ".json")
        self.preferences = preferences; legacyKey = "LibereICloudFiles." + identity + ".access"
    }
    func load() async throws -> [String: Date] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try self.read() }) }
        }
    }
    func loadSynchronously() throws -> [String: Date] { try queue.sync { try read() } }
    func save(_ values: [String: Date], completion: @escaping @Sendable (Error?) -> Void) {
        queue.async {
            do { try self.write(values); completion(nil) }
            catch { completion(error) }
        }
    }
    /// Called during application termination; drains pending saves before return.
    func flush(_ values: [String: Date]) throws { try queue.sync { try write(values) } }
    private func read() throws -> [String: Date] {
        if let loaded { return loaded }
        if FileManager.default.fileExists(atPath: url.path) {
            persisted = try JSONDecoder().decode([String: Date].self, from: Data(contentsOf: url))
        }
        legacyData = preferences.data(forKey: legacyKey)
        var values = persisted
        if let legacyData {
            let legacy = try JSONDecoder().decode([String: Date].self, from: legacyData)
            values.merge(legacy, uniquingKeysWith: max)
        }
        loaded = values
        return values
    }
    private func write(_ values: [String: Date]) throws {
        _ = try read()
        guard values != persisted || legacyData != nil else { return }
        let data = try JSONEncoder().encode(values)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let verified = try JSONDecoder().decode([String: Date].self, from: Data(contentsOf: url))
        guard verified == values else { throw CocoaError(.fileWriteUnknown) }
        persisted = values; loaded = values
        if let legacyData, preferences.data(forKey: legacyKey) == legacyData {
            preferences.removeObject(forKey: legacyKey)
        }
        legacyData = nil
    }
}

/// iCloud Drive availability is independent of CloudKit note synchronization.
struct ICloudFileSnapshot: Equatable, Sendable {
    var ubiquitous = false
    var local = false
    var current = false
    var regular = false
    var uploaded = false
    var uploading = false
    var downloading = false
    var conflicts = false
    var downloadStateKnown = true
    var accessDate: Date?
    var modifiedDate: Date?
    var error: String?
    var canEvict: Bool { ubiquitous && local && current && regular && uploaded && downloadStateKnown && !uploading && !downloading && !conflicts && error == nil }
    static func read(_ url: URL) throws -> Self {
        // These checks run off the main thread, where NSURL does not clear its
        // resource cache on the next main run-loop pass. Each poll must be fresh.
        var inspectedURL = url
        inspectedURL.removeAllCachedResourceValues()
        let values = try inspectedURL.resourceValues(forKeys: [.isUbiquitousItemKey, .isRegularFileKey,
            .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
            .ubiquitousItemIsDownloadingKey, .ubiquitousItemHasUnresolvedConflictsKey,
            .ubiquitousItemDownloadingErrorKey, .ubiquitousItemUploadingErrorKey,
            .contentAccessDateKey, .contentModificationDateKey])
        var materialized: Bool?
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus == nil {
            // Some File Providers omit the old ubiquity status. Check only the
            // indexed file's metadata; opening its contents would hydrate it.
            materialized = inspectedURL.withUnsafeFileSystemRepresentation { path -> Bool? in
                guard let path else { return nil }
                var info = stat()
                guard fstatat(AT_FDCWD, path, &info, 0) == 0 else { return nil }
                return (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) && (info.st_flags & UInt32(SF_DATALESS)) == 0
            }
        }
        return Self(resourceValues: values, materialized: materialized)
    }
}

extension ICloudFileSnapshot {
    init(resourceValues values: URLResourceValues, materialized: Bool? = nil) {
        self.init(ubiquitous: values.isUbiquitousItem == true, downloadingStatus: values.ubiquitousItemDownloadingStatus,
                  downloading: values.ubiquitousItemIsDownloading, regular: values.isRegularFile == true, materialized: materialized)
        uploaded = values.ubiquitousItemIsUploaded == true
        // Unknown safety metadata must never authorize eviction.
        uploading = values.ubiquitousItemIsUploading != false
        conflicts = values.ubiquitousItemHasUnresolvedConflicts != false
        accessDate = values.contentAccessDate; modifiedDate = values.contentModificationDate
        error = (values.ubiquitousItemDownloadingError ?? values.ubiquitousItemUploadingError)?.localizedDescription
    }
    init(ubiquitous: Bool, downloadingStatus: URLUbiquitousItemDownloadingStatus?, downloading: Bool?, regular: Bool, materialized: Bool? = nil) {
        self.init(ubiquitous: ubiquitous,
            local: ubiquitous ? downloadingStatus == .current || downloadingStatus == .downloaded || (downloadingStatus == nil && materialized == true) : regular,
            current: downloadingStatus == .current, regular: regular,
            downloading: ubiquitous && downloading == true, downloadStateKnown: downloading != nil)
    }
}

@MainActor final class ICloudFiles: ObservableObject {
    enum Availability: Equatable {
        case checking, local, remote, downloading, releasing, failed(String), unavailable(String)
        var needsObservation: Bool {
            switch self { case .checking, .remote, .downloading, .failed: return true; default: return false }
        }
    }
    static let inactivity: TimeInterval = 7 * 24 * 60 * 60
    @Published private var states: [String: Availability] = [:]
    @Published var automaticRelease: Bool { didSet { preferences.set(automaticRelease, forKey: preferenceKey + ".enabled") } }
    @Published private(set) var status = "已上传且 7 天未查阅的文件可自动释放本地下载"
    private let root: URL
    private let preferences: UserDefaults
    private let preferenceKey: String
    private var lastViewed: [String: Date] = [:]
    private let accessMetadata: ICloudAccessMetadata
    private var accessLoadTask: Task<Void, Never>?
    private var accessLoaded = false
    private var accessDirty = false
    private var leases: [String: Set<UUID>] = [:]
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var refreshRequests: [String: UUID] = [:]
    private var cloudPaths: Set<String> = []
    private var prefetchTask: Task<Void, Never>?
    private var sweepRunning = false
    private var cursor = 0
    private var persistTask: Task<Void, Never>?
    private let inspect: @Sendable (URL) throws -> ICloudFileSnapshot
    private let startDownload: @Sendable (URL) throws -> Void
    private let evict: @Sendable (URL) throws -> Void

    init(root: URL, preferences: UserDefaults = .standard, metadataDirectory: URL? = nil,
         inspect: @escaping @Sendable (URL) throws -> ICloudFileSnapshot = { try ICloudFileSnapshot.read($0) },
         download: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.startDownloadingUbiquitousItem(at: $0) },
         evict: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.evictUbiquitousItem(at: $0) }) {
        self.root = root; self.preferences = preferences; self.inspect = inspect; self.startDownload = download; self.evict = evict
        let identity = AssetFingerprint.sha256(Data(root.standardizedFileURL.resolvingSymlinksInPath().path.utf8))
        preferenceKey = "LibereICloudFiles." + identity
        automaticRelease = preferences.object(forKey: preferenceKey + ".enabled") as? Bool ?? true
        let metadata = ICloudAccessMetadata(identity: identity, preferences: preferences, directory: metadataDirectory)
        accessMetadata = metadata
        accessLoadTask = Task { [weak self] in
            do {
                let values = try await metadata.load()
                guard !Task.isCancelled else { return }
                self?.finishLoadingAccess(values)
            } catch { self?.accessFailure(error) }
        }
    }
    deinit { accessLoadTask?.cancel(); prefetchTask?.cancel(); persistTask?.cancel(); for task in downloadTasks.values { task.cancel() } }
    func path(for url: URL) -> String? { ReferencePath.relative(url, inside: root) }
    func availability(of url: URL) -> Availability { path(for: url).flatMap { states[$0] } ?? .checking }
    func retain(_ url: URL, token: UUID, now: Date = Date()) {
        guard let path = path(for: url) else { return }
        leases[path, default: []].insert(token); touch(path, now: now)
    }
    func release(_ url: URL, token: UUID, now: Date = Date()) {
        guard let path = path(for: url), leases[path]?.remove(token) != nil else { return }
        if leases[path]?.isEmpty == true {
            leases.removeValue(forKey: path); touch(path, now: now)
        }
    }
    func viewed(_ url: URL, now: Date = Date()) { if let path = path(for: url) { touch(path, now: now) } }
    private func touch(_ path: String, now: Date) {
        guard lastViewed[path] != now else { return }
        lastViewed[path] = now; accessDirty = true; persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }; self?.saveAccess()
        }
    }
    private func finishLoadingAccess(_ values: [String: Date], save: Bool = true) {
        guard !accessLoaded else { return }
        // A preview may have been opened while the old history was loading.
        if lastViewed.isEmpty { lastViewed = values }
        else { lastViewed.merge(values, uniquingKeysWith: max) }
        accessLoaded = true; accessDirty = true
        if save { saveAccess() }
    }
    private func accessFailure(_ error: Error) {
        status = (accessLoaded ? "访问记录暂时无法保存：" : "访问记录暂时无法读取，自动释放已暂停：") + error.localizedDescription
    }
    private func saveAccess() {
        guard accessLoaded, accessDirty else { return }
        accessDirty = false
        accessMetadata.save(lastViewed) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.accessDirty = true; self?.accessFailure(error)
            }
        }
    }
    func persist(now: Date = Date()) {
        persistTask?.cancel()
        // Persisting during termination also counts still-open previews as viewed
        // now, even if SwiftUI does not send onDisappear before process exit.
        for path in leases.keys { lastViewed[path] = max(lastViewed[path] ?? now, now) }
        do {
            if !accessLoaded { finishLoadingAccess(try accessMetadata.loadSynchronously(), save: false) }
            try accessMetadata.flush(lastViewed); accessDirty = false
        } catch { accessDirty = true; accessFailure(error) }
    }
    func refresh(_ url: URL) async {
        guard let path = path(for: url), states[path] != .releasing else { return }
        let request = UUID(); refreshRequests[path] = request
        let inspect = inspect
        let result = await Task.detached { Result { try inspect(url) } }.value
        guard !Task.isCancelled, states[path] != .releasing, refreshRequests[path] == request else { return }
        refreshRequests.removeValue(forKey: path)
        switch result {
        case .success(let value):
            if value.ubiquitous { cloudPaths.insert(path) } else { cloudPaths.remove(path) }
            if value.local { states[path] = .local }
            else if let error = value.error { states[path] = .failed(error) }
            else if value.ubiquitous {
                if !value.downloading, downloadTasks[path] == nil, case .failed = states[path] ?? .checking { return }
                states[path] = value.downloading || downloadTasks[path] != nil ? .downloading : .remote
            }
            else { states[path] = .unavailable("找不到原文件，请确认文件位置；本地文件不会从 iCloud 自动恢复。") }
        case .failure(let error): states[path] = .unavailable(error.localizedDescription)
        }
    }
    /// A visible waiting preview also notices downloads started in Finder and
    /// completions after an earlier error. It stops polling once content is local.
    func watch(_ url: URL, includeRemote: Bool = true) async {
        while !Task.isCancelled {
            await refresh(url)
            let state = availability(of: url)
            guard state == .downloading || (includeRemote && state.needsObservation) else { return }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) }
            catch { return }
        }
    }
    func download(_ url: URL) {
        guard let path = path(for: url), downloadTasks[path] == nil, states[path] != .releasing else { return }
        touch(path, now: Date()); states[path] = .downloading
        let inspect = inspect, start = startDownload
        downloadTasks[path] = Task { [weak self] in
            defer { self?.downloadTasks.removeValue(forKey: path) }
            do {
                try await Task.detached {
                    let state = try inspect(url)
                    if state.local { return }
                    guard state.ubiquitous else { throw CocoaError(.ubiquitousFileUnavailable) }
                    try start(url)
                }.value
                // Poll metadata only; never read the file to force an implicit download.
                for _ in 0..<180 {
                    guard !Task.isCancelled, let self else { return }
                    await self.refresh(url)
                    if case .local = self.availability(of: url) { return }
                    if case .failed = self.availability(of: url) { return }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                guard !Task.isCancelled, let self else { return }
                await self.refresh(url)
                if self.availability(of: url) != .local { self.states[path] = .failed("下载尚未完成，请检查网络后重试。") }
            } catch {
                guard !Task.isCancelled, let self else { return }
                await self.refresh(url)
                if self.availability(of: url) != .local { self.states[path] = .failed(error.localizedDescription) }
            }
        }
    }
    func requireLocal(_ url: URL) throws {
        guard path(for: url) != nil else { throw FileIndexError.outsideLibrary }
        guard availability(of: url) != .releasing else { throw Self.downloadRequired }
        let value = try inspect(url)
        guard value.local else { throw Self.downloadRequired }
        viewed(url)
    }
    static var downloadRequired: NSError { NSError(domain: "ICloudFile", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件保存在 iCloud，请先在预览中点击「下载文件」。"]) }
    /// The caller supplies indexed paths and open editor/reader paths. No directory
    /// enumeration occurs, and each timer tick inspects at most 32 old candidates.
    func maintain(indexedPaths: Set<String>, protectedPaths: Set<String>, now: Date = Date(), limit: Int = 32,
                  isProtected: @MainActor (String) -> Bool = { _ in false }) async {
        await accessLoadTask?.value
        guard accessLoaded, automaticRelease, !sweepRunning else { return }
        sweepRunning = true; defer { sweepRunning = false }
        let eligible = indexedPaths.filter(Self.manages)
        for path in lastViewed.keys.filter({ !eligible.contains($0) && leases[$0] == nil }) {
            lastViewed.removeValue(forKey: path); accessDirty = true
        }
        for path in eligible where lastViewed[path] == nil { lastViewed[path] = now; accessDirty = true }
        let old = eligible.filter { now.timeIntervalSince(lastViewed[$0] ?? now) >= Self.inactivity }.sorted()
        saveAccess()
        guard !old.isEmpty else { return }
        let count = min(max(0, limit), old.count), start = cursor % old.count
        cursor = (start + count) % old.count
        let inspect = inspect, evict = evict
        for offset in 0..<count {
            let path = old[(start + offset) % old.count]
            guard automaticRelease, !protectedPaths.contains(path), !isProtected(path), leases[path] == nil, downloadTasks[path] == nil,
                  let url = ReferencePath.resolve(path, inside: root) else { continue }
            let result = await Task.detached { Result { try inspect(url) } }.value
            guard automaticRelease, !Task.isCancelled, leases[path] == nil, downloadTasks[path] == nil,
                  !protectedPaths.contains(path), !isProtected(path), now.timeIntervalSince(lastViewed[path] ?? now) >= Self.inactivity,
                  case .success(let value) = result, value.canEvict,
                  now.timeIntervalSince(max(value.accessDate ?? .distantPast, value.modifiedDate ?? .distantPast)) >= Self.inactivity else { continue }
            let finalCheck = await Task.detached { Result { try inspect(url) } }.value
            guard automaticRelease, !Task.isCancelled, leases[path] == nil, downloadTasks[path] == nil,
                  !protectedPaths.contains(path), !isProtected(path), now.timeIntervalSince(lastViewed[path] ?? now) >= Self.inactivity,
                  case .success(let latest) = finalCheck, latest.canEvict,
                  now.timeIntervalSince(max(latest.accessDate ?? .distantPast, latest.modifiedDate ?? .distantPast)) >= Self.inactivity else { continue }
            refreshRequests.removeValue(forKey: path); states[path] = .releasing
            do {
                // No actor suspension between the final live protection check and
                // the OS eviction request: a new in-app editor/kernel cannot start
                // in that gap. All metadata queries remain off the UI actor.
                try evict(url)
                states[path] = .remote; status = "已释放本地下载，云端原文件与批注保留"
            } catch { states[path] = .checking; status = "部分文件暂时无法释放：" + error.localizedDescription }
        }
    }
    func isCloud(_ url: URL) -> Bool { path(for: url).map { cloudPaths.contains($0) } ?? false }
    func downloadPage(_ urls: [URL]) {
        let unique = Array(Set(urls.filter { path(for: $0) != nil })).sorted { $0.path < $1.path }
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            var completed = 0
            for url in unique {
                guard !Task.isCancelled, let self else { return }
                await self.refresh(url)
                if self.availability(of: url) != .local, self.isCloud(url) {
                    self.download(url)
                    while !Task.isCancelled, let path = self.path(for: url), self.downloadTasks[path] != nil {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
                guard !Task.isCancelled else { return }
                completed += 1; self.status = "本页下载检查：\(completed) / \(unique.count)"
            }
        }
    }
    /// Explicit release ignores age, while retaining every upload/conflict/open
    /// document/kernel protection. Visible previews must be collapsed first.
    func releasePage(_ urls: [URL], isProtected: @MainActor (String) -> Bool = { _ in false }) async {
        await accessLoadTask?.value
        guard accessLoaded else { return }
        while sweepRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return }
        }
        sweepRunning = true; defer { sweepRunning = false }
        var released = 0, kept = 0
        let inspect = inspect, evict = evict
        for url in Set(urls) {
            guard !Task.isCancelled, let path = path(for: url), Self.manages(path) else { continue }
            guard leases[path] == nil, downloadTasks[path] == nil, !isProtected(path) else { kept += 1; continue }
            let first = await Task.detached { Result { try inspect(url) } }.value
            guard case .success(let metadata) = first, metadata.canEvict else { kept += 1; continue }
            let second = await Task.detached { Result { try inspect(url) } }.value
            guard !Task.isCancelled, case .success(let latest) = second, latest.canEvict,
                  leases[path] == nil, downloadTasks[path] == nil, !isProtected(path) else { kept += 1; continue }
            refreshRequests.removeValue(forKey: path); states[path] = .releasing
            do { try evict(url); states[path] = .remote; cloudPaths.insert(path); released += 1 }
            catch { states[path] = .failed(error.localizedDescription); kept += 1 }
        }
        status = "已释放 \(released) 个本地下载；\(kept) 个使用中、未上传或非云端文件保持本地"
    }
    static func manages(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("."), !path.hasPrefix("/"), !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return false }
        let first = path.split(separator: "/").first.map(String.init) ?? ""
        return !["Assets", "Sync", "Recoveries"].contains(first) && path != "Projects/index.json"
            && path != "workspace.json" && path != "workspace.previous.json" && !(first.hasPrefix("History-") && first.hasSuffix(".json"))
    }
}

private struct ICloudObservation: Equatable {
    let url: URL?
    let pending: Bool
}

@MainActor struct ICloudFileGate<Content: View>: View {
    @ObservedObject var files: ICloudFiles
    let url: URL?
    var close: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content
    @ViewState private var token = UUID()
    @Environment(\.scenePhase) private var scenePhase
    private func buttonTitle(_ url: URL) -> String { if case .failed = files.availability(of: url) { return "重试" }; return "下载文件" }
    var body: some View {
        ZStack {
            if let url {
                switch files.availability(of: url) {
                case .local: content()
                case .checking: ProgressView("正在检查文件…").frame(maxWidth: .infinity, maxHeight: .infinity)
                case .releasing: ProgressView("正在释放本地下载…").frame(maxWidth: .infinity, maxHeight: .infinity)
                case .unavailable(let error):
                    VStack(spacing: 10) {
                        Label("文件暂不可用", systemImage: "doc.questionmark")
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Button("重新检查") { Task { await files.refresh(url) } }
                    }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .remote, .downloading, .failed:
                    VStack(spacing: 12) {
                        Image(systemName: "icloud.and.arrow.down").font(.title2).foregroundStyle(.secondary)
                        Text(url.lastPathComponent).font(.headline).lineLimit(2)
                        if case .failed(let error) = files.availability(of: url) { Text(error).font(.caption).foregroundStyle(.secondary) }
                        else { Text("原文件保存在 iCloud，下载后即可预览。").font(.caption).foregroundStyle(.secondary) }
                        if case .downloading = files.availability(of: url) {
                            ProgressView("正在下载…")
                            Button("重新检查") { Task { await files.refresh(url) } }
                        }
                        else { Button(buttonTitle(url)) { files.download(url) }.buttonStyle(.borderedProminent) }
                    }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else { ContentUnavailableView("找不到文件索引", systemImage: "doc.questionmark") }
        }
        .overlay(alignment: .topTrailing) {
            if let close, url.map({ files.availability(of: $0) != .local }) ?? true {
                Button("完成", action: close).keyboardShortcut(.cancelAction).padding(10)
            }
        }
        .task(id: ICloudObservation(url: url, pending: url.map { files.availability(of: $0).needsObservation } ?? false)) {
            guard let url else { return }
            files.retain(url, token: token); await files.watch(url)
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active, let url { Task { await files.refresh(url) } } }
        .onChange(of: url) { old, _ in if let old { files.release(old, token: token) } }
        .onDisappear { if let url { files.release(url, token: token) } }
    }
}

@MainActor struct ICloudStorageSettings: View {
    @ObservedObject var files: ICloudFiles
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("自动释放 7 天未查阅的 iCloud 文件", isOn: $files.automaticRelease)
            Text("仅释放已上传且未使用的本地下载，云端原文件保留；再次查看时可在预览中下载。")
                .font(.caption).foregroundStyle(.secondary)
            Text(files.status).font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor struct CloudFileBadge: View {
    @ObservedObject var files: ICloudFiles
    let url: URL
    @Environment(\.scenePhase) private var scenePhase
    private var label: String {
        switch files.availability(of: url) {
        case .checking: return "检查中"
        case .local: return files.isCloud(url) ? "已下载" : "本地"
        case .remote: return "云端"
        case .downloading: return "下载中"
        case .releasing: return "释放中"
        case .failed: return "下载失败"
        case .unavailable: return "不可用"
        }
    }
    private var icon: String {
        switch files.availability(of: url) {
        case .local: return files.isCloud(url) ? "checkmark.icloud" : "internaldrive"
        case .remote, .downloading: return "icloud.and.arrow.down"
        case .failed, .unavailable: return "exclamationmark.icloud"
        default: return "icloud"
        }
    }
    var body: some View {
        Label(label, systemImage: icon).font(.system(size: 9)).foregroundStyle(.secondary)
            .help(label).accessibilityLabel(label)
            .task(id: ICloudObservation(url: url, pending: files.availability(of: url) == .downloading)) { await files.watch(url, includeRemote: false) }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await files.refresh(url) } } }
    }
}
