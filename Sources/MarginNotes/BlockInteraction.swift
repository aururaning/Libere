import SwiftUI
#if SWIFT_PACKAGE
import MarginCore
#endif

@MainActor extension AppStore {
    func canvasHit(at point: CGPoint) -> CanvasHitTarget {
        guard let note else { return .outside }
        return CanvasHitTesting.target(x: point.x, y: point.y, in: note, selected: blockSelection,
            zoom: zoom, handleSize: BlockMoveHandle.hitSize, controls: tool == .select, anchors: tool != .ink)
    }
    func canBeginBlockDrag(_ id: UUID, at point: CGPoint, resizing: Bool) -> Bool {
        guard tool == .select, let block = note?.blocks.first(where: { $0.id == id }), !block.locked else { return false }
        switch canvasHit(at: point) {
        case .block(let target), .move(let target): return target == id && !resizing
        case .resize(let target): return target == id && resizing
        default: return false
        }
    }

    /// SwiftUI may offer taps close to a view to that view. Resolve the actual paper
    /// coordinate again so that proximity can never select or drag a different block.
    func tapCanvas(at point: CGPoint, count: Int = 1) {
        guard tool == .select || tool == .text else { return }
        switch canvasHit(at: point) {
        case .block(let id):
            if count > 1 { activateBlock(id) } else { selectBlock(id) }
        case .move(let id), .resize(let id): selectBlock(id)
        case .anchor(let id): if let anchor = note?.anchors.first(where: { $0.id == id }) { annotate(anchor) }
        case .paper:
            if tool == .text || (tool == .select && count > 1) { insert(.text, point: point) }
            else if tool == .select { clearBlockSelection() }
        case .outside: clearBlockSelection()
        }
    }

    func activateBlock(_ id: UUID) {
        guard let block = note?.blocks.first(where: { $0.id == id }) else { return }
        if block.collapsed == true { selectBlock(id); toggleCollapsed(id); return }
        switch block.kind {
        case .formula: selectBlock(id); formulaEditor = block
        case .pdf: selectBlock(id); openAttachment(block)
        case .file where AttachmentFormat(filename: block.assetName) == .image: selectBlock(id); openAttachment(block)
        case .file where AttachmentFormat(filename: block.assetName) == nil: selectBlock(id); openAttachment(block)
        default: beginBlockEditing(id)
        }
    }

    func openAttachment(_ block: Block, page: Int? = nil, fullScreen: Bool = false) {
        guard let note, let current = note.blocks.first(where: { $0.id == block.id }),
              let url = attachmentURL(for: current) else { return }
        finishBlockEditing()
        #if os(macOS)
        if current.kind == .file, AttachmentFormat(filename: current.assetName) == nil {
            do { try iCloudFiles.requireLocal(url); NSWorkspace.shared.open(url) }
            catch { message = error.localizedDescription }
            return
        }
        PDFWindow.shared.open(store: self, noteID: note.id, block: current, page: page, fullScreen: fullScreen)
        #else
        readerInitialPage = page; readerBlock = current
        #endif
    }
    /// Only one content editor owns the keyboard. Commit before changing its page or selection.
    func finishBlockEditing() {
        guard !endingBlockEditing, editingBlockID != nil || formatting.view != nil else { return }
        endingBlockEditing = true
        #if os(macOS)
        let text = formatting.view ?? (NSApp?.keyWindow?.firstResponder as? NSTextView)
        text?.unmarkText()
        formatting.didChange?()
        (text?.window ?? NSApp?.keyWindow)?.makeFirstResponder(nil)
        #else
        formatting.view?.unmarkText()
        formatting.didChange?()
        (currentTextResponder as? UIView)?.window?.endEditing(true)
        #endif
        editingBlockID = nil; blockKeyboardFocus = false; formatting.clear()
        saveEditors()
        endingBlockEditing = false
    }

    func beginBlockEditing(_ id: UUID) {
        interactingBlockID = nil
        multiSelection.selectOnly(id)
        guard !endingBlockEditing, let block = note?.blocks.first(where: { $0.id == id }) else { return }
        // Images share the file attachment model but never enter a source editor.
        guard block.kind != .file || AttachmentFormat(filename: block.assetName) != .image else { selectBlock(id); return }
        if editingBlockID != id { finishBlockEditing() }
        if draggingBlockID != id { draggingBlockID = nil }
        tool = .select; blockSelection = id; editingBlockID = id
        blockKeyboardFocus = false; sidebarHasFocus = false
    }

    func selectBlock(_ id: UUID, keyboard: Bool = true) {
        interactingBlockID = nil
        multiSelection.selectOnly(id)
        guard note?.blocks.contains(where: { $0.id == id }) == true else { return }
        finishBlockEditing()
        if draggingBlockID != id { draggingBlockID = nil }
        tool = .select; blockSelection = id; sidebarHasFocus = false
        blockKeyboardFocus = keyboard
        if keyboard { keyboardFocusRequest = UUID() }
        formatting.clear()
    }

