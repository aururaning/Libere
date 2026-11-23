import SwiftUI
import Combine
import UniformTypeIdentifiers
import PDFKit
#if SWIFT_PACKAGE
import MarginCore
#endif

struct NoteTree: Identifiable {
    let note: Note
    var children: [NoteTree]?
    var id: UUID { note.id }
    static func build(_ workspace: Workspace) -> [NoteTree] {
        let alive = workspace.notes.filter { !$0.deleted }
        let ids = Set(alive.map(\.id))
        let children = Dictionary(grouping: alive, by: \.parentID).mapValues { $0.sorted(by: Workspace.sidebarLess) }
        var visited: Set<UUID> = []
        func branch(_ note: Note) -> NoteTree {
            visited.insert(note.id)
            var nested: [NoteTree] = []
            for child in children[note.id] ?? [] where !visited.contains(child.id) {
                nested.append(branch(child))
            }
            return NoteTree(note: note, children: nested.isEmpty ? nil : nested)
        }
        let roots = alive.filter { $0.parentID == nil || !ids.contains($0.parentID!) }.sorted(by:Workspace.sidebarLess)
        var result: [NoteTree] = []
        for root in roots where !visited.contains(root.id) { result.append(branch(root)) }
        // A malformed/imported parent cycle must not make pages disappear.
        for note in alive where visited.insert(note.id).inserted { result.append(NoteTree(note: note, children: nil)) }
        return result
    }
}

