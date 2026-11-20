import SwiftUI
import PDFKit
#if SWIFT_PACKAGE
import MarginCore
#endif

enum Palette {
    static let accent = Color(red: 0.15, green: 0.34, blue: 0.78)
    static let desk = Color(red: 0.93, green: 0.94, blue: 0.96)
    static let ink = Color(red: 0.10, green: 0.11, blue: 0.13)
    static func tint(_ name: String) -> Color {
        switch name { case "gray", "yellow": return Color(red: 0.96, green: 0.96, blue: 0.97)
        case "blue", "green": return Color(red: 0.92, green: 0.95, blue: 1)
        default: return .white }
    }
}
@MainActor struct NoteCanvas: View {
    @ObservedObject var store: AppStore
    let note: Note
    @StateObject private var contentState = CanvasContentState()
    var body: some View {
        GeometryReader { viewport in
            let retained = Set([store.blockSelection, store.editingBlockID, store.draggingBlockID].compactMap { $0 })
            let blocks = contentState.blocks(in: note, viewport: viewport.size, zoom: store.zoom, preserving: retained)
            CanvasViewport(pageID: note.id, size: CGSize(width: note.width, height: note.height),
                           zoom: store.zoom, fitting: store.fitToWidth, didZoom: store.finishCanvasZoom,
                           content: AnyView(paper(blocks: blocks).environment(\.colorScheme, .light).environment(\.canvasRenderScale, store.zoom)),
                           routesMagnification: true, didClickDesk: store.clearBlockSelection,
                           pointerInteraction: store.canvasPointer,
                           didChangeVisibleRect: { id, rect in
                               guard id == note.id else { return }
                               contentState.schedule(pageID: id, visible: rect, blocks: note.blocks)
                           })
                .background(CanvasKeyboard(store: store).frame(width: 0, height: 0))
                .onAppear { store.fitCanvasToViewport(viewport.size) }
                .onChange(of: viewport.size) { _, size in store.fitCanvasToViewport(size) }
                .onChange(of: note.id) { _, _ in store.fitCanvasToViewport(viewport.size) }
                .onChange(of: note.paper) { _, _ in store.fitCanvasToViewport(viewport.size) }
                .onChange(of: store.fitToWidth) { _, _ in store.fitCanvasToViewport(viewport.size) }
                .overlay(alignment: .bottom) {
                    if store.tool == .anchor { Text("点击放置一个批注点，随后自动回到选择 · Esc 取消")
                        .font(.caption).padding(12).background(.regularMaterial, in: Capsule()).padding(16).allowsHitTesting(false) }
                    if store.tool == .ink { Text("附件内按当前页保存 · 画布批注独立保存 · 手指滚动")
                        .font(.caption).padding(10).background(.regularMaterial, in: Capsule()).padding(14).allowsHitTesting(false) }
                }
        }
    }
    var paper: some View { paper(blocks: note.blocks) }
    private func paper(blocks: [Block]) -> some View {
        ZStack(alignment: .topLeading) {
                paperBackground
                if store.grid { DotGrid().allowsHitTesting(false) }
                ForEach(blocks) { block in
                    BlockCard(store: store, block: block).allowsHitTesting(store.tool != .anchor && (store.tool != .ink || block.kind.hasAttachment))
                        .zIndex(store.blockSelection == block.id ? 1 : 0)
                }
                let destination = InkDestination(noteID: note.id)
                InkOverlay(data: note.ink, enabled: store.tool == .ink, options: store.inkOptions,
                           excludedRects: note.blocks.filter { $0.kind.hasAttachment && $0.collapsed != true }.map { CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height) },
                           begin: { store.checkpoint(destination) }) { data, bounds in
                    store.saveInk(data, bounds: bounds, to: destination)
                }.id(note.id).frame(width: note.width, height: note.height).allowsHitTesting(store.tool == .ink).zIndex(2)
                if store.tool == .anchor { Color.clear.contentShape(Rectangle()).onTapGesture { point in store.addAnchor(point) }.zIndex(3) }
                if store.tool != .ink {
                    ForEach(note.anchors) { anchor in
                        if let p = CanvasLayout.point(anchor, blocks: note.blocks),
                           store.tool == .anchor || store.blockSelection == anchor.ownerID || store.block?.anchorID == anchor.id {
                            marker(anchor)
                                .frame(width: 44 / store.zoom, height: 44 / store.zoom)
                                .offset(x: p.x - 22 / store.zoom, y: p.y - 22 / store.zoom).zIndex(4)
                        }
                    }
                }
            }
            .frame(width: note.width, height: note.height).clipped()
            .coordinateSpace(name: "note-paper")
            .overlay(alignment: .bottomTrailing) { Text(note.paper.title).font(.system(size: 10)).foregroundStyle(.tertiary).padding(12).allowsHitTesting(false) }
    }
    @ViewBuilder private var paperBackground: some View {
        #if os(macOS)
        Rectangle().fill(.white).overlay { CanvasPointerSurface(area: .paper) }
        #else
        Rectangle().fill(.white).contentShape(Rectangle())
            .gesture(SpatialTapGesture(count: 2, coordinateSpace: .named("note-paper")).onEnded { store.tapCanvas(at: $0.location, count: 2) }
                .exclusively(before: SpatialTapGesture(coordinateSpace: .named("note-paper")).onEnded { store.tapCanvas(at: $0.location) }))
        #endif
    }
    private func marker(_ a: AnnotationAnchor) -> some View {
        let regions = CanvasHitTesting.anchorRegions(a, in: note, selected: store.blockSelection, zoom: store.zoom, handleSize: BlockMoveHandle.hitSize)
        let point = CanvasLayout.point(a, blocks: note.blocks) ?? (x: 0, y: 0)
        let shape = AnchorHitShape(regions: regions, origin: CGPoint(x: point.x - 22 / store.zoom, y: point.y - 22 / store.zoom))
        return Button { store.annotate(a) } label: { Image(systemName: "text.bubble.fill").font(.system(size: 11 / store.zoom, weight: .medium))
            .frame(width: 24 / store.zoom, height: 24 / store.zoom).foregroundStyle(.white).background(Palette.accent, in: Circle()).overlay(Circle().stroke(.white, lineWidth: 2 / store.zoom))
            .frame(width: 44 / store.zoom, height: 44 / store.zoom).contentShape(shape) }
            .buttonStyle(.plain).help("打开\(a.label) · 右键调整关联")
            .accessibilityLabel("打开\(a.label)")
            .contextMenu {
                Button("打开文字批注") { store.annotate(a) }
                ForEach(AnchorEdge.allCases, id: \.self) { edge in Button(edge.title) { store.changeAnchor(a.id, edge: edge) } }
                Button("删除批注点", role: .destructive) { store.removeAnchor(a.id) }
            }
    }
}
struct AnchorHitShape: Shape {
    let regions: [Rect]
    let origin: CGPoint
    func path(in rect: CGRect) -> Path {
        var result = Path()
        for r in regions { result.addRect(CGRect(x: r.x - origin.x, y: r.y - origin.y, width: r.width, height: r.height)) }
        return result
    }
}
@MainActor struct DotGrid: View {
    // One reusable 24-point tile, rather than enumerating the entire long page on every zoom.
    private static let tile: Image = {
        let context = CGContext(data: nil, width: 48, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: 2, y: 2); context.setFillColor(CGColor(gray: 0, alpha: 0.10))
        context.fillEllipse(in: CGRect(x: 11.35, y: 11.35, width: 1.3, height: 1.3))
        return Image(decorative: context.makeImage()!, scale: 2)
    }()
    var body: some View { Rectangle().fill(ImagePaint(image: Self.tile)) }
}
@MainActor struct BlockCard: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var pointer: CanvasPointerInteraction
    let block: Block
    init(store: AppStore, block: Block) {
        self.store = store; self.block = block; self.pointer = store.canvasPointer
    }
    @GestureState private var movement = CGSize.zero
    @GestureState private var growth = CGSize.zero
    @GestureState private var dragging = false
    @ViewState private var dragSession: DragSession?
    @ViewState private var pdfPageCount: Int?
    private struct DragSession {
        let id = UUID()
        let frame: Rect
        let resizing: Bool
        let noteID: UUID?
    }
    private var selected: Bool { store.blockSelection == block.id }
    private var editing: Bool { store.editingBlockID == block.id }
    private var frame: Rect {
        let proposed = pointer.preview.flatMap { $0.blockID == block.id ? $0.frame : nil }
            ?? Rect(block.frame.x + movement.width, block.frame.y + movement.height, block.frame.width + growth.width, block.frame.height + growth.height)
        return Rect(proposed.x, proposed.y, max(100, proposed.width),
                    block.isFilePlugin && block.collapsed == true ? Block.collapsedHeight : max(80, proposed.height))
    }
    private var moving: Bool { movement != .zero || (pointer.preview?.blockID == block.id && pointer.preview?.resizing == false) }
    private var resizeFrame: Rect { CanvasItemGeometry.resizeCorner(for: block, frame: frame, zoom: store.zoom) }
    private var handleOffset: CGSize {
        BlockMoveHandle.offset(for: CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
                               in: store.note.map { CGSize(width: $0.width, height: $0.height) })
    }
    @ViewBuilder private var focusBoundary: some View {
        if editing { BlockFocusBoundary(store: store, blockID: block.id, moveHandleOffset: handleOffset) }
    }
    private var snapTarget: AnnotationAnchor? {
        guard block.kind == .text, moving, store.snap, let note = store.note else { return nil }
        return CanvasLayout.nearest(to: frame, note: note, excluding: block.id, tolerance: 20 / store.zoom, ignoring: block.anchorID)
    }
    var body: some View {
        let handle = selected && store.tool == .select
            ? Rect(frame.x + handleOffset.width, frame.y + handleOffset.height, BlockMoveHandle.hitSize, BlockMoveHandle.hitSize) : nil
        CanvasItemPlacement(geometry: CanvasItemGeometry(body: frame, handle: handle)) { card } handle: { moveHandle }
            .onChange(of: dragging) { _, active in
                guard !active, let token = dragSession?.id else { return }
                // Cancellation has no onEnded callback. Defer cleanup until a normal
                // end has had a chance to commit, and never cancel a newer gesture.
                DispatchQueue.main.async {
                    if dragSession?.id == token { dragSession = nil; store.cancelBlockDrag(block.id) }
                }
            }
            .onDisappear { store.cancelBlockDrag(block.id) }
    }
    private var card: some View {
        VStack(spacing: 0) {
            if block.kind != .text { header }
            if block.collapsed != true {
                BlockScrollScope(id: block.id) {
                    contents.environment(\.canvasRenderScale, store.zoom)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        if store.tool == .select && !editing {
                            selectionSurface
                                .padding(.top, block.kind == .text ? 30 : block.kind == .file && AttachmentFormat(filename: block.assetName) != .image ? 28 : 0)
                                .padding(.bottom, block.kind == .pdf ? CanvasItemGeometry.pdfFooterHeight : 0)
                        }
                    }
            }
        }
            .frame(width: frame.width, height: frame.height)
            .contentShape(Rectangle())
            .background { focusBoundary }
            .background(Palette.tint(block.tint))
            .overlay(alignment: .leading) { if block.quote { Rectangle().fill(Palette.accent.opacity(0.6)).frame(width: 3) } }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected || snapTarget != nil ? Palette.accent : Color.black.opacity(0.08), lineWidth: selected ? 1.5 : 1))
            .overlay {
                if block.kind == .text {
                    #if os(macOS)
                    CanvasPointerSurface(area: .border(block.id))
                    #else
                    BlockBorder().fill(.clear, style: FillStyle(eoFill: true)).contentShape(BlockBorder(), eoFill: true)
                        .gesture(moveGesture).simultaneousGesture(selectionTap)
                    #endif
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if selected && !block.locked && block.collapsed != true {
                    ResizeCorner(length: min(resizeFrame.width - 3, min(30, max(18, min(frame.width, frame.height) * 0.10))), hitSize: resizeFrame.width)
                        #if os(macOS)
                        .overlay { CanvasPointerSurface(area: .resize(block.id)) }
                        #else
                        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("note-paper"))
                            .updating($growth) { value, state, _ in if acceptsDrag(value.startLocation, resizing: true) { state = value.translation } }
                            .updating($dragging) { value, state, _ in state = acceptsDrag(value.startLocation, resizing: true) }
                            .onChanged { value in beginDrag(value.startLocation, resizing: true) }
                            .onEnded { endDrag($0.translation) })
                        #endif
                        .padding(.bottom, frame.maxY - resizeFrame.maxY)
                }
            }
            .overlay(alignment: .topLeading) {
                if let anchor = snapTarget, let note = store.note, let p = CanvasLayout.point(anchor, blocks: note.blocks) {
                    Path { path in
                        path.move(to: CGPoint(x: -30, y: p.y - frame.y)); path.addLine(to: CGPoint(x: frame.width + 30, y: p.y - frame.y))
                        path.move(to: CGPoint(x: p.x - frame.x, y: -30)); path.addLine(to: CGPoint(x: p.x - frame.x, y: frame.height + 30))
                    }.stroke(Palette.accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3])).allowsHitTesting(false)
                    Text("吸附 · \(anchor.label)").font(.caption2).padding(5).foregroundStyle(.white).background(Palette.accent, in: Capsule()).offset(y: -28).allowsHitTesting(false)
                }
            }
            .contextMenu {
                if let source = block.sourceURL, let url = WebLink.url(source) { Link("打开资料来源", destination: url) }
                Button(block.locked ? "解锁位置和大小" : "锁定位置和大小") { store.checkpoint(); store.editBlock(block.id) { $0.locked.toggle() } }
                Button("添加文字批注") { store.addAnnotation(to: block.id) }
                Button("自定批注点位置") { store.selectBlock(block.id); store.tool = .anchor }
                if block.kind.hasAttachment { Button("阅读与页内批注") { openAttachment() } }
                if block.isFilePlugin {
                    Button("复制为引用") { store.selectBlock(block.id); store.copySelectedBlock() }
                    if let source = block.reference { Button("前往来源页面") { store.select(source.noteID); store.selectBlock(source.blockID) } }
                }
                if block.kind.hasAttachment || block.kind == .link { Button(block.collapsed == true ? "展开内容" : "收起内容") { store.toggleCollapsed(block.id) } }
                if block.kind == .link, let noteID = store.selection {
                    Menu("显示方式") { ForEach(LinkDisplayMode.allCases, id: \.self) { mode in Button(mode.title) { store.setLinkMode(mode, noteID: noteID, blockID: block.id) } } }
                    Button("获取 HTML 文件") { Task { await store.fetchHTML(noteID: noteID, blockID: block.id) } }
                    Button("在系统浏览器打开") { store.openLink(block) }
                }
                if block.anchorID != nil { Button("解除批注关联") { store.checkpoint(); store.editBlock(block.id) { $0.anchorID = nil } } }
                Button("删除内容块", role: .destructive) { store.deleteBlock(block.id) }
            }
    }
    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                FileTypeBadge(block: block)
                Text(block.isFilePlugin ? store.attachmentTitle(block, on: store.selection) : "LaTeX").font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.head)
                    .help(store.attachmentTitle(block, on: store.selection))
                if block.reference != nil || block.relativeFilePath != nil { Image(systemName: "link").font(.system(size: 9)).help("文件引用") }
                if block.locked { Image(systemName: "lock.fill").font(.system(size: 9)) }
                if block.anchorID != nil { Image(systemName: "link").font(.system(size: 9)) }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                #if os(macOS)
                .overlay { CanvasPointerSurface(area: .body(block.id)) }
                #else
                .gesture(moveGesture).simultaneousGesture(selectionTap)
                #endif
            if block.kind.hasAttachment || block.kind == .link {
                Button { store.toggleCollapsed(block.id) } label: { Image(systemName: block.collapsed == true ? "chevron.down" : "chevron.up") }.buttonStyle(.plain).disabled(block.locked).help(block.collapsed == true ? "展开预览" : "收起为标题")
            }
            if selected && block.kind.hasAttachment { Button(action: openAttachment) { Image(systemName: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.plain).help(block.kind == .pdf || AttachmentFormat(filename: block.assetName) == .image ? "全屏阅读" : "展开阅读") }
            if selected && block.kind == .formula { Button { store.formulaEditor = block } label: { Image(systemName: "pencil") }.buttonStyle(.plain) }
        }.foregroundStyle(selected ? Palette.accent : Color.secondary).padding(.horizontal, 8).frame(height: Block.collapsedHeight)
            .background(selected ? Palette.accent.opacity(0.08) : Color.black.opacity(0.018))
    }
    @ViewBuilder private var selectionSurface: some View {
        #if os(macOS)
        CanvasPointerSurface(area: .body(block.id))
            .accessibilityHint("单击选中或拖动，双击编辑或打开")
        #else
        Color.clear.contentShape(Rectangle())
            .gesture(SpatialTapGesture(count: 2, coordinateSpace: .named("note-paper")).onEnded { store.tapCanvas(at: $0.location, count: 2) }
                .exclusively(before: selectionTap))
            .simultaneousGesture(moveGesture)
            .accessibilityLabel("\(block.kind == .text ? "文字" : "资料")内容块")
            .accessibilityHint("单击选中或拖动，双击编辑或打开")
        #endif
    }
    private var moveHandle: some View {
        BlockMoveHandle(locked: block.locked, active: selected || moving)
            .accessibilityIdentifier("block-move-\(block.id)")
            #if os(macOS)
            .overlay { CanvasPointerSurface(area: .move(block.id)) }
            #else
            .simultaneousGesture(selectionTap)
            .gesture(moveGesture)
            #endif
    }
    private var selectionTap: some Gesture {
        SpatialTapGesture(coordinateSpace: .named("note-paper")).onEnded { store.tapCanvas(at: $0.location) }
    }
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("note-paper"))
            .updating($movement) { value, state, _ in if acceptsDrag(value.startLocation, resizing: false) { state = value.translation } }
            .updating($dragging) { value, state, _ in state = acceptsDrag(value.startLocation, resizing: false) }
            .onChanged { beginDrag($0.startLocation, resizing: false) }
            .onEnded { endDrag($0.translation) }
    }
    private func acceptsDrag(_ point: CGPoint, resizing: Bool) -> Bool {
        guard store.tool == .select, !block.locked else { return false }
        if let dragSession { return dragSession.resizing == resizing && dragSession.noteID == store.selection }
        return store.canBeginBlockDrag(block.id, at: point, resizing: resizing)
    }
    private func beginDrag(_ point: CGPoint, resizing: Bool) {
        guard dragSession == nil, acceptsDrag(point, resizing: resizing) else { return }
        dragSession = DragSession(frame: block.frame, resizing: resizing, noteID: store.selection)
        store.beginBlockDrag(block.id, at: point, resizing: resizing)
    }
    private func endDrag(_ translation: CGSize) {
        guard let session = dragSession else { return }; dragSession = nil
        guard session.noteID == store.selection, store.tool == .select,
              store.draggingBlockID == block.id else { store.cancelBlockDrag(block.id); return }
        let old = session.frame
        let proposed = session.resizing
            ? Rect(old.x, old.y, max(100, old.width + translation.width), max(80, old.height + translation.height))
            : Rect(old.x + translation.width, old.y + translation.height, old.width, old.height)
        store.setFrame(block.id, proposed, resizing: session.resizing)
        store.finishBlockDrag(block.id)
    }
    @ViewBuilder private var contents: some View {
        switch block.kind {
        case .text:
            MarkdownBox(store: store, block: block)
        case .formula:
            MathPreview(source: block.text, size: block.fontSize).allowsHitTesting(false)
        case .file:
            if let note = store.note { FileBlockContent(store: store, noteID: note.id, block: block) }
        case .link:
            if let note = store.note { LinkBlockContent(store: store, noteID: note.id, block: block) }
        case .pdf:
            if store.attachmentURL(for: block) != nil, let note = store.note {
                let paging = AttachmentPagination(page: block.pdfPage, pageCount: pdfPageCount ?? 0)
                let previewPage = block.locked ? block.pdfPage : paging.page
                VStack(spacing: 0) {
                    if let pdfPageCount {
                        if pdfPageCount > 0 {
                            AttachmentSurface(store: store, noteID: note.id, block: block, page: previewPage, inkEnabled: store.tool == .ink, resolutionScale: store.zoom)
                                .id("\(block.id)-\(previewPage)")
                        } else {
                            ContentUnavailableView("无法读取 PDF", systemImage: "doc.questionmark", description: Text("请检查文件是否可用、已解密且包含页面。"))
                        }
                    } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    HStack {
                        Button { turnPDF(-1) } label: { Image(systemName: "chevron.left").frame(width: 28, height: CanvasItemGeometry.pdfFooterHeight).contentShape(Rectangle()) }
                            .disabled(!paging.hasPrevious || block.locked).accessibilityLabel("上一页")
                        Spacer(minLength: 0)
                        Text(block.locked && previewPage != paging.page ? "锁定页已不在文件中" : paging.label).font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
                        Spacer(minLength: 0)
                        Button { turnPDF(1) } label: { Image(systemName: "chevron.right").frame(width: 28, height: CanvasItemGeometry.pdfFooterHeight).contentShape(Rectangle()) }
                            .disabled(!paging.hasNext || block.locked).accessibilityLabel("下一页")
                    }.buttonStyle(.plain).padding(.horizontal, 4).frame(height: CanvasItemGeometry.pdfFooterHeight).background(.white)
                        .help(block.locked ? "预览页已锁定；可打开全屏阅读浏览其他页。" : "翻页只切换页内批注，页外批注保持不动。")
                }
                .task(id: block.attachmentContentIdentity) { pdfPageCount = store.pdfPageCount(for: block) }
            }
        }
    }
    private func openAttachment() {
        store.openAttachment(block)
    }
    private func turnPDF(_ delta: Int) {
        guard let noteID = store.selection else { return }
        store.turnPDFPage(noteID: noteID, blockID: block.id, by: delta)
    }
}
@MainActor struct FormulaEditor: View {
    @ObservedObject var store: AppStore
    let block: Block
    @Environment(\.dismiss) private var dismiss
    @ViewState private var source = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("写下一个公式").font(.title2.bold()); Spacer(); Button("取消") { dismiss() } }
            MathPreview(source: source, size: 28).frame(height: 170).background(Palette.desk, in: RoundedRectangle(cornerRadius: 12))
            Text("LaTeX 源码").font(.subheadline.bold())
            TextEditor(text: $source).font(.system(.body, design: .monospaced)).frame(minHeight: 130).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            Text("离线支持分式、根式、上下标、希腊字母、积分、求和与基础矩阵。").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("保存公式") { store.checkpoint(); store.editBlock(block.id) { $0.text = source }; dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command) }
        }.padding(24).frame(minWidth: 420, idealWidth: 560, minHeight: 480).onAppear { source = block.text }
    }
}
