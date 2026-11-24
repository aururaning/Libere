import SwiftUI
#if SWIFT_PACKAGE
import MarginCore
#endif

@MainActor struct FeatureGuideView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var query = ""
    @ViewState private var selectedSectionID: String? = "start"
    private let loaded: Result<FeatureGuideCatalog, Error>

    init(store: AppStore, catalog: FeatureGuideCatalog? = nil) {
        self.store = store
        loaded = catalog.map(Result.success) ?? Result { try FeatureGuideCatalog.load() }
    }
    var body: some View {
        Group {
            switch loaded {
            case .success(let catalog): guide(catalog)
            case .failure:
                VStack(spacing: 18) {
                    ContentUnavailableView("暂时无法读取功能教程", systemImage: "book.closed", description: Text("请确认正在使用完整的 Libere 应用。已有资料不受影响。"))
                    Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                }.padding(28)
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, idealWidth: 1080, minHeight: 540, idealHeight: 740)
        #else
        .frame(minHeight: 400)
        #endif
        .background(Palette.desk)
    }
    private func guide(_ catalog: FeatureGuideCatalog) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(catalog.title).font(.system(size: 28, weight: .bold))
                    Text(catalog.subtitle).font(.system(size: 15)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.borderedProminent)
            }.padding(.horizontal, 26).padding(.top, 24).padding(.bottom, 20)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索功能、操作或快捷键", text: $query).textFieldStyle(.plain)
                    .accessibilityIdentifier("feature-guide-search")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("清除教程搜索")
                }
                Text("\(catalog.topicCount) 项功能").font(.system(size: 13)).foregroundStyle(.secondary)
            }.padding(12).background(.background, in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 26).padding(.bottom, 18)
            Divider()
            GeometryReader { geometry in
                let matches = catalog.matchingSections(query: query)
                if geometry.size.width >= 820 {
                    HStack(spacing: 0) {
                        navigation(matches, horizontal: false).frame(width: 220)
                        Divider()
                        articles(matches)
                    }
                } else {
                    VStack(spacing: 0) {
                        navigation(matches, horizontal: true)
                        Divider()
                        articles(matches)
                    }
                }
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { footerContents }
                VStack(alignment: .leading, spacing: 10) { footerContents }
            }.padding(.horizontal, 26).padding(.vertical, 14)
        }
        .onChange(of: query) { _, value in selectedSectionID = value.isEmpty ? catalog.sections.first?.id : nil }
        .accessibilityIdentifier("feature-guide")
    }
    @ViewBuilder private var footerContents: some View {
                Text("从「笔记 → 功能教程」随时回来查阅。覆盖升级不会重复弹出。").font(.system(size: 13)).foregroundStyle(.secondary)
                Button("打开示例场景") { store.openShowcase(); dismiss() }.buttonStyle(.bordered)
    }
    private func navigation(_ sections: [FeatureGuideCatalog.Section], horizontal: Bool) -> some View {
        ScrollView(horizontal ? .horizontal : .vertical) {
            if horizontal {
                HStack(spacing: 8) { navigationItems(sections) }.padding(12)
            } else {
                VStack(alignment: .leading, spacing: 5) { navigationItems(sections) }.padding(14)
            }
        }.background(Palette.accent.opacity(0.035))
    }
    @ViewBuilder private func navigationItems(_ sections: [FeatureGuideCatalog.Section]) -> some View {
        if !query.isEmpty {
            navigationButton(id: nil, title: "全部搜索结果", symbol: "line.3.horizontal.decrease.circle", count: sections.reduce(0) { $0 + $1.topics.count })
        }
        ForEach(sections) { section in
            navigationButton(id: section.id, title: section.title, symbol: section.symbol, count: section.topics.count)
        }
    }
    private func navigationButton(id: String?, title: String, symbol: String, count: Int) -> some View {
        Button { selectedSectionID = id } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20)
                Text(title).font(.system(size: 14, weight: selectedSectionID == id ? .semibold : .regular))
                Spacer(minLength: 12)
                Text("\(count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            }.padding(.horizontal, 12).padding(.vertical, 11)
                .foregroundStyle(selectedSectionID == id ? Palette.accent : .primary)
                .background(selectedSectionID == id ? Palette.accent.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("\(title)，\(count) 项功能")
    }
    private func articles(_ matches: [FeatureGuideCatalog.Section]) -> some View {
        let visible = selectedSectionID.flatMap { id in matches.first { $0.id == id }.map { [$0] } } ?? matches
        return ScrollViewReader { proxy in
            ScrollView {
                if visible.isEmpty {
                    ContentUnavailableView.search(text: query).padding(.top, 70)
                } else {
                    VStack(alignment: .leading, spacing: 28) {
                        Color.clear.frame(height: 0).id("feature-guide-top")
                        ForEach(visible) { section in
                            VStack(alignment: .leading, spacing: 18) {
                                VStack(alignment: .leading, spacing: 9) {
                                    Label(section.title, systemImage: section.symbol).font(.system(size: 25, weight: .semibold)).foregroundStyle(Palette.ink)
                                    Text(section.summary).font(.system(size: 16)).foregroundStyle(.secondary)
                                }
                                ForEach(section.topics) { topic in FeatureGuideTopicCard(topic: topic) }
                            }.id(section.id)
                        }
                    }.padding(.horizontal, 28).padding(.bottom, 28).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.onChange(of: selectedSectionID) { _, _ in proxy.scrollTo("feature-guide-top", anchor: .top) }
                .onChange(of: query) { _, _ in proxy.scrollTo("feature-guide-top", anchor: .top) }
        }
    }
}

@MainActor private struct FeatureGuideTopicCard: View {
    let topic: FeatureGuideCatalog.Topic
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 14) {
                Text(topic.title).font(.system(size: 19, weight: .semibold))
                Spacer(minLength: 0)
                if !topic.shortcuts.isEmpty {
                    Text(topic.shortcuts.joined(separator: " · ")).font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.accent).padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            Text(topic.summary).font(.system(size: 16)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(topic.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.accent).frame(width: 16)
                        Text(step).font(.system(size: 15)).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.textSelection(.enabled)
            if let note = topic.note, !note.isEmpty {
                Text(note).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.accent.opacity(0.09), lineWidth: 1))
            .accessibilityElement(children: .contain)
    }
}

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
            ScrollView { content(columns: geometry.size.width >= 700 ? 2 : 1)
                    .background(FolderWheelRouter(store: store, pageID: catalog.rootID).frame(width: 0, height: 0))
            }
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