@MainActor struct LibraryView: View {
    @ObservedObject var store: AppStore
    var openStorage: () -> Void = {}
    var openAgent: () -> Void = {}
    @Environment(\.scenePhase) private var phase
    @ViewState private var showingImporter = false
    @ViewState private var importingBackup = false
    @ViewState private var importCollapsed = false
    @ViewState private var exporting = false
    @ViewState private var backup: BackupDocument?
    @ViewState private var inspector = false
    @ViewState private var showingReferences = false
    @ViewState private var referenceAsPage = false
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 210, ideal: 245, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if store.showTrash { trashView }
                else if let note = store.note {
                    titlebar(note)
                    if note.id == ShowcaseCatalog.rootPageID, let catalog = store.showcaseCatalog {
                        ShowcaseHome(store: store, catalog: catalog)
                    }
                    else if note.isFolder { folderView(note) }
                    else {
                        if let scene = store.showcaseCatalog?.scenario(containing: note.id) { ShowcaseGuide(store: store, scenario: scene) }
                        tools
                        if store.tool == .ink {
                            ScrollView(.horizontal, showsIndicators: false) { InkControls(store: store).padding(.horizontal, 20).padding(.vertical, 7) }
                            Divider()
                        }
                        HStack(spacing: 0) {
                            NoteCanvas(store: store, note: note)
                            if inspector { Divider(); InspectorView(store: store).frame(width: 216) }
                        }
                    }
                } else {
                    ContentUnavailableView { Label("留一页给新的想法", systemImage: "square.and.pencil") }
                    description: { Text("新建笔记，或从左侧选择已有页面。") }
                    actions: { Button("新建笔记") { store.create() }.buttonStyle(.borderedProminent) }
                }
                statusbar
            }
        }
        .tint(Palette.accent)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: importingBackup ? [.marginBackup, .json] : AttachmentFormat.importTypes) { result in
            do {
                let url = try result.get()
                if importingBackup { try store.importBackup(url) }
                else { store.importFile(url, collapsed: importCollapsed) }
            } catch let error as CocoaError where error.code == .userCancelled {
                return
            } catch { store.message = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: backup, contentType: .marginBackup, defaultFilename: "\(AppBrand.name)-Backup") { result in
            if case .failure(let error) = result { store.message = error.localizedDescription }
        }
        .sheet(item:$store.deletionRequest) { request in DeletePageSheet(store:store,id:request.id) }
        .sheet(item: $store.formulaEditor) { block in FormulaEditor(store: store, block: block) }
        .sheet(isPresented: $showingReferences) { FileReferencePicker(store: store, asPage: referenceAsPage) }
        .alert("提示", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("知道了", role: .cancel) { store.message = nil }
        } message: { Text(store.message ?? "") }
        .onChange(of: store.selection) { _, _ in store.blockSelection = nil; store.tool = .select; store.formatting.clear(); store.showTrash = false }
        .onChange(of: phase) { _, next in
            if next == .active {
                store.refreshVisibleReferences()
                Task { await store.cloud?.refresh() }
            } else {
                if let id = store.folderOverviewEditingID { store.finishFolderOverviewEditing(noteID: id) }
                store.saveEditors(); store.flush()
            }
        }
        .onReceive(timer) { _ in if phase == .active { Task { await store.cloud?.refresh(); await store.maintainICloudFiles() } } }
        .task { await store.maintainICloudFiles() }
        .task { if UserDefaults.standard.bool(forKey: "MarginCloudEnabled") { store.enableCloud() } }
        #if os(macOS)
        .frame(minWidth: 980, minHeight: 680)
        .sheet(item: $store.readerBlock) { block in
            if let id = store.selection { AttachmentReader(store: store, noteID: id, block: block).frame(minWidth: 760, minHeight: 560) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            if let id = store.folderOverviewEditingID { store.finishFolderOverviewEditing(noteID: id) }
            store.iCloudFiles.persist(); store.stopKernels(); store.flush()
        }
        #else
        .fullScreenCover(item: $store.readerBlock) { block in
            if let id = store.selection { AttachmentReader(store: store, noteID: id, block: block) }
        }
        #endif
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("搜索标题与笔记", text: $store.search).textFieldStyle(.plain) }.padding(9).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
            ScrollViewReader { proxy in
            List(selection: Binding(get: { store.selection }, set: { if let id = $0 { store.select(id) } })) {
                Section {
                    HStack {
                        Label("知识库",systemImage:"folder")
                        Spacer()
                        if store.draggingPageID != nil { Text("拖到这里移至根目录").font(.caption2) }
                    }.font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:28)
                        .contentShape(Rectangle())
                        .background(store.pageDropPlacement == .inside(nil) ? Palette.accent.opacity(0.13) : Color.clear,in:RoundedRectangle(cornerRadius:6))
                        .onDrop(of:[.liberePage],delegate:PageDropDelegate(store:store,target:nil,height:28))
                    if store.search.isEmpty {
                        ForEach(sidebarItems, id: \.note.id) { item in
                            PageDragRow(store:store,note:item.note) {
                            HStack(spacing: 5) {
                                if item.hasChildren {
                                    SidebarDisclosureButton(pageID: item.note.id, title: item.note.title,
                                        expanded: store.expandedPages.contains(item.note.id)) {
                                        if store.expandedPages.contains(item.note.id) { store.expandedPages.remove(item.note.id) }
                                        else { store.expandedPages.insert(item.note.id) }
                                    }
                                } else { Color.clear.frame(width: SidebarDisclosureButton.size.width, height: SidebarDisclosureButton.size.height) }
                                row(item.note)
                            }.padding(.leading, CGFloat(item.depth) * 14)
                            }.tag(item.note.id).id(item.note.id)
                        }
                    } else {
                        ForEach(store.workspace.notes.filter { !$0.deleted && ($0.title.localizedCaseInsensitiveContains(store.search) || $0.summary.localizedCaseInsensitiveContains(store.search)) }) { note in PageDragRow(store:store,note:note) { row(note) }.tag(note.id) }
                    }
                }
            }.listStyle(.sidebar).background(SidebarKeyboard(store:store))
                .onChange(of: store.selection) { _, id in if let id { proxy.scrollTo(id) } }
                .onChange(of: store.renaming) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
            }
            HStack {
                Menu { Button("新建笔记") { store.create() }; Button("新建文件夹") { store.create(folder: true) }; Button("引用文件为子页面") { referenceAsPage = true; showingReferences = true } }
                label: { Label("新建", systemImage: "plus") }
                Spacer()
                Button { store.showTrash.toggle() } label: { Image(systemName: "shippingbox") }.buttonStyle(.plain).accessibilityLabel("回收站").help("回收站")
                Menu {
                    Button("导出索引与批注") { do { backup = try store.backup(); exporting = true } catch { store.message = error.localizedDescription } }
                    Button("导入索引与批注") { importingBackup = true; showingImporter = true }
                    Button("Agent 接入…",action:openAgent)
                    Toggle("删除含子项时提示",isOn:$store.confirmSubtreeDeletion)
                    Divider()
                    Button("启用 iCloud") { store.enableCloud() }
                    Button("存储位置…", action: openStorage)
                } label: { Image(systemName: "ellipsis.circle") }
            }.padding(16)
        }
    }
    private var sidebarItems: [(note: Note, depth: Int, hasChildren: Bool)] {
        var result: [(note: Note, depth: Int, hasChildren: Bool)] = []
        func visit(_ tree: NoteTree, depth: Int) {
            result.append((tree.note, depth, tree.children != nil))
            if store.expandedPages.contains(tree.id) { for child in tree.children ?? [] { visit(child, depth: depth + 1) } }
        }
        for root in NoteTree.build(store.workspace) { visit(root, depth: 0) }
        return result
    }
    private func row(_ note: Note) -> some View {
        HStack(spacing: 6) {
            Image(systemName: note.isFolder ? "folder" : "doc.text").foregroundStyle(.secondary)
            if store.renaming == note.id { SidebarNameField(text: $store.renameDraft, commit: { store.commitRename() }, cancel: { store.cancelRename() }).frame(height: 23) }
            else { Text(note.title.isEmpty ? "未命名" : note.title) }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .lineLimit(1).contextMenu {
                Button("重命名（Enter）") { store.beginRename(note.id) }
                Button("新建子页面") { store.create(parent: note.id) }
                Button("新建子文件夹") { store.create(folder: true, parent: note.id) }
                Button("引用文件为子页面") { store.select(note.id); referenceAsPage = true; showingReferences = true }
                Menu("移动到") {
                    Button("知识库根目录") { store.move(note.id, to: nil) }
                    ForEach(store.workspace.moveTargets(for: note.id)) { target in
                        Button(target.title) { store.move(note.id, to: target.id) }
                    }
                }
                Button("移入回收站（⌘⌫）", role: .destructive) { store.requestTrash(note.id) }
                #if os(macOS)
                Button("打开原文件夹") { if store.flush() { NSWorkspace.shared.open(store.directories.directory(for: note.id, in: store.workspace)) } }
                #endif
            }
    }
    private func titlebar(_ note: Note) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(breadcrumb(note)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                TextField("未命名笔记", text: Binding(get: { store.note?.title ?? "" }, set: { title in store.edit { $0.title = title } }))
                    .textFieldStyle(.plain).font(.system(size: 23, weight: .semibold)).onSubmit { store.flush() }
            }
            Spacer()
            if !note.isFolder {
                Button { inspector.toggle() } label: { Image(systemName: "sidebar.right") }.buttonStyle(.plain).help("画布与批注设置")
            }
            Button("子页面", systemImage: "doc.badge.plus") { store.create(parent: note.id) }.buttonStyle(.plain).help("新建子页面")
        }.padding(.horizontal, 16).padding(.vertical, 10).background(.background)
    }
    private func breadcrumb(_ note: Note) -> String {
        var titles: [String] = []; var id = note.parentID; var visited: Set<UUID> = [note.id]
        while let next = id, !visited.contains(next), let parent = store.workspace.notes.first(where: { $0.id == next }) {
            titles.insert(parent.title, at: 0); visited.insert(next); id = parent.parentID
        }
        return (["知识库"] + titles).joined(separator: "  /  ")
    }
    private var tools: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 13) {
                ForEach(EditorTool.allCases, id: \.self) { tool in
                    Button { choose(tool) } label: {
                        Label(tool.title, systemImage: tool.icon).font(.system(size: 12, weight: .medium)).padding(.horizontal, 9).padding(.vertical, 7)
                            .background(store.tool == tool ? Palette.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                }
                Divider().frame(height: 20)
                Button { store.insert(.formula) } label: { Label("公式", systemImage: "function") }.buttonStyle(.plain)
                Menu {
                    Button("添加索引并展开") { importCollapsed = false; importingBackup = false; showingImporter = true }
                    Button("添加索引并收起") { importCollapsed = true; importingBackup = false; showingImporter = true }
                } label: { Label("添加文件索引", systemImage: "doc.badge.plus") }
                Menu {
                    ForEach(LinkDisplayMode.allCases, id: \.self) { mode in Button("粘贴为" + mode.title) { store.pasteLink(mode: mode) } }
                } label: { Label("粘贴链接", systemImage: "link") }
                Button { referenceAsPage = false; showingReferences = true } label: { Label("引用", systemImage: "doc.on.doc") }.buttonStyle(.plain)
                Divider().frame(height: 20)
                Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.plain).disabled(!store.canUndo).help("撤销画布操作")
                Button { store.redo() } label: { Image(systemName: "arrow.uturn.forward") }.buttonStyle(.plain).disabled(!store.canRedo)
                Button { store.fitToWidth = false; store.zoom = max(0.25, store.zoom - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }.buttonStyle(.plain)
                Text("\(Int(store.zoom * 100))%").font(.caption.monospacedDigit()).frame(width: 38)
                Button { store.fitToWidth = false; store.zoom = min(6, store.zoom + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }.buttonStyle(.plain)
                Button { store.fitToWidth = true } label: { Image(systemName: "arrow.left.and.right") }.buttonStyle(.plain).help("铺满页面宽度")
            }.padding(.horizontal, 20).padding(.vertical, 9)
        }.background(.background).overlay(alignment: .bottom) { Divider() }
    }
    private func choose(_ tool: EditorTool) {
        if tool == .anchor {
            guard let block = store.block else { store.message = "先选中要批注的内容块。"; return }
            store.addAnnotation(to: block.id); return
        }
        store.tool = tool
        if tool != .select { store.formatting.clear() }
    }
    private var statusbar: some View {
        HStack(spacing: 8) {
            Circle().fill(store.saveStatus == "已保存到本机" ? Palette.accent : Color.secondary).frame(width: 5, height: 5)
            Text(store.saveStatus)
            Spacer()
            Button { if store.cloud == nil { store.enableCloud() } else { Task { await store.cloud?.refresh(); await store.maintainICloudFiles() } } } label: {
                Label(store.cloudStatus, systemImage: "icloud")
            }.buttonStyle(.plain)
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 29).background(.background)
    }
    private func folderView(_ note: Note) -> some View {
        let children = store.workspace.children(note.id)
        let childCounts = Dictionary(grouping: store.workspace.notes.filter { !$0.deleted }, by: \.parentID).mapValues(\.count)
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                FolderOverview(store: store, noteID: note.id).id(note.id)
                Text("\(children.count) 个子项目").font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 18)], spacing: 18) {
                    ForEach(children) { child in
                        let summary = child.summary
                        Button { store.select(child.id) } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(systemName: child.isFolder ? "folder.fill" : "doc.text").font(.title2).foregroundStyle(Palette.accent)
                                Text(child.title).font(.headline).lineLimit(2)
                                Text(summary.isEmpty ? "留一页给新的想法" : summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                Spacer(minLength: 0)
                                Text("\(child.blocks.count) 个内容块 · \(childCounts[child.id] ?? 0) 个子项目").font(.caption2).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 160).padding(20).background(.background, in: RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(28)
                .background(FolderWheelRouter(store: store, pageID: note.id).frame(width: 0, height: 0))
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.desk)
    }
    private var trashView: some View {
        VStack(alignment: .leading) {
            Text("回收站").font(.title.bold()).padding()
            List(store.workspace.notes.filter(\.deleted)) { note in HStack { Label(note.title, systemImage: note.isFolder ? "folder" : "doc.text"); Spacer(); Button("恢复") { store.recover(note.id) } } }
        }
    }
}

