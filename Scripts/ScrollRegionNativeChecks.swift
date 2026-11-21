import Foundation
import SwiftUI

@MainActor func runScrollRegionNativeChecks() async throws -> Int {
    var count = 0
    func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereScrollRegions-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(root: root)
    store.create(); store.cancelRename(); store.fitToWidth = false
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let container = CanvasDocumentView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
    window.contentView = container
    defer { window.contentView = nil }
    let canvas = CanvasScrollView(frame: container.bounds)
    canvas.pointerInteraction = store.canvasPointer
    canvas.update(pageID: store.selection!, size: CGSize(width: 1200, height: 2600), zoom: 1, fitting: false, content: AnyView(Color.white))
    container.addSubview(canvas)
    // A sidebar can cover the detail view during split-view overlay/transitions.
    // Its points remain inside the detail's rectangle, but belong to the sidebar.
    let sidebar = NSScrollView(frame: NSRect(x: 0, y: 0, width: 245, height: 700))
    sidebar.documentView = CanvasDocumentView(frame: NSRect(x: 0, y: 0, width: 245, height: 2400))
    sidebar.hasVerticalScroller = true; container.addSubview(sidebar)
    container.layoutSubtreeIfNeeded(); canvas.layoutSubtreeIfNeeded(); sidebar.layoutSubtreeIfNeeded()
    let sidebarPoint = container.convert(CGPoint(x: 100, y: 150), to: nil)
    check(canvas.contentView.bounds.contains(canvas.contentView.convert(sidebarPoint, from: nil)), "Fixture reproduces overlapping sidebar/detail geometry")
    let before = canvas.contentView.bounds.origin
    check(!canvas.routeAttachmentScroll(at: sidebarPoint, in: window, delta: CGSize(width: 0, height: -60), precise: true),
          "The canvas must not consume a wheel event belonging to the sidebar")
    check(canvas.contentView.bounds.origin == before, "Sidebar wheel input cannot move the main page")
    SelectionWheel.scrollPage(sidebar, delta: CGSize(width: 0, height: -60), precise: true)
    check(sidebar.contentView.bounds.minY > 0, "The sidebar remains scrollable after the detail declines its wheel event")
    let selectedPage = store.selection!
    let block = Block(.text, frame: Rect(20, 20, 400, 300), text: "选中块")
    store.edit { $0.blocks = [block] }; store.selectBlock(block.id)
    for direction in [-80.0, 80.0] {
        check(!canvas.routeAttachmentScroll(at: sidebarPoint, in: window, delta: CGSize(width: 0, height: direction), precise: true),
              "Selecting a block never gives it ownership of sidebar wheel input")
    }
    check(canvas.pointerArea(at: sidebarPoint, in: window) == nil
          && !canvas.beginPointer(at: sidebarPoint, in: window, area: .paper, clickCount: 1),
          "Canvas pointer capture cannot steal sidebar disclosure clicks")
    let detailPoint = container.convert(CGPoint(x: 600, y: 150), to: nil)
    store.clearBlockSelection()
    check(canvas.routeAttachmentScroll(at: detailPoint, in: window, delta: CGSize(width: 0, height: -60), precise: true)
          && canvas.contentView.bounds.minY > before.y, "Uncovered detail input still scrolls the main page")
    canvas.isHidden = true
    check(!canvas.routeAttachmentScroll(at: detailPoint, in: window, delta: CGSize(width: 0, height: -60), precise: true),
          "A hidden detail viewport cannot capture another region's wheel input")

    let folder = NSScrollView(frame: container.bounds)
    let folderDocument = CanvasDocumentView(frame: NSRect(x: 0, y: 0, width: 1000, height: 2400))
    folder.documentView = folderDocument; folder.hasVerticalScroller = true
    container.addSubview(folder, positioned: .below, relativeTo: sidebar)
    store.create(folder: true); store.cancelRename()
    let marker = FolderWheelView(frame: .zero); marker.pageID = store.selection!; marker.store = store
    folderDocument.addSubview(marker); container.layoutSubtreeIfNeeded()
    let folderBefore = folder.contentView.bounds.origin
    for selection in [nil, store.selection] {
        store.folderBlockSelection = selection
        check(!marker.routeScroll(at: sidebarPoint, in: window, delta: CGSize(width: 0, height: -60), precise: true)
              && folder.contentView.bounds.origin == folderBefore, "Folder introductions also reject sidebar events with or without a selection")
    }
    store.folderBlockSelection = nil
    check(marker.routeScroll(at: detailPoint, in: window, delta: CGSize(width: 0, height: -60), precise: true),
          "The folder page still accepts events within its own region")

    let folderID = store.selection!
    store.create(parent: folderID); store.cancelRename(); let childID = store.selection!
    store.select(selectedPage); store.expandedPages.remove(folderID)
    let library = NSHostingView(rootView: LibraryView(store: store))
    window.contentView = library
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func disclosure() -> SidebarDisclosureControl? {
        descendants(library).compactMap { $0 as? SidebarDisclosureControl }.first { $0.pageID == folderID }
    }
    for _ in 0..<100 {
        library.layoutSubtreeIfNeeded()
        if disclosure() != nil { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard let button = disclosure() else { preconditionFailure("Production sidebar did not create its disclosure control") }
    check(button.bounds.width >= 28 && button.bounds.height >= 30, "The actual sidebar uses the enlarged disclosure rectangle")
    for point in [CGPoint(x: 2, y: 2), CGPoint(x: 26, y: 2), CGPoint(x: 2, y: 28), CGPoint(x: 26, y: 28)] {
        check(button.hitTest(button.convert(point, to: button.superview)) === button,
              "Padding around every corner of the disclosure glyph remains clickable")
    }
    button.performClick(nil)
    check(store.expandedPages.contains(folderID) && store.selection == selectedPage,
          "The production disclosure expands children without navigating away from the main page")
    library.layoutSubtreeIfNeeded(); await Task.yield(); library.layoutSubtreeIfNeeded()
    check(store.workspace.children(folderID).contains { $0.id == childID }, "Disclosure actions preserve the folder's contents")
    disclosure()?.performClick(nil)
    check(!store.expandedPages.contains(folderID) && store.selection == selectedPage,
          "The same disclosure collapses children without changing page selection")
    print("PASS: \(count) scroll region ownership assertions")
    return count
}
