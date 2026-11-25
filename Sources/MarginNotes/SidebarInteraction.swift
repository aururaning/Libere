import SwiftUI
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import MarginCore
#endif

extension UTType { static let liberePage = UTType(exportedAs:"app.marginnotes.page-drag",conformingTo:.data) }

@MainActor struct SidebarDisclosureButton: View {
    let pageID: UUID
    let title: String
    let expanded: Bool
    var toggle: () -> Void
    #if os(macOS)
    static let size = CGSize(width: 28, height: 30)
    #else
    static let size = CGSize(width: 44, height: 44)
    #endif
    var body: some View {
        #if os(macOS)
        SidebarDisclosureNative(pageID: pageID, title: title, expanded: expanded, toggle: toggle)
            .frame(width: Self.size.width, height: Self.size.height)
        #else
        Button(action: toggle) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: Self.size.width, height: Self.size.height).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel((expanded ? "收起" : "展开") + title)
            .accessibilityValue(expanded ? "已展开" : "已收起")
        #endif
    }
}

@MainActor struct PageDropDelegate: DropDelegate {
    static let supportedTypes: [UTType] = [.liberePage, .fileURL]
    let store: AppStore
    let target: UUID?
    let height: CGFloat
    func placement(at point: CGPoint) -> PagePlacement {
        guard let target else { return .inside(nil) }
        let rowHeight = height.isFinite && height > 0 ? height : 28
        let edge = min(7, rowHeight * 0.25)
        if point.y < edge { return .before(target) }
        if point.y > rowHeight - edge { return .after(target) }
        return .inside(target)
    }
    private func isPageDrop(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.liberePage.identifier) }
    }
    private func fileProviders(_ providers: [NSItemProvider]) -> [NSItemProvider] {
        providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    }
    func accepts(_ providers: [NSItemProvider], at point: CGPoint) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { return false }
        if isPageDrop(providers) {
            guard let id = store.draggingPageID else { return false }
            return store.workspace.canPlace(id, at: placement(at: point))
        }
        guard let target, store.workspace.notes.contains(where: { $0.id == target && !$0.deleted }) else { return false }
        return !fileProviders(providers).isEmpty
    }
    func update(_ providers: [NSItemProvider], at point: CGPoint) {
        var next: PagePlacement?
        if accepts(providers, at: point) { next = isPageDrop(providers) ? placement(at: point) : .inside(target) }
        if store.pageDropPlacement != next { store.pageDropPlacement = next }
    }
    /// Both payloads share one native row destination. A nested file-only drop
    /// receiver must not consume the row center before page nesting sees it.
    @discardableResult func perform(_ providers: [NSItemProvider], at point: CGPoint) -> Bool {
        defer { store.draggingPageID = nil; store.pageDropPlacement = nil }
        guard accepts(providers, at: point) else { return false }
        if isPageDrop(providers), let id = store.draggingPageID {
            return store.placePage(id, at: placement(at: point))
        }
        guard let target else { return false }
        return store.indexDroppedFiles(providers: fileProviders(providers), noteID: target)
    }
    func clearOwnHighlight() {
        guard let placement = store.pageDropPlacement else { return }
        let owns: Bool
        switch placement {
        case .inside(let id): owns = id == target
        case .before(let id), .after(let id): owns = id == target
        }
        if owns { store.pageDropPlacement = nil }
    }
    func validateDrop(info: DropInfo) -> Bool {
        accepts(info.itemProviders(for: Self.supportedTypes), at: info.location)
    }
    func dropEntered(info: DropInfo) { update(info.itemProviders(for: Self.supportedTypes), at: info.location) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let providers = info.itemProviders(for: Self.supportedTypes)
        update(providers, at: info.location)
        guard accepts(providers, at: info.location) else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: isPageDrop(providers) ? .move : .copy)
    }
    func dropExited(info: DropInfo) { clearOwnHighlight() }
    func performDrop(info: DropInfo) -> Bool {
        perform(info.itemProviders(for: Self.supportedTypes), at: info.location)
    }
}

