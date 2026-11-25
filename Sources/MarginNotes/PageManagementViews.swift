import SwiftUI
#if SWIFT_PACKAGE
import MarginCore
#endif

/// The draft is owned by this field's immutable page identity, not the current
/// selection. IME candidates never reach workspace persistence.
#if os(macOS)
@MainActor struct PageTitleField: NSViewRepresentable {
    let noteID: UUID
    let title: String
    let commit: (UUID, String) -> Bool
    var owner: AppStore? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> CanvasTitleField {
        let field = CanvasTitleField(); field.stringValue = title; field.isBordered = false; field.drawsBackground = false
        field.focusRingType = .none; field.font = .systemFont(ofSize: 23, weight: .semibold)
        field.delegate = context.coordinator; field.target = context.coordinator; field.action = #selector(Coordinator.submit)
        field.titleOwner = owner; field.titlePageID = noteID
        field.finishForCanvas = { [weak coordinator = context.coordinator, weak field] in
            guard let coordinator, let field else { return true }
            return coordinator.finishForCanvas(field)
        }
        field.setAccessibilityLabel("页面标题，回车保存"); return field
    }
    func updateNSView(_ field: CanvasTitleField, context: Context) {
        context.coordinator.parent = self
        field.titleOwner = owner; field.titlePageID = noteID
        if !context.coordinator.editing && !context.coordinator.rejectedDraft
            && (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { field.stringValue = title }
    }
    static func dismantleNSView(_ field: CanvasTitleField, coordinator: Coordinator) {
        guard coordinator.editing else { return }
        if let editor = field.currentEditor() as? NSTextView { editor.unmarkText(); field.stringValue = editor.string }
        coordinator.save(field)
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PageTitleField
        var editing = false
        var baseline: String
        var rejectedDraft = false
        private var saving = false
        init(_ parent: PageTitleField) { self.parent = parent; baseline = parent.title }
        func controlTextDidBeginEditing(_ notification: Notification) { editing = true; baseline = parent.title }
        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField { save(field) }
            editing = false
        }
        @objc func submit(_ field: NSTextField) { save(field) }
        @discardableResult func save(_ field: NSTextField, finishComposition: Bool = false) -> Bool {
            guard !saving else { return true }
            saving = true; defer { saving = false }
            if finishComposition, let editor = field.currentEditor() as? NSTextView {
                editor.unmarkText(); field.stringValue = editor.string
            }
            guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return false }
            let draft = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard draft != baseline else { rejectedDraft = false; return true }
            guard parent.commit(parent.noteID, draft) else { rejectedDraft = true; return false }
            field.stringValue = draft; baseline = draft; rejectedDraft = false; return true
        }
        func finishForCanvas(_ field: NSTextField) -> Bool {
            let accepted = save(field, finishComposition: true)
            if accepted { editing = false }
            return accepted
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            if command == #selector(NSResponder.cancelOperation(_:)), let field = control as? NSTextField {
                field.stringValue = parent.title; baseline = parent.title; rejectedDraft = false; editing = false
                field.window?.makeFirstResponder(nil); return true
            }
            return false
        }
    }
}
#else
@MainActor struct PageTitleField: UIViewRepresentable {
    let noteID: UUID
    let title: String
    let commit: (UUID, String) -> Bool
    var owner: AppStore? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField(); field.text = title; field.font = .systemFont(ofSize: 23, weight: .semibold)
        field.delegate = context.coordinator; field.returnKeyType = .done
        field.accessibilityLabel = "页面标题，回车保存"; return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if !field.isFirstResponder && field.markedTextRange == nil { field.text = title }
    }
    static func dismantleUIView(_ field: UITextField, coordinator: Coordinator) {
        field.unmarkText(); coordinator.save(field)
    }
    @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: PageTitleField
        var baseline: String
        init(_ parent: PageTitleField) { self.parent = parent; baseline = parent.title }
        func textFieldDidBeginEditing(_ field: UITextField) { baseline = parent.title }
        func save(_ field: UITextField) {
            guard field.markedTextRange == nil else { return }
            let draft = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if draft != baseline, parent.commit(parent.noteID, draft) { field.text = draft; baseline = draft }
        }
        func textFieldShouldReturn(_ field: UITextField) -> Bool { save(field); field.resignFirstResponder(); return true }
        func textFieldDidEndEditing(_ field: UITextField) { save(field) }
    }
}
#endif

@MainActor struct PurgePagesSheet: View {
    @ObservedObject var store: AppStore
    let request: AppStore.PurgeRequest
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("永久清除 \(request.pageIDs.count) 个页面？").font(.title2.bold())
            Text("将移除这些页面的文字、布局、手写与批注记录，并清理对应撤销记录。此操作不能撤销。")
            Text("资料库文件夹中的 PDF、图片、Notebook 等原文件会完整保留。其他页面对同一文件的引用不受影响。")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { store.purgeRequest = nil }.keyboardShortcut(.cancelAction)
                Button("永久清除页面记录", role: .destructive) { store.confirmPurge() }
            }
        }.padding(24).frame(width: 450)
    }
}

@MainActor struct MovePageSheet: View {
    @ObservedObject var store: AppStore
    let pageID: UUID
    @ViewState private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("移动页面与所属原文件").font(.title2.bold()); Spacer(); Button("取消") { store.movingPageID = nil } }
            TextField("搜索目标页面或文件夹", text: $query).textFieldStyle(.roundedBorder)
            List {
                Button("知识库根目录") { move(nil) }
                ForEach(store.workspace.moveTargets(for: pageID).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { note in
                    Button { move(note.id) } label: { Label(note.title, systemImage: note.isFolder ? "folder" : "doc.text") }
                }
            }
        }.padding(24).frame(minWidth: 440, minHeight: 400)
    }
    private func move(_ parent: UUID?) { if store.placePage(pageID, at: .inside(parent)) { store.movingPageID = nil } }
}
