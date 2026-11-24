import Foundation
import SwiftUI

@MainActor func runClipboardArchiveNativeChecks() async throws -> Int {
    _ = NSApplication.shared
    var count = 0
    func check(_ value: Bool, _ message: String) {
        if !value { FileHandle.standardError.write(Data(("FAILED clipboard archive: " + message + "\n").utf8)) }
        precondition(value, message); count += 1
    }
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("LiberePasteIntegration-" + UUID().uuidString)
    let root = fixture.appendingPathComponent("library"), outside = fixture.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let original = outside.appendingPathComponent("资料.zip"), bytes = Data([0x50,0x4b,0,0xff,0x80])
    try bytes.write(to: original)
    let store = try AppStore(root: root)
    store.create(); store.cancelRename(); let first = store.selection!
    var existing = Block(.text, frame: Rect(680,1020,100,90), text: "existing")
    existing.locked = true
    store.edit { $0.paper = .a4; $0.blocks = [existing]; $0.ink = Data([7,8,9]) }
    let before = store.note!, point = CGPoint(x: 690, y: 1040)
    check(store.pasteFileURLs([original], at: point), "Outside file paste is accepted immediately")
    check(store.clipboardPastes.pendingCount == 1, "A file archive is represented as pending background work")
    store.create(); store.cancelRename(); let other = store.selection!, otherBlocks = store.note!.blocks
    await store.clipboardPastes.waitUntilIdle()
    let archivedPage = store.workspace.notes.first { $0.id == first }!
    let pasted = archivedPage.blocks.last!
    check(store.selection == other && store.note!.blocks == otherBlocks, "Navigation while copying never redirects the destination")
    check(pasted.frame.x == point.x && pasted.frame.y == point.y, "Paste starts exactly at the requested pointer even over occupied space")
    check(archivedPage.paper.isContinuous && archivedPage.width >= pasted.frame.maxX && archivedPage.height >= pasted.frame.maxY,
          "Paper grows to retain pointer placement at its right/bottom edge")
    check(archivedPage.blocks.first == existing && archivedPage.ink == before.ink, "Existing locked content and handwriting remain unchanged")
    let archived = store.attachmentURL(for: pasted)!
    check(pasted.relativeFilePath!.contains("/压缩包/") && archived != original, "Outside file is archived by type in the page directory")
    check(try Data(contentsOf: original) == bytes && Data(contentsOf: archived) == bytes, "Source and archived original both preserve bytes")
    store.undo()
    check(store.workspace.notes.first { $0.id == first }!.blocks == before.blocks, "One undo removes the entire pasted batch")
    check(FileManager.default.fileExists(atPath: archived.path), "Undo retains the independent archived original for recovery and redo")
    store.redo()
    check(store.workspace.notes.first { $0.id == first }!.blocks.last?.relativeFilePath == pasted.relativeFilePath, "Redo restores the same file index")

    store.select(first)
    let payload = try store.clipboardData(for: [pasted.id])
    store.select(other)
    check(store.pasteBlocks(payload, at: CGPoint(x: 140, y: 190)), "Internal file block paste creates a source index synchronously")
    let alias = store.block!
    check(alias.relativeFilePath == pasted.relativeFilePath && alias.fileIdentity == pasted.fileIdentity && alias.reference == FileReference(noteID: first, blockID: pasted.id),
          "Internal paste shares original identity and captures source page/block")
    check(store.clipboardPastes.pendingCount == 0, "Internal references never enter the archive-copy queue")
    store.revealReferenceSource(alias)
    check(store.selection == first && store.blockSelection == pasted.id && store.revealBlockID == pasted.id, "Jump to original reveals the exact source block")
    store.revealBlockID = nil

    let owned = store.directories.directory(for: first, in: store.workspace).appendingPathComponent("owned.txt")
    try Data("owned".utf8).write(to: owned)
    check(store.indexFileURLs([owned]), "Fixture contains a library-owned indexed source")
    let ownedID = store.block!.fileIdentity
    check(store.pasteFileURLs([original, owned], at: CGPoint(x: 80, y: 250)), "Mixed outside-copy and library-reference paste starts")
    check(store.renamePage(first, to: "移动后的页面"), "Target page may be renamed while copying runs")
    await store.clipboardPastes.waitUntilIdle()
    let moved = store.workspace.notes.first { $0.id == first }!, mixed = Array(moved.blocks.suffix(2))
    check(mixed.count == 2 && mixed.last?.fileIdentity == ownedID, "Reference relocation follows stable IDs even if prepare begins after rename")
    check(mixed.allSatisfy { $0.relativeFilePath?.hasPrefix("移动后的页面/") == true }, "Copied and referenced files use the page's current directory")
    check(mixed[0].assetName.contains("(2)") && FileManager.default.fileExists(atPath: store.attachmentURL(for: mixed[0])!.path),
          "Repeated same-name pastes archive a distinct file without overwriting")

    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jGZkAAAAASUVORK5CYII=")!
    check(store.pasteClipboardFileData(png, suggestedFilename: "剪贴板图片.png", at: CGPoint(x: 210,y:330)), "Clipboard pixels without a path can become a new archived original")
    await store.clipboardPastes.waitUntilIdle()
    let imageBlock = store.block!
    check(imageBlock.relativeFilePath?.contains("/图片/") == true && imageBlock.frame.x == 210 && imageBlock.frame.y == 330,
          "Raw clipboard images use their type directory and pointer position")
    check(try Data(contentsOf: store.attachmentURL(for: imageBlock)!) == png, "Raw data is preserved without image conversion")

    store.create(folder: true); store.cancelRename(); let folder = store.selection!
    check(store.pasteFileURLs([original], at: nil), "A folder page accepts file paste")
    await store.clipboardPastes.waitUntilIdle()
    check(store.selection == folder && store.workspace.children(folder).count == 1, "Folder paste creates an indexed child without changing current navigation")
    check(store.pasteBlocks(payload), "A folder page also accepts existing in-app file blocks")
    let internalChild = store.workspace.children(folder).first { $0.blocks.first?.fileIdentity == pasted.fileIdentity }
    check(internalChild?.blocks.first?.reference == FileReference(noteID: first, blockID: pasted.id),
          "An internal paste on a folder creates a source-linked child page")
    check(store.selection == folder && store.clipboardPastes.pendingCount == 0,
          "Internal folder paste remains synchronous and never archives the original again")

    let viewport = CanvasScrollView(frame: NSRect(x: 0,y:0,width:900,height:650))
    let window = NSWindow(contentRect: NSRect(x: 150,y:140,width:900,height:650),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false; window.contentView = viewport; viewport.pointerInteraction = store.canvasPointer
    defer { window.contentView = nil }
    let page = UUID(), knownPoint = CGPoint(x: 850,y:1300)
    for scale in [0.5,1.0,1.5,2.0] {
        viewport.update(pageID: page, size: CGSize(width:2000,height:3500), zoom:scale, fitting:false, content:AnyView(Color.white))
        viewport.layoutSubtreeIfNeeded(); viewport.reveal(CGRect(x: knownPoint.x,y:knownPoint.y,width:1,height:1)); viewport.layoutSubtreeIfNeeded()
        let inWindow = viewport.paper.convert(knownPoint,to:nil)
        let actual = viewport.clipboardPoint(at:inWindow,in:window,allowingFallback:false)
        check(actual.map { abs($0.x-knownPoint.x)<0.01 && abs($0.y-knownPoint.y)<0.01 } == true,
              "Native pointer conversion accounts for scrolling and \(scale)x magnification")
        let menuPoint = NSPoint(x:-1000,y:-1000), fallback = viewport.clipboardPoint(at:menuPoint,in:window)
        check(fallback.map { abs($0.x-knownPoint.x)<0.01 && abs($0.y-knownPoint.y)<0.01 } == true,
              "Menu paste retains the last pointer location inside the paper")
    }
    check(viewport.clipboardPoint(at:.zero,in:nil) == nil, "Another window cannot supply a paste location")
    viewport.update(pageID:UUID(),size:CGSize(width:2000,height:3500),zoom:1,fitting:false,content:AnyView(Color.white))
    let afterNavigation = viewport.clipboardPoint(at:NSPoint(x:-1000,y:-1000),in:window)
    check(afterNavigation != knownPoint, "Changing pages discards the old page's cached pointer")
    print("PASS: \(count) clipboard archive, source reference, captured-page and native pointer assertions")
    return count
}
