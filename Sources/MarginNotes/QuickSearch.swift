import SwiftUI
#if SWIFT_PACKAGE
import MarginCore
#endif

@MainActor final class QuickSearchModel: ObservableObject {
    @Published private(set) var results: [WorkspaceSearchResult] = []
    @Published private(set) var isLoading = false
    private var index: WorkspaceSearch?
    private var query = ""
    private var generation = UUID()
    private var searchID = UUID()
    private var buildTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    func prepare(_ workspace: Workspace) {
        buildTask?.cancel(); searchTask?.cancel(); generation = UUID(); isLoading = true
        let request = generation
        buildTask = Task { [weak self] in
            let index = await Task.detached(priority: .userInitiated) { WorkspaceSearch(workspace: workspace) }.value
            guard !Task.isCancelled, let self, self.generation == request else { return }
            self.index = index; self.search(self.query)
        }
    }
    func search(_ value: String) {
        query = value; searchTask?.cancel(); searchID = UUID()
        guard let index else { return }
        isLoading = true
        let request = searchID
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) { index.results(query: value) }.value
            guard !Task.isCancelled, let self, self.searchID == request else { return }
            self.results = results; self.isLoading = false
        }
    }
    func cancel() { buildTask?.cancel(); searchTask?.cancel(); generation = UUID(); searchID = UUID() }
}

@MainActor struct QuickSearchView: View {
    @ObservedObject var store: AppStore
    @StateObject private var model = QuickSearchModel()
    @ViewState private var query = ""
    @ViewState private var selected: String?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索页面、正文、公式、文件名或 #标签", text: $query)
                    .textFieldStyle(.plain).focused($focused).onSubmit(openSelected)
                    .accessibilityLabel("搜索资料库")
                if model.isLoading { ProgressView().controlSize(.small) }
                Button("关闭") { close() }.keyboardShortcut(.cancelAction)
            }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "最近编辑的页面" : "\(model.results.count) 条匹配结果")
                .font(.caption).foregroundStyle(.secondary)
            if model.results.isEmpty && !model.isLoading {
                ContentUnavailableView.search(text: query).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selected) {
                    ForEach(model.results) { result in
                        Button { open(result) } label: { SearchResultRow(result: result) }
                            .buttonStyle(.plain).tag(result.id).padding(.vertical, 4)
                    }
                }.listStyle(.plain)
            }
            Text("搜索已保存的页面与批注；文件内容需先在页面中记录。输入 #标签 可筛选。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 520, idealWidth: 700, minHeight: 430, idealHeight: 560)
            .task(id: store.workspace.notes.map(\.revision)) { model.prepare(store.workspace); focused = true }
            .onChange(of: query) { _, value in model.search(value) }
            .onChange(of: model.results) { _, results in
                if !results.contains(where: { $0.id == selected }) { selected = results.first?.id }
            }
            .onDisappear { model.cancel() }
            #if os(macOS)
            .onMoveCommand { direction in
                guard !model.results.isEmpty, direction == .up || direction == .down else { return }
                let current = model.results.firstIndex { $0.id == selected } ?? 0
                let index = min(model.results.count - 1, max(0, current + (direction == .down ? 1 : -1)))
                selected = model.results[index].id
            }
            #endif
    }
    private func openSelected() { if let result = model.results.first(where: { $0.id == selected }) ?? model.results.first { open(result) } }
    private func close() { store.showingQuickSearch = false; dismiss() }
    private func open(_ result: WorkspaceSearchResult) {
        close(); store.revealSearchResult(noteID: result.noteID, blockID: result.blockID, annotationPage: result.annotationPage)
    }
}

@MainActor private struct SearchResultRow: View {
    let result: WorkspaceSearchResult
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(result.title.isEmpty ? "未命名" : result.title).font(.headline).lineLimit(1)
                Spacer()
                Text(result.kind.label + (result.annotationPage.map { " · 第 \($0 + 1) 页" } ?? "")).font(.caption).foregroundStyle(.secondary)
            }
            if result.kind != .title { Text(result.snippet).font(.subheadline).lineLimit(2) }
            Text(result.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

@MainActor extension AppStore {
    func revealSearchResult(noteID: UUID, blockID: UUID? = nil, annotationPage: Int? = nil) {
        guard workspace.notes.contains(where: { $0.id == noteID && !$0.deleted }) else { message = "这个页面已移入回收站或不存在。"; return }
        select(noteID)
        guard selection == noteID else { return }
        guard let blockID, let block = note?.blocks.first(where: { $0.id == blockID }) else { return }
        selectBlock(blockID); revealBlockID = blockID
        if let page = annotationPage, block.kind.hasAttachment { openAttachment(block, page: page) }
    }
}
