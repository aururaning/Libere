import SwiftUI
import Combine

// Name the public property-wrapper type explicitly; some SDKs also export a State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

@main @MainActor struct MarginNotesApp: App {
    @StateObject private var bootstrap = Bootstrap()
    var body: some Scene {
        WindowGroup(AppBrand.name) {
            if let store = bootstrap.store {
                LibraryView(store: store, openStorage: { bootstrap.showingStorage = true }, openAgent: { bootstrap.showingAgent = true }).preferredColorScheme(.light)
                    .id(store.repository.root)
                    .overlay { if bootstrap.isLoading { WorkspaceLoadingView() } }
                    .sheet(isPresented: $bootstrap.showingStorage) { WorkspaceSetup(bootstrap: bootstrap, settings: true) }
                    .sheet(isPresented: $bootstrap.showingAgent) { if let agent = bootstrap.agent { AgentSettings(controller:agent) } }
                #if MARGIN_LOCAL_BUILD
                    .task { await MacWindowCheck.observe(store: store) }
                #endif
            }
            else if bootstrap.isLoading { WorkspaceLoadingView() }
            else { WorkspaceSetup(bootstrap: bootstrap) }
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        #endif
        .commands {
            CommandGroup(replacing: .pasteboard) {
                Button("剪切") { bootstrap.store?.cutFocused() }.keyboardShortcut("x", modifiers: .command)
                Button("复制") { bootstrap.store?.copyFocused() }.keyboardShortcut("c", modifiers: .command)
                Button("粘贴") { bootstrap.store?.pasteFocused() }.keyboardShortcut("v", modifiers: .command)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") { bootstrap.store?.undoFocused() }.keyboardShortcut("z", modifiers: .command)
                Button("重做") { bootstrap.store?.redoFocused() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("笔记") {
                Button("场景展示") { bootstrap.store?.openShowcase() }
                Divider()
                Button("新建笔记") { bootstrap.store?.create() }.keyboardShortcut("n", modifiers: .command)
                Button("新建子页面") { if let store = bootstrap.store { store.create(parent: store.selection) } }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("粘贴为链接块") { bootstrap.store?.pasteLink() }.keyboardShortcut("v", modifiers: [.command, .option, .shift])
                Button("插入文字框") { bootstrap.store?.insert(.text) }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("插入公式") { bootstrap.store?.insert(.formula) }.keyboardShortcut("m", modifiers: [.command, .shift])
                Divider()
                Button("加粗") { bootstrap.store?.formatText(.bold) }.keyboardShortcut("b", modifiers: .command)
                Button("斜体") { bootstrap.store?.formatText(.italic) }.keyboardShortcut("i", modifiers: .command)
                Button("荧光标记") { bootstrap.store?.formatText(.highlight) }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button("增大字号") { bootstrap.store?.formatText(.grow(2)) }.keyboardShortcut("=", modifiers: [.command, .shift])
                Button("减小字号") { bootstrap.store?.formatText(.grow(-2)) }.keyboardShortcut("-", modifiers: [.command, .shift])
                #if os(macOS)
                Button("显示字体") { if let store = bootstrap.store { FontPanel.shared.show(store) } }.keyboardShortcut("t", modifiers: .command)
                #endif
                Button("放大页面") { if let store = bootstrap.store { store.fitToWidth = false; store.zoom = min(6, store.zoom + 0.1) } }.keyboardShortcut("=", modifiers: .command)
                Button("缩小页面") { if let store = bootstrap.store { store.fitToWidth = false; store.zoom = max(0.25, store.zoom - 0.1) } }.keyboardShortcut("-", modifiers: .command)
                Button("铺满页面宽度") { bootstrap.store?.fitToWidth = true }.keyboardShortcut("0", modifiers: .command)
                Divider()
                Button("撤销画布操作") { bootstrap.store?.undo() }.keyboardShortcut("z", modifiers: [.command, .option])
                Button("重做画布操作") { bootstrap.store?.redo() }.keyboardShortcut("z", modifiers: [.command, .option, .shift])
                Button("保存到本机") { bootstrap.store?.saveEditors(); bootstrap.store?.flush() }.keyboardShortcut("s", modifiers: .command)
                Button("存储位置…") { bootstrap.showingStorage = true }
                Button("Agent 接入…") { bootstrap.showingAgent = true }.disabled(bootstrap.agent == nil)
            }
        }
        #if os(macOS)
        Settings { WorkspaceSetup(bootstrap: bootstrap, settings: true) }
        #endif
    }
}
