import SwiftUI
import WebKit
#if SWIFT_PACKAGE
import MarginCore
#endif

@MainActor extension AppStore {
    func openLinkedPage(_ id: UUID) {
        guard workspace.notes.contains(where: { $0.id == id && !$0.deleted }) else {
            message = "这个页面已移入回收站或不存在。"; return
        }
        select(id)
    }
    func activateMarkdownURL(_ value: String) {
        guard let url = URL(string: value) else { return }
        if let id = PageLink.noteID(in: url) { openLinkedPage(id); return }
        guard ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
    #if os(macOS)
    /// Cmd-click queries the rendered link beneath the selection surface. Ordinary
    /// clicks and drags remain on the canvas; results are pinned to this page/text.
    @discardableResult func openMarkdownLink(at point: NSPoint, in window: NSWindow?) -> Bool {
        guard let window, let root = window.contentView, let note else { return false }
        for block in note.blocks.reversed() where block.kind == .text && block.usesMarkdown && editingBlockID != block.id {
            guard let scope = SelectionWheel.scope(block.id, in: root), scope.visibleRect.contains(scope.convert(point, from: nil)),
                  let canvas = CanvasScrollView.magnificationTarget(from: scope), SelectionWheel.owns(point, in: window, scroll: canvas),
                  case .block(let hit) = canvasPointer.hit(at: canvas.paper.convert(point, from: nil)), hit == block.id else { continue }
            func findWeb(_ view: NSView) -> WKWebView? {
                if let web = view as? WKWebView, web.navigationDelegate is MarkdownNavigation { return web }
                return view.subviews.compactMap(findWeb).first
            }
            guard let web = findWeb(scope) else { continue }
            let p = web.convert(point, from: nil), scale = max(0.01, web.pageZoom)
            let x = p.x / scale, y = (web.isFlipped ? p.y : web.bounds.height - p.y) / scale
            guard x.isFinite, y.isFinite else { return false }
            let origin = note.id, source = block.text
            web.evaluateJavaScript("document.elementFromPoint(\(x),\(y))?.closest('a')?.getAttribute('href') || null") { [weak self] value, _ in
                Task { @MainActor in
                    guard let self, self.selection == origin, self.editingBlockID != block.id,
                          self.note?.blocks.first(where: { $0.id == block.id })?.text == source,
                          let value = value as? String else { return }
                    self.activateMarkdownURL(value)
                }
            }
            return true
        }
        return false
    }
    #endif
}
