import Foundation

public enum PaperKind: String, Codable, CaseIterable, Sendable {
    case a4, landscape, continuous, wideContinuous
    public var title: String { switch self { case .a4: return "A4"; case .landscape: return "横向画布"; case .continuous: return "纵向长页"; case .wideContinuous: return "宽幅长页" } }
    public var width: Double { self == .landscape || self == .wideContinuous ? 1123 : 794 }
    public var height: Double { width == 1123 ? 794 : 1123 }
    public var isContinuous: Bool { self == .continuous || self == .wideContinuous }
}
public struct Rect: Codable, Equatable, Sendable {
    public var x: Double; public var y: Double; public var width: Double; public var height: Double
    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var maxX: Double { x + width }; public var maxY: Double { y + height }
    public func intersects(_ r: Rect, gap: Double = 0) -> Bool { x < r.maxX + gap && maxX + gap > r.x && y < r.maxY + gap && maxY + gap > r.y }
}
public enum BlockKind: String, Codable, Sendable {
    case text, formula, pdf, file, link
    public var hasAttachment: Bool { self == .pdf || self == .file }
}
public enum TextFormat: String, Codable, Sendable { case richText, markdown }
public enum LinkDisplayMode: String, Codable, CaseIterable, Sendable {
    case card, html, browser
    public var title: String { switch self { case .card: return "链接卡片"; case .html: return "HTML 页面"; case .browser: return "内嵌浏览器" } }
}
public struct FileReference: Codable, Equatable, Sendable {
    public var noteID: UUID
    public var blockID: UUID
    public init(noteID: UUID, blockID: UUID) { self.noteID = noteID; self.blockID = blockID }
}
public struct Block: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var kind: BlockKind
    public var frame: Rect
    public var text: String
    public var rtf: Data?
    // Optional fields keep existing version-1 documents readable.
    public var textFormat: TextFormat?
    public var fontFamily: String?
    public var usesMarkdown: Bool { textFormat == .markdown }
    public var fontSize = 22.0
    public var quote = false
    public var tint = "paper"
    public var locked = false
    public var anchorID: UUID?
    public var assetID: UUID?
    public var assetSHA256: String?
    public var assetByteCount: Int64?
    /// Legacy identifiers are read only for migration; new files use relativeFilePath.
    public var notebookAssetID: UUID?
    public var workingAssetID: UUID?
    public var displayAssetID: UUID? { workingAssetID ?? notebookAssetID ?? assetID }
    public var referencedAssets: [UUID] { Array(Set([assetID, notebookAssetID, workingAssetID].compactMap { $0 })) }
    public var collapsed: Bool?
    public var expandedHeight: Double?
    public var linkURL: String?
    public var sourceURL: String?
    public var linkMode: LinkDisplayMode?
    public var linkHTMLBaseURL: String?
    public var linkEncoding: String?
    public var fileID: UUID?
    public var reference: FileReference?
    /// A file inside the selected library can be referenced directly, without copying its bytes.
    public var relativeFilePath: String?
    public var contentRevision: UUID?
    public var fileIdentity: UUID { fileID ?? assetID ?? id }
    public var isFilePlugin: Bool { kind.hasAttachment || kind == .link }
    public static let collapsedHeight = 36.0
    public var visibleFrame: Rect {
        Rect(frame.x, frame.y, frame.width, isFilePlugin && collapsed == true ? Self.collapsedHeight : frame.height)
    }
    public var assetName = ""
    public var pdfPage = 0
    /// Separate from Note.ink and Note.anchors. Keys are zero-based attachment pages.
    public var pageAnnotations: [String: AttachmentPageAnnotations]?
    public func annotations(on page: Int) -> AttachmentPageAnnotations {
        pageAnnotations?[String(page)] ?? AttachmentPageAnnotations()
    }
    public init(_ kind: BlockKind, frame: Rect, text: String = "") {
        self.kind = kind; self.frame = frame; self.text = text
        self.textFormat = kind == .text ? .markdown : nil
    }
}
public struct PageTextAnnotation: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var frame: Rect
    public var text: String
    public var fontSize: Double?
    public var fontFamily: String?
    public init(frame: Rect, text: String = "") { self.frame = frame; self.text = text }
}
public struct AttachmentPageAnnotations: Codable, Equatable, Sendable {
    public var ink: Data?
    public var inkBounds: Rect?
    public var texts: [PageTextAnnotation] = []
    public init() {}
}
public enum AnchorEdge: String, Codable, CaseIterable, Sendable {
    case leading, trailing
    public var title: String { self == .leading ? "文字左侧对齐" : "文字右侧对齐" }
}
public struct AnnotationAnchor: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var ownerID: UUID
    public var label: String
    /// Coordinates relative to the owner block, including positions outside its frame.
    public var u: Double; public var v: Double
    public var edge: AnchorEdge
    public init(ownerID: UUID, label: String, u: Double, v: Double, edge: AnchorEdge = .leading) {
        self.ownerID = ownerID; self.label = label; self.u = u; self.v = v; self.edge = edge
    }
}
public struct VersionVector: Codable, Equatable, Sendable {
    public var counters: [String: Int]
    public init(_ counters: [String: Int] = [:]) { self.counters = counters }
    public mutating func tick(_ device: String) { counters[device, default: 0] += 1 }
    public func includes(_ other: Self) -> Bool { other.counters.allSatisfy { counters[$0.key, default: 0] >= $0.value } }
    public func joined(_ other: Self) -> Self {
        var result = self
        for (key, value) in other.counters { result.counters[key] = max(counters[key, default: 0], value) }
        return result
    }
}
public struct Note: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var parentID: UUID?
    public var sidebarOrder: Int?
    public var trashBatchID: UUID?
    public var title: String
    public var isFolder = false
    /// Editable folder introduction in Markdown. Nil keeps the default introduction;
    /// an empty string deliberately hides it. Optional for older notes and backups.
    public var folderOverview: String?
    /// Physical entries managed by this sidebar item. Cross-page file references
    /// do not acquire ownership of another page's source file.
    public var managedDirectoryPath: String?
    public var managedFilePath: String?
    public var paper = PaperKind.continuous
    /// Continuous canvases use document coordinates, independent of the current zoom.
    /// Optional dimensions preserve compatibility with existing notebooks and backups.
    public var canvasWidth: Double?
    public var canvasHeight: Double?
    public var blocks: [Block] = []
    public var anchors: [AnnotationAnchor] = []
    public var ink: Data?
    public var inkBounds: Rect?
    public var version = VersionVector()
    public var revision = UUID()
    public var modifiedAt = Date()
    public var deleted = false
    public var conflictOf: UUID?
    public init(title: String, parent: UUID? = nil, folder: Bool = false) { self.title = title; parentID = parent; isFolder = folder }
    public mutating func touch(_ device: String) { version.tick(device); revision = UUID(); modifiedAt = Date() }
    public var contentRight: Double {
        max(blocks.map(\.frame.maxX).max() ?? 0, inkBounds?.maxX ?? 0,
            anchors.compactMap { CanvasLayout.point($0, blocks: blocks).map { $0.x + 12 } }.max() ?? 0)
    }
    public var contentBottom: Double {
        max(blocks.map(\.frame.maxY).max() ?? 0, inkBounds?.maxY ?? 0,
            anchors.compactMap { CanvasLayout.point($0, blocks: blocks).map { $0.y + 12 } }.max() ?? 0)
    }
    public var width: Double {
        guard paper.isContinuous else { return paper.width }
        return max(320, canvasWidth ?? paper.width, contentRight)
    }
    public var height: Double {
        guard paper.isContinuous else { return paper.height }
        return CanvasExtent.expandedHeight(current: max(paper.height, canvasHeight ?? 0), contentBottom: contentBottom)
    }
    public mutating func extendCanvasForContent() {
        guard paper.isContinuous else { return }
        canvasHeight = height
        if let canvasWidth, contentRight > canvasWidth { self.canvasWidth = contentRight }
    }
    public mutating func fitCanvas(width viewportWidth: Double, height viewportHeight: Double) {
        guard paper.isContinuous, viewportWidth.isFinite, viewportHeight.isFinite,
              viewportWidth > 0, viewportHeight > 0 else { return }
        canvasWidth = max(320, viewportWidth, contentRight)
        canvasHeight = CanvasExtent.expandedHeight(current: max(height, viewportHeight), contentBottom: contentBottom)
    }
    public var summary: String {
        // Folder cards need a short excerpt, not a joined copy of every text block.
        var result = "", remaining = 120
        func append(_ text: String) {
            guard !text.isEmpty, remaining > 0 else { return }
            if !result.isEmpty { result.append(" "); remaining -= 1 }
            let prefix = text.prefix(remaining)
            result.append(contentsOf: prefix); remaining -= prefix.count
        }
        if isFolder, let folderOverview { append(folderOverview) }
        for block in blocks {
            if remaining == 0 { break }
            if block.kind == .text { append(block.text) }
        }
        return result
    }
}

