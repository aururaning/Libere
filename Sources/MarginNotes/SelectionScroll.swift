import SwiftUI
import WebKit

#if os(macOS)
/// A native boundary makes the selected content's scroll owner discoverable even
/// when a SwiftUI selection overlay is above its editor, PDF or web content.
@MainActor final class BlockScrollHost: NSView {
    var blockID = UUID()
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); host.sizingOptions = []; addSubview(host)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); host.frame = bounds }
}

@MainActor struct BlockScrollScope<Content: View>: NSViewRepresentable {
    let id: UUID
    @ViewBuilder var content: () -> Content
    func makeNSView(context: Context) -> BlockScrollHost { BlockScrollHost(frame: .zero) }
    func updateNSView(_ view: BlockScrollHost, context: Context) {
        view.blockID = id; view.host.rootView = AnyView(content()); view.host.frame = view.bounds
    }
}

@MainActor enum SelectionWheel {
    /// Geometry alone is insufficient when a sidebar or inspector overlays the
    /// detail. Claim input only when AppKit's frontmost hit belongs to this scroll
    /// view, and only inside its actually visible clip region.
    static func owns(_ point: NSPoint, in eventWindow: NSWindow?, scroll: NSScrollView) -> Bool {
        guard point.x.isFinite, point.y.isFinite, let window = scroll.window,
              eventWindow === window, window.attachedSheet == nil,
              !scroll.isHiddenOrHasHiddenAncestor, let root = window.contentView,
              scroll.contentView.visibleRect.contains(scroll.contentView.convert(point, from: nil)) else { return false }
        let inParent = root.superview?.convert(point, from: nil) ?? point
        guard let hit = root.hitTest(inParent) else { return false }
        return hit === scroll || hit.isDescendant(of: scroll)
    }
    static func editorContains(_ point: NSPoint, in view: NSView) -> Bool {
        guard !view.isHiddenOrHasHiddenAncestor else { return false }
        if let text = view as? NSTextView, text.isEditable, text.visibleRect.contains(text.convert(point, from: nil)) { return true }
        return view.subviews.contains { editorContains(point, in: $0) }
    }
    static func scope(_ id: UUID, in root: NSView) -> BlockScrollHost? {
        var queue = [root]
        while let view = queue.popLast() {
            if let host = view as? BlockScrollHost, host.blockID == id, !host.isHiddenOrHasHiddenAncestor { return host }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
    private static func scrollOwner(in root: NSView) -> NSView? {
        guard !root.isHiddenOrHasHiddenAncestor else { return nil }
        if root is WKWebView || root is NSScrollView { return root }
        for child in root.subviews { if let owner = scrollOwner(in: child) { return owner } }
        return nil
    }
    /// Consume only if this direction can move the selected contents. WebKit
    /// answers asynchronously; its original event is retained and falls back once.
    @discardableResult static func scrollContent(in root: NSView, delta: CGSize, precise: Bool, point: NSPoint,
                                                  fallback: (@MainActor () -> Void)? = nil) -> Bool {
        guard let owner = scrollOwner(in: root) else { return false }
        if let web = owner as? WKWebView {
            let local = web.convert(point, from: nil)
            let scale = max(0.01, web.pageZoom)
            let dx = -delta.width * (precise ? 1 : 24) / scale
            let dy = -delta.height * (precise ? 1 : 24) / scale
            guard dx.isFinite, dy.isFinite else { return false }
            let x = max(0, min(web.bounds.width, local.x)) / scale
            let y = max(0, min(web.bounds.height, web.isFlipped ? local.y : web.bounds.height - local.y)) / scale
            web.evaluateJavaScript("""
            (() => {
              let e = document.elementFromPoint(\(x), \(y));
              const candidates = [];
              while (e && e !== document.documentElement && e !== document.body) {
                const s = getComputedStyle(e);
                if ((/auto|scroll/.test(s.overflowY) && e.scrollHeight > e.clientHeight)
                    || (/auto|scroll/.test(s.overflowX) && e.scrollWidth > e.clientWidth)) candidates.push(e);
                e = e.parentElement;
              }
              if (document.scrollingElement) candidates.push(document.scrollingElement);
              for (const item of candidates) {
                const beforeX = item.scrollLeft, beforeY = item.scrollTop;
                item.scrollBy({left:\(dx), top:\(dy), behavior:'instant'});
                if (Math.abs(item.scrollLeft-beforeX)>0.01 || Math.abs(item.scrollTop-beforeY)>0.01) return true;
              }
              return false;
            })()
            """) { result, error in
                if error != nil || (result as? Bool) != true { fallback?() }
            }
            return true
        }
        if let scroll = owner as? NSScrollView {
            return scrollPage(scroll, delta: delta, precise: precise)
        }
        return false
    }
    @discardableResult static func scrollPage(_ scroll: NSScrollView, delta: CGSize, precise: Bool) -> Bool {
        guard delta.width.isFinite, delta.height.isFinite else { return false }
        if let canvas = scroll as? CanvasScrollView { return canvas.scrollPaper(delta: delta, precise: precise) }
        let clip = scroll.contentView, unit = clip.convert(NSSize(width: 1, height: 1), from: nil)
        let before = clip.bounds.origin
        var rect = clip.bounds
        rect.origin.x -= delta.width * (precise ? 1 : scroll.horizontalLineScroll) * abs(unit.width)
        rect.origin.y += delta.height * (precise ? 1 : scroll.verticalLineScroll) * abs(unit.height) * (scroll.documentView?.isFlipped == true ? -1 : 1)
        clip.scroll(to: clip.constrainBoundsRect(rect).origin); scroll.reflectScrolledClipView(clip)
        return abs(before.x - clip.bounds.minX) > 0.0001 || abs(before.y - clip.bounds.minY) > 0.0001
    }
}

/// This zero-size marker lives inside a folder page's outer SwiftUI ScrollView.
@MainActor final class FolderWheelView: NSView {
    weak var store: AppStore?
    var pageID = UUID()
    private var monitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.route(event) == true }
            return handled ? nil : event
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    func route(_ event: NSEvent) -> Bool {
        guard let store, store.selection == pageID, event.window === window, let outer = enclosingScrollView,
              SelectionWheel.owns(event.locationInWindow, in: event.window, scroll: outer),
              let content = outer.documentView else { return false }
        if event.type == .leftMouseDown {
            let scope = SelectionWheel.scope(pageID, in: content)
            if let scope, scope.bounds.contains(scope.convert(event.locationInWindow, from: nil)) {
                if store.folderBlockSelection != pageID { store.folderBlockSelection = pageID }
            } else if store.folderBlockSelection != nil { store.folderBlockSelection = nil }
            return false
        }
        return routeScroll(at: event.locationInWindow, in: event.window,
                           delta: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas)
    }
    func routeScroll(at point: NSPoint, in eventWindow: NSWindow?, delta: CGSize, precise: Bool) -> Bool {
        guard let store, store.selection == pageID, eventWindow === window, let outer = enclosingScrollView,
              SelectionWheel.owns(point, in: eventWindow, scroll: outer), let content = outer.documentView else { return false }
        if store.folderBlockSelection == pageID, let scope = SelectionWheel.scope(pageID, in: content),
           SelectionWheel.scrollContent(in: scope, delta: delta, precise: precise, point: point, fallback: { [weak self, weak outer] in
               guard let self, let outer, let current = self.store, current.selection == self.pageID,
                     current.folderBlockSelection == self.pageID, outer.window === eventWindow else { return }
               SelectionWheel.scrollPage(outer, delta: delta, precise: precise)
           }) { return true }
        SelectionWheel.scrollPage(outer, delta: delta, precise: precise)
        return true
    }
}
@MainActor struct FolderWheelRouter: NSViewRepresentable {
    let store: AppStore; let pageID: UUID
    func makeNSView(context: Context) -> FolderWheelView { FolderWheelView() }
    func updateNSView(_ view: FolderWheelView, context: Context) { view.store = store; view.pageID = pageID }
}
#else
@MainActor struct BlockScrollScope<Content: View>: View {
    let id: UUID
    @ViewBuilder var content: () -> Content
    var body: some View { content() }
}
@MainActor struct FolderWheelRouter: View {
    let store: AppStore; let pageID: UUID
    var body: some View { EmptyView() }
}
#endif
