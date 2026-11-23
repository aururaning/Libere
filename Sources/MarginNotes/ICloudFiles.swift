import SwiftUI
#if SWIFT_PACKAGE
import MarginCore
#endif

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
    var accessDate: Date?
    var modifiedDate: Date?
    var error: String?
    var canEvict: Bool { ubiquitous && local && current && regular && uploaded && !uploading && !downloading && !conflicts && error == nil }
    static func read(_ url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .isRegularFileKey,
            .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
            .ubiquitousItemIsDownloadingKey, .ubiquitousItemHasUnresolvedConflictsKey,
            .ubiquitousItemDownloadingErrorKey, .ubiquitousItemUploadingErrorKey,
            .contentAccessDateKey, .contentModificationDateKey])
        let cloud = values.isUbiquitousItem == true
        let status = values.ubiquitousItemDownloadingStatus
        return Self(ubiquitous: cloud,
            local: cloud ? status == .current || status == .downloaded : FileManager.default.fileExists(atPath: url.path),
            current: status == .current, regular: values.isRegularFile == true,
            uploaded: values.ubiquitousItemIsUploaded == true,
            // Unknown safety metadata must never authorize eviction.
            uploading: values.ubiquitousItemIsUploading != false,
            downloading: cloud && values.ubiquitousItemIsDownloading != false,
            conflicts: values.ubiquitousItemHasUnresolvedConflicts != false,
            accessDate: values.contentAccessDate, modifiedDate: values.contentModificationDate,
            error: (values.ubiquitousItemDownloadingError ?? values.ubiquitousItemUploadingError)?.localizedDescription)
    }
}

@MainActor final class ICloudFiles: ObservableObject {
    enum Availability: Equatable {
        case checking, local, remote, downloading, releasing, failed(String), unavailable(String)
    }
    static let inactivity: TimeInterval = 7 * 24 * 60 * 60
    @Published private var states: [String: Availability] = [:]
    @Published var automaticRelease: Bool { didSet { preferences.set(automaticRelease, forKey: preferenceKey + ".enabled") } }
    @Published private(set) var status = "已上传且 7 天未查阅的文件可自动释放本地下载"
    private let root: URL
    private let preferences: UserDefaults
    private let preferenceKey: String
    private var lastViewed: [String: Date]
    private var leases: [String: Set<UUID>] = [:]
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var sweepRunning = false
    private var cursor = 0
    private var persistTask: Task<Void, Never>?
    private let inspect: @Sendable (URL) throws -> ICloudFileSnapshot
    private let startDownload: @Sendable (URL) throws -> Void
    private let evict: @Sendable (URL) throws -> Void

    init(root: URL, preferences: UserDefaults = .standard,
         inspect: @escaping @Sendable (URL) throws -> ICloudFileSnapshot = { try ICloudFileSnapshot.read($0) },
         download: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.startDownloadingUbiquitousItem(at: $0) },
         evict: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.evictUbiquitousItem(at: $0) }) {
        self.root = root; self.preferences = preferences; self.inspect = inspect; self.startDownload = download; self.evict = evict
        preferenceKey = "LibereICloudFiles." + AssetFingerprint.sha256(Data(root.standardizedFileURL.resolvingSymlinksInPath().path.utf8))
        automaticRelease = preferences.object(forKey: preferenceKey + ".enabled") as? Bool ?? true
        lastViewed = (preferences.data(forKey: preferenceKey + ".access")).flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
    }
    deinit { persistTask?.cancel(); for task in downloadTasks.values { task.cancel() } }
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
        lastViewed[path] = now; persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }; self?.persist()
        }
    }
    func persist(now: Date = Date()) {
        // Persisting during termination also counts still-open previews as viewed
        // now, even if SwiftUI does not send onDisappear before process exit.
        for path in leases.keys { lastViewed[path] = max(lastViewed[path] ?? now, now) }
        if let data = try? JSONEncoder().encode(lastViewed) { preferences.set(data, forKey: preferenceKey + ".access") }
    }
    func refresh(_ url: URL) async {
        guard let path = path(for: url), states[path] != .releasing else { return }
        let inspect = inspect
        let result = await Task.detached { Result { try inspect(url) } }.value
        guard !Task.isCancelled, states[path] != .releasing else { return }
        switch result {
        case .success(let value):
            if value.local { states[path] = .local }
            else if let error = value.error { states[path] = .failed(error) }
            else if value.ubiquitous { states[path] = value.downloading || downloadTasks[path] != nil ? .downloading : .remote }
            else { states[path] = .unavailable("找不到原文件，请确认文件位置；本地文件不会从 iCloud 自动恢复。") }
        case .failure(let error): states[path] = .unavailable(error.localizedDescription)
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
                    guard try inspect(url).ubiquitous else { throw CocoaError(.ubiquitousFileUnavailable) }
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
                self?.states[path] = .failed("下载尚未完成，请检查网络后重试。")
            } catch { self?.states[path] = .failed(error.localizedDescription) }
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
        guard automaticRelease, !sweepRunning else { return }
        sweepRunning = true; defer { sweepRunning = false }
        let eligible = indexedPaths.filter(Self.manages)
        lastViewed = lastViewed.filter { eligible.contains($0.key) || leases[$0.key] != nil }
        for path in eligible where lastViewed[path] == nil { lastViewed[path] = now }
        let old = eligible.filter { now.timeIntervalSince(lastViewed[$0] ?? now) >= Self.inactivity }.sorted()
        persist(now: now)
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
            states[path] = .releasing
            do {
                // No actor suspension between the final live protection check and
                // the OS eviction request: a new in-app editor/kernel cannot start
                // in that gap. All metadata queries remain off the UI actor.
                try evict(url)
                states[path] = .remote; status = "已释放本地下载，云端原文件与批注保留"
            } catch { states[path] = .checking; status = "部分文件暂时无法释放：" + error.localizedDescription }
        }
    }
    static func manages(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("."), !path.hasPrefix("/"), !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return false }
        let first = path.split(separator: "/").first.map(String.init) ?? ""
        return !["Assets", "Sync", "Recoveries"].contains(first) && path != "Projects/index.json"
            && path != "workspace.json" && path != "workspace.previous.json" && !(first.hasPrefix("History-") && first.hasSuffix(".json"))
    }
}

@MainActor struct ICloudFileGate<Content: View>: View {
    @ObservedObject var files: ICloudFiles
    let url: URL?
    var close: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content
    @SwiftUI.State private var token = UUID()
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
                        if case .downloading = files.availability(of: url) { ProgressView("正在下载…") }
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
        .task(id: url) {
            guard let url else { return }
            files.retain(url, token: token); await files.refresh(url)
            while !Task.isCancelled, files.availability(of: url) == .downloading {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if !Task.isCancelled { await files.refresh(url) }
            }
        }
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
