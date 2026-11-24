import Foundation
import SwiftUI

@MainActor func runFeatureGuideNativeChecks() throws -> Int {
    _ = NSApplication.shared
    var count = 0
    func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
    let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let source = project.appendingPathComponent("Sources/MarginNotes/Resources/Showcase.json")
    let data = try Data(contentsOf: source)
    let guide = try FeatureGuideCatalog.decode(data)
    check(Set(guide.sections.map(\.id)) == ["start", "canvas", "text", "ink", "pdf", "files", "code", "organize", "find", "selection", "clipboard", "storage", "agent", "recovery"],
          "Guide covers every current functional area without creating library pages")
    check(guide.topicCount == 56 && guide.sections.allSatisfy { !$0.topics.isEmpty }, "Guide has 56 individually actionable topics in 14 groups")
    check(guide.matchingSections(query: "").count == guide.sections.count, "Empty search keeps the complete contents")
    check(guide.matchingSections(query: "库外").flatMap(\.topics).contains { $0.id == "clipboard.outside" }, "Clipboard archive instructions are discoverable")
    check(guide.matchingSections(query: "无路径").flatMap(\.topics).contains { $0.id == "clipboard.bytes" }, "Raw clipboard image and PDF instructions are discoverable")
    check(guide.matchingSections(query: "SHIFT enter").flatMap(\.topics).contains { $0.id == "code.notebook-cells" }, "Search is case-insensitive and matches multiple shortcut terms")
    check(guide.matchingSections(query: "不存在的功能检索样本").isEmpty, "No-match search returns an empty result")
    let generic = guide.sections.flatMap(\.topics).first { $0.id == "files.generic" }!
    check(generic.steps.contains { $0.contains("打开原文件") } && generic.summary.contains("没有内嵌预览"), "Generic files are documented as external-open cards, not universal embedded previews")
    let clipboard = guide.sections.first { $0.id == "clipboard" }!
    check(Set(clipboard.topics.map(\.id)).isSuperset(of: ["clipboard.inside", "clipboard.outside", "clipboard.bytes", "clipboard.internal"]),
          "Library paths, outside archives, raw data and in-app source copies have distinct instructions")

    let suite = "LibereFeatureGuideChecks-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    check(GuidePresentation.consumeAutomaticPresentation(isNewLibrary: true, defaults: defaults), "A first-use new library presents help once")
    check(!GuidePresentation.consumeAutomaticPresentation(isNewLibrary: true, defaults: defaults), "A second new library does not repeat automatic help")
    defaults.set("future-version", forKey: "TestAppVersion")
    check(!GuidePresentation.consumeAutomaticPresentation(isNewLibrary: true, defaults: defaults), "An app version change does not reset the one-time marker")
    defaults.removeObject(forKey: GuidePresentation.automaticPresentationKey)
    check(!GuidePresentation.consumeAutomaticPresentation(isNewLibrary: false, defaults: defaults), "An existing library upgraded without a marker does not present help")
    check(defaults.bool(forKey: GuidePresentation.automaticPresentationKey), "An existing-library upgrade consumes the marker")
    check(!GuidePresentation.consumeAutomaticPresentation(isNewLibrary: true, defaults: defaults), "A later new library cannot trigger help after an existing-library upgrade")

    let oldCatalog = try JSONDecoder().decode(ShowcaseCatalog.self, from: data)
    try oldCatalog.validate()
    check(oldCatalog.backup.workspace.notes.count == 13 && oldCatalog.rootID == ShowcaseCatalog.rootPageID,
          "Legacy examples and their stable root remain available separately")
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("LibereFeatureGuide-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let prepared = try AppStore.prepareStartup(root: fixture, device: "feature-guide-check")
    let store = try AppStore(root: fixture, preferences: defaults, prepared: prepared)
    let before = store.workspace, selection = store.selection
    let bytes = try Data(contentsOf: store.repository.workspaceURL)
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    for width in [1100, 720] {
        let view = FeatureGuideView(store: store, catalog: guide)
            .frame(width: CGFloat(width), height: 760)
            .environment(\.colorScheme, .light)
        // These are our synthetic test views. Capture their native controls rather
        // than ImageRenderer, which omits TextField/ScrollView's AppKit backing.
        // No existing application window or user library is observed here.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 760)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            if descendants(host).contains(where: { $0 is NSTextField }),
               descendants(host).compactMap({ $0 as? NSScrollView }).contains(where: { ($0.documentView?.bounds.height ?? 0) > 200 }) { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let searchFields = descendants(host).compactMap { $0 as? NSTextField }.filter { $0.placeholderString == "搜索功能、操作或快捷键" }
        let scrolls = descendants(host).compactMap { $0 as? NSScrollView }
        print("GUIDE NATIVE \(width): textFields=\(searchFields.count), scrolls=\(scrolls.count), heights=\(scrolls.map { $0.documentView?.bounds.height ?? 0 })")
        check(searchFields.contains { !$0.isHiddenOrHasHiddenAncestor && host.bounds.intersects($0.convert($0.bounds, to: host)) }, "The actual tutorial search field is present and in visible bounds")
        check(scrolls.contains { !$0.isHiddenOrHasHiddenAncestor && ($0.documentView?.bounds.height ?? 0) > 200 && host.bounds.intersects($0.convert($0.bounds, to: host)) }, "The actual first category's scrollable content is laid out")
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { preconditionFailure("Guide native bitmap allocation failed") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { preconditionFailure("Guide native bitmap encoding failed") }
        let output = project.appendingPathComponent(".build/validation/feature-guide-\(width).png")
        try png.write(to: output)
        let backingSize = host.convertToBacking(host.bounds).size
        check(bitmap.pixelsWide == Int(backingSize.width.rounded()) && bitmap.pixelsHigh == Int(backingSize.height.rounded()), "Guide layout renders at \(width)-point desktop width using native backing scale")
    }
    check(store.workspace == before && store.selection == selection, "Opening/rendering help does not insert pages or change selection")
    check(try Data(contentsOf: store.repository.workspaceURL) == bytes, "Guide rendering never rewrites the user's library index")
    check(!store.workspace.notes.contains { $0.id == ShowcaseCatalog.rootPageID }, "Guide display does not install the legacy example tree")

    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var corruptGuide = object["guide"] as! [String: Any]
    var sections = corruptGuide["sections"] as! [[String: Any]]
    sections.append(sections[0]); corruptGuide["sections"] = sections; object["guide"] = corruptGuide
    do {
        _ = try FeatureGuideCatalog.decode(JSONSerialization.data(withJSONObject: object))
        preconditionFailure("Duplicate guide category was accepted")
    } catch ShowcaseCatalog.ContentError.invalid { check(true, "Invalid bundled guide structure is rejected") }
    print("PASS: \(count) feature guide coverage, search, one-time presentation and native layout assertions")
    return count
}
