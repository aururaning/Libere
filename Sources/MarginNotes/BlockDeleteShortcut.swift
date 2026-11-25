import SwiftUI
#if SWIFT_PACKAGE
import MarginCore
#endif
#if os(macOS)
import WebKit

@MainActor extension AppStore {
    /// Command-Delete is a canvas action only when the current main canvas owns
    /// the selection. A preview button may own the native responder without
    /// taking away that selection; an actual text/input responder always wins.
    @discardableResult func handleBlockDeleteShortcut(_ event: NSEvent, in targetWindow: NSWindow?) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard event.type == .keyDown, [51, 117].contains(event.keyCode), modifiers == .command,
              let window = targetWindow, event.window == nil || event.window === window,
              isCanvasPasteWindow(window), let note, !note.isFolder,
              !sidebarHasFocus, renaming == nil, editingBlockID == nil,
              deletionRequest == nil, purgeRequest == nil, formulaEditor == nil,
              movingPageID == nil, !showingQuickSearch,
              !canvasPointer.isPressed, draggingBlockID == nil else { return false }
        // Includes title/search field editors and native source/Notebook inputs.
        // Even read-only text views retain their native selection semantics.
        if window.firstResponder is NSTextInputClient { return false }
        var responderView = window.firstResponder as? NSView
        while let view = responderView {
            // WebKit may contain a live HTML input that is not represented as an
            // NSTextView. Without a trustworthy synchronous editing state, keep
            // its key native; selecting the block header returns canvas focus.
            if view is WKWebView { return false }
            responderView = view.superview
        }
        let selected = multiSelection.selectedIDs.intersection(note.blocks.map(\.id))
        guard !selected.isEmpty else { return false }
        guard saveEditors() else {
            message = "有文件尚未保存成功，请处理保存提示后再删除内容块。"
            return true
        }
        // Existing operations supply lock protection, one-step undo and anchor
        // cleanup. They remove only the canvas records, never the original file.
        if selected.count > 1 { multiSelection.delete() }
        else if let id = selected.first { deleteBlock(id) }
        return true
    }
}
#endif
