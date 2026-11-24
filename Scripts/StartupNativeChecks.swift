import Foundation
import SwiftUI

private actor StartupCheckGate {
    private(set) var started = false
    private(set) var finished = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        if !released { await withCheckedContinuation { continuation = $0 } }
        finished = true
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

@MainActor func runStartupNativeChecks() async throws -> Int {
    var count = 0
    func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereStartupCheck-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try Repository(root: root)
    let visibleURL = root.appendingPathComponent("visible.py"), editorURL = root.appendingPathComponent("editor.py")
    try Data("visible".utf8).write(to: visibleURL); try Data("editor".utf8).write(to: editorURL)
    func reference(_ path: String) -> Block {
        var block = Block(.file, frame: Rect(20, 20, 380, 500))
        block.assetName = (path as NSString).lastPathComponent; block.relativeFilePath = path
        return block
    }
    var visible = Note(title: "首屏"), offscreen = Note(title: "打开的编辑器")
    visible.blocks = [reference("visible.py")]; offscreen.blocks = [reference("editor.py")]
    var pages = [visible, offscreen]
    for pageIndex in 0..<1000 {
        var page = Note(title: "资料 \(pageIndex)")
        page.blocks = (0..<31).map { reference("unopened/\(pageIndex)-\($0).py") }
        pages.append(page)
    }
    let workspace = Workspace(notes: pages)
    try repository.save(workspace)
    let originalBytes = try Data(contentsOf: repository.workspaceURL)
    let device = AppStore.deviceIdentifier()
    let before = DispatchTime.now().uptimeNanoseconds
    let prepared = try await Task.detached(priority: .userInitiated) { try AppStore.prepareStartup(root: root, device: device) }.value
    let preparedAt = DispatchTime.now().uptimeNanoseconds
    check(prepared.workspace == workspace, "Background preparation preserves the full existing workspace")
    check(Set(prepared.referenceStamps.keys) == ["visible.py"],
          "31,002 references require only the initial page's one metadata check at startup")
    let installBegan = DispatchTime.now().uptimeNanoseconds
    let store = try AppStore(root: root, prepared: prepared)
    let installedAt = DispatchTime.now().uptimeNanoseconds
    check(store.selection == visible.id && store.workspace == workspace, "Prepared data initializes the same selected page and document")
    check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Projects").path),
          "Opening a library does not rebuild all working directories")
    check((try? Data(contentsOf: repository.workspaceURL)) == originalBytes,
          "Opening an existing library does not rewrite workspace.json")
    do { _ = try AppStore(root: root.appendingPathComponent("wrong-root"), prepared: prepared); preconditionFailure("Accepted wrong prepared root") }
    catch { check(true, "A prepared snapshot cannot be attached to a different library") }

    let session = try store.textFileSession(noteID: offscreen.id, blockID: offscreen.blocks[0].id)
    try Data("visible file changed externally".utf8).write(to: visibleURL)
    try Data("offscreen editor changed externally".utf8).write(to: editorURL)
    store.refreshVisibleReferences()
    check(store.workspace.notes[0].blocks[0].contentRevision != nil && store.workspace.notes[1].blocks[0].contentRevision != nil,
          "Activation refreshes the current page and existing offscreen editor sessions")
    check(store.workspace.notes.dropFirst(2).allSatisfy { $0.blocks.allSatisfy { $0.contentRevision == nil } },
          "Activation leaves unrelated files and their page revisions untouched")
    let reopenedEditor = try store.textFileSession(noteID: offscreen.id, blockID: offscreen.blocks[0].id)
    check(reopenedEditor !== session && reopenedEditor.document.text == "offscreen editor changed externally",
          "An editor opened outside the initial page has a change baseline and reloads external edits")
    check(store.flush(), "Explicit saving persists only index data")
    check(FileManager.default.fileExists(atPath: store.directories.directory(for: visible.id, in: store.workspace).path),
          "The library root remains available after saving")

    let legacyRoot = root.appendingPathComponent("Legacy")
    let legacyRepository = try Repository(root: legacyRoot)
    var legacy = Workspace(notes: [Note(title: "旧资料库")]); legacy.schemaVersion = 1
    try legacyRepository.save(legacy)
    let legacyPrepared = try await Task.detached { try AppStore.prepareStartup(root: legacyRoot, device: device) }.value
    check(legacyPrepared.needsMigration && legacyPrepared.workspace?.schemaVersion == 3,
          "Legacy indexes are migrated during background preparation without scanning source files")
    check(try legacyRepository.load() == legacy, "A prepared or canceled library migration never rewrites the original index")
    _ = try AppStore(root: legacyRoot, prepared: legacyPrepared)
    check(try legacyRepository.load()?.schemaVersion == 3, "Adopting the prepared library durably commits the index migration")

    let fastRoot = root.appendingPathComponent("Fast")
    let fastRepository = try Repository(root: fastRoot)
    try fastRepository.save(Workspace(notes: [Note(title: "新选择的资料库")]))
    let fastPrepared = try await Task.detached { try AppStore.prepareStartup(root: fastRoot, device: device) }.value
    let gate = StartupCheckGate()
    let wasEnabled = UserDefaults.standard.object(forKey: "LibereAgentEnabled")
    UserDefaults.standard.set(false, forKey: "LibereAgentEnabled")
    defer {
        if let wasEnabled { UserDefaults.standard.set(wasEnabled, forKey: "LibereAgentEnabled") }
        else { UserDefaults.standard.removeObject(forKey: "LibereAgentEnabled") }
    }
    let bootstrap = Bootstrap(restoreOnInit: false, loader: { url, _ in
        if url == root { await gate.wait(); return prepared }
        if url == fastRoot { return fastPrepared }
        throw StoreError.corrupt
    })
    defer { bootstrap.agent?.stop() }
    bootstrap.open(root, remember: false)
    check(bootstrap.isLoading && bootstrap.store == nil, "Opening returns immediately with a loading state before I/O finishes")
    for _ in 0..<200 { if await gate.started { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    check(await gate.started, "The slow opening request reached background preparation")
    let loadingHost = NSHostingView(rootView: WorkspaceLoadingView())
    loadingHost.frame = NSRect(x: 0, y: 0, width: 980, height: 680); loadingHost.layoutSubtreeIfNeeded()
    check(!loadingHost.subviews.isEmpty, "The native loading view can lay out while data preparation is pending")
    bootstrap.open(fastRoot, remember: false)
    for _ in 0..<200 { if !bootstrap.isLoading { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    check(bootstrap.store?.repository.root == fastRoot && !bootstrap.isLoading,
          "A newer library choice is published while an earlier request is still pending")
    await gate.release()
    for _ in 0..<200 { if await gate.finished { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    try await Task.sleep(nanoseconds: 20_000_000)
    check(bootstrap.store?.repository.root == fastRoot, "A late canceled opening cannot replace the newer library")

    let retained = bootstrap.store!
    retained.edit { $0.title = "加载期间保留的修改" }
    bootstrap.open(root.appendingPathComponent("Corrupt"), remember: false)
    for _ in 0..<200 { if !bootstrap.isLoading { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    check(bootstrap.store === retained && bootstrap.error != nil && !bootstrap.isLoading,
          "A failed opening keeps the previous library available with an error")
    check((try? fastRepository.load())?.notes.first?.title == "加载期间保留的修改", "Old-library edits are saved before a failed switch")
    retained.edit { $0.title = "再次打开同一资料库" }
    bootstrap.open(fastRoot, remember: false)
    for _ in 0..<200 { if !bootstrap.isLoading { break }; try await Task.sleep(nanoseconds: 5_000_000) }
    check(bootstrap.store === retained && retained.note?.title == "再次打开同一资料库" && bootstrap.error == nil,
          "Reopening the same root retains the live store instead of restoring an older snapshot")

    let report: [String: Any] = ["pages": workspace.notes.count, "references": 31_002,
        "startup_reference_checks": prepared.referenceStamps.count,
        "background_prepare_ms": Double(preparedAt - before) / 1e6,
        "main_actor_store_ms": Double(installedAt - installBegan) / 1e6]
    print("STARTUP_BENCHMARK " + String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
    print("PASS: \(count) startup loading, metadata scope, cancellation and library-switch safety assertions")
    return count
}
