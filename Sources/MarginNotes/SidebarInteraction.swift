import SwiftUI
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import MarginCore
#endif

extension UTType { static let liberePage = UTType(exportedAs:"app.marginnotes.page-drag",conformingTo:.data) }

@MainActor struct PageDropDelegate: DropDelegate {
    let store: AppStore
    let target: UUID?
    let height: CGFloat
    func placement(_ info: DropInfo) -> PagePlacement {
        guard let target else { return .inside(nil) }
        if info.location.y < height * 0.25 { return .before(target) }
        if info.location.y > height * 0.75 { return .after(target) }
        return .inside(target)
    }
    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to:[.liberePage]), let id = store.draggingPageID else { return false }
        return store.workspace.canPlace(id,at:placement(info))
    }
    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info); return DropProposal(operation:validateDrop(info:info) ? .move : .forbidden)
    }
    func dropExited(info: DropInfo) { store.pageDropPlacement = nil }
    func update(_ info: DropInfo) { store.pageDropPlacement = validateDrop(info:info) ? placement(info) : nil }
    func performDrop(info: DropInfo) -> Bool {
        defer { store.draggingPageID = nil; store.pageDropPlacement = nil }
        guard validateDrop(info:info), let id = store.draggingPageID else { return false }
        return store.placePage(id,at:placement(info))
    }
}

@MainActor struct PageDragRow<Content: View>: View {
    @ObservedObject var store: AppStore
    let note: Note
    @ViewBuilder let content: () -> Content
    @ViewState private var height: CGFloat = 28
    var body: some View {
        content().frame(minHeight:28).contentShape(Rectangle())
            .background(GeometryReader { geometry in
                Color.clear.onAppear { height = geometry.size.height }
                    .onChange(of:geometry.size.height) { _, value in height = value }
            })
            .background(store.pageDropPlacement == .inside(note.id) ? Palette.accent.opacity(0.13) : Color.clear,in:RoundedRectangle(cornerRadius:6))
            .overlay(alignment:.top) { if store.pageDropPlacement == .before(note.id) { Rectangle().fill(Palette.accent).frame(height:2).allowsHitTesting(false) } }
            .overlay(alignment:.bottom) { if store.pageDropPlacement == .after(note.id) { Rectangle().fill(Palette.accent).frame(height:2).allowsHitTesting(false) } }
            .onDrag {
                guard store.renaming == nil else { return NSItemProvider() }
                store.draggingPageID = note.id; store.pageDropPlacement = nil
                let provider = NSItemProvider(); provider.suggestedName = note.title
                provider.registerDataRepresentation(forTypeIdentifier:UTType.liberePage.identifier,visibility:.ownProcess) { completion in
                    completion(Data(note.id.uuidString.utf8),nil); return nil
                }
                return provider
            }
            .onDrop(of:[.liberePage],delegate:PageDropDelegate(store:store,target:note.id,height:height))
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
                store.draggingPageID = nil; store.pageDropPlacement = nil
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
