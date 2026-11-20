import Foundation
import SwiftUI
import WebKit

@MainActor func runFolderOverviewUINativeChecks() async throws -> Int {
    var count = 0
    func check(_ result: Bool, _ label: String) { precondition(result, label); count += 1 }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereFolderOverviewUI-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(root: root)
    store.create(folder: true); store.cancelRename()
    let folderID = store.selection!
    store.create(parent: folderID); store.cancelRename()
    let childID = store.selection!
    store.edit { $0.title = "课程资料" }
    store.select(folderID)
    let initial = "# 我的分类\n\n## 课程\n- " + PageLink.markdown(title: "课程资料", id: childID)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: FolderOverview(store: store, noteID: folderID, defaultText: initial)
        .frame(width: 640).frame(height: 720, alignment: .top))
    window.contentView = host
    defer { window.contentView = nil }
    func navigation() -> MarkdownNavigation? {
        descendants(host).compactMap { $0 as? WKWebView }.compactMap { $0.navigationDelegate as? MarkdownNavigation }.first
    }
    func editor() -> NSTextView? { descendants(host).compactMap { $0 as? NSTextView }.first }
    func settle(until condition: () -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded(); await Task.yield(); host.layoutSubtreeIfNeeded()
            if condition() { return true }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    check(try await settle { navigation() != nil }, "The actual folder introduction creates a native Markdown preview")
    let originalNavigation = navigation()!
    check(originalNavigation.html.contains("<h1>我的分类</h1>")
          && originalNavigation.html.contains("<h2>课程</h2>")
          && originalNavigation.html.contains(PageLink.url(for: childID).absoluteString),
          "The default introduction renders headings and the real child-page link")
    check(store.note!.folderOverview == nil && editor() == nil,
          "Displaying a default introduction neither persists it nor starts an editor")

    check(store.beginFolderOverviewEditing(noteID: folderID), "The folder editor session starts")
    check(try await settle { editor() != nil && window.firstResponder === editor() },
          "Entering introduction editing creates and automatically focuses the actual native text editor")
    let text = editor()!
    check(text.string == initial && store.formatting.view === text && store.formatting.blockID == folderID,
          "The folder editor shares the actual native formatting state with a stable folder identity")
    check(store.note!.folderOverview == nil,
          "Entering the editor without typing does not replace nil with the default text")
    check(store.finishFolderOverviewEditing(noteID: folderID), "Finishing the unchanged folder editor saves successfully")
    check(try await settle { editor() == nil && navigation() != nil },
          "Finishing the folder editor restores the Markdown preview")
    check(store.note!.folderOverview == nil && store.folderOverviewEditingID == nil,
          "An unchanged edit preserves the default and releases the editor session")

    // Use the navigation delegate owned by the actual preview. This checks the
    // FolderOverview openPage closure without waiting for HTML rendering or
    // launching an external app.
    let activeNavigation = navigation()!
    check(activeNavigation.openPageLink(PageLink.url(for: childID)) && store.selection == childID,
          "A real folder-preview page link selects its child page")
    store.select(folderID)
    let beforeExternal = store.selection
    check(!activeNavigation.openPageLink(URL(string: "https://example.com/page")!) && store.selection == beforeExternal,
          "An external URL is not mistaken for an internal page navigation")
    check(!activeNavigation.openPageLink(URL(string: "libere://page/not-a-uuid")!) && store.selection == beforeExternal,
          "A malformed internal link cannot change the selected page")
    if let index = store.workspace.notes.firstIndex(where: { $0.id == childID }) { store.workspace.notes[index].deleted = true }
    store.message = nil
    check(activeNavigation.openPageLink(PageLink.url(for: childID))
          && store.selection == folderID && store.message == "这个页面已移入回收站或不存在。",
          "A deleted child link stays on the folder and explains why it cannot open")

    print("PASS: \(count) folder introduction native preview, focus, completion and page-link routing assertions")
    return count
}
