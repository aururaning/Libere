import SwiftUI
import PDFKit
#if SWIFT_PACKAGE
import MarginCore
#endif

/// The paper coordinate system is independent of its preview frame, scroll position and zoom.
@MainActor struct AttachmentSurface: View {
    @Environment(\.canvasRenderScale) private var outerRenderScale
    @ObservedObject var store: AppStore
    let noteID: UUID
    let block: Block
    let page: Int
    var inkEnabled = false
    var textEnabled = false
    var fitPage = true
    var zoom = 1.0
    var resolutionScale = 1.0
    var zoomChanged: ((Double) -> Void)? = nil
    @ViewState private var pdfDocument: PDFDocument?
    @ViewState private var pdfPage: PDFPage?
    @ViewState private var image: AttachmentImage?
    @ViewState private var html: String?
    @ViewState private var paperSize = CGSize(width: 740, height: 600)
    @ViewState private var error: String?
    @ViewState private var selectedTextID: UUID?
    private var destination: InkDestination { InkDestination(noteID: noteID, blockID: block.id, page: page) }
    private var annotations: AttachmentPageAnnotations { block.annotations(on: page) }

    var body: some View {
        GeometryReader { viewport in
            if let error { ContentUnavailableView("暂时无法预览", systemImage: "doc.questionmark", description: Text(error)) }
            else if pdfPage != nil || image != nil || html != nil {
                let scale = max(0.001, (fitPage && block.kind == .pdf
                    ? min(viewport.size.width / paperSize.width, viewport.size.height / paperSize.height)
                    : viewport.size.width / paperSize.width))
                if let zoomChanged {
                    CanvasViewport(pageID: block.id,
                                   size: CGSize(width: paperSize.width * scale, height: paperSize.height * scale),
                                   zoom: zoom, fitting: false, didZoom: zoomChanged,
                                   content: AnyView(document(scale: scale, magnification: zoom)),
                                   routesMagnification: true)
                } else {
                    #if os(macOS)
                    CanvasViewport(pageID: block.id,
                                   size: CGSize(width: paperSize.width * scale, height: paperSize.height * scale),
                                   zoom: 1, fitting: false, didZoom: { _ in },
                                   content: AnyView(document(scale: scale, magnification: 1)), attachmentBlockID: block.id)
                    #else
                    ScrollView([.horizontal, .vertical]) {
                        document(scale: scale, magnification: 1)
                            .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .top)
                    }
                    #endif
                }
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .background(.white)
        .onChange(of: textEnabled) { _, enabled in if !enabled { selectedTextID = nil } }
        .onChange(of: destination) { _, _ in selectedTextID = nil }
        .task(id: "\(block.attachmentContentIdentity)-\(page)") { await load() }
    }
    private func document(scale: CGFloat, magnification: Double) -> some View {
        ZStack(alignment: .topLeading) {
            if let pdfPage {
                VectorPDFPage(page: pdfPage, resolutionScale: resolutionScale * magnification)
                    .frame(width: paperSize.width * scale, height: paperSize.height * scale)
                    .allowsHitTesting(false)
            }
            if let image {
                Image(decorative: image.image, scale: 1)
                    .resizable().interpolation(.high)
                    .frame(width: paperSize.width * scale, height: paperSize.height * scale)
                    .allowsHitTesting(false)
                    .accessibilityLabel(block.assetName)
            }
            paper(scale: scale * magnification)
                .environment(\.canvasRenderScale, outerRenderScale * scale * magnification)
                .frame(width: paperSize.width, height: paperSize.height)
                .coordinateSpace(name: "attachment-\(destination)")
                .clipped()
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: paperSize.width * scale, height: paperSize.height * scale, alignment: .topLeading)
        }.frame(width: paperSize.width * scale, height: paperSize.height * scale, alignment: .topLeading)
    }
    private func paper(scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if html != nil { Color.white }
            if let html {
                AttachmentWebView(html: html, heightChanged: { height in
                    if abs(paperSize.height - height) > 1 { paperSize.height = height }
                }).frame(width: paperSize.width, height: paperSize.height)
            }
            if textEnabled {
                Color.clear.contentShape(Rectangle()).onTapGesture(count: 2) { point in
                    selectedTextID = store.insertPageText(at: point, paper: paperSize, destination: destination, clickCount: 2)
                }
            }
            ForEach(annotations.texts) { text in
                PageTextCard(store: store, destination: destination, annotation: text, editing: textEnabled,
                             selection: $selectedTextID, paper: paperSize, scale: scale * resolutionScale)
            }
            InkOverlay(data: annotations.ink, enabled: inkEnabled, options: store.inkOptions,
                       begin: { store.checkpoint(destination) }, save: { data, bounds in store.saveInk(data, bounds: bounds, to: destination) })
                .id("\(noteID)-\(block.id)-\(page)")
                .frame(width: paperSize.width, height: paperSize.height).allowsHitTesting(inkEnabled)
        }
    }
    private func load() async {
        pdfPage = nil; pdfDocument = nil; image = nil; html = nil; error = nil
        guard let url = store.attachmentURL(for: block) else { error = "附件不存在。"; return }
        guard FileManager.default.fileExists(atPath: url.path) else { error = "附件尚未下载，请联网后同步。"; return }
        if block.kind == .pdf {
            guard let document = PDFDocument(url: url), let pdfPage = document.page(at: page) else { error = "无法读取这一页 PDF。"; return }
            let size = PDFPageDrawing.size(of: pdfPage)
            guard size.width > 0, size.height > 0 else { error = "PDF 页面尺寸无效。"; return }
            paperSize = size
            pdfDocument = document; self.pdfPage = pdfPage
        } else if AttachmentFormat(filename: block.assetName) == .image {
            let result = await Task.detached(priority: .userInitiated) { Result { try AttachmentImage.load(from: url) } }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let value):
                // Stable document points keep photo annotations legible regardless
                // of camera resolution; the original image pixels remain untouched.
                paperSize = CGSize(width: 740, height: 740 * value.size.height / value.size.width)
                image = value
            case .failure(let failure): error = failure.localizedDescription
            }
        } else {
            guard let format = AttachmentFormat(filename: block.assetName) else { error = "暂不支持此文件。"; return }
            let result = await Task.detached { Result { try format.document(at: url) } }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let value): paperSize = CGSize(width: 740, height: 240); html = value
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}

