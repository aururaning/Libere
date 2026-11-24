import Foundation
import SwiftUI
import AppKit

@MainActor private final class PasteRouteTextView: NSTextView {
    var pasteCalls = 0
    override func paste(_ sender: Any?) { pasteCalls += 1 }
}

@MainActor func runPasteboardFileNativeChecks() async throws -> Int {
    _ = NSApplication.shared
    var count = 0
    func check(_ result: Bool, _ label: String) { precondition(result,label); count += 1 }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiberePasteboardFiles-" + UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    let a = root.appendingPathComponent("图 表#1.custom-extension"), b = root.appendingPathComponent("archive.zip")
    try Data("original A".utf8).write(to:a); try Data("original B".utf8).write(to:b)
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    check(board.writeObjects([a as NSURL,b as NSURL,a as NSURL]),"Finder-style URL pasteboard fixture is valid")
    check(CanvasPasteboardContents.fileURLs(from:board).map(\.path) == [a.path,b.path],
          "Modern file URLs preserve Unicode, special characters, order and deduplicate aliases")
    board.clearContents(); board.declareTypes([CanvasPasteboardContents.legacyFilenames],owner:nil)
    board.setPropertyList([b.path,a.path,b.path],forType:CanvasPasteboardContents.legacyFilenames)
    check(CanvasPasteboardContents.fileURLs(from:board).map(\.path) == [b.path,a.path],
          "Legacy Finder filename lists remain supported in their original order")
    board.clearContents()
    let one = NSPasteboardItem(), two = NSPasteboardItem()
    one.setData(Data(a.absoluteString.utf8),forType:.fileURL); two.setString(b.absoluteString,forType:.fileURL)
    board.writeObjects([one,two])
    check(CanvasPasteboardContents.fileURLs(from:board).map(\.path) == [a.path,b.path],
          "Item-level file URL data and strings are both read")
    board.clearContents(); board.setString("https://example.invalid/file.pdf",forType:.URL)
    check(CanvasPasteboardContents.fileURLs(from:board).isEmpty,"A web URL is not mistaken for an original file")
    check(CanvasPasteboardContents.textFileURLs("\"\(a.path)\"\n\(b.path)",libraryRoot:root)?.map(\.path) == [a.path,b.path],
          "Copied quoted pathname lists can be pasted as multiple files")
    check(CanvasPasteboardContents.textFileURLs("/api/" + UUID().uuidString,libraryRoot:root) == nil,
          "A non-file slash-prefixed string remains ordinary text")
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,
                                  hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    for x in 0..<2 { for y in 0..<2 { bitmap.setColor(NSColor(deviceRed:0.1,green:0.2,blue:0.9,alpha:1),atX:x,y:y) } }
    let png = bitmap.representation(using:.png,properties:[:])!, tiff = bitmap.tiffRepresentation!
    board.clearContents(); board.setData(tiff,forType:.tiff); board.setData(png,forType:.png)
    let raster = CanvasPasteboardContents.binaryFile(from:board)
    check(raster?.data == png && raster?.suggestedFilename.hasSuffix(".png") == true,
          "Raw clipboard PNG is returned byte-for-byte, without conversion or temporary files")
    board.clearContents(); board.setData(tiff,forType:.tiff)
    check(CanvasPasteboardContents.binaryFile(from:board)?.data == tiff,"TIFF-only clipboard content also preserves its original bytes")
    board.clearContents(); board.setString("ordinary text",forType:.string)
    check(CanvasPasteboardContents.binaryFile(from:board) == nil,"Text does not manufacture a binary file payload")

    let library = root.appendingPathComponent("Library"), store = try AppStore(root:library)
    store.create(); store.cancelRename(); store.fitToWidth = false; store.zoom = 1
    store.edit { $0.blocks = []; $0.canvasWidth = 1600; $0.canvasHeight = 2600 }
    let noteID = store.selection!
    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:700),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false
    let canvas = CanvasScrollView(frame:NSRect(x:0,y:0,width:1000,height:700)); canvas.pointerInteraction = store.canvasPointer
    canvas.update(pageID:noteID,size:CGSize(width:1600,height:2600),zoom:1,fitting:false,content:AnyView(Color.white))
    window.contentView = canvas; canvas.layoutSubtreeIfNeeded()
    let input = PasteRouteTextView(frame:NSRect(x:20,y:20,width:300,height:80)); input.isEditable = true
    canvas.host.addSubview(input); window.makeFirstResponder(input)
    defer { window.contentView = nil; store.flush() }
    check(store.isCanvasPasteWindow(window),"The library's pointer-owning viewport is recognized as the main paste destination")
    let reader = NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:500),styleMask:[.titled],backing:.buffered,defer:false)
    reader.isReleasedWhenClosed = false
    let readerViewport = CanvasScrollView(frame:NSRect(x:0,y:0,width:700,height:500))
    readerViewport.update(pageID:UUID(),size:CGSize(width:700,height:1000),zoom:1,fitting:false,content:AnyView(Color.white))
    reader.contentView = readerViewport
    let readerInput = PasteRouteTextView(frame:NSRect(x:10,y:10,width:280,height:100)); readerViewport.host.addSubview(readerInput); reader.makeFirstResponder(readerInput)
    defer { reader.contentView = nil }
    check(!store.isCanvasPasteWindow(reader),"A standalone reader is not confused with the main canvas even though it also zooms")
    board.clearContents(); board.writeObjects([a as NSURL,b as NSURL])
    let originalCount = store.note!.blocks.count
    store.pasteFocused(in:reader,pasteboard:board)
    check(readerInput.pasteCalls == 1 && store.note!.blocks.count == originalCount,
          "File paste in a standalone reader stays native and never inserts into the page behind it")
    board.clearContents(); board.setString("typed text",forType:.string)
    store.pasteFocused(in:window,pasteboard:board)
    check(input.pasteCalls == 1 && store.note!.blocks.count == originalCount,
          "Ordinary text paste still belongs to the active native editor")
    board.clearContents()
    // A Finder thumbnail representation must not be archived a second time.
    let fileWithThumbnail = NSPasteboardItem(), otherFile = NSPasteboardItem()
    fileWithThumbnail.setString(a.absoluteString,forType:.fileURL); fileWithThumbnail.setData(png,forType:.png)
    otherFile.setString(b.absoluteString,forType:.fileURL)
    board.writeObjects([fileWithThumbnail,otherFile])
    store.pasteFocused(in:window,pasteboard:board)
    await store.clipboardPastes.waitUntilIdle()
    check(input.pasteCalls == 1 && store.note!.blocks.count == originalCount + 2,
          "Multiple files take priority over stale editor focus, and their thumbnail is not duplicated: \(store.message ?? "")")
    let pasted = Array(store.note!.blocks.suffix(2))
    check(Set(pasted.map(\.assetName)) == Set([a.lastPathComponent,b.lastPathComponent]),
          "Unknown extensions and archives both become file cards")
    check(pasted.allSatisfy { $0.relativeFilePath != nil && store.attachmentURL(for:$0).map { ReferencePath.relative($0,inside:library) != nil } == true },
          "Copied external files are stored inside the selected library")
    check(try Data(contentsOf:a) == Data("original A".utf8) && Data(contentsOf:b) == Data("original B".utf8),
          "Archiving pasted external paths leaves both originals untouched")
    let rawCount = store.note!.blocks.count
    board.clearContents(); board.setData(png,forType:.png); window.makeFirstResponder(input)
    store.pasteFocused(in:window,pasteboard:board)
    await store.clipboardPastes.waitUntilIdle()
    check(store.note!.blocks.count == rawCount + 1 && input.pasteCalls == 1,"A raw clipboard image becomes one page file instead of disappearing into a text editor")
    check(try store.block.flatMap(store.attachmentURL).map { try Data(contentsOf:$0) } == png,"Raw PNG archival preserves the exact pasteboard bytes")
    board.clearContents(); board.setData(try store.clipboardData(for:[store.block!.id]),forType:CanvasPasteboardContents.canvasBlocks); board.setData(png,forType:.png)
    let blockCount = store.note!.blocks.count
    store.pasteFocused(in:window,pasteboard:board)
    check(store.note!.blocks.count == blockCount + 1,"An internal block payload wins over alternate raster representations")
    let point = CGPoint(x:900,y:1500)
    check(store.smartPaste("pasted at explicit point",at:point) && store.block?.frame.x == point.x && store.block?.frame.y == point.y,
          "Smart text paste forwards the caller's document-space pointer position")
    let copiedText = store.block!, textCount = store.note!.blocks.count
    board.clearContents(); board.setData(try store.clipboardData(for:[copiedText.id]),forType:CanvasPasteboardContents.canvasBlocks)
    board.setString(copiedText.text,forType:.string); board.setData(png,forType:.png)
    window.makeFirstResponder(input); store.pasteFocused(in:window,pasteboard:board)
    check(store.note!.blocks.count == textCount + 1 && store.block?.kind == .text
          && store.block?.reference?.blockID == copiedText.id && input.pasteCalls == 1,
          "Internal text blocks preserve source indexes ahead of stale editor focus and alternate raw data")
    let linkPoint = CGPoint(x:1000,y:1900)
    check(store.smartPaste("https://example.invalid/pointer",at:linkPoint) && store.block?.kind == .link
          && store.block?.frame.x == linkPoint.x && store.block?.frame.y == linkPoint.y,
          "Smart URL paste forwards the same explicit position")
    store.create(folder:true); store.cancelRename(); let folderID = store.selection!
    let folderContent = NSView(frame:NSRect(x:0,y:0,width:1000,height:700))
    let owner = LibraryPasteOwnerView(frame:.zero); owner.store = store; folderContent.addSubview(owner)
    window.makeFirstResponder(nil); window.contentView = folderContent
    check(store.isCanvasPasteWindow(window) && !store.isCanvasPasteWindow(reader),
          "The main folder overview marker permits file paste without admitting an unrelated reader")
    board.clearContents(); board.writeObjects([a as NSURL,b as NSURL])
    store.pasteFocused(in:window,pasteboard:board); await store.clipboardPastes.waitUntilIdle()
    check(store.workspace.children(folderID).count == 2,
          "Pasting files on a folder overview creates indexed child pages in that folder")
    print("PASS: \(count) clipboard file representation, editor priority and archive routing assertions")
    return count
}
