import SwiftUI
#if SWIFT_PACKAGE
import MarginCore
#endif

@MainActor struct BacklinksView: View {
    @ObservedObject var store: AppStore
    let noteID: UUID
    @ViewState private var links: [PageBacklink] = []
    @ViewState private var loading = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("反向链接", systemImage: "link").font(.headline)
                Spacer(); if loading { ProgressView().controlSize(.small) } else { Text("\(links.count)").font(.caption).foregroundStyle(.secondary) }
            }
            if links.isEmpty && !loading {
                Text("暂无其他页面链接到这里。输入 [[页面名]] 可建立页面链接。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(links) { link in
                Button { store.revealSearchResult(noteID: link.sourceNoteID, blockID: link.sourceBlockID, annotationPage: link.annotationPage) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(link.title.isEmpty ? "未命名" : link.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(link.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text(link.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.vertical, 3)
            }
        }.task(id: BacklinkRefreshKey(noteID: noteID, revisions: store.workspace.notes.map(\.revision))) {
            loading = true
            let snapshot = store.workspace, target = noteID
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { WikiLinks.backlinks(to: target, in: snapshot) }.value
            guard !Task.isCancelled else { return }; links = result; loading = false
        }
    }
    private struct BacklinkRefreshKey: Equatable { let noteID: UUID; let revisions: [UUID] }
}

@MainActor struct PageTagsEditor: View {
    @ObservedObject var store: AppStore
    let noteID: UUID
    @ViewState private var draft = ""
    private var tags: [String] { store.workspace.notes.first(where: { $0.id == noteID })?.tags ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("标签", systemImage: "tag").font(.headline)
            if !tags.isEmpty { Text(tags.map { "#" + $0 }.joined(separator: "  ")).font(.caption).foregroundStyle(Palette.accent) }
            HStack {
                TextField("用逗号分隔标签", text: $draft).textFieldStyle(.roundedBorder).onSubmit(save)
                Button("保存", action: save).disabled(WorkspaceSearch.normalizedTags(draft) == tags)
            }
        }.onAppear { draft = tags.joined(separator: ", ") }
            .onChange(of: noteID) { _, _ in draft = tags.joined(separator: ", ") }
            .onChange(of: tags) { _, value in draft = value.joined(separator: ", ") }
    }
    private func save() { store.setTags(noteID: noteID, tags: WorkspaceSearch.normalizedTags(draft)) }
}