@MainActor struct InspectorView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("画布").font(.headline)
                Picker("纸张", selection: Binding(get: { store.note?.paper ?? .continuous }, set: { store.changePaper($0) })) {
                    ForEach(PaperKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("显示点阵", isOn: $store.grid)
                Toggle("文字吸附对齐", isOn: $store.snap)
                Button("整理版面", systemImage: "square.grid.2x2") { store.arrange() }
                Divider()
                if let block = store.block {
                    Text(block.kind == .pdf ? "资料与批注" : "内容块").font(.headline)
                    Toggle("锁定位置与大小", isOn: Binding(get: { block.locked }, set: { value in store.checkpoint(); store.editBlock(block.id) { $0.locked = value } }))
                    Text("\(Int(block.frame.width)) × \(Int(block.frame.height))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if block.kind == .text { textControls(block) }
                    if block.kind == .formula {
                        Button("编辑公式") { store.formulaEditor = block }
                        Stepper("字号 \(Int(block.fontSize))", value: Binding(get: { block.fontSize }, set: { value in store.editBlock(block.id) { $0.fontSize = value } }), in: 12...64, step: 2)
                    }
                    if block.kind.hasAttachment {
                        Button("阅读与页内批注", systemImage: "pencil.and.outline") { store.readerBlock = block }
                        Text("附件内的手写与文字按页保存。下方批注点属于页外，翻页时保持原位。").font(.caption).foregroundStyle(.secondary)
                    }
                    anchorControls(block)
                    if block.anchorID != nil { Button("解除批注关联") { store.checkpoint(); store.editBlock(block.id) { $0.anchorID = nil } } }
                    Button("删除内容块", role: .destructive) { store.deleteBlock(block.id) }
                } else {
                    Label("点击内容块边缘，查看设置。", systemImage: "cursorarrow").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("手写始终自由，不参与吸附和重排。").font(.caption).foregroundStyle(.secondary)
            }.font(.system(size: 12)).padding(18)
        }.background(.background)
    }
    @ViewBuilder private func anchorControls(_ block: Block) -> some View {
        Button(block.kind.hasAttachment ? "添加页外文字批注" : "添加文字批注", systemImage: "text.bubble") { store.addAnnotation(to: block.id) }
        Button("自定批注点位置", systemImage: "scope") { store.selectBlock(block.id); store.tool = .anchor }
        Text("文字批注自动放在附近空位；点击圆点可继续编辑。自定位置后自动回到选择。").font(.caption).foregroundStyle(.secondary)
        ForEach(store.note?.anchors.filter { $0.ownerID == block.id } ?? []) { anchor in
            VStack(alignment: .leading, spacing: 6) {
                TextField("名称", text: Binding(get: { anchor.label }, set: { label in store.edit { note in if let i = note.anchors.firstIndex(where: { $0.id == anchor.id }) { note.anchors[i].label = label } } }))
                Picker("对齐", selection: Binding(get: { anchor.edge }, set: { store.changeAnchor(anchor.id, edge: $0) })) {
                    ForEach(AnchorEdge.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden()
                HStack { Button("打开批注") { store.annotate(anchor) }; Spacer(); Button(role: .destructive) { store.removeAnchor(anchor.id) } label: { Image(systemName: "trash") } }
            }.padding(10).background(Palette.desk, in: RoundedRectangle(cornerRadius: 8))
        }
    }
    private func textControls(_ block: Block) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !block.usesMarkdown {
                Button("使用 Markdown 编辑") { store.checkpoint(); store.formatting.clear(); store.editBlock(block.id) { $0.textFormat = .markdown } }
            }
            Text("先点击文字或选中一段文字，再设置格式。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { store.formatText(.bold) } label: { Image(systemName: "bold") }
                Button { store.formatText(.italic) } label: { Image(systemName: "italic") }
                Button { store.formatText(.highlight) } label: { Image(systemName: "highlighter") }
            }
            HStack { Button("A−") { store.formatText(.grow(-2)) }; Button("A+") { store.formatText(.grow(2)) } }
            if block.usesMarkdown {
                HStack {
                    Button("行内公式") { store.formatText(.inlineFormula) }
                    Button("独立公式") { store.formatText(.displayFormula) }
                }
                Text("$…$ 行内 · $$…$$ 独立\n编辑时输入源码，预览时排版。字体和字号作用于整个 Markdown 框。").font(.caption).foregroundStyle(.secondary)
            }
            Menu("字体") {
                Button("系统字体") { store.formatText(.font("system")) }
                Button("宋体") { store.formatText(.font("Songti SC")) }
                Button("苹方") { store.formatText(.font("PingFang SC")) }
                Button("等宽字体") { store.formatText(.font("Menlo")) }
            }
            Toggle("左侧强调线", isOn: Binding(get: { block.quote }, set: { value in store.editBlock(block.id) { $0.quote = value } }))
            Picker("底色", selection: Binding(get: { block.tint }, set: { value in store.editBlock(block.id) { $0.tint = value } })) {
                Text("白色").tag("paper"); Text("浅灰").tag("gray"); Text("浅蓝").tag("blue")
                if block.tint == "yellow" { Text("浅灰").tag("yellow") }; if block.tint == "green" { Text("浅蓝").tag("green") }
            }
        }
    }
}

