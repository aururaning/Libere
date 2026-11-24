import SwiftUI
#if SWIFT_PACKAGE
import MarginCore
#endif

/// Start with nearby cards, then admit others as the user scrolls. A card that has
/// appeared stays alive until page navigation, preserving editor/ink state and the
/// attachment's own scroll position. Native bounds changes never edit the note.
@MainActor final class CanvasContentState: ObservableObject {
    @Published private(set) var loadedIDs: Set<UUID> = []
    private(set) var pageID: UUID?
    private(set) var region: Rect?
    private var pending: (UUID, CGRect, [Block])?
    private var scheduled = false

    func blocks(in note: Note, viewport: CGSize, zoom: Double, preserving: Set<UUID>) -> [Block] {
        let scale = zoom.isFinite && zoom > 0 ? zoom : 1
        let width = viewport.width.isFinite ? max(1, viewport.width / scale) : 800
        let height = viewport.height.isFinite ? max(1, viewport.height / scale) : 600
        let initial = Rect(0, 0, width, height)
        let region = pageID == note.id ? self.region : nil
        let retained = (pageID == note.id ? loadedIDs : []).union(preserving)
        return CanvasVisibility.blocks(note.blocks, in: region ?? CanvasVisibility.region(around: initial)!, retaining: retained)
    }

    func schedule(pageID: UUID, visible: CGRect, blocks: [Block]) {
        pending = (pageID, visible, blocks)
        guard !scheduled else { return }
        scheduled = true
        // Bounds can change during NS/UIViewRepresentable updates. Coalesce them
        // and publish outside that transaction, after the final page/zoom is set.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard let (id, visible, blocks) = self.pending else { return }
            self.pending = nil
            self.update(pageID: id, visible: visible, blocks: blocks)
        }
    }

    func update(pageID: UUID, visible: CGRect, blocks: [Block]) {
        guard let region = CanvasVisibility.region(around: Rect(visible.minX, visible.minY, visible.width, visible.height)) else { return }
        var next = self.pageID == pageID ? loadedIDs : []
        next.formUnion(CanvasVisibility.blocks(blocks, in: region).map(\.id))
        let changed = self.pageID != pageID || next != loadedIDs
        self.pageID = pageID; self.region = region
        if changed { loadedIDs = next }
    }
}

/// Native scroll containers keep live magnification out of the document's observable model.
/// Only the final scale is published, so a pinch does not rebuild every editor/PDF per sample.
#if os(macOS)
@MainActor final class CanvasDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Keep spare space symmetric in document coordinates, including during a native pinch.
/// A longer/wider document keeps AppKit's normal scrolling constraints on that axis.
@MainActor final class CenteredCanvasClipView: NSClipView {
    var centersVertically = true
    override func scroll(to newOrigin: NSPoint) {
        let proposed = NSRect(origin: newOrigin, size: bounds.size)
        super.scroll(to: constrainBoundsRect(proposed).origin)
    }
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return result }
        if result.width > document.frame.width {
            result.origin.x = document.frame.midX - result.width / 2
        }
        if centersVertically && result.height > document.frame.height {
            result.origin.y = document.frame.midY - result.height / 2
        }
        return result
    }
}

