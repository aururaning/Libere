import Foundation
#if SWIFT_PACKAGE
import MarginCore
#endif

/// Read-only help lives in the application bundle, never in the user's library.
struct FeatureGuideCatalog: Decodable, Sendable {
    struct Topic: Decodable, Identifiable, Sendable {
        let id: String
        let title: String
        let summary: String
        let steps: [String]
        let shortcuts: [String]
        let keywords: [String]
        let note: String?
        fileprivate var searchableText: String { ([title, summary] + steps + shortcuts + keywords + [note ?? ""]).joined(separator: " ") }
    }
    struct Section: Decodable, Identifiable, Sendable {
        let id: String
        let title: String
        let symbol: String
        let summary: String
        var topics: [Topic]
    }
    private struct Envelope: Decodable { let guide: FeatureGuideCatalog }
    let version: Int
    let title: String
    let subtitle: String
    let sections: [Section]
    var topicCount: Int { sections.reduce(0) { $0 + $1.topics.count } }

    static func load() throws -> Self {
        guard let url = AppBrand.resources.url(forResource: "Showcase", withExtension: "json") else { throw ShowcaseCatalog.ContentError.missing }
        return try decode(Data(contentsOf: url))
    }
    static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Envelope.self, from: data).guide
        try value.validate(); return value
    }
    func validate() throws {
        let topics = sections.flatMap(\.topics)
        guard version == 1, !title.isEmpty, !subtitle.isEmpty, !sections.isEmpty,
              Set(sections.map(\.id)).count == sections.count,
              Set(topics.map(\.id)).count == topics.count,
              sections.allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty && !$0.symbol.isEmpty && !$0.summary.isEmpty && !$0.topics.isEmpty }),
              topics.allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty && !$0.summary.isEmpty && !$0.steps.isEmpty && $0.steps.allSatisfy { !$0.isEmpty } }) else {
            throw ShowcaseCatalog.ContentError.invalid
        }
    }
    func matchingSections(query: String) -> [Section] {
        let terms = query.split(whereSeparator: \.isWhitespace).map { Self.fold(String($0)) }
        guard !terms.isEmpty else { return sections }
        return sections.compactMap { section in
            var result = section
            let context = section.title + " " + section.summary
            result.topics = section.topics.filter { topic in
                let haystack = Self.fold(context + " " + topic.searchableText)
                return terms.allSatisfy(haystack.contains)
            }
            return result.topics.isEmpty ? nil : result
        }
    }
    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
    }
}

enum GuidePresentation {
    // Deliberately independent of app/guide version: replacing the application
    // must never turn an ordinary upgrade into another first-run presentation.
    static let automaticPresentationKey = "LibereFeatureGuideAutomaticPresentationConsumed"
    static func consumeAutomaticPresentation(isNewLibrary: Bool, defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: automaticPresentationKey) else { return false }
        defaults.set(true, forKey: automaticPresentationKey)
        // Existing libraries also consume the marker, without showing help or
        // inserting any tutorial pages, including upgrades from older builds.
        return isNewLibrary
    }
}

struct ShowcaseCatalog: Decodable {
    struct Scenario: Decodable, Identifiable {
        let id: String
        let pageID: UUID
        let title: String
        let subtitle: String
        let symbol: String
        let detail: String
        let step: String
        let children: [UUID]
        var pages: [UUID] { [pageID] + children }
    }
    static let rootPageID = UUID(uuidString: "462189CA-E72B-5435-89F8-10CA53835958")!
    let version: Int
    let rootID: UUID
    let scenarios: [Scenario]
    let backup: BackupPayload

    enum ContentError: LocalizedError {
        case missing, invalid, collision
        var errorDescription: String? {
            switch self {
            case .missing: return "没有找到场景展示素材，请重新打开完整的 Libere 应用。"
            case .invalid: return "场景展示素材校验失败，已有笔记保持原样。"
            case .collision: return "已有同标识的示例内容，未覆盖现有页面。"
            }
        }
    }
    static func load() throws -> Self {
        guard let url = AppBrand.resources.url(forResource: "Showcase", withExtension: "json") else { throw ContentError.missing }
        let catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try catalog.validate()
        return catalog
    }
    func scenario(containing pageID: UUID) -> Scenario? { scenarios.first { $0.pages.contains(pageID) } }
    func validate() throws {
        let notes = backup.workspace.notes, ids = Set(notes.map(\.id))
        guard version == 1, (1...2).contains(backup.format), (1...3).contains(backup.workspace.schemaVersion),
              rootID == Self.rootPageID, ids.count == notes.count,
              notes.contains(where: { $0.id == rootID && $0.isFolder && $0.parentID == nil }),
              backup.workspace.descendants(rootID) == ids,
              Set(scenarios.map(\.id)).count == scenarios.count,
              scenarios.allSatisfy({ scene in
                  notes.contains(where: { $0.id == scene.pageID && $0.parentID == rootID && !$0.isFolder })
                      && scene.children.allSatisfy { id in notes.contains { $0.id == id && $0.parentID == scene.pageID } }
              }) else { throw ContentError.invalid }
        let blocks = notes.flatMap(\.blocks)
        guard Set(blocks.map(\.id)).count == blocks.count else { throw ContentError.invalid }
        for block in blocks {
            for id in block.referencedAssets where backup.assets[id.uuidString] == nil { throw ContentError.invalid }
            if let id = block.assetID, let bytes = backup.assets[id.uuidString] {
                guard block.assetSHA256 == AssetFingerprint.sha256(bytes), block.assetByteCount == Int64(bytes.count) else { throw ContentError.invalid }
            }
            if let reference = block.reference {
                guard notes.first(where: { $0.id == reference.noteID })?.blocks.contains(where: { $0.id == reference.blockID }) == true else { throw ContentError.invalid }
            }
        }
    }
}

@MainActor extension AppStore {
    /// Install once per library. Edited, moved or trashed examples are never reseeded.
    /// Assets are staged first; only a durable workspace commit publishes new pages.
    @discardableResult func installShowcaseIfNeeded(catalog supplied: ShowcaseCatalog? = nil) throws -> Bool {
        let catalog = try supplied ?? showcaseCatalog ?? ShowcaseCatalog.load()
        try catalog.validate()
        showcaseCatalog = catalog
        if workspace.purgedPageIDs.contains(catalog.rootID) { return false }
        if workspace.notes.contains(where: { $0.id == catalog.rootID }) { return false }
        let incoming = Set(catalog.backup.workspace.notes.map(\.id))
        guard incoming.isDisjoint(with: workspace.notes.map(\.id)) else { throw ShowcaseCatalog.ContentError.collision }
        // Examples contain only page metadata. Users add their own files explicitly.
        try commitShowcase(catalog)
        return true
    }
    func openShowcase() {
        do {
            try installShowcaseIfNeeded()
            let id = ShowcaseCatalog.rootPageID
            if workspace.notes.first(where: { $0.id == id })?.deleted == true { recover(id) }
            select(id); search = ""; expandedPages.insert(id)
        } catch { message = error.localizedDescription }
    }
}
