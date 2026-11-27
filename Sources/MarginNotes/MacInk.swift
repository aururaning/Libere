#if os(macOS)
import AppKit
import SwiftUI
import PencilKit
#if SWIFT_PACKAGE
import MarginCore
#endif

/// Pencil/tablet input can arrive as mouse subtypes or as a pure tablet stream.
/// Finger touches are left to the ancestor scroll view in both cases.
@MainActor class TabletInkGesture: NSGestureRecognizer {
    private(set) var points: [PKStrokePoint] = []
    private(set) var creationDate = Date()
    var options = InkOptions()
    var excludedRects: [CGRect] = []
    private var activeOptions = InkOptions()
    private var startTime: TimeInterval = 0
    private var windowPoint = NSPoint.zero
    private var priorCoalescing: Bool?
    private var pressure: CGFloat = 0.5
    static func isTablet(_ event: NSEvent) -> Bool {
        if event.type == .tabletPoint { return true }
        if event.type == .tabletProximity {
            return event.pointingDeviceType == .pen || event.pointingDeviceType == .eraser
        }
        guard [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved].contains(event.type) else { return false }
        if event.subtype == .tabletPoint { return true }
        if event.subtype == .tabletProximity { return event.pointingDeviceType == .pen || event.pointingDeviceType == .eraser }
        return false
    }
    override func mouseDown(with event: NSEvent) {
        #if LIBERE_INPUT_TRACE
        SidecarInputTrace.record("pen-mouse-down", event: event)
        #endif
        guard Self.isTablet(event) else { state = .failed; return }
        beginStroke(event)
    }
    private func beginStroke(_ event: NSEvent) {
        guard let view,
              !excludedRects.contains(where: { $0.contains(view.convert(event.locationInWindow, from: nil)) }) else { state = .failed; return }
        creationDate = Date(); startTime = event.timestamp; points = []; activeOptions = options
        pressure = max(0.08, CGFloat(event.pressure))
        priorCoalescing = NSEvent.isMouseCoalescingEnabled
        NSEvent.isMouseCoalescingEnabled = false
        append(event); state = .began
    }
    override func mouseDragged(with event: NSEvent) { sample(event) }
    override func tabletPoint(with event: NSEvent) {
        #if LIBERE_INPUT_TRACE
        SidecarInputTrace.record("pen-tablet-point", event: event, extra: ["state": state.rawValue])
        #endif
        guard Self.isTablet(event) else { return }
        let contact = event.buttonMask.rawValue & 1 != 0 || event.pressure > 0
        if state == .possible {
            if contact { beginStroke(event) }
        } else if state == .began || state == .changed {
            if contact { sample(event) }
            else { endStroke(event) }
        }
    }
    private func sample(_ event: NSEvent) {
        guard state == .began || state == .changed else { return }
        append(event); state = .changed
    }
    override func mouseUp(with event: NSEvent) {
        endStroke(event)
    }
    private func endStroke(_ event: NSEvent) {
        guard state == .began || state == .changed else { return }
        append(event); restoreCoalescing(); state = .ended
    }
    @available(macOS 26.0, *)
    override func mouseCancelled(with event: NSEvent) { restoreCoalescing(); state = state == .possible ? .failed : .cancelled }
    override func touchesCancelled(with event: NSEvent) { restoreCoalescing(); state = state == .possible ? .failed : .cancelled }
    override func reset() { restoreCoalescing(); super.reset(); points = []; windowPoint = .zero }
    private func restoreCoalescing() { if let priorCoalescing { NSEvent.isMouseCoalescingEnabled = priorCoalescing }; priorCoalescing = nil }
    override func location(in view: NSView?) -> NSPoint { view?.convert(windowPoint, from: nil) ?? windowPoint }
    private func append(_ event: NSEvent) {
        guard let view else { return }
        windowPoint = event.locationInWindow
        let point = view.convert(windowPoint, from: nil)
        let time = max(0, event.timestamp - startTime)
        if let last = points.last, last.timeOffset == time && last.location == point { return }
        if event.pressure > 0 { pressure += (CGFloat(event.pressure) - pressure) * 0.4 }
        let width = activeOptions.pointWidth(pressure: max(0.08, min(1, pressure)))
        points.append(PKStrokePoint(location: point, timeOffset: time, size: CGSize(width: width, height: width),
                                    opacity: activeOptions.opacity, force: pressure, azimuth: 0, altitude: .pi / 2))
    }
}