@MainActor final class CanvasScrollView: NSScrollView {
    let paper = CanvasDocumentView()
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    private(set) var liveMagnifying = false
    private(set) var centeringAdjustments = 0
    private var pageID: UUID?
    private var requestedZoom: CGFloat = 1
    var routesMagnification = false { didSet { updateMagnificationMonitor() } }
    var attachmentBlockID: UUID?
    private var magnificationMonitor: Any?
    private var deskMonitor: Any?
    private var pointerMonitor: Any?
    private var lastCanvasPointerInWindow: NSPoint?
    var pointerInteraction: CanvasPointerInteraction? { didSet { updatePointerMonitor() } }
    var didClickDesk: (() -> Void)? { didSet { updateDeskMonitor() } }
    private var routedGesture = false
    private var magnificationEndTask: Task<Void, Never>?
    var didZoom: (Double) -> Void = { _ in }
    var didChangeVisibleRect: ((UUID, CGRect) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView = CenteredCanvasClipView(frame: bounds)
        borderType = .noBorder; drawsBackground = true
        backgroundColor = NSColor(calibratedWhite: 0.91, alpha: 1)
        contentView.drawsBackground = true; contentView.backgroundColor = backgroundColor
        hasHorizontalScroller = true; hasVerticalScroller = true
        autohidesScrollers = true; scrollerStyle = .overlay
        horizontalScrollElasticity = .none; verticalScrollElasticity = .none
        automaticallyAdjustsContentInsets = false; contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        minMagnification = 0.25; maxMagnification = 6; allowsMagnification = true
        host.sizingOptions = []; paper.addSubview(host); documentView = paper
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(reportVisibleRect), name: NSView.boundsDidChangeNotification, object: contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(startMagnifying), name: NSScrollView.willStartLiveMagnifyNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(endMagnifying), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(windowLostFocus(_:)), name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowLostFocus(_:)), name: NSWindow.willCloseNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    deinit {
        NotificationCenter.default.removeObserver(self)
        magnificationEndTask?.cancel()
        if let magnificationMonitor { NSEvent.removeMonitor(magnificationMonitor) }
        if let deskMonitor { NSEvent.removeMonitor(deskMonitor) }
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMagnificationMonitor()
        updateDeskMonitor()
        updatePointerMonitor()
        if pointerInteraction != nil { window?.acceptsMouseMovedEvents = true }
    }
    @objc private func windowLostFocus(_ notification: Notification) {
        if notification.object as? NSWindow === window { pointerInteraction?.cancel() }
    }
    private func updatePointerMonitor() {
        guard pointerInteraction != nil, window != nil else {
            if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor); self.pointerMonitor = nil }
            pointerInteraction?.cancel()
            return
        }
        guard pointerMonitor == nil else { return }
        window?.acceptsMouseMovedEvents = true
        pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type != .keyDown { self.rememberCanvasPointer(at: event.locationInWindow, in: event.window) }
                if event.type == .scrollWheel {
                    return self.routeAttachmentScroll(at: event.locationInWindow, in: event.window,
                        delta: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas)
                }
                if event.type == .leftMouseDown {
                    if event.modifierFlags.contains(.command), self.pointerInteraction?.openMarkdownLink(at: event.locationInWindow, in: event.window) == true { return true }
                    guard !event.modifierFlags.contains(.control),
                          let area = self.pointerArea(at: event.locationInWindow, in: event.window) else { return false }
                    return self.beginPointer(at: event.locationInWindow, in: event.window, area: area, clickCount: event.clickCount, extendingSelection: event.modifierFlags.contains(.shift))
                }
                guard self.pointerInteraction?.isPressed == true else { return false }
                if event.type == .keyDown {
                    guard event.keyCode == 53 else { return false }
                    self.pointerInteraction?.cancel(); return true
                }
                return self.continuePointer(event.type, at: event.locationInWindow, in: event.window)
            }
            return handled ? nil : event
        }
    }
    /// Use AppKit's native conversion so magnification, scrolling and a centered
    /// page all resolve to the same paper coordinate. Menu paste falls back to
    /// the last pointer position within this page, then its visible center.
    func clipboardPoint(at point: NSPoint, in eventWindow: NSWindow?, allowingFallback: Bool = true) -> CGPoint? {
        guard let window, eventWindow === window, pointerInteraction != nil,
              !isHiddenOrHasHiddenAncestor, pageID != nil else { return nil }
        func paperPoint(_ point: NSPoint) -> CGPoint? {
            let clipPoint = contentView.convert(point, from: nil)
            let local = paper.convert(point, from: nil)
            guard local.x.isFinite, local.y.isFinite, contentView.bounds.contains(clipPoint), paper.bounds.contains(local) else { return nil }
            return local
        }
        if let local = paperPoint(point) { lastCanvasPointerInWindow = point; return local }
        guard allowingFallback else { return nil }
        if let lastCanvasPointerInWindow, let local = paperPoint(lastCanvasPointerInWindow) { return local }
        let visible = paper.bounds.intersection(paper.convert(contentView.bounds, from: contentView))
        guard !visible.isNull, !visible.isEmpty else { return nil }
        return CGPoint(x: visible.midX, y: visible.midY)
    }
    private func rememberCanvasPointer(at point: NSPoint, in eventWindow: NSWindow?) {
        _ = clipboardPoint(at: point, in: eventWindow, allowingFallback: false)
    }
    /// Selection owns wheel routing throughout the page, independent of hover.
    @discardableResult func routeAttachmentScroll(at point: NSPoint, in eventWindow: NSWindow?, delta: CGSize, precise: Bool) -> Bool {
        guard let window, eventWindow === window, !liveMagnifying, pointerInteraction?.isPressed != true,
              SelectionWheel.owns(point, in: eventWindow, scroll: self), pointerInteraction != nil else { return false }
        if let id = pointerInteraction?.selectedScrollBlockID, let scope = SelectionWheel.scope(id, in: host),
           SelectionWheel.scrollContent(in: scope, delta: delta, precise: precise, point: point) { return true }
        _ = scrollPaper(delta: delta, precise: precise)
        return true
    }
    func reveal(_ rect: CGRect) {
        let target = contentView.convert(rect, from: paper)
        var next = contentView.bounds
        next.origin = CGPoint(x: target.midX - next.width/2, y: target.midY - next.height/2)
        contentView.scroll(to: contentView.constrainBoundsRect(next).origin)
        reflectScrolledClipView(contentView)
    }
    @discardableResult func scrollPaper(delta: CGSize, precise: Bool) -> Bool {
        guard delta.width.isFinite, delta.height.isFinite else { return false }
        let unit = contentView.convert(NSSize(width: 1, height: 1), from: nil)
        let dx = delta.width * (precise ? 1 : horizontalLineScroll) * abs(unit.width)
        let dy = delta.height * (precise ? 1 : verticalLineScroll) * abs(unit.height)
        let before = contentView.bounds.origin
        var next = contentView.bounds; next.origin.x -= dx; next.origin.y -= dy
        next = contentView.constrainBoundsRect(next)
        guard abs(before.x - next.minX) > 0.001 || abs(before.y - next.minY) > 0.001 else { return false }
        contentView.scroll(to: next.origin); reflectScrolledClipView(contentView)
        return true
    }
    /// SwiftUI's hosting hit test can disagree with the rendered geometry under
    /// NSScrollView magnification. Use real, explicit native surface bounds instead.
    /// Do not consume inline buttons, native text selection, anchors or scrollbars.
    func pointerArea(at point: NSPoint, in eventWindow: NSWindow?) -> CanvasPointerInteraction.Area? {
        guard let window, eventWindow === window, let pointerInteraction, !liveMagnifying,
              SelectionWheel.owns(point, in: eventWindow, scroll: self) else { return nil }
        for scroller in [horizontalScroller, verticalScroller].compactMap({ $0 }) {
            if !scroller.isHidden && scroller.bounds.contains(scroller.convert(point, from: nil)) { return nil }
        }
        let target = pointerInteraction.hit(at: paper.convert(point, from: nil))
        if case .block(let id) = target, pointerInteraction.editingBlockID == id,
           let scope = SelectionWheel.scope(id, in: host), SelectionWheel.editorContains(point, in: scope) { return nil }
        var pending = [host as NSView]
        while let view = pending.popLast() {
            if let surface = view as? CanvasPointerView, surface.area.accepts(target),
               surface.containsPointer(surface.convert(point, from: nil)) { return surface.area }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }
    @discardableResult func beginPointer(at point: NSPoint, in eventWindow: NSWindow?,
                                         area: CanvasPointerInteraction.Area, clickCount: Int, extendingSelection: Bool = false) -> Bool {
        guard let window, eventWindow === window, !liveMagnifying,
              SelectionWheel.owns(point, in: eventWindow, scroll: self) else { return false }
        return pointerInteraction?.down(at: paper.convert(point, from: nil), area: area,
                                        clickCount: clickCount, scale: magnification, extendingSelection: extendingSelection) == true
    }
    @discardableResult func continuePointer(_ type: NSEvent.EventType, at point: NSPoint, in eventWindow: NSWindow?) -> Bool {
        guard let pointerInteraction, pointerInteraction.isPressed else { return false }
        guard let window, eventWindow === window else { pointerInteraction.cancel(); return false }
        let local = paper.convert(point, from: nil)
        if type == .leftMouseDragged { pointerInteraction.dragged(to: local) }
        else if type == .leftMouseUp { pointerInteraction.up(at: local) }
        else { return false }
        return true
    }
    private func updateDeskMonitor() {
        guard didClickDesk != nil, window != nil else {
            if let deskMonitor { NSEvent.removeMonitor(deskMonitor); self.deskMonitor = nil }; return
        }
        guard deskMonitor == nil else { return }
        deskMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { _ = self?.handleDeskClick(at: event.locationInWindow, in: event.window) }
            return event
        }
    }
    @discardableResult func handleDeskClick(at point: NSPoint, in eventWindow: NSWindow?) -> Bool {
        guard let window, eventWindow === window, didClickDesk != nil,
              SelectionWheel.owns(point, in: eventWindow, scroll: self),
              !paper.bounds.contains(paper.convert(point, from: nil)) else { return false }
        for scroller in [horizontalScroller, verticalScroller].compactMap({ $0 }) {
            if !scroller.isHidden && scroller.bounds.contains(scroller.convert(point, from: nil)) { return false }
        }
        didClickDesk?(); return true
    }
    /// Reader gestures go to the nearest native zoom viewport before WebKit or an
    /// embedded text scroll view can consume them. Wheel, pen and keyboard events pass through.
    static func magnificationTarget(from view: NSView?) -> CanvasScrollView? {
        var current = view
        while let candidate = current {
            if let viewport = candidate as? CanvasScrollView, viewport.allowsMagnification { return viewport }
            current = candidate.superview
        }
        return nil
    }
    private func updateMagnificationMonitor() {
        guard routesMagnification, window != nil else {
            if let magnificationMonitor { NSEvent.removeMonitor(magnificationMonitor) }
            magnificationMonitor = nil; routedGesture = false
            magnificationEndTask?.cancel()
            return
        }
        guard magnificationMonitor == nil else { return }
        magnificationMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            guard let self, event.window === self.window, let root = event.window?.contentView else { return event }
            let point = root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            guard self.routedGesture || Self.magnificationTarget(from: root.hitTest(point)) === self else { return event }
            self.routedGesture = true
            self.routeMagnification(event)
            return nil
        }
    }
    private func routeMagnification(_ event: NSEvent) {
        applyMagnification(event.magnification, at: paper.convert(event.locationInWindow, from: nil), phase: event.phase)
    }
    /// Keep the complete gesture in the native container; publish only its final scale.
    func applyMagnification(_ delta: CGFloat, at point: NSPoint, phase: NSEvent.Phase) {
        guard allowsMagnification, delta.isFinite else { return }
        let ending = phase.contains(.ended) || phase.contains(.cancelled)
        guard liveMagnifying || !ending else { routedGesture = false; return }
        if !liveMagnifying { startMagnifying() }
        if !phase.contains(.cancelled), delta != 0 {
            let scale = min(maxMagnification, max(minMagnification, magnification * max(0.01, 1 + delta)))
            setMagnification(scale, centeredAt: point)
        }
        if ending { endMagnifying() }
        else {
            // Some forwarded Sidecar streams omit an end phase. Release the old gesture
            // after a short idle period so the next pinch cannot inherit stale state.
            magnificationEndTask?.cancel()
            magnificationEndTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled else { return }
                self?.endMagnifying()
            }
        }
    }
    override func layout() {
        super.layout()
        centerCanvas()
        reportVisibleRect()
    }
    @objc private func reportVisibleRect() {
        guard let pageID, let didChangeVisibleRect else { return }
        didChangeVisibleRect(pageID, paper.convert(contentView.bounds, from: contentView))
    }
    private func centerCanvas() {
        // Native clipping already constrains each live pinch. Avoid a second scroll/layout
        // pass, especially when AppKit rounds a centered origin to a backing pixel.
        guard !liveMagnifying else { return }
        let constrained = contentView.constrainBoundsRect(contentView.bounds)
        let backing = contentView.convertToBacking(NSSize(width: 1, height: 1))
        let pixelX = 0.5 / max(0.001, abs(backing.width)), pixelY = 0.5 / max(0.001, abs(backing.height))
        guard abs(constrained.minX - contentView.bounds.minX) > pixelX
                || abs(constrained.minY - contentView.bounds.minY) > pixelY else { return }
        centeringAdjustments += 1
        contentView.scroll(to: constrained.origin)
        reflectScrolledClipView(contentView)
    }
    @objc private func startMagnifying() { pointerInteraction?.cancel(); liveMagnifying = true }
    @objc private func endMagnifying() {
        guard liveMagnifying else { return }
        magnificationEndTask?.cancel(); magnificationEndTask = nil; routedGesture = false
        liveMagnifying = false; requestedZoom = magnification
        didZoom(Double(magnification))
    }
    func update(pageID: UUID, size: CGSize, zoom: Double, fitting: Bool, content: AnyView) {
        defer { reportVisibleRect() }
        let changedPage = self.pageID != pageID
        if changedPage { pointerInteraction?.cancel(); lastCanvasPointerInWindow = nil }
        self.pageID = pageID
        let origin = contentView.bounds.origin
        if paper.frame.size != size {
            paper.setFrameSize(size); host.frame = CGRect(origin: .zero, size: size)
        }
        host.rootView = content
        centerCanvas()
        guard !liveMagnifying else { return }
        let scale = CGFloat(min(6, max(0.25, zoom)))
        if changedPage || abs(requestedZoom - scale) > 0.0001 || abs(magnification - scale) > 0.0001 {
            requestedZoom = scale
            if fitting || changedPage {
                magnification = scale
                contentView.scroll(to: NSPoint(x: 0, y: changedPage ? 0 : origin.y))
                reflectScrolledClipView(contentView)
            } else {
                let visible = documentVisibleRect
                setMagnification(scale, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
            }
        }
        centerCanvas()
    }
}

