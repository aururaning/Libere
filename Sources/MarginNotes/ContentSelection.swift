import SwiftUI
#if SWIFT_PACKAGE
import MarginCore
#endif
#if os(macOS)
import WebKit
@MainActor extension AppStore {
    func selectAllFocused(in targetWindow: NSWindow? = nil) {
        guard let window = targetWindow ?? NSApp.keyWindow else { return }
        if let text = window.firstResponder as? NSTextView {
            text.selectAll(nil); return
        }
        var responder = window.firstResponder as? NSView
        while let view = responder {
            if view is WKWebView { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: window.firstResponder, from: nil); return }
            responder = view.superview
        }
        guard !sidebarHasFocus, let pageID = selection, let block,
              block.kind == .text || (block.kind == .file && AttachmentFormat(filename: block.assetName)?.isTextEditable == true) else { return }
        if block.collapsed == true { toggleCollapsed(block.id) }
        beginBlockEditing(block.id)
        Task { @MainActor [weak self, weak window] in
            for _ in 0..<60 {
                guard let self, let window, self.selection == pageID, self.blockSelection == block.id,
                      self.editingBlockID == block.id, let root = window.contentView else { return }
                root.layoutSubtreeIfNeeded()
                if let scope = SelectionWheel.scope(block.id, in: root), let text = Self.editableText(in: scope) {
                    // Do not take focus back from another input chosen during loading.
                    if let active = window.firstResponder as? NSTextView, active !== text { return }
                    window.makeFirstResponder(text); text.selectAll(nil); return
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }
    private static func editableText(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.isEditable, !text.isHiddenOrHasHiddenAncestor { return text }
        for child in view.subviews { if let text = editableText(in: child) { return text } }
        return nil
    }
}
#else
@MainActor extension AppStore {
    func selectAllFocused() {
        if let responder = currentTextResponder { UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.selectAll(_:)), to: responder, from: nil, for: nil) }
    }
}
#endif
