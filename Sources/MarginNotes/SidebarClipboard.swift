import SwiftUI
#if SWIFT_PACKAGE
import MarginCore
#endif

@MainActor extension AppStore {
    static var pageClipboardType: String { "app.libere.sidebar-pages" }
    var clipboardLibraryID: String { repository.root.standardizedFileURL.resolvingSymlinksInPath().path }
    func pageClipboardData(_ id: UUID) throws -> Data {
        finishBlockEditing()
        guard saveEditors() else { throw CocoaError(.fileWriteUnknown) }
        return try JSONEncoder().encode(PageClipboard(library: clipboardLibraryID, rootID: id, workspace: workspace))
    }
    @discardableResult func pastePageClipboard(_ data: Data, into parent: UUID?, move: Bool = false) -> Bool {
        do {
            let payload = try JSONDecoder().decode(PageClipboard.self, from: data)
            guard payload.format == 1, payload.library == clipboardLibraryID else { throw FileIndexError.outsideLibrary }
            guard !clipboardMoves.isBusy else { message = "正在移动文件，请完成后再整理页面。"; return false }
            #if os(macOS)
            guard PDFWindow.shared.prepareReaders(store: self) else { return false }
            #endif
            if move {
                guard workspace.notes.contains(where: { $0.id == payload.rootID && !$0.deleted }) else { throw PageClipboard.ClipboardError.missing }
                guard workspace.canPlace(payload.rootID, at: .inside(parent)) else { throw PageClipboard.ClipboardError.recursiveDestination }
                return placePage(payload.rootID, at: .inside(parent))
            }
            var copies = try payload.copies(into: parent, in: workspace)
            var directoryBindings: [UUID: String] = [:]
            var base = repository.root
            if let parent, let target = workspace.notes.first(where: { $0.id == parent && !$0.deleted }) {
                let location = try clipboardPastes.archiveLocation(for: target, hasCopies: true, store: self)
                base = location.url
                if let binding = location.binding { directoryBindings[parent] = binding }
            }
            var directories: [UUID: URL] = [:]
            for i in copies.indices {
                let owner = copies[i].parentID.flatMap { directories[$0] } ?? base
                let url = owner.appendingPathComponent(WorkspaceDirectories.safeName(copies[i].title) + "__" + copies[i].id.uuidString.prefix(8), isDirectory: true)
                guard let path = ReferencePath.relative(url, inside: repository.root),
                      !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
                copies[i].managedDirectoryPath = path; directories[copies[i].id] = url
            }
            // These are new, empty page directories. The indexed originals are
            // shared by path; copying a subtree never archives those files again.
            for page in copies { try FileManager.default.createDirectory(at: directories[page.id]!, withIntermediateDirectories: true) }
            try commitIndexedPages(copies, directoryBindings: directoryBindings, selectInserted: false)
            if let parent { expandedPages.insert(parent) }
            sidebarHasFocus = true
            return true
        } catch { message = error.localizedDescription; return false }
    }
    func revealPageSource(_ id: UUID) {
        guard let source = workspace.notes.first(where: { $0.id == id })?.sourceNoteID,
              workspace.notes.contains(where: { $0.id == source && !$0.deleted }) else {
            message = "原页面已移入回收站或删除。"; return
        }
        select(source)
    }
    #if os(macOS)
    @discardableResult func copyPage(_ id: UUID, pasteboard: NSPasteboard = .general) -> Bool {
        do {
            let data = try pageClipboardData(id)
            pasteboard.clearContents(); pasteboard.setData(data, forType: .init(Self.pageClipboardType))
            pasteboard.setString(workspace.notes.first { $0.id == id }?.title ?? "", forType: .string)
            return true
        } catch { message = error.localizedDescription; return false }
    }
    func isLibraryClipboardWindow(_ window: NSWindow?) -> Bool {
        guard let window, window.attachedSheet == nil, !showTrash, let root = window.contentView else { return false }
        var pending = [root]
        while let view = pending.popLast() {
            if let scope = view as? LibraryPasteOwnerView, scope.store === self, !scope.isHiddenOrHasHiddenAncestor { return true }
            pending += view.subviews
        }
        return false
    }
    @discardableResult func pastePagesFocused(in window: NSWindow?, pasteboard: NSPasteboard = .general, move: Bool = false) -> Bool {
        guard isLibraryClipboardWindow(window), let data = pasteboard.data(forType: .init(Self.pageClipboardType)) else { return false }
        guard commitTitleEditing(in: window) else { return true }
        var parent = sidebarRootSelected ? nil : selection
        if !move, let payload = try? JSONDecoder().decode(PageClipboard.self, from: data), parent == payload.rootID {
            parent = workspace.notes.first { $0.id == payload.rootID }?.parentID
        }
        let version = pasteboard.changeCount
        if pastePageClipboard(data, into: parent, move: move), pasteboard.changeCount == version,
           let original = try? JSONDecoder().decode(PageClipboard.self, from: data), move {
            _ = copyPage(original.rootID, pasteboard: pasteboard)
        }
        return true
    }
    func pastePages(into parent: UUID?, move: Bool = false, pasteboard: NSPasteboard = .general) {
        guard let data = pasteboard.data(forType: .init(Self.pageClipboardType)) else { return }
        if pastePageClipboard(data, into: parent, move: move),
           let original = try? JSONDecoder().decode(PageClipboard.self, from: data), move {
            _ = copyPage(original.rootID, pasteboard: pasteboard)
        }
    }
    #else
    @discardableResult func copyPage(_ id: UUID) -> Bool {
        do { UIPasteboard.general.setItems([[Self.pageClipboardType: try pageClipboardData(id)]]); return true }
        catch { message = error.localizedDescription; return false }
    }
    func pastePages(into parent: UUID?, move: Bool = false) {
        guard let data = UIPasteboard.general.data(forPasteboardType: Self.pageClipboardType) else { return }
        _ = pastePageClipboard(data, into: parent, move: move)
    }
    #endif
}
