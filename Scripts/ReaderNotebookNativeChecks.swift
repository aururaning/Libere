import Foundation
import SwiftUI

/// Exercise a read-only transition before the input method has flushed its real
/// marked text. Current AppKit normally clears composition in its native setter.
@MainActor private final class ClosingMarkedTextView: NSTextView {
    var reportsReadOnly = false
    override var isEditable: Bool {
        get { !reportsReadOnly && super.isEditable }
        set { super.isEditable = newValue }
    }
}

@MainActor func runReaderNotebookNativeChecks() async throws -> Int {
    var count = 0
    func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereReaderNotebook-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data(##"{"nbformat":4,"metadata":{"custom":"keep"},"cells":[{"id":"code","cell_type":"code","source":"x=1","metadata":{},"outputs":[]},{"id":"md","cell_type":"markdown","source":"# 标题","metadata":{}}]}"##.utf8)
    let legacy = try NotebookSession(data: Data(#"{"nbformat":4,"cells":[{"cell_type":"code","source":"A","metadata":{},"outputs":[]},{"cell_type":"code","source":"B","metadata":{},"outputs":[]}]}"#.utf8), directory: root) { _ in }
    let firstID = legacy.document.cells[0].id, secondID = legacy.document.cells[1].id, originalGeneration = legacy.structureGeneration
    check(legacy.edit("A edited", cellID: firstID, generation: originalGeneration), "A live cell-ID editor writes its own source")
    var lateCalls = 0, acceptedLateIME = false
    let oldBlock = Block(.text, frame: Rect(0,0,380,240), text: "A edited")
    let oldEditor = RichTextEditor(block: oldBlock, formatting: TextFormatting(), focus: {}, checkpoint: {}) { _, text in
        lateCalls += 1; acceptedLateIME = legacy.edit(text, cellID: firstID, generation: originalGeneration)
    }
    let oldCoordinator = oldEditor.makeCoordinator(), oldText = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 240))
    oldText.isRichText = false; oldText.string = "A edited"; oldText.delegate = oldCoordinator
    oldText.setMarkedText("迟到输入", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: 0, length: 8))
    legacy.moveCell(0, by: 1)
    check(legacy.document.cells.map(\.id) == [secondID, firstID], "The first legacy-cell reorder preserves both runtime identities")
    let movedBytes = try legacy.document.serialized(), oldScroll = NSScrollView(); oldScroll.documentView = oldText
    RichTextEditor.dismantleNSView(oldScroll, coordinator: oldCoordinator)
    check(lateCalls == 1 && !acceptedLateIME && (try? legacy.document.serialized()) == movedBytes,
          "A late marked-text dismantle callback cannot overwrite the new occupant of the old index")
    let movedGeneration = legacy.structureGeneration
    check(legacy.edit("A current", cellID: firstID, generation: movedGeneration) && legacy.document.cells[0].source == "B" && legacy.document.cells[1].source == "A current",
          "A fresh editor follows its stable cell identity to the new position")
    legacy.deleteCell(1)
    check(!legacy.edit("deleted stale", cellID: firstID, generation: movedGeneration)
          && !legacy.edit("deleted stale", cellID: firstID, generation: legacy.structureGeneration) && legacy.document.cells[0].source == "B",
          "Deleted cell callbacks cannot edit a surviving cell even with a current generation")
    legacy.undoCellChange()
    check(!legacy.edit("pre-undo stale", cellID: firstID, generation: movedGeneration) && legacy.document.cells[1].source == "A current",
          "Undo invalidates callbacks created before the restored structure")
    let beforeConversion = legacy.structureGeneration
    legacy.convertCell(1, to: "markdown")
    check(!legacy.edit("old code editor", cellID: firstID, generation: beforeConversion) && legacy.document.cells[1].kind == "markdown" && legacy.document.cells[1].source == "A current",
          "Conversion rejects callbacks from the previous editor kind")
    let convertedGeneration = legacy.structureGeneration
    check(legacy.edit("new markdown", cellID: firstID, generation: convertedGeneration), "The newly created converted-cell editor remains writable")
    legacy.undoCellChange()
    check(!legacy.edit("late converted editor", cellID: firstID, generation: convertedGeneration) && legacy.document.cells[1].kind == "code" && legacy.document.cells[1].source == "A current",
          "Undoing conversion cannot be overwritten by a retired Markdown editor")
    legacy.save()
    var writes = 0
    let session = try NotebookSession(data: bytes, directory: root) { _ in writes += 1 }
    session.busy = true; session.edit("forbidden", at: 0); session.deleteCell(0); session.insertCell(at: 0); session.moveCell(0, by: 1); session.convertCell(0, to: "markdown")
    check(session.document.cells.count == 2 && session.document.cells[0].source == "x=1" && session.document.cells[0].kind == "code", "Busy sessions reject edits and all structural mutations")
    session.busy = false; session.edit("x=2", at: 0); check(session.save(), "Explicit Notebook save succeeds")
    let savedWrites = writes
    session.document.setSource("unscheduled later change", at: 0)
    try await Task.sleep(nanoseconds: 450_000_000)
    check(writes == savedWrites && session.hasUnsavedChanges, "An explicit save cancels the old debounce instead of saving unrelated later state")
    session.save(); session.deleteCell(0)
    check(session.document.cells.count == 1 && session.cellUndoAvailable, "Cell deletion is saved with an in-memory structural undo")
    session.undoCellChange(); check(session.document.cells.count == 2 && session.document.cells[0].source == "unscheduled later change", "Structural undo restores deleted cells and source")
    session.runAndAdvance(1)
    check(session.document.cells.count == 3 && session.focusedCellID == session.document.cells[2].id, "Shift Enter on Markdown adds/focuses the following cell without requiring a kernel")
    session.moveCell(2, by: -1); check(session.document.cells[1].kind == "code", "Cell movement updates the live notebook")
    session.convertCell(1, to: "markdown"); check(session.document.cells[1].kind == "markdown", "Code/Markdown conversion preserves live structure")

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 750), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: NotebookEditor(session: session, filename: "test.ipynb", documentZoom: .constant(2)))
    window.contentView = host
    defer { window.contentView = nil }
    func settle() async throws { for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 15_000_000) } }
    try await settle()
    guard let source = descendants(host).compactMap({ $0 as? SourceInputHost }).first,
          let text = source.textView(in: source.host) else { preconditionFailure("Missing production Notebook source input") }
    check(text.isEditable, "An idle Notebook cell has an editable native text view")
    var parent: NSView? = source; var insideZoom = false
    while let value = parent { if value is CanvasScrollView { insideZoom = true }; parent = value.superview }
    check(insideZoom, "Only the document area hosts Notebook source editors inside the reader viewport")
    session.busy = true; try await settle()
    check(!text.isEditable, "Busy state reaches the actual NSTextView and prevents source editing")
    session.busy = false; try await settle()
    check(text.isEditable, "Finishing execution restores native input")
    var advanced = 0; source.run = { advanced += 1 }; window.makeFirstResponder(text)
    func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }
    check(source.handle(key(36, .shift)) && advanced == 1, "Shift Enter is consumed by the focused cell command")
    check(!source.handle(key(36)) && !source.handle(key(36, .command)), "Ordinary Return and other modified commands remain native editing input")
    source.editable = false; check(!source.handle(key(36, .shift)), "Busy cell input cannot trigger another execution shortcut")

    let paging = ReaderPagingKeyView(); paging.enabled = true; var delta = 0; paging.turn = { delta += $0 }; host.addSubview(paging)
    check(!paging.handle(key(124)), "PDF navigation never steals cursor arrows from an input field")
    window.makeFirstResponder(nil)
    check(paging.handle(key(124)) && delta == 1 && paging.handle(key(49, .shift)) && delta == 0, "PDF arrow and Shift Space route next/previous when no input owns the keyboard")
    check(!paging.handle(key(124, .command)), "PDF page navigation leaves command shortcuts alone")
    var deleted = 0, cleared = 0
    let annotationKey = PageAnnotationKeyView(); annotationKey.enabled = true; annotationKey.delete = { deleted += 1 }; annotationKey.clear = { cleared += 1 }; host.addSubview(annotationKey)
    check(annotationKey.handle(key(51)) && deleted == 1, "Delete removes the selected annotation when it is not editing text")
    window.makeFirstResponder(text)
    check(!annotationKey.handle(key(51)) && deleted == 1, "Delete inside annotation/source text remains a character operation")
    check(annotationKey.handle(key(53)) && cleared == 1, "Escape ends annotation selection/editing")
    window.makeFirstResponder(nil)

    let viewport = CanvasScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 750)); window.contentView = viewport
    for zoom in [0.25, 0.5, 1.0, 2.0, 6.0] {
        viewport.update(pageID: UUID(), size: CGSize(width: 1500, height: 2600), zoom: zoom, fitting: false, content: AnyView(EmptyView()))
        viewport.layoutSubtreeIfNeeded()
        let pointer = PageAnnotationPointerView(frame: NSRect(x: 40, y: 40, width: 200, height: 100)); viewport.paper.addSubview(pointer)
        var delta = CGSize.zero; pointer.commit = { delta = $0 }
        let start = pointer.convert(CGPoint(x: 20, y: 20), to: nil), end = pointer.convert(CGPoint(x: 65, y: 50), to: nil)
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        pointer.mouseDown(with: mouse(.leftMouseDown, start)); pointer.mouseDragged(with: mouse(.leftMouseDragged, end))
        pointer.frame.origin.x += 45; pointer.frame.origin.y += 30
        pointer.mouseUp(with: mouse(.leftMouseUp, end))
        check(abs(delta.width - 45) < 0.01 && abs(delta.height - 30) < 0.01, "Annotation drag coordinates stay exact while the native view moves at zoom \(zoom)")
        pointer.borderOnly = true
        check(pointer.hitTest(pointer.convert(CGPoint(x: 40, y: 20), to: pointer.superview)) == nil,
              "Editing annotations leave top text rows available for native selection at zoom \(zoom)")
        pointer.removeFromSuperview()
    }

    let store = try AppStore(root: root.appendingPathComponent("library")); store.create(); store.cancelRename()
    var block = Block(.pdf, frame: Rect(20,20,400,500)); block.relativeFilePath = "test.pdf"; block.assetName = "test.pdf"
    let noteID = store.selection!; store.edit { $0.blocks = [block] }; store.flush()
    let windows = PDFWindow(); windows.presentsWindows = false
    windows.open(store: store, noteID: noteID, block: block)
    let first = windows.existingWindow(store: store, noteID: noteID, blockID: block.id)!
    windows.open(store: store, noteID: noteID, block: block, page: 3)
    check(windows.windowCount == 1 && windows.existingWindow(store: store, noteID: noteID, blockID: block.id) === first,
          "Repeated opening of one library/note/block reuses its reader window")
    check(!first.styleMask.contains(.fullScreen), "Readers open as ordinary windows unless full screen is explicitly requested")
    let reader = first.contentView as! NSHostingView<AttachmentReader>
    check(reader.rootView.navigation.request?.page == 3, "A search/navigation page request reaches the reused reader")
    var alias = block; alias.id = UUID(); windows.open(store: store, noteID: noteID, block: alias)
    check(windows.windowCount == 2, "Independent annotation references retain separate reader identities")
    let oldCloseGuard = reader.rootView.navigation.canClose
    var committedClosingText = "", guardCalls = 0, guardSawCommittedInput = false
    let closingInput = ClosingMarkedTextView(frame: NSRect(x: 10, y: 10, width: 300, height: 80))
    closingInput.isRichText = false; closingInput.string = "原文"
    let closingEditor = RichTextEditor(block: Block(.text, frame: Rect(0,0,300,80), text: "原文"),
                                      formatting: TextFormatting(), focus: {}, checkpoint: {}) { _, value in committedClosingText = value }
    let closingCoordinator = closingEditor.makeCoordinator(); closingInput.delegate = closingCoordinator
    first.contentView!.addSubview(closingInput); first.makeFirstResponder(closingInput)
    closingInput.setMarkedText("新增中文", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: 2, length: 0))
    check(!first.isKeyWindow && closingInput.hasMarkedText(), "The close fixture has real pending Chinese input in a non-key reader")
    reader.rootView.navigation.canClose = {
        guardCalls += 1
        guardSawCommittedInput = !closingInput.hasMarkedText() && committedClosingText == "原文新增中文"
        return false
    }
    check(!windows.windowShouldClose(first) && guardCalls == 1 && guardSawCommittedInput,
          "Closing a non-key reader commits its sender's marked input before invoking the save guard")
    check(first.contentView != nil && windows.existingWindow(store: store, noteID: noteID, blockID: block.id) === first,
          "A failed close after committing input still retains the reader content and registry")
    closingInput.setMarkedText("保留候选", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: 0, length: 0))
    closingInput.reportsReadOnly = true
    check(!windows.windowShouldClose(first) && guardCalls == 1 && closingInput.hasMarkedText(),
          "Read-only marked input blocks closing before composition is discarded or the save guard runs")
    closingInput.reportsReadOnly = false; closingInput.unmarkText(); closingInput.delegate = nil
    first.makeFirstResponder(nil); closingInput.removeFromSuperview(); reader.rootView.navigation.canClose = oldCloseGuard
    let good = try Data(contentsOf: store.repository.workspaceURL); try Data("bad".utf8).write(to: store.repository.workspaceURL)
    check(!windows.windowShouldClose(first), "A save failure prevents the native window close action")
    check(first.contentView != nil && windows.existingWindow(store: store, noteID: noteID, blockID: block.id) === first,
          "A blocked close retains the reader content and its iCloud preview lease")
    try good.write(to: store.repository.workspaceURL)
    first.close(); windows.existingWindow(store: store, noteID: noteID, blockID: alias.id)?.close()
    check(windows.windowCount == 0, "Closing readers releases their registry entries")
    check(first.contentView == nil, "Successful close disposes reader content even while the NSWindow remains retained")
    print("PASS: \(count) reader reuse, paging, annotation keys and Notebook editing assertions")
    return count
}
