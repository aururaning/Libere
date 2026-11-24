import Foundation
import SwiftUI

@MainActor private final class GuideTipProbe {
    var target: CGRect?
    var size: CGSize?
}

@MainActor private struct GuideTipProbeView: View {
    let store: AppStore
    let shown: Bool
    let probe: GuideTipProbe
    let open: () -> Void
    let dismiss: () -> Void
    var body: some View {
        LibraryView(store: store, openGuide: open, showGuideTip: shown, dismissGuideTip: dismiss)
            .overlayPreferenceValue(GuideButtonAnchorKey.self) { anchor in
                if let anchor {
                    GeometryReader { geometry in
                        let target = geometry[anchor]
                        Color.clear.allowsHitTesting(false)
                            .onAppear { probe.target = target; probe.size = geometry.size }
                            .onChange(of: target) { _, rect in probe.target = rect; probe.size = geometry.size }
                            .onChange(of: geometry.size) { _, size in probe.target = target; probe.size = size }
                    }.allowsHitTesting(false)
                }
            }
    }
}

@MainActor func runGuideTipNativeChecks() async throws -> Int {
    _ = NSApplication.shared
    var count = 0
    func check(_ value: Bool, _ label: String) {
        if !value { FileHandle.standardError.write(Data(("FAILED guide tip: " + label + "\n").utf8)) }
        precondition(value, label); count += 1
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("LibereGuideTip-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let suite = "LibereGuideTip." + UUID().uuidString
    let testDefaults = UserDefaults(suiteName: suite)!
    defer { testDefaults.removePersistentDomain(forName: suite) }
    let cloud = UserDefaults.standard.object(forKey: "MarginCloudEnabled")
    UserDefaults.standard.set(false, forKey: "MarginCloudEnabled")
    defer {
        if let cloud { UserDefaults.standard.set(cloud, forKey: "MarginCloudEnabled") }
        else { UserDefaults.standard.removeObject(forKey: "MarginCloudEnabled") }
    }
    let store = try AppStore(root: fixture, preferences: testDefaults)
    var page = Note(title: "新的笔记")
    page.canvasWidth = 1000; page.canvasHeight = 3000
    store.workspace = Workspace(notes: [page]); store.selection = page.id
    store.fitToWidth = false; store.zoom = 1
    try store.repository.save(store.workspace)
    var opened = 0, dismissed = 0

    func bitmap(_ host: NSView) throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }
    func blueSamples(_ bitmap: NSBitmapImageRep) -> Int {
        var result = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 6) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 6) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent < 0.4 && color.greenComponent < 0.6 && color.blueComponent > 0.6 { result += 1 }
            }
        }
        return result
    }
    for width in [1100, 980, 760] {
        let height = width == 1100 ? 760 : 700
        let probe = GuideTipProbe()
        func content(_ shown: Bool) -> AnyView {
            AnyView(GuideTipProbeView(store: store, shown: shown, probe: probe,
                                     open: { opened += 1 }, dismiss: { dismissed += 1 })
                .frame(width: CGFloat(width), height: CGFloat(height)).environment(\.colorScheme, .light))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content(false)); host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: width, height: height); window.contentView = host
        defer { window.contentView = nil; window.close() }
        var canvas: CanvasScrollView?
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            canvas = descendants(host).compactMap { $0 as? CanvasScrollView }.first { $0.pointerInteraction === store.canvasPointer }
            if probe.target != nil, canvas != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let target = probe.target, let canvas else { preconditionFailure("The actual main library did not expose its tutorial anchor/canvas") }
        check(store.flush(), "The no-tip library layout is saved before the overlay comparison")
        let baselineWorkspace = store.workspace
        let point = canvas.contentView.convert(NSPoint(x: canvas.contentView.bounds.minX + 70, y: canvas.contentView.bounds.minY + canvas.contentView.bounds.height * 0.75), to: nil)
        let baselineOwns = SelectionWheel.owns(point, in: window, scroll: canvas)
        let baselineArea = canvas.pointerArea(at: point, in: window)
        let noTip = try bitmap(host), baselineBlue = blueSamples(noTip)
        host.rootView = content(true)
        for _ in 0..<12 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
        let shown = try bitmap(host), shownBlue = blueSamples(shown)
        guard let shownTarget = probe.target, let size = probe.size,
              let shownCanvas = descendants(host).compactMap({ $0 as? CanvasScrollView }).first(where: { $0.pointerInteraction === store.canvasPointer }) else {
            preconditionFailure("Showing the tooltip removed the target/canvas")
        }
        let layout = GuideTipLayout(target: shownTarget, container: size)
        let owns = SelectionWheel.owns(point, in: window, scroll: shownCanvas)
        let area = shownCanvas.pointerArea(at: point, in: window)
        print("GUIDE TIP \(width): host=\(host.bounds.size), container=\(size), target=\(shownTarget), origin=\(layout.origin), arrowX=\(layout.arrowX), blue=\(baselineBlue)/\(shownBlue), owns=\(baselineOwns)/\(owns), area=\(String(describing: baselineArea))/\(String(describing: area))")
        check(target == shownTarget, "Showing the layer does not shift the actual question-mark anchor")
        check(shownBlue > baselineBlue + 300, "The actual library renders the blue tutorial card, not only its preference anchor")
        check(layout.origin.x >= 0 && layout.origin.x + layout.width <= size.width,
              "The tip card remains inside its real layout container")
        check(abs(layout.origin.x + layout.arrowX - shownTarget.midX) < 0.01,
              "The arrow points to the actual question mark's horizontal center")
        if width >= 980 {
            check(shownTarget.minX >= CGFloat(width) / 2 && shownTarget.maxX <= CGFloat(width) && shownTarget.maxY < 120,
                  "The tutorial target is visibly in the upper-right of a supported Mac window")
            check(baselineOwns && owns && baselineArea == .paper && area == .paper,
                  "The overlay leaves the same outside-card canvas point hit-testable")
            let oldOrigin = shownCanvas.contentView.bounds.origin
            check(shownCanvas.routeAttachmentScroll(at: point, in: window, delta: CGSize(width: 0, height: -55), precise: true)
                  && shownCanvas.contentView.bounds.origin.y > oldOrigin.y,
                  "Wheel input outside the card still scrolls the main canvas")
        }
        let output = project.appendingPathComponent(".build/validation/guide-tip-\(width).png")
        guard let png = shown.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: output)
        if width == 1100 {
            // Render the relevant region directly from our own hosting view.
            // Native sidebar/system surfaces can appear black in cacheDisplay;
            // the detail keeps the question mark, pointer and complete card.
            let detailX = max(0, shownCanvas.convert(shownCanvas.bounds, to: host).minX)
            let topInset = max(0, (host.bounds.height - CGFloat(height)) / 2)
            let detailHeight = min(250, host.bounds.height - topInset)
            let detailRect = NSRect(x: detailX,
                y: host.isFlipped ? topInset : host.bounds.maxY - topInset - detailHeight,
                width: host.bounds.width - detailX, height: detailHeight)
            guard let detail = host.bitmapImageRepForCachingDisplay(in: detailRect) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: detailRect, to: detail)
            guard let detailPNG = detail.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try detailPNG.write(to: project.appendingPathComponent(".build/validation/guide-tip-detail.png"))
        }
        let scale = host.convertToBacking(host.bounds).size
        check(shown.pixelsWide == Int(scale.width.rounded()) && shown.pixelsHigh == Int(scale.height.rounded()),
              "The tooltip snapshot uses the native backing scale")
        check(store.workspace == baselineWorkspace, "Showing the overlay does not edit the warmed library contents")
    }
    check(opened == 0 && dismissed == 0, "Rendering the passive first-use layer does not invoke either action")
    check(store.workspace.notes.count == 1, "The overlay does not insert tutorial pages into the synthetic library")
    print("PASS: \(count) tutorial tip anchor, native layout, canvas hit and wheel assertions")
    return count
}
