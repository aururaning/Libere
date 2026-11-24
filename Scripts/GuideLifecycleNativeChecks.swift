import Foundation
import SwiftUI

@MainActor func runGuideLifecycleNativeChecks() async throws -> Int {
    _ = NSApplication.shared
    var count = 0
    func check(_ value: Bool, _ label: String) {
        if !value { FileHandle.standardError.write(Data(("FAILED guide lifecycle: " + label + "\n").utf8)) }
        precondition(value, label); count += 1
    }
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("LibereGuideLifecycle-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let suite = "LibereGuideLifecycle." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let agentEnabled = UserDefaults.standard.object(forKey: "LibereAgentEnabled")
    UserDefaults.standard.set(false, forKey: "LibereAgentEnabled")
    defer {
        if let agentEnabled { UserDefaults.standard.set(agentEnabled, forKey: "LibereAgentEnabled") }
        else { UserDefaults.standard.removeObject(forKey: "LibereAgentEnabled") }
    }
    func settle(_ bootstrap: Bootstrap) async throws {
        for _ in 0..<400 {
            if !bootstrap.isLoading { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        preconditionFailure("Guide lifecycle fixture did not finish loading")
    }
    let root = base.appendingPathComponent("first-library")
    let first = Bootstrap(restoreOnInit: false, guideDefaults: defaults)
    first.open(root, remember: false); try await settle(first)
    defer { first.agent?.stop() }
    check(first.error == nil && first.store?.isNewLibrary == true && first.showingGuideTip && !first.showingGuide,
          "The first newly created library points to help with an overlay instead of opening a modal guide")
    check(first.store!.workspace.notes.count == 2 && !first.store!.workspace.notes.contains { $0.id == ShowcaseCatalog.rootPageID },
          "Automatic help does not insert the thirteen editable sample pages")
    first.dismissGuideTip()
    first.open(root, remember: false); try await settle(first)
    check(!first.showingGuide && !first.showingGuideTip, "Reopening the same library does not redisplay the guide or tip")
    // Opening the already active store explicitly flushes pending edits. Capture
    // the upgrade baseline after that save; JSON object key order is not a data
    // change, and must not be confused with tutorial reseeding during relaunch.
    let saved = try Data(contentsOf: root.appendingPathComponent("workspace.json"))
    let reopened = Bootstrap(restoreOnInit: false, guideDefaults: defaults)
    reopened.open(root, remember: false); try await settle(reopened)
    defer { reopened.agent?.stop() }
    check(reopened.error == nil && reopened.store?.isNewLibrary == false && !reopened.showingGuide && !reopened.showingGuideTip,
          "Replacing/relaunching the application keeps an existing library free of automatic help")
    check(try Data(contentsOf: root.appendingPathComponent("workspace.json")) == saved,
          "An ordinary update does not rewrite the library to install help content")

    let upgradeSuite = suite + ".upgrade", upgradeDefaults = UserDefaults(suiteName: upgradeSuite)!
    defer { upgradeDefaults.removePersistentDomain(forName: upgradeSuite) }
    let upgrade = Bootstrap(restoreOnInit: false, guideDefaults: upgradeDefaults)
    upgrade.open(root, remember: false); try await settle(upgrade)
    defer { upgrade.agent?.stop() }
    check(!upgrade.showingGuide && !upgrade.showingGuideTip && upgradeDefaults.bool(forKey: GuidePresentation.automaticPresentationKey),
          "A legacy installation without the new preference is treated as an upgrade, never another first run")
    upgrade.showingGuideTip = true
    upgrade.presentGuide()
    check(upgrade.showingGuide && !upgrade.showingGuideTip && upgrade.store!.workspace.notes.count == 2,
          "The manual help entry remains available without seeding pages")
    upgrade.showingGuide = false
    upgrade.open(base.appendingPathComponent("second-library"), remember: false); try await settle(upgrade)
    check(upgrade.store?.isNewLibrary == true && !upgrade.showingGuide && !upgrade.showingGuideTip,
          "Creating another library after onboarding does not repeat the guide")
    print("PASS: \(count) first-use, upgrade and manual-guide lifecycle assertions")
    return count
}
