import Foundation
import SwiftUI
import PDFKit

/// Exercise the production entry point used by Inspector/Canvas/search and its
/// shared window registry. The Inspector button closure is checked separately by
/// source review; hidden SwiftUI windows do not expose a usable AX button tree.
@MainActor func runInspectorReaderNativeChecks() async throws -> Int {
    var count = 0
    func check(_ value: Bool, _ label: String) {
        if !value { FileHandle.standardError.write(Data(("FAILED InspectorReader: " + label + "\n").utf8)) }
        precondition(value, label); count += 1
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereInspectorReader-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(root: root); store.create(); store.cancelRename()
    let image = NSImage(size: NSSize(width: 200, height: 300))
    image.lockFocus(); NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 200, height: 300)).fill(); image.unlockFocus()
    let pdf = PDFDocument(); pdf.insert(PDFPage(image: image)!, at: 0)
    let url = root.appendingPathComponent("inspector.pdf"); check(pdf.write(to: url), "The Inspector fixture contains a valid local PDF")
    store.importFile(url)
    guard let block = store.block, let noteID = store.selection else { preconditionFailure("Missing indexed fixture block") }
    let manager = PDFWindow.shared, originalPresentation = PDFWindow.shared.presentsWindows
    manager.presentsWindows = false
    let baseline = manager.windowCount
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: InspectorView(store: store)); window.contentView = host
    defer {
        manager.existingWindow(store: store, noteID: noteID, blockID: block.id)?.close()
        manager.presentsWindows = originalPresentation; window.contentView = nil
        store.flush()
    }
    host.layoutSubtreeIfNeeded()
    store.openAttachment(block)
    guard let first = manager.existingWindow(store: store, noteID: noteID, blockID: block.id) else { preconditionFailure("Inspector did not open the shared independent reader") }
    check(store.readerBlock == nil && window.attachedSheet == nil,
          "Inspector uses the Mac independent-window route without setting legacy sheet state")
    check(manager.windowCount == baseline + 1 && !first.styleMask.contains(.fullScreen),
          "Inspector opens one ordinary reader window instead of forcing full screen")
    store.openAttachment(block)
    await Task.yield()
    check(manager.windowCount == baseline + 1 && manager.existingWindow(store: store, noteID: noteID, blockID: block.id) === first,
          "Repeated calls through the Inspector entry reuse the same reader identity")
    store.openAttachment(block, page: 0)
    check(manager.existingWindow(store: store, noteID: noteID, blockID: block.id) === first,
          "Canvas/search opening shares the Inspector-created reader rather than creating another window")
    let source = root.appendingPathComponent("inspector-source.md")
    try Data("# 原文".utf8).write(to: source); store.importFile(source)
    guard let textBlock = store.block else { preconditionFailure("Missing text-file index") }
    let session = try store.textFileSession(noteID: noteID, blockID: textBlock.id)
    store.beginBlockEditing(textBlock.id); session.edit("# 已提交的编辑")
    store.openAttachment(textBlock)
    let textWindow = manager.existingWindow(store: store, noteID: noteID, blockID: textBlock.id)
    check(textWindow != nil && store.editingBlockID == nil && !session.hasUnsavedChanges,
          "The unified entry commits an inline file editor before opening its independent reader")
    check(try String(contentsOf: source, encoding: .utf8) == "# 已提交的编辑",
          "Inspector-style opening preserves the pending original-file edit")
    textWindow?.close()
    first.close()
    check(manager.windowCount == baseline && first.contentView == nil, "Closing the Inspector-created reader releases its registry and content")
    print("PASS: \(count) production Inspector reader routing and shared-window assertions")
    return count
}
