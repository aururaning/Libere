import SwiftUI
import PDFKit
import QuartzCore

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

/// PDF tiles are rendered on demand instead of allocating a full-page bitmap at 600%.
/// Both platform view systems supply their usual flipped drawing context to draw(_:).
final class PDFTileLayer: CATiledLayer {
    override init() {
        super.init()
        tileSize = CGSize(width: 512, height: 512)
        levelsOfDetail = 4; levelsOfDetailBias = 4
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override class func fadeDuration() -> CFTimeInterval { 0 }
}

/// CATiledLayer may draw several tiles concurrently. Serialize access to each PDF page.
final class PDFTileRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private var page: PDFPage?
    func setPage(_ page: PDFPage?) {
        lock.lock(); defer { lock.unlock() }
        self.page = page
    }
    func draw(in context: CGContext, bounds: CGRect) {
        lock.lock(); defer { lock.unlock() }
        guard let page else { return }
        PDFPageDrawing.draw(page, in: context, bounds: bounds)
    }
}

#if os(macOS)
@MainActor final class PDFVectorView: NSView {
    private let renderer = PDFTileRenderer()
    var page: PDFPage? { didSet { if page !== oldValue { renderer.setPage(page); needsDisplay = true } } }
    var resolutionScale: CGFloat = 1
    override var isFlipped: Bool { true }
    override func makeBackingLayer() -> CALayer { PDFTileLayer() }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); refreshResolution() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshResolution() }
    func refreshResolution() {
        wantsLayer = true
        // Tiled layers choose the detail level from the native transform themselves.
        // Multiplying this by zoom as well would render the same zoom twice.
        let scale = window?.backingScaleFactor ?? 2
        if layer?.contentsScale != scale { layer?.contentsScale = scale; needsDisplay = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        renderer.draw(in: context, bounds: bounds)
    }
}
@MainActor struct VectorPDFPage: NSViewRepresentable {
    let page: PDFPage
    var resolutionScale: CGFloat = 1
    func makeNSView(context: Context) -> PDFVectorView { PDFVectorView() }
    func updateNSView(_ view: PDFVectorView, context: Context) {
        if view.page !== page { view.page = page; view.needsDisplay = true }
        if view.resolutionScale != resolutionScale { view.resolutionScale = resolutionScale; view.needsDisplay = true }
        view.refreshResolution()
    }
}
#else
@MainActor final class PDFVectorView: UIView {
    private let renderer = PDFTileRenderer()
    var page: PDFPage? { didSet { if page !== oldValue { renderer.setPage(page); setNeedsDisplay() } } }
    var resolutionScale: CGFloat = 1
    override class var layerClass: AnyClass { PDFTileLayer.self }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        renderer.draw(in: context, bounds: bounds)
    }
}
@MainActor struct VectorPDFPage: UIViewRepresentable {
    let page: PDFPage
    var resolutionScale: CGFloat = 1
    func makeUIView(context: Context) -> PDFVectorView { let view = PDFVectorView(); view.backgroundColor = .white; view.contentMode = .redraw; return view }
    func updateUIView(_ view: PDFVectorView, context: Context) {
        let scale = view.window?.screen.scale ?? 2
        if view.page !== page || view.contentScaleFactor != scale || view.resolutionScale != resolutionScale {
            view.page = page; view.contentScaleFactor = scale; view.resolutionScale = resolutionScale; view.setNeedsDisplay()
        }
    }
}
#endif
