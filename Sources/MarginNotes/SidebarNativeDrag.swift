import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers

private struct SidebarDragPayload: Codable {
    let library: String
    let pageID: UUID
}

/// A List can replace its native row while a published highlight changes.
/// AppKit's drag source therefore belongs to the store, not that temporary row.
@MainActor final class SidebarDragSession: NSObject, NSDraggingSource {
    private weak var store: AppStore?
    var pageID: UUID?
    init(store: AppStore) { self.store = store }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        store?.draggingPageID = pageID
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        store?.draggingPageID = nil; store?.pageDropPlacement = nil; pageID = nil
    }
}

/// The row owns the press and the AppKit drag session. SwiftUI List selection
/// and its nested gesture recognizers no longer compete to start the same drag.
@MainActor final class SidebarRowHost: NSView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    weak var store: AppStore?
    var pageID: UUID?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private static let pageType = NSPasteboard.PasteboardType(UTType.liberePage.identifier)
    private var library: String { store?.repository.root.standardizedFileURL.resolvingSymlinksInPath().path ?? "" }
    private var destination: PageDropDelegate? { store.map { PageDropDelegate(store: $0, target: pageID, height: bounds.height) } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        host.sizingOptions = []; addSubview(host)
        registerForDraggedTypes([Self.pageType, .fileURL])
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func layout() { super.layout(); host.frame = bounds }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(convert(point, from: superview)) else { return nil }
        let hit = super.hitTest(point)
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown,
              !event.modifierFlags.contains(.control) else { return hit }
        var current = hit
        while let view = current, view !== self {
            if view is NSControl || view is NSTextView { return hit }
            current = view.superview
        }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        guard let store, let window, store.commitTitleEditing(in: window) else { return }
        if let pageID {
            store.select(pageID)
            guard store.selection == pageID, store.renaming == nil else { return }
        }
        store.sidebarHasFocus = true; store.sidebarRootSelected = pageID == nil
        window.makeFirstResponder(self)
        guard let pageID else { return }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { return }
            guard hypot(next.locationInWindow.x-start.x, next.locationInWindow.y-start.y) >= 3 else { continue }
            let item = NSPasteboardItem()
            guard let data = try? JSONEncoder().encode(SidebarDragPayload(library: library, pageID: pageID)) else { return }
            item.setData(data, forType: Self.pageType)
            let dragging = NSDraggingItem(pasteboardWriter: item)
            let image = NSImage(size: bounds.size)
            image.lockFocus()
            let title = store.workspace.notes.first { $0.id == pageID }?.title ?? "页面"
            (title as NSString).draw(at: CGPoint(x: 8, y: 7), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
            image.unlockFocus()
            dragging.setDraggingFrame(bounds, contents: image)
            store.sidebarDragSession.pageID = pageID
            beginDraggingSession(with: [dragging], event: next, source: store.sidebarDragSession).animatesToStartingPositionsOnCancelOrFail = true
            return
        }
    }
    private func sourcePage(_ pasteboard: NSPasteboard) -> UUID? {
        guard let data = pasteboard.data(forType: Self.pageType),
              let value = try? JSONDecoder().decode(SidebarDragPayload.self, from: data), value.library == library else { return nil }
        return value.pageID
    }
    private func updateDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let store, let destination else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        if let id = sourcePage(sender.draggingPasteboard) {
            guard store.workspace.canPlace(id, at: destination.placement(at: point)) else { destination.clearOwnHighlight(); return [] }
            if store.draggingPageID != id { store.draggingPageID = id }
            let placement = destination.placement(at: point)
            if store.pageDropPlacement != placement { store.pageDropPlacement = placement }
            return .move
        }
        if pageID != nil, !CanvasPasteboardContents.fileURLs(from: sender.draggingPasteboard).isEmpty {
            if store.pageDropPlacement != .inside(pageID) { store.pageDropPlacement = .inside(pageID) }
            return .copy
        }
        destination.clearOwnHighlight(); return []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { destination?.clearOwnHighlight() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !updateDrop(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let store, let destination else { return false }
        defer { store.draggingPageID = nil; store.pageDropPlacement = nil }
        let success: Bool
        if let id = sourcePage(sender.draggingPasteboard) {
            success = store.placePage(id, at: destination.placement(at: convert(sender.draggingLocation, from: nil)))
        } else if let pageID {
            success = store.indexFileURLs(CanvasPasteboardContents.fileURLs(from: sender.draggingPasteboard), noteID: pageID)
        } else { return false }
        if success { store.sidebarHasFocus = true; store.sidebarRootSelected = false; window?.makeFirstResponder(self) }
        return success
    }
}

@MainActor struct SidebarNativeRow: NSViewRepresentable {
    let store: AppStore
    let pageID: UUID?
    let content: AnyView
    func makeNSView(context: Context) -> SidebarRowHost { SidebarRowHost(frame: .zero) }
    func updateNSView(_ view: SidebarRowHost, context: Context) {
        view.store = store; view.pageID = pageID
        view.host.rootView = AnyView(content.environment(\.controlActiveState, context.environment.controlActiveState)
            .environment(\.colorScheme, context.environment.colorScheme))
        view.host.frame = view.bounds
    }
}
#endif
