import SwiftUI

#if os(macOS)
@MainActor final class RenameNameField: CanvasTitleField {
    private var selectedInitially = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !selectedInitially else { return }; selectedInitially = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if let owner = self.titleOwner, let noteID = self.titlePageID, owner.renaming != noteID { return }
            window.makeFirstResponder(self); self.currentEditor()?.selectAll(nil)
        }
    }
}
@MainActor struct SidebarNameField: NSViewRepresentable {
    @Binding var text: String
    let commit: () -> Bool
    var cancel: () -> Void = {}
    var owner: AppStore? = nil
    var noteID: UUID? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> RenameNameField {
        let field = RenameNameField(); field.stringValue = text; field.isBordered = false; field.drawsBackground = false
        field.focusRingType = .none; field.font = .systemFont(ofSize: 13); field.delegate = context.coordinator
        field.target = context.coordinator; field.action = #selector(Coordinator.accept)
        field.titleOwner = owner; field.titlePageID = noteID
        field.finishForCanvas = { [weak coordinator = context.coordinator, weak field] in
            guard let coordinator, let field else { return true }
            return coordinator.save(field, finishComposition: true)
        }
        field.setAccessibilityLabel("页面名称，回车保存")
        return field
    }
    func updateNSView(_ field: RenameNameField, context: Context) {
        context.coordinator.parent = self
        field.titleOwner = owner; field.titlePageID = noteID
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { field.stringValue = text }
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SidebarNameField
        private var saving = false
        init(_ parent: SidebarNameField) { self.parent = parent }
        private var ownsDraft: Bool { parent.noteID.map { parent.owner?.renaming == $0 } ?? true }
        func controlTextDidChange(_ notification: Notification) {
            guard ownsDraft, let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField { _ = save(field) }
        }
        @objc func accept(_ field: NSTextField) { _ = save(field) }
        func save(_ field: NSTextField, finishComposition: Bool = false) -> Bool {
            guard !saving, ownsDraft else { return true }
            saving = true; defer { saving = false }
            if finishComposition, let editor = field.currentEditor() as? NSTextView {
                editor.unmarkText(); field.stringValue = editor.string
            }
            guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return false }
            parent.text = field.stringValue
            return parent.commit()
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            if command == #selector(NSResponder.cancelOperation(_:)) { parent.cancel(); return true }
            return false
        }
    }
}
#else
@MainActor final class RenameNameField: UITextField {
    private var selectedInitially = false
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !selectedInitially else { return }; selectedInitially = true
        DispatchQueue.main.async { [weak self] in self?.becomeFirstResponder(); self?.selectAll(nil) }
    }
}
@MainActor struct SidebarNameField: UIViewRepresentable {
    @Binding var text: String
    let commit: () -> Bool
    var cancel: () -> Void = {}
    var owner: AppStore? = nil
    var noteID: UUID? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> RenameNameField {
        let field = RenameNameField(); field.text = text; field.delegate = context.coordinator; field.returnKeyType = .done
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.accessibilityLabel = "页面名称，回车保存"; return field
    }
    func updateUIView(_ field: RenameNameField, context: Context) { context.coordinator.parent = self; if field.text != text && field.markedTextRange == nil { field.text = text } }
    @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SidebarNameField
        init(_ parent: SidebarNameField) { self.parent = parent }
        private var ownsDraft: Bool { parent.noteID.map { parent.owner?.renaming == $0 } ?? true }
        @objc func changed(_ field: UITextField) { if ownsDraft { parent.text = field.text ?? "" } }
        func textFieldShouldReturn(_ field: UITextField) -> Bool { guard !ownsDraft || parent.commit() else { return false }; field.resignFirstResponder(); return true }
        func textFieldDidEndEditing(_ field: UITextField) { if ownsDraft { _ = parent.commit() } }
    }
}
#endif
