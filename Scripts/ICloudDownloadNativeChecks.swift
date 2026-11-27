import Foundation
import SwiftUI

private final class DownloadStateFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ICloudFileSnapshot
    private var reads = 0
    private var downloads = 0
    var failAfterCompleting = false
    init(_ value: ICloudFileSnapshot) { self.value = value }
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    var downloadCount: Int { lock.lock(); defer { lock.unlock() }; return downloads }
    func set(_ value: ICloudFileSnapshot) { lock.lock(); self.value = value; lock.unlock() }
    func read(_ url: URL) -> ICloudFileSnapshot { lock.lock(); defer { lock.unlock() }; reads += 1; return value }
    func download(_ url: URL) throws {
        lock.lock(); downloads += 1; value.local = true; value.current = true; let fail = failAfterCompleting; lock.unlock()
        if fail { throw CocoaError(.ubiquitousFileUnavailable) }
    }
}
private final class RefreshOrderFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let unblock = DispatchSemaphore(value: 0)
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    func read(_ url: URL) -> ICloudFileSnapshot {
        lock.lock(); count += 1; let first = count == 1; lock.unlock()
        if first { _ = unblock.wait(timeout: .now() + 5) }
        return ICloudFileSnapshot(ubiquitous: true, local: !first, current: !first, regular: true, downloading: first)
    }
}
@MainActor private final class DownloadReadyMarker: NSView {}
@MainActor private struct DownloadReadyContent: NSViewRepresentable {
    func makeNSView(context: Context) -> DownloadReadyMarker { DownloadReadyMarker() }
    func updateNSView(_ view: DownloadReadyMarker, context: Context) {}
}

@MainActor func runICloudDownloadNativeChecks() async throws -> Int {
    _ = NSApplication.shared
    var count = 0
    func check(_ value: Bool, _ label: String) {
        if !value { FileHandle.standardError.write(Data(("FAILED cloud readiness: " + label + "\n").utf8)) }
        precondition(value, label); count += 1
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereCloudReady-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "LibereCloudReady-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("ready.md"), bytes = Data("already downloaded".utf8)
    try bytes.write(to: file)
    let sameURL = file
    check(try ICloudFileSnapshot.read(sameURL).local, "A real regular file is initially available")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    let directory = try await Task.detached { try ICloudFileSnapshot.read(sameURL) }.value
    check(!directory.local && !directory.regular, "Reusing a URL cannot retain the old regular-file state after its backing item changes")
    try FileManager.default.removeItem(at: file); try bytes.write(to: file)
    let fresh = try await Task.detached { try ICloudFileSnapshot.read(sameURL) }.value
    check(fresh.local && !fresh.downloading && (try? Data(contentsOf: file)) == bytes,
          "The same URL observes the newly available file without changing its contents")

    let absent = ICloudFileSnapshot(ubiquitous: true, downloadingStatus: nil, downloading: nil, regular: true, materialized: false)
    let present = ICloudFileSnapshot(ubiquitous: true, downloadingStatus: nil, downloading: nil, regular: true, materialized: true)
    check(!absent.local && !absent.downloading, "Missing download metadata does not mean an active transfer")
    check(present.local && !present.canEvict, "A materialized file with omitted legacy status is readable but not eligible for eviction")
    var incomplete = ICloudFileSnapshot(ubiquitous: true, downloadingStatus: .current, downloading: nil, regular: true)
    incomplete.uploaded = true; incomplete.uploading = false; incomplete.conflicts = false
    check(incomplete.local && !incomplete.downloadStateKnown && !incomplete.canEvict,
          "Unknown transfer state still blocks eviction even when the UI can load local content")

    let order = RefreshOrderFixture()
    let racing = ICloudFiles(root: root, preferences: defaults, metadataDirectory: root.appendingPathComponent("meta"), inspect: { order.read($0) })
    let older = Task { await racing.refresh(file) }
    for _ in 0..<100 where order.readCount == 0 { try await Task.sleep(nanoseconds: 2_000_000) }
    check(order.readCount == 1, "The old status request is waiting while a newer query starts")
    await racing.refresh(file)
    check(racing.availability(of: file) == .local, "The newer local result becomes visible immediately")
    order.unblock.signal(); await older.value
    check(racing.availability(of: file) == .local, "A late obsolete downloading result cannot cover the completed file")

    let remote = ICloudFileSnapshot(ubiquitous: true, local: false, regular: true)
    let local = ICloudFileSnapshot(ubiquitous: true, local: true, current: true, regular: true)
    let backend = DownloadStateFixture(remote)
    let files = ICloudFiles(root: root, preferences: defaults, metadataDirectory: root.appendingPathComponent("gate-meta"),
        inspect: { backend.read($0) }, download: { try backend.download($0) })
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: ICloudFileGate(files: files, url: file) { DownloadReadyContent() })
    window.contentView = host
    defer { window.contentView = nil }
    for _ in 0..<100 {
        host.layoutSubtreeIfNeeded()
        if backend.readCount > 0 { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    check(!descendants(host).contains { $0 is DownloadReadyMarker }, "The real preview initially waits for a remote file")
    backend.set(local)
    for _ in 0..<250 {
        host.layoutSubtreeIfNeeded()
        if descendants(host).contains(where: { $0 is DownloadReadyMarker }) { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    check(descendants(host).contains { $0 is DownloadReadyMarker }, "A Finder-side completion reveals the real preview without recreating its URL or page")
    check(backend.downloadCount == 0, "Observing external completion never starts an implicit download")
    try files.requireLocal(file)

    var failed = remote; failed.error = "temporary network error"; backend.set(failed)
    await files.refresh(file)
    for _ in 0..<100 {
        host.layoutSubtreeIfNeeded()
        if !descendants(host).contains(where: { $0 is DownloadReadyMarker }) { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    backend.set(local)
    for _ in 0..<250 {
        host.layoutSubtreeIfNeeded()
        if descendants(host).contains(where: { $0 is DownloadReadyMarker }) { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    check(files.availability(of: file) == .local, "The mounted preview restarts observation after an error and recovers")

    let readyBackend = DownloadStateFixture(local)
    let alreadyReady = ICloudFiles(root: root, preferences: defaults, metadataDirectory: root.appendingPathComponent("ready-meta"),
        inspect: { readyBackend.read($0) }, download: { try readyBackend.download($0) })
    alreadyReady.download(file)
    for _ in 0..<100 where alreadyReady.availability(of: file) != .local { try await Task.sleep(nanoseconds: 5_000_000) }
    check(readyBackend.downloadCount == 0 && alreadyReady.availability(of: file) == .local, "A stale download button opens an already-local file without a second download")
    let errorBackend = DownloadStateFixture(remote); errorBackend.failAfterCompleting = true
    let completedWithError = ICloudFiles(root: root, preferences: defaults, metadataDirectory: root.appendingPathComponent("error-meta"),
        inspect: { errorBackend.read($0) }, download: { try errorBackend.download($0) })
    completedWithError.download(file)
    for _ in 0..<100 where completedWithError.availability(of: file) != .local { try await Task.sleep(nanoseconds: 5_000_000) }
    check(completedWithError.availability(of: file) == .local, "An API error arriving after materialization cannot hide completed content")
    print("PASS: \(count) fresh iCloud metadata, external completion, stale-result and native preview readiness assertions")
    return count
}