@MainActor struct AttachmentReader: View {
    @ObservedObject var store: AppStore
    let noteID: UUID
    let block: Block
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @ViewState private var page = 0
    @ViewState private var pageCount = 0
    @ViewState private var loadedContent: String?
    @ViewState private var mode = "ink"
    @ViewState private var zoom = 1.0
    @ViewState private var notebook: NotebookSession?
    @ViewState private var textFile: TextFileSession?
    @ViewState private var exportOriginal = false
    @ViewState private var original: AttachmentExport?
    private var current: Block? { store.workspace.notes.first { $0.id == noteID && !$0.deleted }?.blocks.first { $0.id == block.id } }
    private var paging: AttachmentPagination { AttachmentPagination(page: page, pageCount: pageCount) }
    private var modeSelection: Binding<String> {
        Binding(get: { mode }, set: { next in
            guard next != mode, store.prepareAttachmentNavigation() else { return }
            mode = next
        })
    }
    var body: some View {
        if let current {
            ICloudFileGate(files: store.iCloudFiles, url: store.attachmentURL(for: current), close: close) { readerContent }
        } else { readerContent }
    }
    private var readerContent: some View {
        NavigationStack {
            if let current {
                VStack(spacing: 0) {
                    HStack {
                        Picker("批注方式", selection: modeSelection) {
                            Text("浏览").tag("read"); Text("手写").tag("ink"); Text("文字批注").tag("text")
                            if AttachmentFormat(filename: current.assetName) == .notebook { Text("Notebook").tag("notebook") }
                            else if current.kind == .file && AttachmentFormat(filename: current.assetName)?.isTextEditable == true { Text("编辑文本").tag("source") }
                        }.pickerStyle(.segmented).frame(maxWidth: 300)
                        Spacer()
                        if current.kind == .pdf {
                            Button { turnPage(-1) } label: { Image(systemName: "chevron.left") }.disabled(!paging.hasPrevious).accessibilityLabel("上一页")
                            Text(paging.label).font(.caption.monospacedDigit())
                            Button { turnPage(1) } label: { Image(systemName: "chevron.right") }.disabled(!paging.hasNext).accessibilityLabel("下一页")
                        }
                        Button { zoom = max(0.25, zoom - 0.25) } label: { Image(systemName: "minus.magnifyingglass") }
                        Text("\(Int((zoom * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 42)
                        Button { zoom = min(6, zoom + 0.25) } label: { Image(systemName: "plus.magnifyingglass") }
                        Button { zoom = 1 } label: { Image(systemName: "arrow.left.and.right") }.help("适合页面宽度")
                    }.padding(12)
                    if mode == "ink" { ScrollView(.horizontal, showsIndicators: false) { InkControls(store: store).padding(.horizontal, 12).padding(.bottom, 8) } }
                    Text(mode == "text" ? "双击页面空白处添加文字；双击批注编辑，拖动四向箭头移动。" : "页内批注 · 随附件当前页显示 · 页外批注保持不动")
                        .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
                    Divider()
                    if mode == "notebook", let notebook {
                        zoomableEditor {
                            NotebookEditor(session: notebook, filename: current.assetName, focus: { store.blockKeyboardFocus = false; store.formatting.clear() })
                        }
                    } else if mode == "source", let textFile {
                        zoomableEditor {
                            TextFileEditor(session: textFile, filename: current.assetName, formatting: AttachmentFormat(filename: current.assetName) == .markdown ? store.formatting : nil,
                                           focus: { store.blockKeyboardFocus = false; store.formatting.clear() })
                        }
                    } else {
                        AttachmentSurface(store: store, noteID: noteID, block: current, page: page,
                                      inkEnabled: mode == "ink", textEnabled: mode == "text", fitPage: false, zoom: zoom,
                                      zoomChanged: { zoom = min(6, max(0.25, $0)) })
                        .id("\(current.id)-\(page)")
                    }
                }
                .navigationTitle(current.assetName)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成", action: close) }
                    ToolbarItem { Button("撤销批注") { store.undo() }.disabled(!store.canUndo) }
                    ToolbarItem { Button("导出原件") {
                        if let url = current.assetID.map({ store.repository.asset($0) }) ?? store.attachmentURL(for: current), let data = try? Data(contentsOf: url) { original = AttachmentExport(data); exportOriginal = true }
                    } }
                }
                .onAppear {
                    if AttachmentFormat(filename: current.assetName) == .notebook {
                        do { notebook = try store.notebookSession(noteID: noteID, blockID: current.id); mode = "notebook" }
                        catch { store.message = error.localizedDescription }
                    } else if current.kind == .file && AttachmentFormat(filename: current.assetName)?.isTextEditable == true {
                        do { textFile = try store.textFileSession(noteID: noteID, blockID: current.id) }
                        catch { store.message = error.localizedDescription }
                    }
                }
                .task(id: current.attachmentContentIdentity) {
                    if current.kind == .pdf {
                        let startingPage = loadedContent == nil ? current.pdfPage : page
                        // Save against the outgoing page before a replaced, shorter PDF
                        // clamps the reader. The locked canvas preview remains untouched.
                        guard store.prepareAttachmentNavigation() else { return }
                        pageCount = store.pdfPageCount(for: current)
                        page = AttachmentPagination(page: startingPage, pageCount: pageCount).page
                    }
                    loadedContent = current.attachmentContentIdentity
                }
                // Keep saving the window-owned sessions too: a source refresh can
                // replace the store's session cache while this reader is still open.
                .onChange(of: mode) { _, _ in notebook?.save(); textFile?.save() }
                .onDisappear { store.prepareAttachmentNavigation(); notebook?.save(); textFile?.save(); store.flush() }
                .fileExporter(isPresented: $exportOriginal, document: original, contentType: UTType(filenameExtension: (current.assetName as NSString).pathExtension) ?? .data, defaultFilename: current.assetName) { result in
                    if case .failure(let error) = result { store.message = error.localizedDescription }
                }
            } else {
                ContentUnavailableView {
                    Label("此附件已移除", systemImage: "doc.questionmark")
                } description: {
                    Text("原笔记或附件已删除，当前阅读窗口已停止编辑。")
                } actions: { Button("关闭", action: close) }
            }
        }
    }
    private func turnPage(_ delta: Int) {
        guard let next = paging.moved(by: delta), store.prepareAttachmentNavigation() else { return }
        page = next
    }
    private func close() {
        guard store.prepareAttachmentNavigation() else { return }
        if let onClose { onClose() } else { dismiss() }
    }
    private func zoomableEditor<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let editor = content()
        return GeometryReader { viewport in
            CanvasViewport(pageID: block.id, size: viewport.size, zoom: zoom, fitting: false,
                           didZoom: { zoom = min(6, max(0.25, $0)) },
                           content: AnyView(editor.frame(width: viewport.size.width, height: viewport.size.height)
                            .environment(\.canvasRenderScale, zoom).environment(\.colorScheme, .light)),
                           routesMagnification: true)
        }
    }
}
