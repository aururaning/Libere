import Foundation
import SwiftUI

@MainActor func runSelectionScrollNativeChecks() throws -> Int {
    var count = 0
    func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereSelectionWheel-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(root: root)
    store.create(folder: true); store.cancelRename()
    let pageID = store.selection!
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
    let document = CanvasDocumentView(frame: NSRect(x: 0, y: 0, width: 700, height: 2400))
    outer.documentView = document; outer.hasVerticalScroller = true
    window.contentView = outer
    defer { window.contentView = nil }
    let scope = BlockScrollHost(frame: NSRect(x: 30, y: 30, width: 500, height: 240)); scope.blockID = pageID
    document.addSubview(scope)
    let inner = NSScrollView(frame: scope.bounds)
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 1400))
    text.string = String(repeating: "目录正文\n", count: 100); text.isVerticallyResizable = false
    inner.documentView = text; inner.hasVerticalScroller = true; scope.addSubview(inner)
    let marker = FolderWheelView(frame: .zero); marker.pageID = pageID; marker.store = store; document.addSubview(marker)
    outer.layoutSubtreeIfNeeded(); inner.layoutSubtreeIfNeeded()
    func point() -> CGPoint { outer.contentView.convert(CGPoint(x: outer.contentView.bounds.midX, y: outer.contentView.bounds.minY + 100), to: nil) }
    check(marker.enclosingScrollView === outer, "The folder marker binds to its outer page scroll view")
    let firstInner = inner.contentView.bounds.origin
    check(marker.routeScroll(at: point(), in: window, delta: CGSize(width: 0, height: -40), precise: true), "The folder page handles unselected wheel input")
    check(outer.contentView.bounds.minY > 0 && inner.contentView.bounds.origin == firstInner,
          "Hovering an unselected folder introduction scrolls only the outer page")
    store.folderBlockSelection = pageID
    window.makeFirstResponder(text)
    let outerBefore = outer.contentView.bounds.origin
    check(marker.routeScroll(at: point(), in: window, delta: CGSize(width: 0, height: -40), precise: true), "A selected folder introduction receives the wheel")
    check(inner.contentView.bounds.minY > firstInner.y && outer.contentView.bounds.origin == outerBefore,
          "Selection transfers scrolling into the native introduction editor")
    check(window.firstResponder === text, "Wheel routing preserves the native editor focus and composition target")
    for direction in [-1.0, 1.0] {
        outer.contentView.scroll(to: CGPoint(x: 0, y: 900)); outer.reflectScrolledClipView(outer.contentView)
        let outerAtBoundary = outer.contentView.bounds.origin
        var end = inner.contentView.bounds; end.origin.y = direction < 0 ? 100_000 : 0
        inner.contentView.scroll(to: inner.contentView.constrainBoundsRect(end).origin); inner.reflectScrolledClipView(inner.contentView)
        let boundary = inner.contentView.bounds.origin
        for _ in 0..<8 {
            check(marker.routeScroll(at: point(), in: window, delta: CGSize(width: 0, height: 80 * direction), precise: true),
                  "Selected introduction hands repeated boundary wheel samples to its outer page")
        }
        check(inner.contentView.bounds.origin == boundary
              && (direction < 0 ? outer.contentView.bounds.minY > outerAtBoundary.y : outer.contentView.bounds.minY < outerAtBoundary.y),
              "Both directional boundaries chain to the folder page without changing inner selection or position")
    }
    store.folderBlockSelection = nil
    check(marker.routeScroll(at: point(), in: window, delta: CGSize(width: 0, height: -40), precise: false)
          && outer.contentView.bounds.minY > outerBefore.y,
          "Clearing selection restores outer scrolling for a conventional mouse wheel")
    store.create(folder: true); store.cancelRename()
    check(store.folderBlockSelection == nil && !marker.routeScroll(at: point(), in: window, delta: CGSize(width: 0, height: -40), precise: true),
          "Switching folders clears selection and disables the previous page's wheel monitor")
    print("PASS: \(count) folder selection, editor focus and scroll-boundary assertions")
    return count
}
