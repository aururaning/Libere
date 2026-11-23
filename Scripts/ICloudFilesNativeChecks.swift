import Foundation
import SwiftUI

private final class CloudFileFixture: @unchecked Sendable {
    private let lock = NSLock()
    var values: [String: ICloudFileSnapshot] = [:]
    private(set) var inspected: [String] = []
    private(set) var released: [String] = []
    private(set) var downloaded: [String] = []
    var delay: TimeInterval = 0
    var failingDownload = false
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return inspected.count }
    func read(_ url: URL) throws -> ICloudFileSnapshot {
        lock.lock(); inspected.append(url.lastPathComponent); let value = values[url.lastPathComponent] ?? ICloudFileSnapshot(); let delay = delay; lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return value
    }
    func evict(_ url: URL) throws { lock.lock(); defer { lock.unlock() }; released.append(url.lastPathComponent); values[url.lastPathComponent]?.local = false }
    func download(_ url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        downloaded.append(url.lastPathComponent)
        if failingDownload { throw CocoaError(.fileReadNoPermission) }
        values[url.lastPathComponent]?.local = true; values[url.lastPathComponent]?.current = true
    }
}

@MainActor func runICloudFilesNativeChecks() async throws -> Int {
    var count = 0
    func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereCloudFiles-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "LibereCloudFilesChecks-" + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    let now = Date(), old = now.addingTimeInterval(-8 * 86400)
    let safe = ICloudFileSnapshot(ubiquitous: true, local: true, current: true, regular: true, uploaded: true,
                                 uploading: false, downloading: false, conflicts: false, accessDate: old, modifiedDate: old)
    let backend = CloudFileFixture()
    let files = ICloudFiles(root: root, preferences: preferences, inspect: { try backend.read($0) }, download: { try backend.download($0) }, evict: { try backend.evict($0) })
    check(backend.inspected.isEmpty, "Opening the iCloud service performs no file scan")
    check(files.automaticRelease && ICloudFiles.inactivity == 7 * 86400, "The user-selected seven-day policy is enabled by default")
    let paths: Set<String> = ["old.md", "recent.md", "editor.md", "visible.md", "unsynced.md", "uploading.md", "downloading.md", "conflict.md", "local.md", "folder.md", "stale.md", "error.md", "modified.md"]
    for path in paths {
        backend.values[path] = safe
        try Data(("source " + path).utf8).write(to: root.appendingPathComponent(path))
        files.viewed(root.appendingPathComponent(path), now: old)
    }
    files.viewed(root.appendingPathComponent("recent.md"), now: now)
    let visibleToken = UUID(); files.retain(root.appendingPathComponent("visible.md"), token: visibleToken, now: old)
    backend.values["unsynced.md"]?.uploaded = false
    backend.values["uploading.md"]?.uploading = true
    backend.values["downloading.md"]?.downloading = true
    backend.values["conflict.md"]?.conflicts = true
    backend.values["local.md"]?.ubiquitous = false
    backend.values["folder.md"]?.regular = false
    backend.values["stale.md"]?.current = false
    backend.values["error.md"]?.error = "upload error"
    backend.values["modified.md"]?.modifiedDate = now
    await files.maintain(indexedPaths: paths, protectedPaths: ["editor.md"], now: now)
    check(backend.released == ["old.md"], "Only an old, uploaded, current, conflict-free, unused iCloud file is released")
    check(!backend.inspected.contains("editor.md") && !backend.inspected.contains("visible.md"), "Open editor and visible preview protections prevent metadata or eviction work")
    check(files.availability(of: root.appendingPathComponent("old.md")) == .remote, "Successful release presents a download placeholder")
    for path in paths { check(try Data(contentsOf: root.appendingPathComponent(path)) == Data(("source " + path).utf8), "Eviction logic never removes or overwrites original bytes") }
    for path in ["workspace.json", "workspace.previous.json", "History-device.json", "Projects/index.json", "Assets/file", "Sync/file", "Recoveries/file", "project/.git/config", "../outside", "/absolute"] {
        check(!ICloudFiles.manages(path), "Control files, legacy assets and unsafe paths are excluded from automatic release")
    }
    let unknown = (0..<1000).map { "unopened-\($0).pdf" }
    let before = backend.inspected.count
    await files.maintain(indexedPaths: Set(unknown), protectedPaths: [], now: now)
    check(backend.inspected.count == before, "First registering a large library records access baselines without scanning files")
    for path in unknown { files.viewed(root.appendingPathComponent(path), now: old); backend.values[path] = safe }
    let boundedBefore = backend.inspected.count
    await files.maintain(indexedPaths: Set(unknown), protectedPaths: [], now: now, limit: 8)
    check(backend.inspected.count - boundedBefore == 16, "A maintenance tick inspects only the configured eight candidates, with a second safety check before release")
    files.automaticRelease = false
    let disabledBefore = backend.released.count
    await files.maintain(indexedPaths: Set(unknown), protectedPaths: [], now: now)
    check(backend.released.count == disabledBefore, "Disabling automatic release prevents evictions")
    let restored = ICloudFiles(root: root, preferences: preferences, inspect: { try backend.read($0) }, download: { try backend.download($0) }, evict: { try backend.evict($0) })
    check(!restored.automaticRelease, "The user's automatic-release preference survives reopening")

    let thresholdBackend = CloudFileFixture(); thresholdBackend.values["threshold.md"] = safe
    let thresholdRoot = root.appendingPathComponent("threshold"), thresholdURL = thresholdRoot.appendingPathComponent("threshold.md")
    let threshold = ICloudFiles(root: thresholdRoot, preferences: preferences,
        inspect: { try thresholdBackend.read($0) }, download: { try thresholdBackend.download($0) }, evict: { try thresholdBackend.evict($0) })
    threshold.viewed(thresholdURL, now: now.addingTimeInterval(-ICloudFiles.inactivity + 1)); threshold.persist()
    let reloaded = ICloudFiles(root: thresholdRoot, preferences: preferences,
        inspect: { try thresholdBackend.read($0) }, download: { try thresholdBackend.download($0) }, evict: { try thresholdBackend.evict($0) })
    await reloaded.maintain(indexedPaths: ["threshold.md"], protectedPaths: [], now: now)
    check(thresholdBackend.released.isEmpty, "Persisted access times keep a file local until seven full days have elapsed")
    await reloaded.maintain(indexedPaths: ["threshold.md"], protectedPaths: [], now: now.addingTimeInterval(1))
    check(thresholdBackend.released == ["threshold.md"], "Seven full inactive days make an otherwise safe file eligible after reopening")

    let remote = root.appendingPathComponent("remote.md")
    var remoteState = safe; remoteState.local = false; remoteState.current = false
    backend.values[remote.lastPathComponent] = remoteState
    await files.refresh(remote)
    check(files.availability(of: remote) == .remote && backend.downloaded.isEmpty, "Preview inspection does not silently download cloud files")
    do { try files.requireLocal(remote); preconditionFailure("Remote edit unexpectedly hydrated a file") }
    catch { check(backend.downloaded.isEmpty, "Opening an editor on a remote file asks for a preview download instead") }
    files.download(remote)
    for _ in 0..<100 {
        if files.availability(of: remote) == .local { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    check(backend.downloaded == ["remote.md"] && files.availability(of: remote) == .local, "Explicit preview download transitions to local content after completion")
    try files.requireLocal(remote)
    let failed = root.appendingPathComponent("failed.md"); backend.values[failed.lastPathComponent] = remoteState; backend.failingDownload = true
    files.download(failed)
    for _ in 0..<100 { if case .failed = files.availability(of: failed) { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    if case .failed = files.availability(of: failed) { check(true, "Download errors are visible and leave the source indexed") } else { preconditionFailure("Missing download failure state") }

    let raceBackend = CloudFileFixture(); raceBackend.values["race.md"] = safe; raceBackend.delay = 0.04
    let race = ICloudFiles(root: root.appendingPathComponent("race"), preferences: preferences, inspect: { try raceBackend.read($0) }, download: { try raceBackend.download($0) }, evict: { try raceBackend.evict($0) })
    let raceURL = root.appendingPathComponent("race/race.md"); race.viewed(raceURL, now: old)
    let maintenance = Task { await race.maintain(indexedPaths: ["race.md"], protectedPaths: [], now: now) }
    try await Task.sleep(nanoseconds: 10_000_000)
    race.retain(raceURL, token: UUID(), now: now)
    await maintenance.value
    check(raceBackend.released.isEmpty, "A preview opened while metadata is being checked cancels pending release")
    let closingBackend = CloudFileFixture(); closingBackend.values["long-open.md"] = safe
    let closingRoot = root.appendingPathComponent("closing"), closingURL = closingRoot.appendingPathComponent("long-open.md")
    let closing = ICloudFiles(root: closingRoot, preferences: preferences,
        inspect: { try closingBackend.read($0) }, download: { try closingBackend.download($0) }, evict: { try closingBackend.evict($0) })
    let closingToken = UUID(); closing.retain(closingURL, token: closingToken, now: old)
    closing.release(closingURL, token: closingToken, now: now)
    await closing.maintain(indexedPaths: ["long-open.md"], protectedPaths: [], now: now)
    check(closingBackend.released.isEmpty, "Closing a preview kept open over seven days starts a fresh inactivity period")
    await closing.maintain(indexedPaths: ["long-open.md"], protectedPaths: [], now: now.addingTimeInterval(ICloudFiles.inactivity))
    check(closingBackend.released == ["long-open.md"], "A closed preview becomes eligible seven days after its last close")

    let dynamicBackend = CloudFileFixture(); dynamicBackend.values["data.csv"] = safe; dynamicBackend.delay = 0.04
    let dynamicRoot = root.appendingPathComponent("dynamic"), dynamicURL = dynamicRoot.appendingPathComponent("data.csv")
    let dynamic = ICloudFiles(root: dynamicRoot, preferences: preferences,
        inspect: { try dynamicBackend.read($0) }, download: { try dynamicBackend.download($0) }, evict: { try dynamicBackend.evict($0) })
    dynamic.viewed(dynamicURL, now: old)
    var kernelStarted = false
    let pending = Task { await dynamic.maintain(indexedPaths: ["data.csv"], protectedPaths: [], now: now,
                                               isProtected: { _ in kernelStarted }) }
    for _ in 0..<100 { if dynamicBackend.readCount >= 2 { break }; try await Task.sleep(nanoseconds: 2_000_000) }
    check(dynamicBackend.readCount >= 2, "The concurrency fixture reached the final metadata safety query")
    kernelStarted = true
    await pending.value
    check(dynamicBackend.released.isEmpty, "A kernel started during the final metadata query protects its working-directory files")
    kernelStarted = false
    await dynamic.maintain(indexedPaths: ["data.csv"], protectedPaths: [], now: now, isProtected: { _ in kernelStarted })
    check(dynamicBackend.released == ["data.csv"], "An inactive working directory becomes eligible again after live protection clears")
    let localURL = root.appendingPathComponent("ordinary.md"); try Data("local content".utf8).write(to: localURL)
    let missingURL = root.appendingPathComponent("missing.md")
    let missingManager = ICloudFiles(root: root, preferences: preferences)
    await missingManager.refresh(missingURL)
    if case .unavailable = missingManager.availability(of: missingURL) { check(true, "Missing local files show recheck rather than a cloud download prompt") }
    else { preconditionFailure("Missing local file offered a cloud download") }
    let real = try ICloudFileSnapshot.read(localURL)
    check(real.local && !real.ubiquitous && !real.canEvict, "Real non-iCloud files are readable and never eligible for eviction")
    print("PASS: \(count) iCloud availability, explicit download and safe local-release assertions")
    return count
}
