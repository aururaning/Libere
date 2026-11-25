import Foundation
import SwiftUI
import PDFKit
import WebKit

@MainActor private struct PDFCanvasFixture: View {
    @ObservedObject var store: AppStore
    var body: some View { if let note = store.note { NoteCanvas(store: store, note: note) } }
}
@MainActor private final class AnnotationZoomFixture: ObservableObject { @Published var zoom = 1.0 }
@MainActor private struct PDFAnnotationFixture: View {
    @ObservedObject var store: AppStore
    @ObservedObject var scale: AnnotationZoomFixture
    let noteID: UUID
    let blockID: UUID
    var body: some View {
        if let block = store.workspace.notes.first(where: { $0.id == noteID })?.blocks.first(where: { $0.id == blockID }) {
            AttachmentSurface(store: store, noteID: noteID, block: block, page: 0, textEnabled: true,
                              fitPage: false, zoom: scale.zoom, zoomChanged: { scale.zoom = $0 })
        }
    }
}

@MainActor func runPDFPreviewNativeChecks() async throws -> Int {
    _ = NSApplication.shared
    var count = 0
    func check(_ value: Bool, _ label: String) {
        if !value { FileHandle.standardError.write(Data(("FAILED PDF preview: " + label + "\n").utf8)) }
        precondition(value, label); count += 1
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func wait(_ host: NSView, _ predicate: () -> Bool) async throws {
        for _ in 0..<250 {
            host.layoutSubtreeIfNeeded()
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Native PDF fixture did not finish layout")
    }
    func makePDF() -> Data {
        let data = NSMutableData(); var media = CGRect(x: 0,y: 0,width: 612,height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &media, nil)!
        for index in 0..<2 {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            ("Libere original selectable text, page \(index)" as NSString).draw(at: CGPoint(x: 50,y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 18)])
            NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
        }
        context.closePDF(); return data as Data
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiberePDFPreview-" + UUID().uuidString)
    let store = try AppStore(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    store.create(); store.cancelRename(); store.fitToWidth = false; store.snap = false
    let noteID = store.selection!, bytes = makePDF(), file = root.appendingPathComponent("original.pdf")
    try bytes.write(to: file); check(store.referenceFile(file), "A valid PDF fixture is indexed")
    let blockID = store.block!.id
    let annotation = PageTextAnnotation(frame: Rect(80,180,220,100), text: "annotation sample")
    var annotationPage = AttachmentPageAnnotations(); annotationPage.texts = [annotation]
    store.edit {
        $0.canvasWidth = 1400; $0.canvasHeight = 2400
        $0.blocks[0].frame = Rect(100,100,400,500)
        $0.blocks[0].pageAnnotations = ["0": annotationPage]
    }
    let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1100,height: 900), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: PDFCanvasFixture(store: store)); window.contentView = host
    defer { window.contentView = nil }
    func canvas() -> CanvasScrollView? { descendants(host).compactMap { $0 as? CanvasScrollView }.first { $0.pointerInteraction === store.canvasPointer } }
    func inline() -> CanvasScrollView? { descendants(host).compactMap { $0 as? CanvasScrollView }.first { $0.attachmentBlockID == blockID } }
    func preview() -> SinglePagePDFView? { descendants(host).compactMap { $0 as? SinglePagePDFView }.first }
    try await wait(host) { preview()?.displayedPage != nil && inline() != nil && canvas() != nil }
    let expectedFit = min(400.0 / 612.0, (500 - Block.collapsedHeight - CanvasItemGeometry.pdfFooterHeight) / 792)
    for zoom in [0.5,1.0,1.5,2.0] {
        store.zoom = zoom
        try await wait(host) { abs((canvas()?.magnification ?? 0)-zoom) < 0.001 }
        try await Task.sleep(nanoseconds: 20_000_000); host.layoutSubtreeIfNeeded()
        canvas()!.reveal(CGRect(x: 50, y: 80, width: 500, height: 80))
        host.layoutSubtreeIfNeeded()
        let pdf = preview()!, surface = inline()!
        let projected = pdf.convert(pdf.bounds, to: host)
        print("PDF SCALE \(zoom): internal=\(surface.magnification), pdf=\(pdf.scaleFactor), projected=\(projected.size)")
        check(abs(surface.magnification - expectedFit) < 0.001 && !surface.allowsMagnification,
              "Inline fitting stays constant rather than acquiring its own canvas zoom")
        check(pdf.scaleFactor == 1 && abs(projected.width - 612 * expectedFit * zoom) < 1.5
              && abs(projected.height - 792 * expectedFit * zoom) < 1.5,
              "PDF geometry scales exactly once with the outer canvas at \(zoom)")
        let readPoint = pdf.convert(CGPoint(x: 100,y: 680), to: nil)
        check(canvas()!.pointerArea(at: readPoint, in: window) == nil,
              "PDF browser contents are not covered by a canvas move-selection surface")
        window.makeFirstResponder(pdf); store.selectAllFocused(in: window)
        check(pdf.currentSelection?.string?.contains("Libere original selectable text") == true,
              "The real native PDF text layer can be selected through the application's select-all command")
        let buttons = descendants(host).compactMap { $0 as? CanvasInlineButtonControl }
        guard let collapse = buttons.first(where: { $0.accessibilityIdentifier() == "block-collapse-" + blockID.uuidString }),
              let reader = buttons.first(where: { $0.accessibilityIdentifier() == "block-reader-" + blockID.uuidString }) else {
            preconditionFailure("PDF header buttons not created")
        }
        for button in [collapse,reader] {
            check(button.bounds.width >= 28 && button.bounds.height >= 28, "Header controls have an actual padded native hit rectangle")
            check(SelectionWheel.owns(button.convert(CGPoint(x: 14, y: 14), to: nil), in: window, scroll: canvas()!),
                  "Header button checks run inside the visible canvas at \(zoom)")
            for p in [CGPoint(x: 2,y: 2),CGPoint(x: 26,y: 2),CGPoint(x: 2,y: button.bounds.height-2),CGPoint(x: 26,y: button.bounds.height-2)] {
                let point = button.convert(p, to: nil)
                if canvas()!.pointerArea(at: point, in: window) != nil {
                    let paperPoint = canvas()!.paper.convert(point, from: nil)
                    let hit = host.hitTest(host.superview?.convert(point, from: nil) ?? point)
                    FileHandle.standardError.write(Data(("HEADER HIT \(button.accessibilityIdentifier()) zoom=\(zoom) button=\(button.frame) bounds=\(button.bounds) window=\(point) paper=\(paperPoint) model=\(store.canvasHit(at:paperPoint)) native=\(String(describing:hit)) area=\(String(describing:canvas()!.pointerArea(at:point,in:window)))\n").utf8))
                }
                check(canvas()!.pointerArea(at: button.convert(p, to: nil), in: window) == nil,
                      "The pointer monitor never steals padded collapse/reader button hits at \(zoom)")
            }
        }
        let viewport = canvas()!, initialFrame = store.block!.frame
        let handle = descendants(host).compactMap { $0 as? CanvasPointerView }.first { $0.area == .move(blockID) }!
        let down = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        check(SelectionWheel.owns(down, in: window, scroll: viewport)
              && viewport.pointerArea(at: down, in: window) == .move(blockID),
              "The rendered PDF drag handle owns its visible native hit at \(zoom)")
        check(viewport.beginPointer(at: down, in: window, area: .move(blockID), clickCount: 1),
              "A normal mouse/three-finger press starts from the rendered handle")
        let start = viewport.paper.convert(down, from: nil)
        let end = CGPoint(x: start.x + 36/zoom, y: start.y + 18/zoom)
        viewport.continuePointer(.leftMouseDragged, at: viewport.paper.convert(end, to: nil), in: window)
        await Task.yield(); host.layoutSubtreeIfNeeded()
        check(store.canvasPointer.preview?.blockID == blockID && store.multiSelection.marquee == nil,
              "Continuous handle dragging moves the PDF instead of starting a marquee")
        viewport.continuePointer(.leftMouseUp, at: viewport.paper.convert(end, to: nil), in: window)
        check(abs(store.block!.frame.x-initialFrame.x-36/zoom) < 0.001
              && abs(store.block!.frame.y-initialFrame.y-18/zoom) < 0.001
              && !store.canvasPointer.isPressed && store.multiSelection.marquee == nil,
              "Releasing the handle commits exactly one scale-correct move")
        store.undo()
        check(store.note?.blocks.first(where: { $0.id == blockID })?.frame == initialFrame,
              "One undo restores the whole handle drag")
        store.selectBlock(blockID)
        try await wait(host) { preview() != nil && inline() != nil }
    }
    store.zoom = 1.5; try await wait(host) { abs((canvas()?.magnification ?? 0)-1.5) < 0.001 }
    let collapse = descendants(host).compactMap { $0 as? CanvasInlineButtonControl }.first { $0.accessibilityIdentifier() == "block-collapse-" + blockID.uuidString }!
    collapse.performClick(nil)
    check(store.block?.collapsed == true, "The actual native collapse button invokes its action")
    try await wait(host) { descendants(host).compactMap { $0 as? CanvasInlineButtonControl }.contains { $0.accessibilityIdentifier() == "block-collapse-" + blockID.uuidString } }
    descendants(host).compactMap { $0 as? CanvasInlineButtonControl }.first { $0.accessibilityIdentifier() == "block-collapse-" + blockID.uuidString }!.performClick(nil)
    try await wait(host) { preview() != nil && store.block?.collapsed != true }
    let beforeWindowScale = preview()!.convert(preview()!.bounds, to: host).size
    let originalCanvasDocument = preview()!.document
    store.editBlock(blockID) { $0.locked = true }; let locked = store.block!
    PDFWindow.shared.presentsWindows = false
    defer { PDFWindow.shared.presentsWindows = true }
    try await wait(host) { descendants(host).compactMap { $0 as? CanvasInlineButtonControl }.contains { $0.accessibilityIdentifier() == "block-reader-" + blockID.uuidString } }
    descendants(host).compactMap { $0 as? CanvasInlineButtonControl }.first { $0.accessibilityIdentifier() == "block-reader-" + blockID.uuidString }!.performClick(nil)
    guard let readerWindow = PDFWindow.shared.existingWindow(store: store, noteID: noteID, blockID: blockID), let readerHost = readerWindow.contentView else { preconditionFailure("Header reader button failed") }
    defer { readerWindow.close() }
    try await wait(readerHost) { descendants(readerHost).contains { $0 is SinglePagePDFView } }
    let readerPDF = descendants(readerHost).compactMap { $0 as? SinglePagePDFView }.first!
    let readerViewport = descendants(readerHost).compactMap { $0 as? CanvasScrollView }.first { $0.routesMagnification && $0.pointerInteraction == nil }!
    check(readerPDF.document !== originalCanvasDocument && readerPDF.displayedPage !== preview()!.displayedPage,
          "Reader and canvas never share their mutable one-page PDF document/view")
    let readerInitial = readerViewport.magnification
    readerViewport.applyMagnification(1, at: CGPoint(x:300,y:300), phase: .began)
    readerViewport.applyMagnification(0, at: CGPoint(x:300,y:300), phase: .ended)
    try await wait(readerHost) { readerViewport.magnification > readerInitial * 1.9 }
    check(readerPDF.scaleFactor == 1 && store.zoom == 1.5, "Reader zoom changes only its own enclosing viewport")
    readerWindow.close(); host.layoutSubtreeIfNeeded(); await Task.yield(); host.layoutSubtreeIfNeeded()
    let afterWindowScale = preview()!.convert(preview()!.bounds, to: host).size
    check(abs(beforeWindowScale.width-afterWindowScale.width) < 1 && abs(beforeWindowScale.height-afterWindowScale.height) < 1,
          "Closing a zoomed reader leaves canvas PDF preview size unchanged")
    check(store.block?.frame == locked.frame && store.block?.pdfPage == locked.pdfPage && store.block?.locked == true,
          "Reader and text selection preserve a locked PDF's canvas frame and preview page")

    let sourceDocument = PDFDocument(data: bytes)!, source = sourceDocument.page(at: 0)!
    let a = SinglePagePDFView(frame: CGRect(x:0,y:0,width:612,height:792)), b = SinglePagePDFView(frame: CGRect(x:0,y:0,width:612,height:792))
    a.update(page: source); b.update(page: source)
    check(a.document !== b.document && a.displayedPage !== b.displayedPage && source.document === sourceDocument,
          "Page copies do not transfer the original page into another document")

    let editWindow = NSWindow(contentRect: NSRect(x:0,y:0,width:760,height:820),styleMask:[.titled],backing:.buffered,defer:false)
    editWindow.isReleasedWhenClosed = false
    let state = AnnotationZoomFixture(), editHost = NSHostingView(rootView: PDFAnnotationFixture(store:store,scale:state,noteID:noteID,blockID:blockID))
    editWindow.contentView = editHost; defer { editWindow.contentView = nil }
    try await wait(editHost) { descendants(editHost).compactMap { $0 as? PageAnnotationPointerView }.contains { $0.bounds.width > 100 } }
    let control = descendants(editHost).compactMap { $0 as? PageAnnotationPointerView }.first { $0.bounds.width > 100 }!
    let location = control.convert(CGPoint(x:20,y:30),to:nil)
    let down = NSEvent.mouseEvent(with:.leftMouseDown,location:location,modifierFlags:[],timestamp:1,windowNumber:editWindow.windowNumber,context:nil,eventNumber:1,clickCount:2,pressure:1)!
    let up = NSEvent.mouseEvent(with:.leftMouseUp,location:location,modifierFlags:[],timestamp:1.1,windowNumber:editWindow.windowNumber,context:nil,eventNumber:2,clickCount:2,pressure:0)!
    control.mouseDown(with:down); control.mouseUp(with:up)
    try await wait(editHost) { descendants(editHost).contains { ($0 as? NSTextView)?.string == annotation.text } }
    for zoom in [1.0,1.5,2.0] {
        state.zoom = zoom
        try await wait(editHost) {
            descendants(editHost).compactMap { $0 as? CanvasScrollView }.contains { $0.routesMagnification && abs($0.magnification - (760.0/612.0)*zoom) < 0.01 }
        }
        let text = descendants(editHost).compactMap { $0 as? NSTextView }.first { $0.string == annotation.text }!
        let button = descendants(editHost).compactMap { $0 as? CanvasInlineButtonControl }.first { $0.accessibilityIdentifier() == "annotation-edit-" + annotation.id.uuidString }!
        let editor = text.enclosingScrollView!, transformed = editor.convert(editor.bounds,to:editHost)
        let buttonFrame = button.convert(button.bounds,to:editHost), total = 760.0/612.0*zoom
        check(abs(transformed.width-annotation.frame.width*total) < 2 && abs(buttonFrame.width-52*total)<2,
              "Annotation editor and preview/edit button share the exact PDF scale at \(zoom)")
        check(text.font?.pointSize == 16, "Document zoom never writes an enlarged annotation font")
    }
    check(try Data(contentsOf:file) == bytes, "Selection and scaling never rewrite the PDF original")
    print("PASS: \(count) PDF scale isolation, text selection, header button and annotation geometry assertions")
    return count
}
