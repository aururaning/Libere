import Foundation
import SwiftUI
import PencilKit
import PDFKit

typealias ViewState<Value> = SwiftUI.State<Value>

private final class HTMLFixtureProtocol: URLProtocol {
    static let bytes = Data("<!doctype html><html><head><title>原始网页</title></head><body><h1>保真 HTML</h1><img src='asset.png'><script>window.example=1</script></body></html>".utf8)
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.bytes); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main @MainActor struct NativeChecks {
    static func main() async throws {
        precondition(Bundle.main.bundleIdentifier == "app.marginnotes.nativechecks", "Run through Scripts/check-native.sh so PencilKit has a bundle identifier")
        if CommandLine.arguments.contains("--sidebar-only") { _ = try runSidebarNativeChecks(); return }
        if CommandLine.arguments.contains("--scroll-regions-only") { _ = try await runScrollRegionNativeChecks(); return }
        if CommandLine.arguments.contains("--content-selection-only") { _ = try await runContentSelectionNativeChecks(); return }
        if CommandLine.arguments.contains("--batch-only") { _ = try runCanvasBatchNativeChecks(); return }
        if CommandLine.arguments.contains("--reader-fixes-only") { _ = try await runInspectorReaderNativeChecks(); _ = try await runReaderReflowNativeChecks(); _ = try await runNotebookEditorIdentityNativeChecks(); return }
        if CommandLine.arguments.contains("--clipboard-only") {
            _ = try await runClipboardLinksNativeChecks()
            _ = try await runPasteboardFileNativeChecks()
            _ = try await runClipboardArchiveNativeChecks()
            _ = try await runGenericFileNativeChecks()
            return
        }
        if CommandLine.arguments.contains("--guide-only") {
            _ = try runFeatureGuideNativeChecks()
            _ = try await runGuideLifecycleNativeChecks()
            _ = try await runGuideTipNativeChecks()
            return
        }
        if CommandLine.arguments.contains("--build30-only") {
            _ = try await runClipboardMoveNativeChecks()
            _ = try await runTitleCanvasFocusNativeChecks()
            _ = try await runBlockDeleteShortcutNativeChecks()
            _ = try await runSidebarNestingNativeChecks()
            _ = try await runPDFPreviewNativeChecks()
            _ = try runSelectionScrollNativeChecks()
            _ = try await runICloudFilesNativeChecks()
            return
        }
        var checks = 0
        func check(_ result: @autoclosure () -> Bool, _ label: String) {
            let passed = result()
            if !passed { FileHandle.standardError.write(Data(("FAILED native: " + label + "\n").utf8)) }
            precondition(passed, label); checks += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MarginNativeCheck-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AppStore(root: root)
        store.create(); store.insert(.text)
        check(store.block?.usesMarkdown == true, "New text uses Markdown")
        store.formatText(.grow(2))
        check(store.block?.fontSize == 24, "Font size changes without editor focus")
        store.formatText(.font("Songti SC"))
        check(store.block?.fontFamily == "Songti SC", "Preview font style")
        let id = store.block!.id
        store.editBlock(id) { $0.text = "文字 $x^2$ **结论**" }
        check(store.flush(), "Markdown autosave")
        let saved = try store.repository.load()
        check(saved?.notes.flatMap(\.blocks).first(where: { $0.id == id })?.text == "文字 $x^2$ **结论**", "Saved source intact")
        var points: [PKStrokePoint] = []
        for index in 0..<3 {
            let location = CGPoint(x: CGFloat(20 + index * 10), y: CGFloat(30 + index * 5))
            let point = PKStrokePoint(location: location, timeOffset: Double(index) / 60,
                                      size: CGSize(width: 3, height: 3), opacity: 1, force: 0.5, azimuth: 0, altitude: .pi / 2)
            points.append(point)
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: .systemBlue), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        let drawing = PKDrawing(strokes: [stroke])
        let decoded = try PKDrawing(data: drawing.dataRepresentation())
        check(decoded.strokes.count == 1 && decoded.strokes[0].path.count == 3, "Mac stroke uses PencilKit data")
        check(!decoded.bounds.isEmpty && decoded.bounds.minX < 20 && decoded.bounds.maxX > 40, "Stroke bounds preserve page coordinates")
        // Exercise the actual Mac view's committed drawing path, including reload and disabled input.
        func raster(_ drawing: PKDrawing) -> (NSBitmapImageRep, Int) {
            let view = MacInkView(frame: NSRect(x: 0, y: 0, width: 800, height: 1200))
            view.update(data: drawing.dataRepresentation(), enabled: false)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 1200, bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
            graphics.cgContext.clear(CGRect(x: 0, y: 0, width: 800, height: 1200))
            graphics.cgContext.translateBy(x: 0, y: 1200); graphics.cgContext.scaleBy(x: 1, y: -1)
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
            var visible = 0
            for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                if bitmap.colorAt(x: x, y: y)!.alphaComponent > 0.05 { visible += 1 }
            } }
            return (bitmap, visible)
        }
        check(raster(decoded).1 > 30, "Reloaded committed ink remains visible when drawing is disabled")
        let mask = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 800, height: 1200)); mask.windingRule = .evenOdd
        mask.appendRect(NSRect(x: 0, y: 0, width: 100, height: 100))
        let masked = PKDrawing(strokes: [PKStroke(ink: stroke.ink, path: stroke.path, mask: mask)])
        check(raster(masked).1 == 0, "Outside ink cannot paint inside the excluded attachment")
        let excluded = [CGRect(x: 10, y: 10, width: 50, height: 50), CGRect(x: 30, y: 30, width: 50, height: 50)]
        let areas = InkClip.areas(in: CGRect(x: 0, y: 0, width: 100, height: 100), excluding: excluded)
        check(areas.reduce(0) { $0 + $1.width * $1.height } == 5900
              && !areas.contains { $0.contains(CGPoint(x: 40, y: 40)) }, "Overlapping attachment frames leave no outside-ink hole")
        check(InkOptions(style: .monoline, color: .red, width: 8).pointWidth(pressure: 0.2) == 8,
              "Monoline width stays constant")
        check(InkOptions(style: .pen, color: .blue, width: 8).pointWidth(pressure: 0.2)
              < InkOptions(style: .pen, color: .blue, width: 8).pointWidth(pressure: 0.8), "Pen responds to pressure")
        if let arg = CommandLine.arguments.firstIndex(of: "--ink-fixture"), arg + 1 < CommandLine.arguments.count {
            let file = URL(fileURLWithPath: CommandLine.arguments[arg + 1])
            let workspace = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: file))
            for note in workspace.notes {
                if let data = note.ink {
                    let restoredDrawing = try PKDrawing(data: data), result = raster(restoredDrawing)
                    check(result.1 > 100, "User's saved Sidecar strokes are visible through the repaired renderer")
                    print("Recovered Sidecar fixture: \(restoredDrawing.strokes.count) strokes, \(result.1) visible pixels")
                    if arg + 2 < CommandLine.arguments.count, let png = result.0.representation(using: .png, properties: [:]) {
                        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[arg + 2]))
                    }
                }
            }
        }

        store.create(); store.insert(.pdf)
        let attachment = store.block!, noteID = store.note!.id
        let page0 = InkDestination(noteID: noteID, blockID: attachment.id, page: 0)
        let page1 = InkDestination(noteID: noteID, blockID: attachment.id, page: 1)
        let outside = InkDestination(noteID: noteID)
        store.saveInk(drawing.dataRepresentation(), bounds: Rect(18, 28, 24, 14), to: outside)
        store.saveInk(drawing.dataRepresentation(), bounds: Rect(18, 28, 24, 14), to: page0)
        var red = stroke; red.ink = PKInk(.pen, color: .systemRed)
        let redDrawing = PKDrawing(strokes: [red])
        store.saveInk(redDrawing.dataRepresentation(), bounds: Rect(18, 28, 24, 14), to: page1)
        store.editPage(page0) { $0.texts.append(PageTextAnnotation(frame: Rect(12, 50, 180, 90), text: "第一页文字")) }
        store.addAnchor(CGPoint(x: 430, y: 80)); let external = store.note!.anchors.last!
        store.annotate(external); let externalBlock = store.block!
        store.editBlock(attachment.id) { $0.pdfPage = 1; $0.locked = true }
        check(store.flush(), "Save independent attachment pages")
        let reopened = try AppStore(root: root)
        let recoveredNote = reopened.workspace.notes.first { $0.id == noteID }!
        let recoveredBlock = recoveredNote.blocks.first { $0.id == attachment.id }!
        check(recoveredBlock.annotations(on: 0).ink == drawing.dataRepresentation(), "Page one survives restart")
        check(recoveredBlock.annotations(on: 1).ink == redDrawing.dataRepresentation(), "Page two survives restart independently")
        check(recoveredBlock.annotations(on: 0).texts.first?.text == "第一页文字", "Page text survives restart")
        check(recoveredNote.ink == drawing.dataRepresentation() && recoveredNote.blocks.contains(externalBlock), "Turning a page leaves outside ink and branches unchanged")
        store.create()
        store.saveInk(nil, bounds: nil, to: page1)
        check(store.note?.ink == nil && store.note?.blocks.isEmpty == true, "Delayed old-page callback cannot write into the selected note")
        let original = store.workspace.notes.first { $0.id == noteID }!.blocks.first { $0.id == attachment.id }!
        check(original.annotations(on: 0).ink != nil && original.annotations(on: 1).ink == nil, "Eraser clears only its captured page")
        // Drive the actual NSTextInputClient and the editor delegate with a UTF-16 prefix.
        let inputBlock = Block(.text, frame: Rect(20, 20, 300, 180), text: "🍎")
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        var committed: [String] = []
        let editor = RichTextEditor(block: inputBlock, formatting: TextFormatting(), focus: {}, checkpoint: {}) { rtf, source in
            check(rtf == nil, "Markdown commits plain source")
            committed.append(source)
        }
        let delegate = editor.makeCoordinator()
        textView.isRichText = false; textView.string = inputBlock.text; textView.delegate = delegate
        delegate.lastText = inputBlock.text
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        let replace = NSRange(location: NSNotFound, length: 0)
        textView.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0), replacementRange: replace)
        delegate.changed(textView)
        check(textView.hasMarkedText() && committed.isEmpty, "Marked candidate stays out of saved source")
        textView.setMarkedText("pinyin", selectedRange: NSRange(location: 6, length: 0), replacementRange: replace)
        textView.insertText("拼音", replacementRange: replace)
        check(!textView.hasMarkedText() && committed == ["🍎拼音"], "Chinese commit after emoji reaches the editor delegate once")
        let format = TextFormatting(); format.markdown = true; format.view = textView
        textView.setSelectedRange(NSRange(location: 2, length: 2)); format.apply(.bold)
        check(textView.string == "🍎**拼音**" && textView.selectedRange() == NSRange(location: 4, length: 2), "Format Chinese UTF-16 selection")
        withExtendedLifetime(delegate) {}

        for kind in [BlockKind.text, .formula, .pdf, .file] {
            store.create(); store.insert(kind)
            let owner = store.block!
            let point = CGPoint(x: owner.frame.maxX + 16, y: owner.frame.y + 20)
            store.addAnchor(point)
            let first = store.note!.anchors.last!
            check(first.ownerID == owner.id, "Every block can own a point: \(kind)")
            store.annotate(first)
            let child = store.block!
            store.annotate(first)
            check(store.block?.id == child.id && store.note?.blocks.count == 2, "Occupied point reopens the same child")
            store.addAnchor(CGPoint(x: child.frame.x, y: child.frame.maxY + 20))
            let second = store.note!.anchors.last!
            store.annotate(second)
            check(store.block?.anchorID == second.id && second.ownerID == child.id, "Create a second-level branch")
            store.deleteBlock(owner.id)
            check(store.note?.blocks.first(where: { $0.id == child.id })?.anchorID == nil
                  && store.note?.anchors.contains(where: { $0.id == second.id }) == true, "Remove owner while retaining child subtree")
            store.undo()
            check(store.note?.blocks.first(where: { $0.id == child.id })?.anchorID == first.id, "Undo restores complete hierarchy")
        }

        let imported = [("demo.py", "print('中文')"), ("demo.html", "<h1>标题</h1>"),
                        ("demo.ipynb", ##"{"nbformat":4,"cells":[{"cell_type":"markdown","source":"# 标题"}]}"##)]
        var importedIDs: [UUID] = []
        store.create()
        for (name, source) in imported {
            let url = root.appendingPathComponent(name)
            try Data(source.utf8).write(to: url)
            store.importFile(url)
            guard let block = store.block, block.assetName == name, block.relativeFilePath == name, block.assetID == nil else { fatalError("Index failed: " + name) }
            importedIDs.append(block.fileIdentity)
            let bytes = try Data(contentsOf: store.attachmentURL(for: block)!)
            check(block.kind == .file && bytes == Data(source.utf8) && !store.workspace.pending.contains(where: { $0.hasPrefix("asset_") }), "Indexed original without an asset copy or asset upload")
        }
        let archive = try store.backup()
        let backupURL = root.appendingPathComponent("test.marginbackup")
        try archive.data.write(to: backupURL)
        let restored = try AppStore(root: root.appendingPathComponent("restored"))
        try restored.importBackup(backupURL)
        for (i, identity) in importedIDs.enumerated() {
            let block = restored.workspace.notes.flatMap(\.blocks).first { $0.fileIdentity == identity }!
            check(block.relativeFilePath == imported[i].0 && block.referencedAssets.isEmpty, "Index backup retains original relative paths and shared identity")
            check(!FileManager.default.fileExists(atPath: restored.attachmentURL(for: block)!.path), "Restoring an index never creates an original file")
        }
        // A child created from any entry point exposes its ancestry and immediately renames.
        store.create(folder: true); let folderID = store.selection!
        store.create(parent: folderID); let parentID = store.selection!
        store.expandedPages = []; store.create(parent: parentID)
        check(store.expandedPages.isSuperset(of: [folderID, parentID]) && store.renaming == store.selection, "New subpage reveals both collapsed ancestors and selects rename")
        store.renameDraft = "层级页"; store.commitRename()
        check(store.note?.title == "层级页" && store.renaming == nil, "Return commits sidebar name")
        let textURL = root.appendingPathComponent("editable.md"); let originalBytes = Data("# 原文\n\n==重点== 🍎".utf8)
        try originalBytes.write(to: textURL); store.importFile(textURL, collapsed: true)
        let sourcePage = store.selection!, sourceBlock = store.block!, sourcePath = store.block!.relativeFilePath!
        check(sourceBlock.collapsed == true && sourceBlock.frame.height == Block.collapsedHeight, "Import collapses to a title-only row")
        store.toggleCollapsed(sourceBlock.id)
        check(store.block?.frame.height == 500 && store.block?.collapsed == false, "Expand restores imported file size")
        let countBeforeReference = (try? FileManager.default.contentsOfDirectory(atPath: store.repository.assets.path).count) ?? 0
        let choice = store.referenceChoices.first { $0.block.id == sourceBlock.id }!
        store.create(); store.addReference(choice)
        let referencePage = store.selection!, referenceBlock = store.block!
        check(referenceBlock.relativeFilePath == sourcePath && referenceBlock.reference?.noteID == sourcePage, "Reference shares the original path and records its owning page")
        check(((try? FileManager.default.contentsOfDirectory(atPath: store.repository.assets.path).count) ?? 0) == countBeforeReference, "Creating a reference stores no duplicate asset")
        let session = try store.textFileSession(noteID: referencePage, blockID: referenceBlock.id)
        session.edit("# 修改稿\n\n**共享内容**"); check(session.save(), "Referenced Markdown saves")
        let copies = store.workspace.notes.flatMap(\.blocks).filter { $0.fileIdentity == sourceBlock.fileIdentity }
        check(copies.count == 2 && copies.allSatisfy { $0.workingAssetID == nil && $0.relativeFilePath == sourcePath } && Set(copies.compactMap(\.contentRevision)).count == 1, "Editing updates the original and all alias revisions without file snapshots")
        check((try? Data(contentsOf: textURL)) == Data("# 修改稿\n\n**共享内容**".utf8), "Editing saves directly into the original file")
        check((try? store.textFileSession(noteID: sourcePage, blockID: sourceBlock.id)) === session, "Two reference editors share one session")
        check(store.attachmentTitle(referenceBlock, on: referencePage).hasSuffix("editable.md"), "Cross-project reference title retains source path and filename")
        store.selectBlock(referenceBlock.id); store.deleteSelectedBlock()
        check(store.note?.blocks.contains(where: { $0.id == referenceBlock.id }) == false, "Delete removes selected block")
        let historyReload = try AppStore(root: root); historyReload.undo()
        check(historyReload.note?.blocks.contains(where: { $0.id == referenceBlock.id }) == true, "Saved undo history restores deleted block after reopening")
        store.undo(); store.selectBlock(referenceBlock.id); store.blockKeyboardFocus = false; store.deleteSelectedBlock()
        check(store.note?.blocks.contains(where: { $0.id == referenceBlock.id }) == true, "Delete does not remove block while editing text")
        let externalURL = root.appendingPathComponent("external.py"); try Data("value = 1\n".utf8).write(to: externalURL)
        let assetCount = (try? FileManager.default.contentsOfDirectory(atPath: store.repository.assets.path).count) ?? 0
        store.referenceFile(externalURL); let directReferenceBlock = store.block!
        let externalSession = try store.textFileSession(noteID: store.selection!, blockID: directReferenceBlock.id)
        externalSession.edit("value = 2\n"); check(externalSession.save(), "Direct library reference is editable")
        check((try? Data(contentsOf: externalURL)) == Data("value = 2\n".utf8), "Direct reference updates the actual project file")
        check(((try? FileManager.default.contentsOfDirectory(atPath: store.repository.assets.path).count) ?? 0) == assetCount, "Direct reference needs no asset copy")
        try Data("changed elsewhere\n".utf8).write(to: externalURL)
        externalSession.edit("my unsaved edit\n"); check(!externalSession.save(), "Concurrent external modification is not silently overwritten")
        check((try? String(contentsOf: externalURL, encoding: .utf8)) == "changed elsewhere\n", "External competing edit survives")
        check((try? store.backup()) == nil, "Backup reports unresolved file edits")
        let cleanStore = try AppStore(root: root)
        let referenceBackup = try cleanStore.backup(); let restoredPayload = try JSONDecoder().decode(BackupPayload.self, from: referenceBackup.data)
        check(restoredPayload.assets.isEmpty && restoredPayload.format == 2, "Backup contains only indexes, page data and annotations")
        let importedCopy = restoredPayload.workspace.notes.flatMap(\.blocks).first { $0.id == directReferenceBlock.id }!
        check(importedCopy.relativeFilePath == directReferenceBlock.relativeFilePath && importedCopy.assetID == nil, "Backup preserves the direct file path without embedding its bytes")
        store.create(); store.edit { $0.paper = .a4; $0.blocks = [Block(.pdf, frame: Rect(20,20,754,1083))] }
        store.blockSelection = store.note!.blocks[0].id; store.addAnchor(CGPoint(x: 793,y:30)); store.annotate(store.note!.anchors[0])
        check(store.note?.blocks.count == 2 && store.note?.paper.isContinuous == true, "Crowded annotation automatically finds available long-page space")
        check(!store.note!.blocks[0].frame.intersects(store.note!.blocks[1].frame), "New annotation does not overlap its source")
        let preferenceID = "MarginLocationCheck-" + UUID().uuidString, defaults = UserDefaults(suiteName: preferenceID)!
        defer { defaults.removePersistentDomain(forName: preferenceID) }
        check((try? WorkspaceLocation.restore(from: defaults)) == nil, "First launch has no implicit chosen folder")
        if CommandLine.arguments.contains("--test-scoped-bookmarks") { do {
            try WorkspaceLocation.remember(root, in: defaults)
            check((try? WorkspaceLocation.restore(from: defaults))?.resolvingSymlinksInPath() == root.resolvingSymlinksInPath(), "Storage folder restores without a picker")
        } catch {
            guard (error as NSError).domain == NSCocoaErrorDomain, (error as NSError).code == 256,
                  String(describing: error).contains("ScopedBookmarksAgent") else { throw error }
            print("SKIP: security-scoped bookmark round trip; ScopedBookmarksAgent denied the test process. Requires actual folder-picker validation.")
        } } else { print("SKIP: security-scoped bookmark round trip requires an authorized app folder picker; use --test-scoped-bookmarks in that environment.") }
        textView.string = "🍎中文 **粗体**"; textView.setSelectedRange(NSRange(location:2,length:2)); format.apply(.highlight)
        check(textView.string == "🍎==中文== **粗体**" && Markdown.body(textView.string).contains("<mark>中文</mark>"), "Highlight shortcut matches Markdown display")
        format.apply(.highlight); check(textView.string == "🍎中文 **粗体**", "Highlight toggles off without nested markup")

        // Draw PDF operators above the old thumbnail ceiling, including crop origins and rotation.
        let pdfData = NSMutableData(), consumer = CGDataConsumer(data: pdfData as CFMutableData)!
        var media = CGRect(x:0,y:0,width:600,height:800)
        let pdfContext = CGContext(consumer: consumer, mediaBox: &media, nil)!
        pdfContext.beginPDFPage(nil); pdfContext.setFillColor(NSColor.red.cgColor); pdfContext.fill(CGRect(x:40,y:60,width:30,height:40))
        pdfContext.setStrokeColor(NSColor.black.cgColor); pdfContext.setLineWidth(0.25)
        for x in 100..<120 { pdfContext.move(to: CGPoint(x:x,y:200)); pdfContext.addLine(to: CGPoint(x:x,y:300)); pdfContext.strokePath() }
        pdfContext.endPDFPage(); pdfContext.closePDF()
        let pdf = PDFDocument(data: pdfData as Data)!, pdfPage = pdf.page(at:0)!
        pdfPage.setBounds(CGRect(x:20,y:30,width:500,height:700), for:.cropBox)
        var shapes: [(Int,Int)] = []
        for rotation in [0,90,180,270] {
            pdfPage.rotation = rotation; let size = PDFPageDrawing.size(of:pdfPage)
            let w = Int(size.width*4), h = Int(size.height*4)
            var pixels = [UInt8](repeating:255,count:w*h*4)
            pixels.withUnsafeMutableBytes { bytes in
                let context = CGContext(data:bytes.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                PDFPageDrawing.draw(pdfPage,in:context,bounds:CGRect(x:0,y:0,width:w,height:h))
            }
            var redCount = 0, minX=w, minY=h, maxX=0, maxY=0
            for i in stride(from:0,to:pixels.count,by:4) where pixels[i] > 220 && pixels[i+1] < 40 && pixels[i+2] < 40 {
                redCount += 1; let x=(i/4)%w, y=(i/4)/w; minX=min(minX,x); minY=min(minY,y); maxX=max(maxX,x); maxY=max(maxY,y)
            }
            check(abs(redCount - 30*40*16) < 400, "Full resolution PDF crop and rotation \(rotation) preserve content area")
            check(max(w,h) > 2400, "PDF render exceeds former preview ceiling")
            shapes.append((maxX-minX+1,maxY-minY+1))
        }
        check(shapes[0].0 == shapes[1].1 && shapes[0].1 == shapes[1].0, "PDF rotation swaps content dimensions exactly")
        let nativePDF = SinglePagePDFView(frame:NSRect(x:0,y:0,width:700,height:500))
        nativePDF.update(page:pdfPage)
        check(nativePDF.document?.pageCount == 1 && nativePDF.displayedPage !== pdfPage,
              "A native preview owns one lightweight page copy rather than a full-file bitmap or shared document")
        check(pdfPage.document === pdf && nativePDF.displayedPage?.rotation == pdfPage.rotation,
              "Creating a preview preserves the original page owner and its rotation")
        nativePDF.scaleFactor = 6
        check(nativePDF.scaleFactor == 1 && nativePDF.minScaleFactor == nativePDF.maxScaleFactor,
              "PDFKit cannot apply an extra independent scale inside the canvas or reader")
        let notebookData = Data(##"{"nbformat":4,"metadata":{"kernelspec":{"name":"python3"}},"cells":[{"cell_type":"code","source":"a = 40\nprint('Swift桥接')\na + 2","outputs":[],"execution_count":null,"metadata":{}}]}"##.utf8)
        var savedNotebook: Data?
        let bridge = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/MarginNotes/Resources/notebook_kernel.py")
        let notebookSession = try NotebookSession(data:notebookData,directory:root,bridge:bridge) { savedNotebook=$0 }
        let oldPython = UserDefaults.standard.string(forKey:"MarginNotebookPython")
        defer { if let oldPython { UserDefaults.standard.set(oldPython,forKey:"MarginNotebookPython") } else { UserDefaults.standard.removeObject(forKey:"MarginNotebookPython") } }
        func waitFor(_ condition: () -> Bool) async throws {
            for _ in 0..<600 { if condition() { return }; try await Task.sleep(nanoseconds:50_000_000) }
            fatalError("Notebook session timeout: " + notebookSession.status)
        }
        notebookSession.discover(); try await waitFor { !notebookSession.kernels.isEmpty }
        notebookSession.start(); try await waitFor { notebookSession.ready }
        notebookSession.run(0); try await waitFor { !notebookSession.busy }
        check(notebookSession.document.cells[0].outputs.contains { ($0["data"] as? [String:String])?["text/plain"] == "42" }, "Swift session executes a real Jupyter cell")
        check(savedNotebook != nil && (try? NotebookDocument(data:savedNotebook!).cells[0].executionCount) == 1, "Actual execution output and count persist to notebook snapshot")
        notebookSession.stop()
        store.create(); store.insertLink("https://fixture.invalid/path/page.html", mode:.card)
        let linkPage = store.selection!, linkBlock = store.block!
        let linkChoice = store.referenceChoices.first { $0.block.id == linkBlock.id }!
        store.create(); store.addReference(linkChoice)
        let linkReferencePage = store.selection!, linkReferenceID = store.block!.id
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [HTMLFixtureProtocol.self]
        let fixtureSession = URLSession(configuration: configuration)
        await store.fetchHTML(noteID: linkReferencePage, blockID: linkReferenceID, session: fixtureSession)
        fixtureSession.invalidateAndCancel()
        let captured = store.block!, origin = store.workspace.notes.first { $0.id == linkPage }!.blocks.first { $0.id == linkBlock.id }!
        check(captured.linkMode == .html && captured.assetID == nil, "HTML capture switches selected link to HTML mode")
        check(store.linkSnapshots[captured.fileIdentity] == HTMLFixtureProtocol.bytes, "HTML preview keeps the response in memory without a stored attachment")
        check(captured.assetID == origin.assetID && captured.fileIdentity == origin.fileIdentity && origin.linkMode == .card, "Link references share HTML data but choose their own display mode")
        store.setLinkMode(.browser, noteID:linkReferencePage,blockID:linkReferenceID)
        check(store.block?.linkMode == .browser && store.block?.assetID == captured.assetID, "Switching to browser preserves captured HTML")
        check(!WebPageNavigation.configuration(live:false).defaultWebpagePreferences.allowsContentJavaScript
              && WebPageNavigation.configuration(live:true).defaultWebpagePreferences.allowsContentJavaScript,
              "HTML and live-browser configurations support their respective modes")
        // Canvas growth is driven by document content; scrolling and magnification are view-only.
        store.create(); store.commitRename(); store.fitCanvasToViewport(CGSize(width: 1800, height: 1200))
        check(store.note?.width == 1800 && store.zoom == 1, "Default canvas creates usable viewport width at 100 percent")
        store.insert(.text, point: CGPoint(x: 1440, y: 0))
        check(store.block?.frame == Rect(1440,0,360,216), "Far right and top edge are editable document coordinates")
        let rightID = store.block!.id
        store.snap = false; store.setFrame(rightID, Rect(1200,650,360,216))
        check(store.note!.height > 1200 && store.block!.frame.x == 1200, "Moving a block near two thirds grows blank space without moving content")
        let movedFrame = store.block!.frame
        store.undo(); check(store.note?.blocks.first { $0.id == rightID }?.frame == Rect(1440,0,360,216), "Drag remains one undoable operation")
        store.redo(); check(store.note?.blocks.first { $0.id == rightID }?.frame == movedFrame, "Redo restores dragged block")
        store.editBlock(rightID) { $0.locked = true }
        store.setFrame(rightID, Rect(0,0,360,216))
        check(store.note?.blocks.first { $0.id == rightID }?.frame == movedFrame, "Move handle cannot move a locked block")
        let stableNote = store.note!, pageID = stableNote.id
        let viewport = CanvasScrollView(frame: NSRect(x:0,y:0,width:1800,height:900))
        var zoomCommits: [Double] = []
        viewport.didZoom = { zoomCommits.append($0); store.finishCanvasZoom($0) }
        let paperContent = AnyView(Color.white.frame(width:1800,height:stableNote.height))
        viewport.update(pageID:pageID,size:CGSize(width:1800,height:stableNote.height),zoom:1,fitting:true,content:paperContent)
        viewport.layoutSubtreeIfNeeded()
        for index in 0..<100 {
            viewport.contentView.scroll(to:NSPoint(x:0,y:index * 1000))
            viewport.reflectScrolledClipView(viewport.contentView)
        }
        check(store.note == stableNote && viewport.paper.frame.height == stableNote.height, "Repeated wheel-equivalent scrolling never extends the document")
        NotificationCenter.default.post(name:NSScrollView.willStartLiveMagnifyNotification,object:viewport)
        for value in [0.5,1.2,2.0,3.0] { viewport.magnification = value }
        check(zoomCommits.isEmpty && store.zoom == 1, "Live zoom does not republish or rebuild the document for every sample")
        viewport.update(pageID:pageID,size:CGSize(width:1800,height:stableNote.height),zoom:1,fitting:true,content:paperContent)
        check(viewport.magnification == 3, "A document update cannot snap an active pinch back to the prior scale")
        NotificationCenter.default.post(name:NSScrollView.didEndLiveMagnifyNotification,object:viewport)
        check(zoomCommits == [3] && store.zoom == 3 && !store.fitToWidth, "Gesture end commits exactly one final scale")
        viewport.contentView.scroll(to:NSPoint(x:400,y:300)); viewport.reflectScrolledClipView(viewport.contentView)
        let beforeZoom = viewport.documentVisibleRect
        viewport.update(pageID:pageID,size:CGSize(width:1800,height:stableNote.height),zoom:2,fitting:false,content:paperContent)
        let afterZoom = viewport.documentVisibleRect
        check(abs(beforeZoom.midX - afterZoom.midX) < 1 && abs(beforeZoom.midY - afterZoom.midY) < 1,
              "Keyboard zoom preserves the visible document center")
        viewport.update(pageID:pageID,size:CGSize(width:1800,height:stableNote.height),zoom:0.5,fitting:false,content:paperContent)
        check(viewport.paper.frame.width == 1800 && viewport.magnification == 0.5
              && viewport.backgroundColor == NSColor(calibratedWhite:0.91,alpha:1), "Zoom-out exposes gray workspace without enlarging the white paper")
        func paperIsCentered(_ view: CanvasScrollView) -> Bool {
            let displayed = view.convert(view.paper.bounds, from: view.paper)
            let area = view.contentView.frame
            return (displayed.width >= area.width || abs(displayed.midX - area.midX) < 1)
                && (displayed.height >= area.height || abs(displayed.midY - area.midY) < 1)
        }
        viewport.layoutSubtreeIfNeeded()
        check(paperIsCentered(viewport), "Small canvas has symmetric gray margins on both axes")
        let documentPoint = NSPoint(x:1300,y:700)
        let screenPoint = viewport.convert(documentPoint, from:viewport.paper)
        let recoveredPoint = viewport.paper.convert(screenPoint, from:viewport)
        check(abs(documentPoint.x - recoveredPoint.x) < 0.001 && abs(documentPoint.y - recoveredPoint.y) < 0.001,
              "Centered padding preserves drawing and drag coordinate conversion")
        let priorCommits = zoomCommits.count
        NotificationCenter.default.post(name:NSScrollView.willStartLiveMagnifyNotification,object:viewport)
        for scale in [0.3,0.7,1.4,0.5] {
            viewport.magnification = scale; viewport.layoutSubtreeIfNeeded()
            check(paperIsCentered(viewport), "Canvas stays centered during live pinch, including crossing viewport size")
        }
        check(zoomCommits.count == priorCommits, "Live centering does not publish extra zoom updates")
        NotificationCenter.default.post(name:NSScrollView.didEndLiveMagnifyNotification,object:viewport)
        viewport.setFrameSize(NSSize(width:1400,height:1100)); viewport.tile(); viewport.layoutSubtreeIfNeeded()
        check(paperIsCentered(viewport), "Window and sidebar width changes recenter the canvas")
        viewport.update(pageID:pageID,size:CGSize(width:1800,height:6000),zoom:0.5,fitting:false,
                        content:AnyView(Color.white.frame(width:1800,height:6000)))
        viewport.contentView.scroll(to:NSPoint(x:0,y:700)); viewport.reflectScrolledClipView(viewport.contentView)
        check(paperIsCentered(viewport) && abs(viewport.contentView.bounds.minY - 700) < 1,
              "A long page stays horizontally centered while retaining vertical scrolling")
        viewport.update(pageID:pageID,size:CGSize(width:1800,height:6000),zoom:2,fitting:false,
                        content:AnyView(Color.white.frame(width:1800,height:6000)))
        viewport.contentView.scroll(to:NSPoint(x:100,y:200)); viewport.reflectScrolledClipView(viewport.contentView)
        check(abs(viewport.contentView.bounds.minX - 100) < 1 && abs(viewport.contentView.bounds.minY - 200) < 1,
              "Larger canvases remain pannable instead of being pulled back to their geometric center")
        viewport.update(pageID:UUID(),size:CGSize(width:900,height:600),zoom:1,fitting:false,
                        content:AnyView(Color.white.frame(width:900,height:600)))
        check(paperIsCentered(viewport), "Switching to a smaller page immediately centers it")
        viewport.update(pageID:UUID(),size:CGSize(width:900,height:600),zoom:0.731,fitting:false,
                        content:AnyView(Color.white.frame(width:900,height:600)))
        viewport.layoutSubtreeIfNeeded()
        let corrections = viewport.centeringAdjustments
        for _ in 0..<40 { viewport.layout() }
        check(viewport.centeringAdjustments == corrections && paperIsCentered(viewport),
              "Fractional zoom does not cause repeated subpixel centering and layout corrections")
        check(store.note == stableNote, "Zoom does not alter text, ink, layout or allocated height")

        // An embedded editor scroll view must not consume the enclosing page's pinch.
        let editorScroll = NSScrollView(frame:NSRect(x:0,y:0,width:200,height:150))
        let embeddedText = NSTextView(frame:editorScroll.bounds); editorScroll.documentView = embeddedText
        viewport.paper.addSubview(editorScroll)
        check(CanvasScrollView.magnificationTarget(from:embeddedText) === viewport,
              "Pinch over a nested text editor routes to its canvas")
        let reader = CanvasScrollView(frame:NSRect(x:0,y:0,width:1200,height:900))
        reader.routesMagnification = true
        viewport.paper.addSubview(reader); reader.paper.addSubview(editorScroll)
        check(CanvasScrollView.magnificationTarget(from:embeddedText) === reader,
              "The innermost attachment viewport owns its gesture")
        reader.allowsMagnification = false
        check(CanvasScrollView.magnificationTarget(from:embeddedText) === viewport,
              "A nonzooming inline preview forwards to the outer canvas")
        reader.allowsMagnification = true
        check(CanvasScrollView.magnificationTarget(from:NSView()) == nil,
              "Magnification routing does not capture toolbar or unrelated-window input")
        var readerCommits: [Double] = []
        reader.didZoom = { readerCommits.append($0) }
        let readerID = UUID(), readerSize = CGSize(width:1200,height:1700)
        let readerContent = AnyView(Color.white.frame(width:readerSize.width,height:readerSize.height))
        reader.update(pageID:readerID,size:readerSize,zoom:1,fitting:false,content:readerContent)
        let focus = NSPoint(x:600,y:450)
        reader.applyMagnification(0,at:focus,phase:.began)
        for _ in 0..<20 { reader.applyMagnification(0.02,at:focus,phase:.changed) }
        let expectedScale = pow(Double(1.02),Double(20))
        check(readerCommits.isEmpty && reader.liveMagnifying && abs(Double(reader.magnification) - expectedScale) < 0.0001,
              "Reader handles every pinch delta natively without publishing per-sample updates")
        reader.update(pageID:readerID,size:readerSize,zoom:1,fitting:false,content:readerContent)
        check(abs(Double(reader.magnification) - expectedScale) < 0.0001 && reader.paper.frame.size == readerSize,
              "Reader content frames stay fixed and stale UI state cannot reset an active pinch")
        reader.applyMagnification(0,at:focus,phase:.ended)
        reader.applyMagnification(0,at:focus,phase:.ended)
        check(readerCommits.count == 1 && !reader.liveMagnifying && abs(readerCommits[0] - expectedScale) < 0.0001,
              "End commits exactly once even if a duplicate end event arrives")
        reader.applyMagnification(-0.1,at:focus,phase:.began)
        reader.applyMagnification(0,at:focus,phase:.cancelled)
        let cancelledScale = reader.magnification
        reader.applyMagnification(0.1,at:focus,phase:.began)
        check(abs(reader.magnification - cancelledScale * 1.1) < 0.0001,
              "A fresh pinch after cancellation uses the current scale, not a stale starting scale")
        reader.applyMagnification(0,at:focus,phase:.ended)
        let beforeUnphased = readerCommits.count
        reader.applyMagnification(0.1,at:focus,phase:[])
        try await Task.sleep(nanoseconds:260_000_000)
        check(!reader.liveMagnifying && readerCommits.count == beforeUnphased + 1,
              "Forwarded gestures missing their end phase release after idle instead of getting stuck")
        reader.applyMagnification(100,at:focus,phase:.began); reader.applyMagnification(0,at:focus,phase:.ended)
        check(reader.magnification == 6, "Reader pinch and toolbar share the 600 percent maximum")
        reader.applyMagnification(-2,at:focus,phase:.began); reader.applyMagnification(0,at:focus,phase:.ended)
        check(reader.magnification == 0.25 && reader.paper.frame.size == readerSize,
              "Reader zoom-out has the 25 percent minimum and never resizes the attachment coordinates")
        checks += try runSidebarNativeChecks()
        checks += try runBlockInteractionNativeChecks()
        checks += try await runCanvasHitNativeChecks()
        checks += try await runCanvasPointerNativeChecks()
        checks += try runShowcaseNativeChecks()
        checks += try runFeatureGuideNativeChecks()
        checks += try await runGuideLifecycleNativeChecks()
        checks += try await runGuideTipNativeChecks()
        checks += try await runAttachmentInteractionNativeChecks()
        checks += try await runPagingHitNativeChecks()
        checks += try runAttachmentPagingNativeChecks()
        checks += try await runImageAttachmentNativeChecks()
        checks += try runFolderOverviewNativeChecks()
        checks += try await runFolderOverviewUINativeChecks()
        checks += try await runNavigationNativeChecks()
        checks += try await runICloudFilesNativeChecks()
        checks += try await runContentSelectionNativeChecks()
        checks += try runCanvasBatchNativeChecks()
        checks += try await runClipboardLinksNativeChecks()
        checks += try await runPasteboardFileNativeChecks()
        checks += try await runClipboardArchiveNativeChecks()
        checks += try await runClipboardMoveNativeChecks()
        checks += try await runTitleCanvasFocusNativeChecks()
        checks += try await runBlockDeleteShortcutNativeChecks()
        checks += try await runSidebarNestingNativeChecks()
        checks += try await runPDFPreviewNativeChecks()
        checks += try await runGenericFileNativeChecks()
        checks += try await runPageManagementNativeChecks()
        checks += try await runReaderNotebookNativeChecks()
        checks += try await runInspectorReaderNativeChecks()
        checks += try await runReaderReflowNativeChecks()
        checks += try await runNotebookEditorIdentityNativeChecks()
        checks += try runSelectionScrollNativeChecks()
        checks += try await runScrollRegionNativeChecks()
        checks += try await runStartupNativeChecks()
        checks += try await runAgentNativeChecks()
        print("PASS: \(checks) native editor, model, attachment, PencilKit and agent assertions")
    }
}
