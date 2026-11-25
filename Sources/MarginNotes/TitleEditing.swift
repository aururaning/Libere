import SwiftUI

#if os(macOS)
/// Only title/name controls opt into this hand-off. Ordinary search fields and
/// document editors retain their native AppKit editing behavior.
@MainActor class CanvasTitleField: NSTextField {
    weak var titleOwner: AppStore?
    var titlePageID: UUID?
    var finishForCanvas: (() -> Bool)?
}

@MainActor enum CanvasTitleEditing {
    fileprivate static func owner(in window: NSWindow?, interaction: CanvasPointerInteraction?) -> AppStore? {
        guard let window, let interaction, let root = window.contentView else { return nil }
        var pending = [root]
        while let view = pending.popLast() {
            let store = (view as? CanvasKeyView)?.store ?? (view as? LibraryPasteOwnerView)?.store
            if let store, store.canvasPointer === interaction { return store }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }
    static func commit(in window: NSWindow?, interaction: CanvasPointerInteraction?) -> Bool {
        owner(in: window, interaction: interaction)?.commitTitleEditing(in: window) ?? true
    }
    static func claimKeyboard(in window: NSWindow?, interaction: CanvasPointerInteraction?) {
        owner(in: window, interaction: interaction)?.claimCanvasKeyboard(in: window)
    }
}

@MainActor extension AppStore {
    /// Finish the native field editor before a consumed canvas mouse-down can
    /// choose its next target. A delayed title commit must not clear that target.
    @discardableResult func commitTitleEditing(in targetWindow: NSWindow?) -> Bool {
        guard let window = targetWindow ?? NSApp.keyWindow,
              CanvasTitleEditing.owner(in: window, interaction: canvasPointer) === self else { return true }
        let editor = window.firstResponder as? NSTextView
        var title = editor?.isFieldEditor == true ? editor?.delegate as? CanvasTitleField : nil
        if title?.titleOwner !== self { title = nil }
        // A sidebar rename may still be waiting for its scheduled initial focus.
        // Finishing it now prevents that callback stealing focus after this click.
        if title == nil, let renaming, let root = window.contentView {
            var pending = [root]
            while let view = pending.popLast() {
                if let field = view as? RenameNameField, field.titleOwner === self, field.titlePageID == renaming {
                    title = field; break
                }
                pending.append(contentsOf: view.subviews)
            }
        }
        guard let field = title else { return true }
        let page = selection, selectedBlock = blockSelection, priorTool = tool
        guard field.finishForCanvas?() != false else {
            // Failed rename transactions leave the draft and its originals intact.
            let active = window.firstResponder as? NSTextView
            let stillEditing = active.map { ($0.delegate as AnyObject?) === field } ?? false
            if field.window === window, !stillEditing, window.firstResponder !== field { window.makeFirstResponder(field) }
            return false
        }
        // renamePage commits through a hierarchy transaction whose selection
        // restoration clears canvas chrome. Retain pre-click hit geometry until
        // this same mouse-down applies its paper/block selection below.
        if selection == page {
            if let selectedBlock, note?.blocks.contains(where: { $0.id == selectedBlock }) == true {
                blockSelection = selectedBlock
            }
            tool = priorTool
        }
        let wasThisField = editor.map { ($0.delegate as AnyObject?) === field } ?? false
        if (wasThisField && window.firstResponder === editor) || window.firstResponder === field {
            guard window.makeFirstResponder(nil) else { return false }
        }
        return true
    }

    /// The zero-size canvas key view owns keyboard commands after a blank-paper
    /// click too. A live block editor/drag handle must keep its own responder.
    func claimCanvasKeyboard(in targetWindow: NSWindow?) {
        guard editingBlockID == nil, let window = targetWindow ?? NSApp.keyWindow,
              let root = window.contentView else { return }
        var pending = [root]
        while let view = pending.popLast() {
            if let key = view as? CanvasKeyView, key.store === self, !key.isHiddenOrHasHiddenAncestor {
                sidebarHasFocus = false; blockKeyboardFocus = true; keyboardFocusRequest = UUID()
                window.makeFirstResponder(key)
                return
            }
            pending.append(contentsOf: view.subviews)
        }
    }
}
#endif
