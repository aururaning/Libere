import SwiftUI
#if SWIFT_PACKAGE
import MarginCore
#endif

/// Folders and the showcase landing page share one editable, persistent introduction.
@MainActor struct FolderOverview: View {
    @ObservedObject var store: AppStore
    let noteID: UUID
    var defaultText = ""
    @ViewState private var previewHeight = 180.0
    @ViewState private var editorHeight = 260.0

    private var note: Note? { store.workspace.notes.first { $0.id == noteID && $0.isFolder && !$0.deleted } }
    private var source: String { note?.folderOverview ?? defaultText }
    private var editing: Bool { store.folderOverviewEditingID == noteID }
    private var children: [Note] { store.workspace.children(noteID) }

    var body: some View {
        if note != nil {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("说明与分类", systemImage: "text.alignleft")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button(editing ? "完成" : "编辑介绍") {
                        if editing { store.finishFolderOverviewEditing(noteID: noteID) }
                        else { store.beginFolderOverviewEditing(noteID: noteID) }
                    }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                        .accessibilityLabel(editing ? "完成编辑文件夹介绍" : "编辑文件夹介绍")
                }
                if editing {
                    editingTools
                    GeometryReader { geometry in
                        let block = editorBlock(width: geometry.size.width)
                        RichTextEditor(block: block, formatting: store.formatting,
                            focus: { store.blockKeyboardFocus = false; store.sidebarHasFocus = false },
                            checkpoint: {}, editable: true, requestFocus: true,
                            measuredHeight: { measured, height in
                                guard measured.id == noteID, measured.text == source,
                                      height.isFinite, height > 0 else { return }
                                editorHeight = min(600, max(260, ceil(height + 16)))
                            }) { _, text in
                                store.updateFolderOverview(noteID: noteID, text: text)
                            }
                    }.frame(height: editorHeight)
                        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                    Text("用标题和列表整理分类，也可以插入子页面链接，完成后点击跳转。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button { store.beginFolderOverviewEditing(noteID: noteID) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("给这个文件夹写一段介绍").font(.headline)
                            Text("写下说明、分类标题或页面目录，让里面的资料更容易找到。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("添加文件夹介绍")
                } else {
                    preview(source)
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
                .onDisappear { store.finishFolderOverviewEditing(noteID: noteID) }
                .onChange(of: noteID) { _, _ in previewHeight = 180; editorHeight = 260 }
        }
    }

    private var editingTools: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                Button("分类标题", systemImage: "textformat.size") { insert("\n\n## 新分类\n\n") }
                Button("列表", systemImage: "list.bullet") { insert("\n- ") }
                if !children.isEmpty {
                    Menu("插入子页面", systemImage: "link") {
                        ForEach(children) { child in
                            Button(child.title) { insert(PageLink.markdown(title: child.title, id: child.id)) }
                        }
                    }
                    Button("插入目录", systemImage: "list.bullet.indent") {
                        insert("\n\n## 目录\n" + children.map { "- " + PageLink.markdown(title: $0.title, id: $0.id) }.joined(separator: "\n") + "\n")
                    }
                }
            }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.accent)
        }
    }

    private func editorBlock(width: Double) -> Block {
        var block = Block(.text, frame: Rect(0, 0, max(100, width), editorHeight), text: source)
        block.id = noteID; block.fontSize = 16; block.textFormat = .markdown
        return block
    }

    private func preview(_ value: String) -> some View {
        GeometryReader { geometry in
            MarkdownWebView(html: Markdown.document(value, size: 18), layoutWidth: geometry.size.width,
                measuredHeight: { width, height in
                    guard value == source, abs(width - geometry.size.width) < 2,
                          height.isFinite, height > 0 else { return }
                    previewHeight = min(100_000, max(56, ceil(height)))
                }, openPage: { id in
                    guard store.workspace.notes.contains(where: { $0.id == id && !$0.deleted }) else {
                        store.message = "这个页面已移入回收站或不存在。"; return
                    }
                    store.select(id)
                })
        }.frame(height: previewHeight)
    }

    /// Insert through the native editor so selection, native undo and IME stay intact.
    private func insert(_ text: String) {
        guard editing else { return }
        if store.formatting.blockID == noteID, let view = store.formatting.view {
            view.unmarkText()
            #if os(macOS)
            view.insertText(text, replacementRange: view.selectedRange())
            view.window?.makeFirstResponder(view)
            #else
            view.insertText(text); view.becomeFirstResponder()
            #endif
            store.formatting.didChange?()
        } else {
            store.updateFolderOverview(noteID: noteID, text: source + text)
        }
    }
}