public enum CanvasExtent {
    /// At two thirds, double the remaining blank space. No scroll offset is involved.
    /// Large pasted/moved content catches up in a few geometric steps, never pixel loops.
    public static func expandedHeight(current: Double, contentBottom: Double) -> Double {
        var height = current.isFinite ? max(1, current) : 1123
        guard contentBottom.isFinite, contentBottom > 0 else { return height }
        if contentBottom >= height { height = contentBottom + max(256, height / 3) }
        while contentBottom >= height * (2.0 / 3.0) {
            height = contentBottom + 2 * (height - contentBottom)
        }
        return ceil(height)
    }
}
public struct Workspace: Codable, Equatable, Sendable {
    public var schemaVersion = 2
    public var notes: [Note] = []
    /// Outbox is written atomically with notes, before enqueueing CloudKit operations.
    public var pending: Set<String> = []
    /// Durable bounded receipts make agent retries idempotent across app restarts.
    public var agentReceipts: [AgentReceipt]?
    public var fileMoveTransactionID: UUID?
    public init(notes: [Note] = []) { self.notes = notes }
    public func children(_ parent: UUID?) -> [Note] {
        notes.filter { !$0.deleted && $0.parentID == parent }.sorted(by:Self.sidebarLess)
    }
    public static func sidebarLess(_ a: Note, _ b: Note) -> Bool {
        if a.sidebarOrder != nil || b.sidebarOrder != nil, a.sidebarOrder != b.sidebarOrder { return (a.sidebarOrder ?? Int.max) < (b.sidebarOrder ?? Int.max) }
        return a.isFolder != b.isFolder ? a.isFolder : (a.modifiedAt == b.modifiedAt ? a.id.uuidString < b.id.uuidString : a.modifiedAt > b.modifiedAt)
    }
    public func descendants(_ id: UUID) -> Set<UUID> {
        var children: [UUID: [UUID]] = [:]
        children.reserveCapacity(notes.count)
        for note in notes {
            if let parent = note.parentID { children[parent, default: []].append(note.id) }
        }
        var found: Set<UUID> = [id]; var queue = [id]
        while let next = queue.popLast() {
            for child in children[next] ?? [] where found.insert(child).inserted { queue.append(child) }
        }
        return found
    }
    public func moveTargets(for id: UUID) -> [Note] {
        guard notes.contains(where: { $0.id == id && !$0.deleted }) else { return [] }
        let excluded = descendants(id)
        return notes.filter { !$0.deleted && !excluded.contains($0.id) }
    }
    public func canMove(_ id: UUID, to parent: UUID?) -> Bool {
        guard notes.contains(where: { $0.id == id && !$0.deleted }) else { return false }
        guard let parent else { return true }
        return notes.contains { $0.id == parent && !$0.deleted } && !descendants(id).contains(parent)
    }
}
