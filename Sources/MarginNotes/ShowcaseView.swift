import SwiftUI
#if SWIFT_PACKAGE
import MarginCore
#endif

@MainActor struct ShowcaseHome: View {
    @ObservedObject var store: AppStore
    let catalog: ShowcaseCatalog
    private var available: [ShowcaseCatalog.Scenario] {
        catalog.scenarios.filter { scene in store.workspace.notes.contains { $0.id == scene.pageID && $0.parentID == catalog.rootID && !$0.deleted } }
    }
    private var additionalPages: [Note] {
        store.workspace.children(catalog.rootID).filter { page in !catalog.scenarios.contains { $0.pageID == page.id } }
    }
    static let defaultOverview = """
    **从资料到思考**

    # 打开一个场景，开始自己的工作。

    读讲义、构思论文、梳理代码、推进项目。每个场景都有完整内容，可以直接编辑、拖动和批注。
    """
    var body: some View {
        GeometryReader { geometry in
            ScrollView { content(columns: geometry.size.width >= 700 ? 2 : 1) }
                .background(Palette.desk)
        }
    }
    func content(columns: Int) -> some View {
            VStack(alignment: .leading, spacing: 26) {
                FolderOverview(store: store, noteID: catalog.rootID, defaultText: Self.defaultOverview).id(catalog.rootID)
                HStack(spacing: 18) {
                    Label("\(available.count) 个场景", systemImage: "square.grid.2x2")
                    Label("\(store.workspace.children(catalog.rootID).count) 个子项目", systemImage: "doc.on.doc")
                }.font(.system(size: 12)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: columns), spacing: 18) {
                    ForEach(available) { scene in
                        if let page = store.workspace.notes.first(where: { $0.id == scene.pageID }) {
                            Button { store.select(scene.pageID) } label: {
                                VStack(alignment: .leading, spacing: 14) {
                                    HStack {
                                        Image(systemName: scene.symbol).font(.system(size: 20)).foregroundStyle(Palette.accent)
                                        Spacer()
                                        Text("0\((catalog.scenarios.firstIndex(where: { $0.id == scene.id }) ?? 0) + 1)")
                                            .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.tertiary)
                                    }
                                    ShowcaseThumbnail(note: page).frame(height: 140)
                                    Text(page.title).font(.system(size: 21, weight: .semibold))
                                    Text(scene.subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
                                    Text(scene.detail).font(.system(size: 11)).foregroundStyle(.secondary).frame(minHeight: 32, alignment: .topLeading)
                                    HStack { Text("进入场景"); Spacer(); Image(systemName: "arrow.up.right") }
                                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accent)
                                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.background, in: RoundedRectangle(cornerRadius: 16))
                                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.accent.opacity(0.10), lineWidth: 1))
                            }.buttonStyle(.plain).accessibilityLabel("打开" + page.title)
                        }
                    }
                }
                if !additionalPages.isEmpty {
                    Text("其他子页面与文件夹").font(.headline)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: columns), spacing: 18) {
                        ForEach(additionalPages) { page in
                            Button { store.select(page.id) } label: {
                                VStack(alignment: .leading, spacing: 12) {
                                    Label(page.title, systemImage: page.isFolder ? "folder" : "doc.text").font(.headline)
                                    if !page.summary.isEmpty { Text(page.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
                                    Text("\(store.workspace.children(page.id).count) 个子项目").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                                    .background(.background, in: RoundedRectangle(cornerRadius: 14))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "hand.point.up.left").font(.title3).foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("从三个小动作开始").font(.system(size: 15, weight: .semibold))
                        Text("单击选中并拖动；双击文字开始编辑；点“相关页面”沿着同一个主题继续整理。")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                Text("示例均为自制演示内容。你的修改会保留，重新打开不会覆盖。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 1120, alignment: .leading).frame(maxWidth: .infinity)
    }
}

/// A live miniature of the actual block geometry, without starting hidden editors.
private struct ShowcaseThumbnail: View {
    let note: Note
    var body: some View {
        Canvas { context, size in
            let scale = size.width / note.width
            for block in note.blocks where block.frame.y * scale < size.height {
                let r = CGRect(x: block.frame.x * scale, y: block.frame.y * scale,
                               width: block.frame.width * scale, height: block.frame.height * scale)
                let shape = Path(roundedRect: r, cornerRadius: 3)
                context.fill(shape, with: .color(block.tint == "blue" ? Palette.accent.opacity(0.12) : .white))
                context.stroke(shape, with: .color(Palette.accent.opacity(0.15)), lineWidth: 0.6)
                let label: String
                switch block.kind {
                case .pdf: label = "PDF  /  " + block.assetName
                case .file: label = block.assetName
                case .formula: label = "公式推导"
                default: label = String(block.text.replacingOccurrences(of: "#", with: "").split(separator: "\n").first ?? "")
                }
                context.draw(Text(label).font(.system(size: 7, weight: .medium)).foregroundStyle(Palette.ink),
                             in: r.insetBy(dx: 5, dy: 5))
            }
        }.background(Color.white.opacity(0.45)).clipShape(RoundedRectangle(cornerRadius: 9))
            .accessibilityLabel("当前场景的内容块版面预览")
    }
}

@MainActor struct ShowcaseGuide: View {
    @ObservedObject var store: AppStore
    let scenario: ShowcaseCatalog.Scenario
    var body: some View {
        HStack(spacing: 14) {
            Button { store.openShowcase() } label: { Label("全部场景", systemImage: "square.grid.2x2") }
                .buttonStyle(.plain).foregroundStyle(Palette.accent)
            Divider().frame(height: 16)
            Text(scenario.step).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            Menu("相关页面") {
                ForEach(scenario.pages, id: \.self) { id in
                    if let page = store.workspace.notes.first(where: { $0.id == id && !$0.deleted }) {
                        Button(page.title) { store.select(id) }
                    }
                }
            }
        }.font(.system(size: 12)).padding(.horizontal, 16).padding(.vertical, 9)
            .background(Palette.accent.opacity(0.055))
    }
}