@MainActor struct PageTextCard: View {
    @ObservedObject var store: AppStore
    let destination: InkDestination
    let annotation: PageTextAnnotation
    let editing: Bool
    @Binding var selection: UUID?
    let paper: CGSize
    let scale: CGFloat
    @GestureState private var movement = CGSize.zero
    @GestureState private var growth = CGSize.zero
    @ViewState private var source = false
    private var active: Bool { editing && selection == annotation.id }
    private var width: CGFloat { min(paper.width, max(growth == .zero ? 1 : 100, annotation.frame.width + growth.width)) }
    private var height: CGFloat { min(paper.height, max(growth == .zero ? 1 : 40, annotation.frame.height + growth.height)) }
    private var frame: Rect { Rect(annotation.frame.x + movement.width, annotation.frame.y + movement.height, width, height) }
    private var textBlock: Block {
        var block = Block(.text, frame: annotation.frame, text: annotation.text)
        block.id = annotation.id; block.fontSize = annotation.fontSize ?? 16; block.fontFamily = annotation.fontFamily
        return block
    }
    var body: some View {
        let handle = editing && selection == annotation.id
            ? CanvasItemGeometry.moveHandle(for: frame, paperWidth: paper.width, paperHeight: paper.height, size: BlockMoveHandle.hitSize) : nil
        CanvasItemPlacement(geometry: CanvasItemGeometry(body: frame, handle: handle)) { card } handle: {
            BlockMoveHandle(active: true).gesture(moveGesture)
        }
    }
    private var card: some View {
        ZStack(alignment: .topTrailing) {
            if active && source {
                RichTextEditor(block: textBlock, formatting: store.formatting, focus: {
                    selection = annotation.id; store.blockKeyboardFocus = false; store.blockSelection = destination.blockID
                },
                               checkpoint: { store.checkpoint(destination) }, changeStyle: { action in
                    store.editPage(destination) { page in
                        guard let i = page.texts.firstIndex(where: { $0.id == annotation.id }) else { return }
                        switch action {
                        case .grow(let step): page.texts[i].fontSize = min(96, max(10, (page.texts[i].fontSize ?? 16) + step))
                        case .font(let name): page.texts[i].fontFamily = name
                        default: break
                        }
                    }
                }, requestFocus: true) { _, value in
                    store.editPage(destination) { if let i = $0.texts.firstIndex(where: { $0.id == annotation.id }) { $0.texts[i].text = value } }
                }
            } else {
                MarkdownWebView(html: Markdown.document(annotation.text, size: annotation.fontSize ?? 16, font: annotation.fontFamily, tint: "blue"))
                    .allowsHitTesting(false)
            }
            if active {
                Button(source ? "预览" : "编辑") { source.toggle() }.buttonStyle(.plain).font(.caption2)
                    .padding(4).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
        }.frame(width: width, height: height).contentShape(Rectangle())
            .background(Palette.tint("blue").opacity(0.96), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                if active {
                    BlockBorder().fill(.clear, style: FillStyle(eoFill: true)).contentShape(BlockBorder(), eoFill: true)
                        .gesture(moveGesture)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if active {
                    ResizeCorner(length: min(24, max(16, min(width, height) * 0.1)), hitSize: CanvasItemGeometry.resizeCorner(for: frame, zoom: scale).width)
                        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("attachment-\(destination)"))
                            .updating($growth) { value, state, _ in state = value.translation }
                            .onEnded { commitFrame(resize: $0.translation) })
                }
            }
            .simultaneousGesture(TapGesture().onEnded { if editing { selection = annotation.id } })
            .onTapGesture(count: 2) { if editing { selection = annotation.id; source = true } }
            .onAppear { if active && annotation.text.isEmpty { source = true } }
            .contextMenu { Button("删除文字批注", role: .destructive) {
                store.checkpoint(destination); store.editPage(destination) { $0.texts.removeAll { $0.id == annotation.id } }
                if selection == annotation.id { selection = nil }
            } }
    }
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("attachment-\(destination)"))
            .updating($movement) { value, state, _ in state = value.translation }
            .onChanged { _ in selection = annotation.id }
            .onEnded { commitFrame(translation: $0.translation) }
    }
    private func commitFrame(translation: CGSize = .zero, resize: CGSize = .zero) {
        let width = min(paper.width, max(resize == .zero ? 1 : 100, annotation.frame.width + resize.width))
        let height = min(paper.height, max(resize == .zero ? 1 : 40, annotation.frame.height + resize.height))
        let rect = Rect(min(max(0, annotation.frame.x + translation.width), paper.width - width), min(max(0, annotation.frame.y + translation.height), paper.height - height), width, height)
        store.checkpoint(destination)
        store.editPage(destination) { if let i = $0.texts.firstIndex(where: { $0.id == annotation.id }) { $0.texts[i].frame = rect } }
    }
}