@MainActor struct CanvasViewport: NSViewRepresentable {
    let pageID: UUID
    let size: CGSize
    let zoom: Double
    let fitting: Bool
    let didZoom: (Double) -> Void
    let content: AnyView
    var routesMagnification = false
    var didClickDesk: (() -> Void)? = nil
    var pointerInteraction: CanvasPointerInteraction? = nil
    var attachmentBlockID: UUID? = nil
    var didChangeVisibleRect: ((UUID, CGRect) -> Void)? = nil
    var revealRect: CGRect? = nil
    var didReveal: (() -> Void)? = nil
    func makeNSView(context: Context) -> CanvasScrollView { CanvasScrollView(frame: .zero) }
    func updateNSView(_ view: CanvasScrollView, context: Context) {
        view.didZoom = didZoom
        view.didChangeVisibleRect = didChangeVisibleRect
        view.routesMagnification = routesMagnification
        view.didClickDesk = didClickDesk
        view.pointerInteraction = pointerInteraction
        view.attachmentBlockID = attachmentBlockID
        view.allowsMagnification = attachmentBlockID == nil
        (view.contentView as? CenteredCanvasClipView)?.centersVertically = attachmentBlockID == nil
        if attachmentBlockID != nil {
            view.backgroundColor = .white; view.contentView.backgroundColor = .white
        }
        view.update(pageID: pageID, size: size, zoom: zoom, fitting: fitting, content: content)
        if let revealRect {
            view.reveal(revealRect)
            if let didReveal { DispatchQueue.main.async(execute: didReveal) }
        }
    }
}
#else
@MainActor final class CanvasScrollController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let scroll = UIScrollView()
    let paper = UIView()
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    private var pageID: UUID?
    private var paperSize = CGSize.zero
    private var liveMagnifying = false
    private var programmatic = false
    private var centering = false
    var didZoom: (Double) -> Void = { _ in }
    var didClickDesk: (() -> Void)?
    var didChangeVisibleRect: ((UUID, CGRect) -> Void)?

    override func loadView() {
        view = scroll
        scroll.backgroundColor = UIColor(white: 0.91, alpha: 1)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.minimumZoomScale = 0.25; scroll.maximumZoomScale = 6
        scroll.bounces = false; scroll.bouncesZoom = false
        scroll.delaysContentTouches = false
        scroll.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        scroll.delegate = self; scroll.addSubview(paper)
        let deskTap = UITapGestureRecognizer(target: self, action: #selector(tappedDesk))
        deskTap.delegate = self; deskTap.cancelsTouchesInView = false
        scroll.addGestureRecognizer(deskTap)
        paper.backgroundColor = .white; paper.clipsToBounds = true
        addChild(host); paper.addSubview(host.view); host.didMove(toParent: self)
        host.view.backgroundColor = .clear; host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overrideUserInterfaceStyle = .light
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        didClickDesk != nil && !paper.bounds.contains(gestureRecognizer.location(in: paper))
    }
    @objc private func tappedDesk() { didClickDesk?() }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        centerCanvas()
        reportVisibleRect()
    }
    private func reportVisibleRect() {
        guard let pageID, let didChangeVisibleRect else { return }
        didChangeVisibleRect(pageID, paper.convert(scroll.bounds, from: scroll))
    }
    private func constrainedOffset(_ target: CGPoint) -> CGPoint {
        let inset = scroll.contentInset
        return CGPoint(x: min(max(-inset.left, target.x), max(-inset.left, scroll.contentSize.width - scroll.bounds.width + inset.right)),
                       y: min(max(-inset.top, target.y), max(-inset.top, scroll.contentSize.height - scroll.bounds.height + inset.bottom)))
    }
    private func centerCanvas() {
        guard !centering, paperSize.width > 0, paperSize.height > 0 else { return }
        centering = true; defer { centering = false }
        let horizontal = max(0, (scroll.bounds.width - paperSize.width * scroll.zoomScale) / 2)
        let vertical = max(0, (scroll.bounds.height - paperSize.height * scroll.zoomScale) / 2)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if scroll.contentInset != inset { scroll.contentInset = inset }
        let offset = constrainedOffset(scroll.contentOffset)
        let pixel = 0.5 / (scroll.window?.screen.scale ?? 2)
        if abs(scroll.contentOffset.x - offset.x) > pixel || abs(scroll.contentOffset.y - offset.y) > pixel {
            scroll.contentOffset = offset
        }
    }
    func update(pageID: UUID, size: CGSize, zoom: Double, fitting: Bool, content: AnyView) {
        defer { reportVisibleRect() }
        loadViewIfNeeded()
        let changedPage = self.pageID != pageID
        self.pageID = pageID
        host.rootView = content
        if paperSize != size {
            paperSize = size; paper.bounds = CGRect(origin: .zero, size: size)
            paper.center = CGPoint(x: size.width * scroll.zoomScale / 2, y: size.height * scroll.zoomScale / 2)
            host.view.frame = paper.bounds
            scroll.contentSize = CGSize(width: size.width * scroll.zoomScale, height: size.height * scroll.zoomScale)
        }
        centerCanvas()
        guard !liveMagnifying else { return }
        let scale = CGFloat(min(6, max(0.25, zoom)))
        if changedPage || abs(scroll.zoomScale - scale) > 0.0001 {
            let oldScale = scroll.zoomScale, oldOffset = scroll.contentOffset
            let center = CGPoint(x: (oldOffset.x + scroll.bounds.width / 2) / oldScale,
                                 y: (oldOffset.y + scroll.bounds.height / 2) / oldScale)
            programmatic = true
            scroll.setZoomScale(scale, animated: false)
            centerCanvas()
            let target = changedPage ? CGPoint.zero : fitting
                ? CGPoint(x: 0, y: oldOffset.y / oldScale * scale)
                : CGPoint(x: center.x * scale - scroll.bounds.width / 2, y: center.y * scale - scroll.bounds.height / 2)
            scroll.contentOffset = constrainedOffset(target)
            programmatic = false
        }
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { paper }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { reportVisibleRect() }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerCanvas(); reportVisibleRect() }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        if !programmatic { liveMagnifying = true }
    }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard !programmatic, liveMagnifying else { return }
        liveMagnifying = false; didZoom(Double(scale))
    }
}

@MainActor struct CanvasViewport: UIViewControllerRepresentable {
    let pageID: UUID
    let size: CGSize
    let zoom: Double
    let fitting: Bool
    let didZoom: (Double) -> Void
    let content: AnyView
    var routesMagnification = false
    var didClickDesk: (() -> Void)? = nil
    var pointerInteraction: CanvasPointerInteraction? = nil
    var attachmentBlockID: UUID? = nil
    var didChangeVisibleRect: ((UUID, CGRect) -> Void)? = nil
    var revealRect: CGRect? = nil
    var didReveal: (() -> Void)? = nil
    func makeUIViewController(context: Context) -> CanvasScrollController { CanvasScrollController() }
    func updateUIViewController(_ controller: CanvasScrollController, context: Context) {
        controller.didZoom = didZoom
        controller.didChangeVisibleRect = didChangeVisibleRect
        controller.didClickDesk = didClickDesk
        controller.update(pageID: pageID, size: size, zoom: zoom, fitting: fitting, content: content)
        if let revealRect {
            controller.scroll.scrollRectToVisible(controller.paper.convert(revealRect, to: controller.scroll), animated: false)
            if let didReveal { DispatchQueue.main.async(execute: didReveal) }
        }
    }
}
#endif