@MainActor struct PageDragRow<Content: View>: View {
    @ObservedObject var store: AppStore
    let note: Note
    @ViewBuilder let content: () -> Content
    @ViewState private var height: CGFloat = 28
    var body: some View {
        #if os(macOS)
        SidebarNativeRow(store: store, pageID: note.id, content: AnyView(rowContent)).frame(height: 30)
        #else
        rowContent
            .onDrag {
                guard store.renaming == nil else { return NSItemProvider() }
                store.draggingPageID = note.id; store.pageDropPlacement = nil
                let provider = NSItemProvider(); provider.suggestedName = note.title
                provider.registerDataRepresentation(forTypeIdentifier:UTType.liberePage.identifier,visibility:.ownProcess) { completion in
                    completion(Data(note.id.uuidString.utf8),nil); return nil
                }
                return provider
            }
            .onDrop(of:PageDropDelegate.supportedTypes,delegate:PageDropDelegate(store:store,target:note.id,height:height))
        #endif
    }
    private var rowContent: some View {
        content().frame(maxWidth: .infinity, minHeight:28).contentShape(Rectangle())
            .background(GeometryReader { geometry in
                Color.clear.onAppear { height = geometry.size.height }
                    .onChange(of:geometry.size.height) { _, value in height = value }
            })
            .background(store.pageDropPlacement == .inside(note.id) ? Palette.accent.opacity(0.13) : Color.clear,in:RoundedRectangle(cornerRadius:6))
            .overlay(alignment:.top) { if store.pageDropPlacement == .before(note.id) { Rectangle().fill(Palette.accent).frame(height:2).allowsHitTesting(false) } }
            .overlay(alignment:.bottom) { if store.pageDropPlacement == .after(note.id) { Rectangle().fill(Palette.accent).frame(height:2).allowsHitTesting(false) } }
            .overlay(alignment:.trailing) {
                if note.isFolder, store.pageDropPlacement == .inside(note.id) {
                    Text("放入文件夹").font(.system(size:11,weight:.semibold)).foregroundStyle(Palette.accent)
                        .padding(.horizontal,7).padding(.vertical,3).background(.regularMaterial,in:Capsule())
                        .padding(.trailing,4).allowsHitTesting(false)
                }
            }
    }
}

@MainActor struct SidebarRootRow: View {
    @ObservedObject var store: AppStore
    private var label: some View {
        HStack {
            Label("知识库", systemImage: "folder")
            Spacer()
            if store.draggingPageID != nil { Text("拖到这里移至根目录").font(.caption2) }
        }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Rectangle())
            .background(store.pageDropPlacement == .inside(nil) ? Palette.accent.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contextMenu {
                Button("粘贴页面或文件夹到根目录") { store.pastePages(into: nil) }
                Button("移动到根目录") { store.pastePages(into: nil, move: true) }
            }
    }
    var body: some View {
        #if os(macOS)
        SidebarNativeRow(store: store, pageID: nil, content: AnyView(label)).frame(height: 30)
        #else
        label.onDrop(of: [.liberePage], delegate: PageDropDelegate(store: store, target: nil, height: 28))
        #endif
    }
}

@MainActor struct DeletePageSheet: View {
    @ObservedObject var store: AppStore
    let id: UUID
    @ViewState private var suppress = false
    private var items: [Note] {
        let ids = store.workspace.liveSubtree(id)
        return store.workspace.notes.filter { ids.contains($0.id) && $0.id != id }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Label("将这一组移入回收站？",systemImage:"trash").font(.title2.weight(.semibold))
            Text(store.workspace.notes.first { $0.id == id }?.title ?? "所选项目").font(.headline).lineLimit(2)
            Text("包含 \(items.filter { !$0.isFolder }.count) 个子页面、\(items.filter(\.isFolder).count) 个子文件夹。它们会一起移入回收站，可用 ⌘Z 或回收站恢复。")
                .foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Toggle("以后删除含子项的项目时不再提示",isOn:$suppress).font(.callout)
            HStack {
                Spacer()
                Button("取消") { store.deletionRequest = nil }.keyboardShortcut(.cancelAction)
                Button("移入回收站",role:.destructive) { store.confirmTrash(suppress:suppress) }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width:440)
    }
}

