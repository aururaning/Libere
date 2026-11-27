#if os(macOS) && LIBERE_INPUT_TRACE
import AppKit

/// Only linked into the isolated handwriting verification app. Records numeric
/// input metadata from that app; never keyboard text, clipboard data or documents.
@MainActor enum SidecarInputTrace {
    private static var records: [[String: Any]] = []
    private static var destination: URL?
    private static var monitor: Any?
    private static var saveTask: Task<Void, Never>?
    private static var sampleCounts: [String: Int] = [:]
    static func install(root: URL) {
        guard monitor == nil else { return }
        destination = root.appendingPathComponent("input-events.json")
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .tabletPoint, .tabletProximity]) { event in
            MainActor.assumeIsolated {
                var extra: [String: Any] = [:]
                if let window = event.window, let root = window.contentView {
                    let point = root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
                    if let hit = root.hitTest(point) { extra["hit"] = String(describing: type(of: hit)) }
                }
                record("raw", event: event, extra: extra)
            }
            return event
        }
    }
    static func record(_ kind: String, event: NSEvent? = nil, extra: [String: Any] = [:]) {
        guard destination != nil, records.count < 200 else { return }
        let sampled = kind == "pen-tablet-point"
            || (kind == "raw" && (event?.type == .leftMouseDragged || event?.type == .tabletPoint))
            || (kind == "pen-action" && extra["state"] as? Int == NSGestureRecognizer.State.changed.rawValue)
        if sampled {
            guard sampleCounts[kind, default: 0] < 12 else { return }
            sampleCounts[kind, default: 0] += 1
        }
        var value = extra; value["kind"] = kind
        if let event {
            value["type"] = event.type.rawValue
            let mouse = [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type)
            let subtype = mouse ? event.subtype : nil
            if let subtype { value["subtype"] = subtype.rawValue }
            if [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .tabletPoint].contains(event.type) {
                value["pressure"] = event.pressure
                if let cg = event.cgEvent { value["tabletDevice"] = cg.getIntegerValueField(.tabletEventDeviceID) }
            }
            if event.type == .tabletPoint || subtype == .tabletPoint { value["buttons"] = event.buttonMask.rawValue }
            if event.type == .tabletProximity || subtype == .tabletProximity {
                value["deviceType"] = event.pointingDeviceType.rawValue; value["entering"] = event.isEnteringProximity
            }
        }
        records.append(value); saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let destination, let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) else { return }
            try? data.write(to: destination, options: .atomic)
        }
    }
}
#endif