/// CPU vector rendering avoids PKDrawing.image's unavailable image representation on this Mac.
/// The same PencilKit B-spline is used during input and after reload; committed geometry is cached.
@MainActor struct MacInkStroke {
    let stroke: PKStroke
    let shape: CGPath
    let samples: [PKStrokePoint]
    init(_ stroke: PKStroke) {
        self.stroke = stroke
        samples = stroke.path.count < 2 ? Array(stroke.path) : Array(stroke.path.interpolatedPoints(by: .distance(0.9)))
        let shape = CGMutablePath()
        var previous: PKStrokePoint?
        for point in samples {
            let radius = max(0.2, point.size.width / 2)
            shape.addEllipse(in: CGRect(x: point.location.x - radius, y: point.location.y - radius, width: radius * 2, height: radius * 2))
            if let previous {
                let dx = point.location.x - previous.location.x, dy = point.location.y - previous.location.y
                let length = hypot(dx, dy)
                if length > 0.001 {
                    let nx = -dy / length, ny = dx / length, r = max(0.2, previous.size.width / 2)
                    shape.move(to: CGPoint(x: previous.location.x + nx * r, y: previous.location.y + ny * r))
                    shape.addLine(to: CGPoint(x: point.location.x + nx * radius, y: point.location.y + ny * radius))
                    shape.addLine(to: CGPoint(x: point.location.x - nx * radius, y: point.location.y - ny * radius))
                    shape.addLine(to: CGPoint(x: previous.location.x - nx * r, y: previous.location.y - ny * r))
                    shape.closeSubpath()
                }
            }
            previous = point
        }
        self.shape = shape
    }
    func draw(in context: CGContext) {
        guard !samples.isEmpty else { return }
        context.saveGState()
        context.concatenate(stroke.transform)
        stroke.mask?.addClip()
        let color = stroke.ink.color.usingColorSpace(.deviceRGB) ?? stroke.ink.color
        let opacity = samples.map(\.opacity).reduce(0, +) / CGFloat(samples.count)
        let alpha = stroke.ink.inkType == .marker ? min(opacity, 0.32) : opacity
        context.setFillColor(color.withAlphaComponent(color.alphaComponent * alpha).cgColor)
        context.addPath(shape); context.fillPath()
        context.restoreGState()
    }
    func hits(_ a: CGPoint, _ b: CGPoint, radius: CGFloat) -> Bool {
        let dx = b.x - a.x, dy = b.y - a.y, length2 = dx * dx + dy * dy
        return samples.contains { point in
            let p = point.location.applying(stroke.transform)
            let t = length2 > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2)) : 0
            return hypot(p.x - (a.x + dx * t), p.y - (a.y + dy * t)) < radius + point.size.width / 2
        }
    }
}