    func clearBlockSelection() {
        interactingBlockID = nil
        multiSelection.clear()
        canvasPointer.cancel()
        finishBlockEditing()
        draggingBlockID = nil
        blockSelection = nil; blockKeyboardFocus = false; sidebarHasFocus = false
        tool = .select; formatting.clear()
    }

    @discardableResult func beginBlockDrag(_ id: UUID, at point: CGPoint? = nil, resizing: Bool = false) -> Bool {
        guard tool == .select, let block = note?.blocks.first(where: { $0.id == id }), !block.locked else { return false }
        if let point, !canBeginBlockDrag(id, at: point, resizing: resizing) { return false }
        guard draggingBlockID != id else { return true }
        if editingBlockID == id {
            // The external handle can move a live editor without destroying its selection,
            // composing text, native undo manager or first responder.
            blockKeyboardFocus = false; sidebarHasFocus = false
        } else { selectBlock(id, keyboard: false) }
        draggingBlockID = id
        return true
    }

    func finishBlockDrag(_ id: UUID) {
        guard draggingBlockID == id else { return }
        draggingBlockID = nil
        if editingBlockID != id { selectBlock(id) }
    }

    func cancelBlockDrag(_ id: UUID) {
        guard draggingBlockID == id else { return }
        draggingBlockID = nil
        if blockSelection == id && editingBlockID == nil {
            blockKeyboardFocus = true; keyboardFocusRequest = UUID()
        }
    }

    /// Default annotation action: create the point and its text together in the nearest free space.
    func addAnnotation(to id: UUID) {
        finishBlockEditing()
        guard let note, let owner = note.blocks.first(where: { $0.id == id }) else { return }
        let anchor = AnnotationAnchor(ownerID: id,
            label: "批注 \(note.anchors.filter { $0.ownerID == id }.count + 1)",
            u: 1 + 24 / owner.frame.width, v: 0, edge: .leading)
        // annotate() records one checkpoint including both the new point and the text.
        annotate(anchor)
    }

    /// Async layout reports must still describe this exact text and width, not an old preview.
    func growTextBlock(_ measured: Block, contentHeight: Double) {
        guard contentHeight.isFinite, contentHeight > 0, contentHeight < 1_000_000,
              draggingBlockID != measured.id, canvasPointer.pressedBlockID != measured.id, let note,
              let current = note.blocks.first(where: { $0.id == measured.id }),
              current.kind == .text, !current.locked,
              current.text == measured.text, current.rtf == measured.rtf,
              current.fontSize == measured.fontSize, current.fontFamily == measured.fontFamily,
              abs(current.frame.width - measured.frame.width) < 0.5 else { return }
        var height = ceil(contentHeight + 30) // The compact edit/preview control.
        if !note.paper.isContinuous { height = min(height, note.paper.height - CanvasLayout.margin - current.frame.y) }
        guard height > current.frame.height + 1 else { return }
        edit { page in
            guard let index = page.blocks.firstIndex(where: { $0.id == current.id }) else { return }
            page.blocks[index].frame.height = height
            // Growing text is not a layout operation: keep other blocks, anchors and ink still.
            for i in page.anchors.indices where page.anchors[i].ownerID == current.id {
                page.anchors[i].v *= current.frame.height / height
            }
        }
        continueFontPanelLayout(blockID: current.id, previousRevision: note.revision)
    }
}

#if os(macOS)
/// Native text views do not resign when clicking non-focusable SwiftUI backgrounds.
/// Observe the containing block, without swallowing the click intended for another control.
@MainActor final class BlockFocusRegion: NSView {
    weak var store: AppStore?
    var blockID: UUID?
    var moveHandleRect: CGRect?
    private var monitor: Any?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
            return event
        }
    }
    func observe(_ event: NSEvent) {
        observeClick(at: event.locationInWindow, in: event.window)
    }
    func observeClick(at point: NSPoint, in eventWindow: NSWindow?) {
        guard let store, store.editingBlockID == blockID, eventWindow === window else { return }
        let local = convert(point, from: nil)
        guard !bounds.contains(local), moveHandleRect?.contains(local) != true else { return }
        store.finishBlockEditing()
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
@MainActor struct BlockFocusBoundary: NSViewRepresentable {
    let store: AppStore
    let blockID: UUID
    var moveHandleOffset: CGSize? = nil
    func makeNSView(context: Context) -> BlockFocusRegion { BlockFocusRegion() }
    func updateNSView(_ view: BlockFocusRegion, context: Context) {
        view.store = store; view.blockID = blockID
        view.moveHandleRect = moveHandleOffset.map {
            CGRect(x: $0.width, y: $0.height, width: BlockMoveHandle.hitSize, height: BlockMoveHandle.hitSize)
        }
    }
}
#else
struct BlockFocusBoundary: View {
    let store: AppStore
    let blockID: UUID
    var moveHandleOffset: CGSize? = nil
    var body: some View { Color.clear.allowsHitTesting(false) }
}
#endif