#if os(macOS)
/// An image-only native button still tracks the entire padded rectangle, rather
/// than limiting the hit area to the tiny chevron's painted pixels.
@MainActor final class SidebarDisclosureControl: NSButton {
    var pageID = UUID()
    var toggle: () -> Void = {}
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""; isBordered = false; imagePosition = .imageOnly; imageScaling = .scaleNone
        setButtonType(.momentaryChange); target = self; action = #selector(activate)
        contentTintColor = .secondaryLabelColor
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func activate() { toggle() }
    func configure(pageID: UUID, title: String, expanded: Bool, toggle: @escaping () -> Void) {
        self.pageID = pageID; self.toggle = toggle
        image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        let label = (expanded ? "收起" : "展开") + title
        toolTip = label; setAccessibilityLabel(label); setAccessibilityValue(expanded ? "已展开" : "已收起")
        setAccessibilityIdentifier("sidebar-disclosure-" + pageID.uuidString)
    }
}
@MainActor struct SidebarDisclosureNative: NSViewRepresentable {
    let pageID: UUID; let title: String; let expanded: Bool; let toggle: () -> Void
    func makeNSView(context: Context) -> SidebarDisclosureControl { SidebarDisclosureControl(frame: .zero) }
    func updateNSView(_ view: SidebarDisclosureControl, context: Context) {
        view.configure(pageID: pageID, title: title, expanded: expanded, toggle: toggle)
    }
}

@MainActor final class SidebarKeyRegion: NSView {
    weak var store: AppStore?
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.keyDown]) { [weak self] event in
            guard let self, let store = self.store, event.window === self.window else { return event }
            if event.type == .leftMouseDown {
                store.sidebarHasFocus = self.bounds.contains(self.convert(event.locationInWindow,from:nil))
                return event
            }
            if event.keyCode == 48 { store.sidebarHasFocus = false; return event }
            return self.handle(event) ? nil : event
        }
    }
    func handle(_ event: NSEvent) -> Bool {
        guard let store, store.sidebarHasFocus, store.renaming == nil, !store.showTrash,
              store.deletionRequest == nil, let selected = store.selection,
              store.workspace.notes.contains(where: { $0.id == selected && !$0.deleted }),
              window?.firstResponder as? NSTextInputClient == nil else { return false }
        let flags = event.modifierFlags.intersection([.command,.shift,.option,.control])
        if event.charactersIgnoringModifiers?.lowercased() == "c", flags == .command {
            if !store.sidebarRootSelected { _ = store.copyPage(selected) }; return true
        }
        if event.charactersIgnoringModifiers?.lowercased() == "x", flags == .command {
            return true // Sidebar files/pages move with Command-Option-V.
        }
        if event.charactersIgnoringModifiers?.lowercased() == "v" {
            if flags == .command { store.pasteFocused(in: window); return true }
            if flags == [.command, .option] { store.moveFocused(in: window); return true }
        }
        guard !store.sidebarRootSelected else { return false }
        if [51,117].contains(event.keyCode), flags == .command { store.requestTrash(selected); return true }
        if [36,76].contains(event.keyCode), flags.isEmpty { store.beginRename(selected); return true }
        return false
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
@MainActor struct SidebarKeyboard: NSViewRepresentable {
    let store: AppStore
    func makeNSView(context:Context) -> SidebarKeyRegion { let view = SidebarKeyRegion(); view.store = store; return view }
    func updateNSView(_ view:SidebarKeyRegion,context:Context) { view.store = store }
}
#else
struct SidebarKeyboard: View { let store: AppStore; var body: some View { EmptyView() } }
#endif
