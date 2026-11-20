import Foundation
import SwiftUI
import PDFKit

@MainActor private struct PagingCanvasFixture: View {
    @ObservedObject var store: AppStore
    var body: some View {
        NoteCanvas(store: store, note: store.note!).paper
    }
}

@MainActor func runPagingHitNativeChecks() async throws -> Int {
    var count = 0
    func check(_ value: Bool, _ name: String) { precondition(value, name); count += 1 }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiberePagingHit-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(root: root)
    store.create(); store.cancelRename(); store.snap = false; store.fitToWidth = false
    let url = root.appendingPathComponent("paging.pdf")
    var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 500)
    let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
    for _ in 0..<3 { context.beginPDFPage(nil); context.endPDFPage() }
    context.closePDF()
    store.importFile(url)
    let imported = store.block!
    check(imported.kind == .pdf && PDFDocument(url: store.attachmentURL(for: imported)!)?.pageCount == 3,
          "Paging fixture uses a real imported three-page PDF")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let viewport = CanvasScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    window.contentView = viewport; viewport.pointerInteraction = store.canvasPointer
    func layout() async {
        viewport.layoutSubtreeIfNeeded(); viewport.host.layoutSubtreeIfNeeded()
        await Task.yield()
        viewport.layoutSubtreeIfNeeded(); viewport.host.layoutSubtreeIfNeeded()
    }
    func show(_ point: CGPoint) -> CGPoint {
        let size = viewport.contentView.bounds.size
        viewport.contentView.scroll(to: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
        viewport.reflectScrolledClipView(viewport.contentView)
        return viewport.paper.convert(point, to: nil)
    }
    for frame in [Rect(100, 100, 420, 500), Rect(100, 100, 100, 80)] {
        for zoom in [0.25, 0.5, 1.0, 2.0, 6.0] {
            for state in ["unselected", "selected", "locked"] {
                var pdf = imported; pdf.frame = frame; pdf.locked = state == "locked"; pdf.pdfPage = 1
                let anchor = AnnotationAnchor(ownerID: pdf.id, label: "下一页旁批注", u: 1 - 18 / frame.width, v: 1 - 14 / frame.height)
                store.clearBlockSelection()
                store.edit { $0.blocks = [pdf]; $0.anchors = [anchor]; $0.fitCanvas(width: 900, height: 1000) }
                if state != "unselected" { store.selectBlock(pdf.id) }
                store.zoom = zoom
                viewport.update(pageID: store.selection!, size: CGSize(width: store.note!.width, height: store.note!.height), zoom: zoom,
                                fitting: true, content: AnyView(PagingCanvasFixture(store: store)))
                await layout()
                for x in [frame.x + 18, frame.x + frame.width / 2, frame.maxX - 18] {
                    for y in [frame.maxY - CanvasItemGeometry.pdfFooterHeight + 1, frame.maxY - 14, frame.maxY - 1] {
                        let point = show(CGPoint(x: x, y: y))
                        check(viewport.pointerArea(at: point, in: window) == nil,
                              "PDF footer stays available to its buttons, state \(state), zoom \(zoom), frame \(frame)")
                        check(store.canvasHit(at: CGPoint(x: x, y: y)) == .block(pdf.id),
                              "The PDF footer has no expanded anchor target, state \(state), zoom \(zoom)")
                    }
                }
                if state == "selected" {
                    let expected = CanvasItemGeometry.resizeCorner(for: pdf, zoom: zoom)
                    let surfaces = descendants(viewport.host).compactMap { $0 as? CanvasPointerView }
                    guard let surface = surfaces.first(where: { $0.area == .resize(pdf.id) }) else {
                        preconditionFailure("The selected PDF must expose a native resize surface")
                    }
                    let actual = surface.convert(surface.bounds, to: viewport.paper)
                    check(abs(actual.minX - expected.x) < 0.1 && abs(actual.minY - expected.y) < 0.1
                          && abs(actual.width - expected.width) < 0.1 && abs(actual.height - expected.height) < 0.1,
                          "Visible PDF handle and semantic resize bounds agree at zoom \(zoom)")
                    let point = CGPoint(x: expected.maxX - 1, y: expected.maxY - 1)
                    check(viewport.pointerArea(at: show(point), in: window) == .resize(pdf.id),
                          "Moving the handle above the footer preserves native resize routing")
                    let before = store.note!.blocks[0].frame
                    check(viewport.beginPointer(at: show(point), in: window, area: .resize(pdf.id), clickCount: 1),
                          "The relocated PDF handle starts a resize")
                    let end = viewport.paper.convert(CGPoint(x: point.x + 40, y: point.y + 30), to: nil)
                    viewport.continuePointer(.leftMouseDragged, at: end, in: window)
                    viewport.continuePointer(.leftMouseUp, at: end, in: window)
                    check(store.note!.blocks[0].frame == Rect(before.x, before.y, before.width + 40, before.height + 30)
                          && store.note!.blocks[0].pdfPage == 1,
                          "The moved handle resizes the PDF without changing its preview page")
                }
            }
        }
    }
    window.contentView = nil
    print("PASS: \(count) PDF footer, native pointer routing and relocated resize handle assertions")
    return count
}
