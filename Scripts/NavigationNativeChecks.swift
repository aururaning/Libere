import Foundation
import SwiftUI
import Combine

@MainActor private struct NavigationCanvasFixture: View {
    @ObservedObject var store: AppStore
    var body: some View { if let note = store.note { NoteCanvas(store: store, note: note) } }
}

@MainActor func runNavigationNativeChecks() async throws -> Int {
    var count = 0
    func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }

    var parent = Note(title: "项目", folder: true)
    parent.sidebarOrder = 0
    let child = Note(title: "子页", parent: parent.id)
    var sibling = Note(title: "同级", parent: parent.id); sibling.sidebarOrder = 0
    let orphan = Note(title: "孤立页", parent: UUID())
    var deleted = Note(title: "回收页", folder: true); deleted.deleted = true
    let recoveredChild = Note(title: "可见子页", parent: deleted.id)
    var a = Note(title: "循环 A"), b = Note(title: "循环 B")
    a.parentID = b.id; b.parentID = a.id
    let library = Workspace(notes: [parent, child, sibling, orphan, deleted, recoveredChild, a, b])
    let trees = NoteTree.build(library)
    func flatten(_ trees: [NoteTree]) -> [UUID] { trees.flatMap { [$0.id] + flatten($0.children ?? []) } }
    let ids = flatten(trees)
    check(ids.count == 7 && Set(ids) == Set(library.notes.filter { !$0.deleted }.map(\.id)),
          "Indexed sidebar includes every live page exactly once, including orphan and cyclic parents")
    check(trees.first?.id == parent.id && trees.first?.children?.map(\.id) == [sibling.id, child.id],
          "Indexed sidebar preserves manual ordering and nesting")
    check(library.moveTargets(for: parent.id).map(\.id) == [orphan.id, recoveredChild.id, a.id, b.id],
          "Move destinations exclude the whole subtree and deleted pages")

    var longPage = Note(title: "大量内容")
    longPage.blocks = (0..<300).map { i in
        var block = Block(.text, frame: Rect(20, Double(i * 800 + 20), 380, 180), text: "内容 \(i)")
        block.textFormat = nil // Native text keeps this fixture independent of WebKit processes.
        return block
    }
    let original = longPage
    let state = CanvasContentState(), viewportSize = CGSize(width: 800, height: 600)
    check(state.blocks(in: longPage, viewport: viewportSize, zoom: 1, preserving: []).count == 2,
          "Opening a 300-block page admits only the nearby two cards")
    let far = longPage.blocks[150].id
    check(state.blocks(in: longPage, viewport: viewportSize, zoom: 1, preserving: [far]).contains { $0.id == far },
          "An offscreen selected, editing or dragging card is admitted immediately")
    var updates = 0
    let subscription = state.$loadedIDs.dropFirst().sink { _ in updates += 1 }
    state.update(pageID: longPage.id, visible: CGRect(origin: .zero, size: viewportSize), blocks: longPage.blocks)
    let firstUpdates = updates
    for offset in 1...20 { state.update(pageID: longPage.id, visible: CGRect(x: 0, y: offset, width: 800, height: 600), blocks: longPage.blocks) }
    check(updates == firstUpdates, "Small scroll samples do not republish an unchanged set of cards")
    state.update(pageID: longPage.id, visible: CGRect(x: 0, y: 24_000, width: 800, height: 600), blocks: longPage.blocks)
    check(state.loadedIDs.contains(longPage.blocks[0].id) && state.loadedIDs.contains(longPage.blocks[30].id)
          && state.loadedIDs.count < 8, "A long jump retains active cards and loads the destination without loading the gap")
    var another = Note(title: "另一页")
    another.blocks = [Block(.text, frame: Rect(20, 20, 380, 180), text: "另一页")]
    state.schedule(pageID: longPage.id, visible: CGRect(x: 0, y: 48_000, width: 800, height: 600), blocks: longPage.blocks)
    state.schedule(pageID: another.id, visible: CGRect(origin: .zero, size: viewportSize), blocks: another.blocks)
    try await Task.sleep(nanoseconds: 20_000_000)
    check(state.pageID == another.id && state.loadedIDs == Set(another.blocks.map(\.id)),
          "Rapid navigation coalesces queued viewport reports and discards the old page's retained cards")
    check(longPage == original, "Lazy admission never changes frames, contents, ink or page metadata")
    withExtendedLifetime(subscription) {}

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereNavigationCheck-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(root: root)
    let firstURL = root.appendingPathComponent("first.py"), secondURL = root.appendingPathComponent("second.py")
    try Data("first".utf8).write(to: firstURL); try Data("second".utf8).write(to: secondURL)
    var first = Note(title: "第一个文件"), alias = Note(title: "同文件的引用"), unrelated = Note(title: "其他文件")
    var firstBlock = Block(.file, frame: Rect(20, 20, 380, 500)); firstBlock.relativeFilePath = "first.py"; firstBlock.assetName = "first.py"
    var aliasBlock = firstBlock; aliasBlock.id = UUID()
    var otherBlock = Block(.file, frame: Rect(20, 20, 380, 500)); otherBlock.relativeFilePath = "second.py"; otherBlock.assetName = "second.py"
    first.blocks = [firstBlock]; alias.blocks = [aliasBlock]; unrelated.blocks = [otherBlock]
    store.workspace = Workspace(notes: [first, alias, unrelated]); store.refreshReferencedFiles()
    try Data("first modified externally".utf8).write(to: firstURL)
    try Data("second modified externally".utf8).write(to: secondURL)
    store.select(first.id)
    let firstRevision = store.workspace.notes[0].blocks[0].contentRevision
    check(firstRevision != nil && store.workspace.notes[1].blocks[0].contentRevision == firstRevision,
          "Opening a changed direct reference updates every alias of that file")
    check(store.workspace.notes[2].blocks[0].contentRevision == nil,
          "Opening one page does not refresh unrelated files elsewhere in the library")
    store.select(unrelated.id)
    check(store.workspace.notes[2].blocks[0].contentRevision != nil,
          "The other file is refreshed as soon as its page is opened")
    _ = try store.textFileSession(noteID: first.id, blockID: firstBlock.id)
    try Data("open editor changed externally again".utf8).write(to: firstURL)
    store.select(unrelated.id)
    check(store.workspace.notes[0].blocks[0].contentRevision != firstRevision && store.saveEditors(),
          "Offscreen open editors are refreshed too, so a stale session cannot block another page's undo/save")
    check(store.flush(), "Scoped reference revisions are durable")

    // Exercise the real production NoteCanvas in an offscreen native hierarchy.
    store.workspace = Workspace(notes: [longPage, another]); store.select(longPage.id)
    store.fitToWidth = false; store.grid = false
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: viewportSize), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: NavigationCanvasFixture(store: store)); window.contentView = host
    defer { window.contentView = nil; store.flush() }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func layout() async throws {
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 15_000_000) }
        host.layoutSubtreeIfNeeded()
    }
    func renderedIDs() -> Set<UUID> {
        Set(descendants(host).compactMap { view in
            guard let surface = view as? CanvasPointerView else { return nil }
            switch surface.area {
            case .body(let id), .border(let id), .move(let id), .resize(let id): return id
            case .paper: return nil
            }
        })
    }
    try await layout()
    let initialIDs = renderedIDs()
    check(initialIDs.contains(longPage.blocks[0].id) && initialIDs.count < 8,
          "Production canvas creates nearby native card surfaces rather than all 300 cards")
    guard let scroll = descendants(host).compactMap({ $0 as? CanvasScrollView }).first else { preconditionFailure("Missing production viewport") }
    scroll.contentView.scroll(to: CGPoint(x: 0, y: 24_000)); scroll.reflectScrolledClipView(scroll.contentView)
    try await layout()
    check(renderedIDs().contains(longPage.blocks[30].id) && renderedIDs().isSuperset(of: initialIDs) && renderedIDs().count < 12,
          "Native scrolling loads destination cards while preserving existing card state")
    store.select(another.id)
    try await layout()
    check(renderedIDs() == Set(another.blocks.map(\.id)), "Switching pages releases the previous page's native cards")
    check(store.workspace.notes[0].blocks == original.blocks && store.workspace.notes[0].ink == original.ink,
          "Native viewport loading does not rewrite the user's content")

    var reported: (UUID, CGRect)?
    let probe = CanvasScrollView(frame: CGRect(origin: .zero, size: viewportSize)); window.contentView = probe
    probe.didChangeVisibleRect = { reported = ($0, $1) }
    for zoom in [0.25, 0.5, 1.0, 2.0, 6.0] {
        probe.update(pageID: longPage.id, size: CGSize(width: 1000, height: 40_000), zoom: zoom, fitting: true, content: AnyView(EmptyView()))
        probe.layoutSubtreeIfNeeded()
        probe.contentView.scroll(to: CGPoint(x: 0, y: 8000)); probe.reflectScrolledClipView(probe.contentView)
        let expected = probe.paper.convert(probe.contentView.bounds, from: probe.contentView)
        check(reported?.0 == longPage.id && reported?.1 == expected,
              "Visible range uses native paper coordinates at zoom \(zoom)")
    }
    print("PASS: \(count) navigation, scoped refresh and lazy canvas loading assertions")
    return count
}
