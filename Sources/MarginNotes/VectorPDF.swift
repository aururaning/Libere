import SwiftUI
import PDFKit

/// Render original PDF operators at the destination's resolution; never make a thumbnail.
enum PDFPageDrawing {
    static func size(of page: PDFPage) -> CGSize {
        let size = page.bounds(for: .cropBox).size
        return abs(page.rotation) % 180 == 90 ? CGSize(width: size.height, height: size.width) : size
    }
    static func draw(_ page: PDFPage, in context: CGContext, bounds: CGRect) {
        let paper = size(of: page)
        guard paper.width > 0, paper.height > 0 else { return }
        context.saveGState()
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
        context.translateBy(x: bounds.minX, y: bounds.maxY)
        context.scaleBy(x: bounds.width / paper.width, y: -bounds.height / paper.height)
        page.draw(with: .cropBox, to: context)
        context.restoreGState()
    }
}

#if os(macOS)
/// Each surface owns one copied PDFPage and its PDFKit selection/scale state.
/// The enclosing CanvasViewport supplies fitting and zoom; PDFKit stays at 1x.
@MainActor final class SinglePagePDFView: PDFView {
    private weak var sourcePage: PDFPage?
    private(set) var displayedPage: PDFPage?
    override init(frame: NSRect) {
        super.init(frame: frame)
        autoScales = false; displayMode = .singlePage; displayDirection = .vertical
        displaysPageBreaks = false; displaysAsBook = false; pageShadowsEnabled = false
        displayBox = .cropBox; backgroundColor = .white
        minScaleFactor = 1; maxScaleFactor = 1; scaleFactor = 1
        setAccessibilityIdentifier("single-page-pdf")
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func update(page: PDFPage) {
        if sourcePage !== page {
            guard let copy = page.copy() as? PDFPage else { return }
            let owned = PDFDocument(); owned.insert(copy, at: 0)
            sourcePage = page; displayedPage = copy; document = owned
            go(to: copy)
        }
        autoScales = false
        if minScaleFactor != 1 { minScaleFactor = 1 }
        if maxScaleFactor != 1 { maxScaleFactor = 1 }
        if scaleFactor != 1 { scaleFactor = 1 }
    }
    override func magnify(with event: NSEvent) {
        // The canvas/reader's local monitor handles this gesture exactly once.
        // Never let PDFKit create a second independent scale inside the block.
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copy = NSMenuItem(title: "复制所选文字", action: #selector(PDFView.copy(_:)), keyEquivalent: "")
        copy.target = self; copy.isEnabled = !(currentSelection?.string ?? "").isEmpty
        let all = NSMenuItem(title: "全选本页文字", action: #selector(PDFView.selectAll(_:)), keyEquivalent: "")
        all.target = self
        menu.autoenablesItems = false; menu.addItem(copy); menu.addItem(all)
        return menu
    }
}
@MainActor struct SelectablePDFPage: NSViewRepresentable {
    let page: PDFPage
    func makeNSView(context: Context) -> SinglePagePDFView { SinglePagePDFView(frame: .zero) }
    func updateNSView(_ view: SinglePagePDFView, context: Context) { view.update(page: page) }
}

#else
@MainActor final class SinglePagePDFView: PDFView {
    private weak var sourcePage: PDFPage?
    private(set) var displayedPage: PDFPage?
    override init(frame: CGRect) {
        super.init(frame: frame)
        autoScales = false; displayMode = .singlePage; displayDirection = .vertical
        displaysPageBreaks = false; displaysAsBook = false; pageShadowsEnabled = false
        displayBox = .cropBox; backgroundColor = .white
        minScaleFactor = 1; maxScaleFactor = 1; scaleFactor = 1
        accessibilityIdentifier = "single-page-pdf"
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    func update(page: PDFPage) {
        if sourcePage !== page {
            guard let copy = page.copy() as? PDFPage else { return }
            let owned = PDFDocument(); owned.insert(copy, at: 0)
            sourcePage = page; displayedPage = copy; document = owned; go(to: copy)
        }
        autoScales = false; minScaleFactor = 1; maxScaleFactor = 1; scaleFactor = 1
        for gesture in gestureRecognizers ?? [] where gesture is UIPinchGestureRecognizer { gesture.isEnabled = false }
    }
}
@MainActor struct SelectablePDFPage: UIViewRepresentable {
    let page: PDFPage
    func makeUIView(context: Context) -> SinglePagePDFView { SinglePagePDFView(frame: .zero) }
    func updateUIView(_ view: SinglePagePDFView, context: Context) { view.update(page: page) }
}

#endif
