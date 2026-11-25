import Foundation

/// Copies page records and their complete live subtree. Indexed originals keep
/// their file identity and path; no file bytes belong in this clipboard payload.
public struct PageClipboard: Codable, Sendable {
    public var format = 1
    public let library: String
    public let rootID: UUID
    public let pages: [Note]

    public enum ClipboardError: LocalizedError {
        case missing, invalid, recursiveDestination
        public var errorDescription: String? {
            switch self {
            case .missing: return "原页面或文件夹已移除，请重新复制。"
            case .invalid: return "剪贴板中的页面结构不完整，请重新复制。"
            case .recursiveDestination: return "不能把页面或文件夹粘贴到它自身或它的子项中。"
            }
        }
    }
    public init(library: String, rootID: UUID, workspace: Workspace) throws {
        guard let root = workspace.notes.first(where: { $0.id == rootID && !$0.deleted }) else { throw ClipboardError.missing }
        self.library = library; self.rootID = rootID
        let children = Dictionary(grouping: workspace.notes.filter { !$0.deleted }, by: \.parentID)
        var result: [Note] = [], pending = [root], visited: Set<UUID> = []
        while let page = pending.popLast() {
            guard visited.insert(page.id).inserted else { continue }
            result.append(page)
            pending += (children[page.id] ?? []).sorted(by: Workspace.sidebarLess).reversed()
        }
        pages = result
    }
    public func copies(into parent: UUID?, in workspace: Workspace) throws -> [Note] {
        let ids = Set(pages.map(\.id))
        guard format == 1, !pages.isEmpty, ids.count == pages.count, pages.first?.id == rootID,
              pages.allSatisfy({ !$0.deleted && ($0.id == rootID || $0.parentID.map(ids.contains) == true) }),
              parent == nil || workspace.notes.contains(where: { $0.id == parent && !$0.deleted }) else { throw ClipboardError.invalid }
        guard parent.map(ids.contains) != true else { throw ClipboardError.recursiveDestination }
        let children = Dictionary(grouping: pages.dropFirst(), by: \.parentID)
        var ordered: [Note] = [], pending = [pages[0]], seen: Set<UUID> = []
        while let page = pending.popLast() {
            guard seen.insert(page.id).inserted else { throw ClipboardError.invalid }
            ordered.append(page); pending += (children[page.id] ?? []).sorted(by: Workspace.sidebarLess).reversed()
        }
        guard seen == ids else { throw ClipboardError.invalid }
        let pageIDs = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, UUID()) })
        let liveFiles = Dictionary(workspace.notes.filter { !$0.deleted }.flatMap(\.blocks).filter(\.isFilePlugin)
            .map { ($0.fileIdentity, $0) }, uniquingKeysWith: { a, _ in a })
        func links(_ text: String) -> String {
            pageIDs.reduce(text) { result, pair in
                result.replacingOccurrences(of: PageLink.url(for: pair.key).absoluteString,
                                            with: PageLink.url(for: pair.value).absoluteString, options: .caseInsensitive)
            }
        }
        let names = Set(workspace.children(parent).map { WorkspaceDirectories.safeName($0.title).lowercased() })
        let originalTitle = ordered[0].title
        var title = originalTitle, suffix = 1
        while names.contains(WorkspaceDirectories.safeName(title).lowercased()) {
            title = originalTitle + (suffix == 1 ? " 副本" : " 副本 \(suffix)"); suffix += 1
        }
        return ordered.map { original in
            var page = original
            page.id = pageIDs[original.id]!
            page.parentID = original.id == rootID ? parent : original.parentID.flatMap { pageIDs[$0] }
            page.sourceNoteID = original.sourceNoteID ?? original.id
            page.managedFilePath = nil; page.managedDirectoryPath = nil
            page.deleted = false; page.deletedAt = nil; page.trashBatchID = nil
            page.originalParentPath = nil; page.permanentlyDeleted = nil; page.conflictOf = nil
            page.version = VersionVector(); page.revision = UUID(); page.modifiedAt = Date()
            if original.id == rootID {
                page.title = title
                let last = workspace.children(parent).compactMap(\.sidebarOrder).max() ?? -1
                page.sidebarOrder = last < Int.max ? last + 1 : last
            }
            page.folderOverview = original.folderOverview.map(links)
            let blockIDs = Dictionary(original.blocks.map { ($0.id, UUID()) }, uniquingKeysWith: { a, _ in a })
            let anchorIDs = Dictionary(original.anchors.map { ($0.id, UUID()) }, uniquingKeysWith: { a, _ in a })
            page.blocks = original.blocks.map { source in
                var block = source
                if source.isFilePlugin {
                    let current = liveFiles[source.fileIdentity] ?? source
                    block.fileID = source.fileIdentity; block.relativeFilePath = current.relativeFilePath
                    block.assetName = current.assetName; block.contentRevision = current.contentRevision
                }
                block.id = blockIDs[source.id]!
                block.reference = source.reference ?? FileReference(noteID: original.id, blockID: source.id)
                block.anchorID = source.anchorID.flatMap { anchorIDs[$0] }
                block.text = links(block.text); block.linkURL = block.linkURL.map(links)
                if var annotations = block.pageAnnotations {
                    for key in Array(annotations.keys) {
                        for i in annotations[key]!.texts.indices {
                            annotations[key]!.texts[i].id = UUID()
                            annotations[key]!.texts[i].text = links(annotations[key]!.texts[i].text)
                        }
                    }
                    block.pageAnnotations = annotations
                }
                return block
            }
            page.anchors = original.anchors.compactMap { anchor in
                guard let owner = blockIDs[anchor.ownerID] else { return nil }
                var copy = anchor; copy.id = anchorIDs[anchor.id]!; copy.ownerID = owner; return copy
            }
            return page
        }
    }
}