@MainActor final class MacInkView: NSView, NSGestureRecognizerDelegate {
    var begin: () -> Void = {}
    var save: (Data?, Rect?) -> Void = { _, _ in }
    private var drawing = PKDrawing()
    private var lastData: Data?
    private var committed: [MacInkStroke] = []
    private var preview: MacInkStroke?
    private var options = InkOptions()
    private var activeOptions = InkOptions()
    private var strokeSave: ((Data?, Rect?) -> Void)?
    private var erased = Set<Int>()
    private var excludedRects: [CGRect] = []
    private var strokeExclusions: [CGRect] = []
    var committedStrokeCount: Int { drawing.strokes.count }
    private lazy var pen: TabletInkGesture = {
        let gesture = TabletInkGesture(target: self, action: #selector(handlePen(_:)))
        gesture.allowedTouchTypes = []; gesture.delegate = self
        // A pen stroke is not a finger pan. Scroll arbitration must not cancel
        // a valid Pencil stroke before the ink action receives its first sample.
        if #available(macOS 27.0, *) { gesture.isCancellableByScrollGesture = false }
        return gesture
    }()
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); addGestureRecognizer(pen) }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !pen.isEnabled || excludedRects.contains(where: { $0.contains(local) }) { return nil }
        return super.hitTest(point)
    }
    func update(data: Data?, enabled: Bool, options: InkOptions = InkOptions(), excludedRects: [CGRect] = []) {
        #if LIBERE_INPUT_TRACE
        if pen.isEnabled != enabled { SidecarInputTrace.record("ink-enabled", extra: ["enabled": enabled, "width": bounds.width, "height": bounds.height]) }
        #endif
        self.options = options; self.excludedRects = excludedRects
        pen.options = options; pen.excludedRects = excludedRects
        if !enabled && strokeSave != nil { finishStroke(); pen.isEnabled = false; return }
        pen.isEnabled = enabled
        if data != lastData {
            lastData = data; drawing = data.flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
            committed = drawing.strokes.map(MacInkStroke.init)
            preview = nil; erased = []; strokeSave = nil
            needsDisplay = true
        }
    }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        #if LIBERE_INPUT_TRACE
        SidecarInputTrace.record("pen-candidate", event: event, extra: ["accepted": TabletInkGesture.isTablet(event)])
        #endif
        return TabletInkGesture.isTablet(event)
    }
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldReceive touch: NSTouch) -> Bool { false }
    @objc private func handlePen(_ gesture: TabletInkGesture) {
        #if LIBERE_INPUT_TRACE
        SidecarInputTrace.record("pen-action", extra: ["state": gesture.state.rawValue, "points": gesture.points.count])
        #endif
        switch gesture.state {
        case .began, .changed, .ended:
            if strokeSave == nil { begin(); strokeSave = save; activeOptions = options; strokeExclusions = excludedRects }
            if activeOptions.style == .eraser {
                let points = gesture.points
                if let last = points.last {
                    let prior = points.count > 1 ? points[points.count - 2].location : last.location
                    for (index, stroke) in committed.enumerated() where !erased.contains(index) {
                        if stroke.hits(prior, last.location, radius: CGFloat(activeOptions.width) + 4) { erased.insert(index) }
                    }
                }
            } else {
                let oldBounds = preview?.stroke.renderBounds ?? .null
                let mask = NSBezierPath()
                for rect in InkClip.areas(in: bounds, excluding: strokeExclusions) { mask.appendRect(rect) }
                let stroke = PKStroke(ink: PKInk(activeOptions.style.type, color: activeOptions.color.native),
                                      path: PKStrokePath(controlPoints: gesture.points, creationDate: gesture.creationDate), mask: mask)
                preview = MacInkStroke(stroke)
                setNeedsDisplay(oldBounds.union(stroke.renderBounds).insetBy(dx: -3, dy: -3))
            }
            if activeOptions.style == .eraser { needsDisplay = true }
            if gesture.state == .ended { finishStroke() }
        case .cancelled, .failed: preview = nil; strokeSave = nil; erased = []; needsDisplay = true
        default: break
        }
    }
    private func finishStroke() {
        guard let strokeSave else { return }
        self.strokeSave = nil
        if activeOptions.style == .eraser {
            guard !erased.isEmpty else { return }
            committed = committed.enumerated().filter { !erased.contains($0.offset) }.map(\.element)
            drawing = PKDrawing(strokes: committed.map(\.stroke)); erased = []
        } else if let preview {
            committed.append(preview); drawing = PKDrawing(strokes: committed.map(\.stroke)); self.preview = nil
        } else { return }
        lastData = drawing.strokes.isEmpty ? nil : drawing.dataRepresentation()
        let b = drawing.bounds
        strokeSave(lastData, b.isNull || b.isEmpty ? nil : Rect(b.minX, b.minY, b.width, b.height))
        needsDisplay = true
    }
    func finishPendingInput() { finishStroke(); pen.isEnabled = false }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setShouldAntialias(true)
        for (index, stroke) in committed.enumerated() where !erased.contains(index) && stroke.stroke.renderBounds.intersects(dirtyRect) { stroke.draw(in: context) }
        preview?.draw(in: context)
    }
}

@MainActor struct MacInkOverlay: NSViewRepresentable {
    let data: Data?; let enabled: Bool
    var options = InkOptions()
    var excludedRects: [CGRect] = []
    let begin: () -> Void; let save: (Data?, Rect?) -> Void
    func makeNSView(context: Context) -> MacInkView { MacInkView(frame: .zero) }
    func updateNSView(_ view: MacInkView, context: Context) {
        view.begin = begin; view.save = save; view.update(data: data, enabled: enabled, options: options, excludedRects: excludedRects)
    }
    static func dismantleNSView(_ view: MacInkView, coordinator: ()) { view.finishPendingInput() }
}
#endif
