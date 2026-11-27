import AppKit
import PencilKit

/// AppKit commits requested states at its input-dispatch boundary. The unit
/// driver supplies that boundary without posting synthetic input to the desktop.
@MainActor private final class ImmediateTabletGesture: TabletInkGesture {
    private var dispatchedState = NSGestureRecognizer.State.possible
    override var state: NSGestureRecognizer.State {
        get { dispatchedState }
        set { dispatchedState = newValue }
    }
}

@MainActor func runPenInputNativeChecks() throws -> Int {
    _ = NSApplication.shared
    var count = 0
    func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
    func tablet(_ type: CGEventType, point: CGPoint, pressure: Double, buttons: Int64) -> NSEvent {
        let event = CGEvent(source: nil)!
        event.type = type; event.location = CGPoint(x: point.x, y: (NSScreen.main?.frame.maxY ?? 0) - point.y)
        event.setIntegerValueField(.tabletEventDeviceID, value: 1)
        event.setIntegerValueField(.tabletEventPointButtons, value: buttons)
        event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        return NSEvent(cgEvent: event)!
    }
    let view = MacInkView(frame: CGRect(x: 0, y: 0, width: 800, height: 1200))
    let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view
    defer { window.contentView = nil }
    var saved: Data?, begins = 0
    view.begin = { begins += 1 }; view.save = { data, _ in saved = data }
    view.update(data: nil, enabled: true)
    let nativePen = view.gestureRecognizers.compactMap { $0 as? TabletInkGesture }.first!
    let action = nativePen.action!
    let pen = ImmediateTabletGesture(target: nil, action: nil)
    pen.allowedTouchTypes = nativePen.allowedTouchTypes
    view.addGestureRecognizer(pen)
    // Feed native event objects directly, then dispatch the real AppKit action.
    // No synthetic input is posted to the desktop or another application.
    pen.action = nil
    func deliver() { _ = NSApp.sendAction(action, to: view, from: pen) }
    let hover = tablet(.tabletPointer, point: CGPoint(x: 120, y: 140), pressure: 0, buttons: 0)
    check(TabletInkGesture.isTablet(hover), "A pure tablet event is recognized as pen input")
    pen.tabletPoint(with: hover)
    check(pen.state == .possible && pen.points.isEmpty, "Pencil hover does not leave ink")
    let first = tablet(.tabletPointer, point: CGPoint(x: 120, y: 140), pressure: 0.55, buttons: 1)
    pen.tabletPoint(with: first); deliver()
    check(pen.state == .began && pen.points.count == 1, "A pure Pencil contact starts a stroke without requiring mouseDown")
    let second = tablet(.tabletPointer, point: CGPoint(x: 150, y: 160), pressure: 0.75, buttons: 1)
    pen.tabletPoint(with: second); deliver()
    check(pen.state == .changed && pen.points.count >= 2, "Tablet samples extend the active stroke")
    pen.tabletPoint(with: tablet(.tabletPointer, point: CGPoint(x: 170, y: 180), pressure: 0, buttons: 0)); deliver()
    check(pen.state == .ended && view.committedStrokeCount == 1 && begins == 1, "Pencil lift commits exactly one stroke without a mouseUp event")
    check(try saved.map { try PKDrawing(data: $0).strokes.count } == 1, "The input action saves a real reloadable PencilKit drawing")
    check(pen.allowedTouchTypes.isEmpty, "The pen recognizer never accepts direct finger touches")
    if #available(macOS 27.0, *) { check(!nativePen.isCancellableByScrollGesture, "Finger scroll arbitration cannot preempt the pen's first sample") }

    pen.state = .possible; pen.reset()
    let mouse = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 50, y: 50), modifierFlags: [], timestamp: 1,
        windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    check(!TabletInkGesture.isTablet(mouse), "Pressure alone never turns a mouse or Force Touch event into a pen")
    pen.mouseDown(with: mouse)
    check(pen.state == .failed && pen.points.isEmpty, "Ordinary pointer input cannot start handwriting")
    pen.state = .possible; pen.reset()
    let local = view.convert(first.locationInWindow, from: nil)
    view.update(data: saved, enabled: true, excludedRects: [CGRect(x: local.x-5, y: local.y-5, width: 10, height: 10)])
    pen.excludedRects = [CGRect(x: local.x-5, y: local.y-5, width: 10, height: 10)]
    pen.tabletPoint(with: first)
    check(pen.state == .failed && view.committedStrokeCount == 1, "A pen contact inside another attachment's ink area does not create a second canvas stroke")
    pen.state = .possible; pen.reset(); view.update(data: saved, enabled: true); pen.excludedRects = []
    pen.tabletPoint(with: first); deliver()
    let lift = NSEvent.mouseEvent(with: .leftMouseUp, location: first.locationInWindow, modifierFlags: [], timestamp: first.timestamp + 0.01,
        windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
    pen.mouseUp(with: lift); deliver()
    check(pen.state == .ended && view.committedStrokeCount == 2, "Mixed tablet/mouse-up delivery also ends and persists the stroke")
    pen.state = .possible; pen.reset()
    print("PASS: \(count) Pencil/tablet contact, hover, lift, persistence, exclusion and finger separation assertions")
    return count
}
