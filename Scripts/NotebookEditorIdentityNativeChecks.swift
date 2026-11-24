import Foundation
import SwiftUI

@MainActor func runNotebookEditorIdentityNativeChecks() async throws -> Int {
    var count = 0
    func check(_ result: Bool, _ label: String) { precondition(result, label); count += 1 }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LibereNotebookIdentity-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = Data(#"{"nbformat":4,"cells":[{"cell_type":"code","source":"first","metadata":{},"outputs":[]},{"cell_type":"code","source":"second","metadata":{},"outputs":[{"output_type":"stream","name":"stdout","text":"old output"}]},{"cell_type":"markdown","source":"last markdown","metadata":{}}],"metadata":{}}"#.utf8)
    let session = try NotebookSession(data: data, directory: directory) { _ in }
    session.kernels = [NotebookKernelChoice(id: "fixture", title: "Fixture")]
    let ids = session.document.cells.map(\.id), retainedID = ids[1]
    let originalToken = session.editorToken(for: retainedID)
    let window = NSWindow(contentRect: NSRect(x:0,y:0,width:1000,height:1800), styleMask:[.titled], backing:.buffered, defer:false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: NotebookEditor(session: session, filename: "fixture.ipynb", compact: true))
    window.contentView = host
    defer { window.contentView = nil; session.save() }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func text(_ value: String) -> NSTextView? {
        descendants(host).compactMap { $0 as? SourceInputHost }.compactMap { $0.textView(in: $0.host) }.first { $0.string == value }
    }
    func settle() async throws {
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 15_000_000) }
    }
    func index(_ id: String) -> Int { session.document.index(ofCellID: id)! }
    try await settle()
    guard let retained = text("second"), let first = text("first"), let undo = retained.undoManager else { preconditionFailure("Missing real Notebook NSTextView/undo manager") }
    undo.removeAllActions(); window.makeFirstResponder(retained)
    retained.breakUndoCoalescing(); undo.beginUndoGrouping()
    retained.insertText("second edited", replacementRange:NSRange(location:0,length:retained.string.utf16.count))
    retained.didChangeText(); undo.endUndoGrouping(); retained.breakUndoCoalescing()
    try await settle()
    check(session.document.cells[index(retainedID)].source == "second edited" && undo.canUndo,
          "The production cell editor registers native text undo and saves into its stable cell")

    session.insertCell(at: 0); let insertedID = session.document.cells[0].id; try await settle()
    check(text("second edited") === retained && text("first") === first && retained.undoManager === undo && undo.canUndo,
          "Inserting another cell retains live native editors and their undo manager")
    check(session.editorToken(for:retainedID) == originalToken, "Insertion preserves the surviving cell's callback lifetime")
    session.undoCellChange(); try await settle()
    check(session.document.cells.map(\.id) == ids && text("second edited") === retained && undo.canUndo,
          "Undoing the first legacy structural edit restores the same cell IDs and text undo")
    check(session.document.index(ofCellID:insertedID) == nil, "Structural undo removes only the inserted cell")
    window.makeFirstResponder(retained); undo.undo(); retained.didChangeText(); try await settle()
    check(retained.string == "second" && session.document.cells[index(retainedID)].source == "second"
          && session.document.cells[index(ids[0])].source == "first", "Native text undo after structural undo updates its own cell, not the old numeric index")
    undo.redo(); retained.didChangeText(); try await settle()
    check(retained.string == "second edited" && undo.canUndo, "Native text redo remains available after structure changes")

    session.insertCell(at: 0); let removed = session.document.cells[0].id; try await settle()
    session.deleteCell(index(removed)); try await settle()
    check(text("second edited") === retained && text("first") === first && undo.canUndo,
          "Deleting an unrelated cell does not rebuild surviving source editors")
    session.moveCell(index(retainedID), by:-1); try await settle()
    check(index(retainedID) == 0 && text("second edited") === retained && undo.canUndo,
          "Reordering retains the moved NSTextView and native undo history")
    check(session.edit("second after move", cellID:retainedID, editorToken:originalToken)
          && session.document.cells[0].source == "second after move"
          && session.document.cells[index(ids[0])].source == "first", "A retained callback follows its cell identity through a reorder")
    try await settle()
    session.clearOutputs(index(retainedID)); try await settle()
    check(text("second after move") === retained && session.editorToken(for:retainedID) == originalToken,
          "Clearing outputs retains the source editor and its callback token")
    session.undoCellChange(); try await settle()
    check(text("second after move") === retained && !session.document.cells[0].outputs.isEmpty,
          "Undoing an output-only change retains source-editor identity")

    session.focusCell(index(ids[2])); try await settle()
    guard let lastMarkdown = text("last markdown") else { preconditionFailure("Missing focused Markdown source editor") }
    let lastToken = session.editorToken(for:ids[2])
    session.runAndAdvance(index(ids[2])); try await settle()
    check(session.document.cells.count == 4 && session.focusedCellID == session.document.cells.last?.id,
          "Shift Enter on the final Markdown cell appends and focuses one cell")
    check(text("last markdown") === lastMarkdown && text("second after move") === retained
          && session.editorToken(for:ids[2]) == lastToken,
          "Last-cell Shift Enter does not recreate the edited cell or its neighbors")

    let retiredToken = session.editorToken(for:retainedID), oldGeneration = session.structureGeneration
    session.convertCell(index(retainedID), to:"markdown"); try await settle()
    check(session.editorToken(for:retainedID) != retiredToken
          && !session.edit("retired code callback",cellID:retainedID,editorToken:retiredToken)
          && !session.edit("retired generation callback",cellID:retainedID,generation:oldGeneration),
          "Converting a cell retires only that cell's old editor callbacks")
    let converted = session.editorToken(for:retainedID)
    session.deleteCell(index(retainedID)); try await settle()
    check(!session.edit("deleted callback",cellID:retainedID,editorToken:converted), "Removed-cell callbacks cannot reach another cell")
    session.undoCellChange(); try await settle()
    check(session.document.index(ofCellID:retainedID) != nil && session.editorToken(for:retainedID) != converted
          && !session.edit("restored stale callback",cellID:retainedID,editorToken:converted),
          "Restoring a deleted cell uses a new editor lifetime despite keeping its stable cell ID")
    let restoredToken = session.editorToken(for:retainedID)
    session.busy = true
    check(!session.edit("busy callback",cellID:retainedID,editorToken:restoredToken), "Busy state still rejects live-cell text changes")
    session.busy = false

    // Exercise the real Shift-Return path and append-before-execute transition,
    // using a tiny deterministic stdio bridge instead of a Jupyter dependency.
    let bridge = directory.appendingPathComponent("identity-kernel.py")
    try Data("""
    import json, sys
    for line in sys.stdin:
        value = json.loads(line)
        if value['op'] == 'start':
            print(json.dumps({'event':'ready'}), flush=True)
        elif value['op'] == 'execute':
            print(json.dumps({'event':'complete','id':value['id'],'status':'ok'}), flush=True)
        elif value['op'] == 'shutdown':
            break
    """.utf8).write(to:bridge)
    let code = try NotebookSession(data: Data(#"{"nbformat":4,"cells":[{"id":"head","cell_type":"code","source":"head","outputs":[],"metadata":{}},{"id":"tail","cell_type":"code","source":"tail","outputs":[],"metadata":{}}]}"#.utf8), directory:directory, bridge:bridge) { _ in }
    defer { code.stop() }
    code.kernels = [NotebookKernelChoice(id:"python3",title:"Fixture")]
    host.rootView = NotebookEditor(session:code,filename:"code.ipynb",compact:true)
    code.start()
    for _ in 0..<200 { if code.ready { break }; try await Task.sleep(nanoseconds:10_000_000) }
    check(code.ready, "The deterministic stdio kernel becomes ready for the production run path")
    try await settle()
    guard let tail = text("tail"), let head = text("head"), let tailUndo = tail.undoManager,
          let surface = descendants(host).compactMap({ $0 as? SourceInputHost }).first(where: { $0.textView(in:$0.host) === tail }) else { preconditionFailure("Missing code source input") }
    window.makeFirstResponder(tail); tailUndo.removeAllActions()
    tailUndo.beginUndoGrouping(); tail.insertText("tail edited",replacementRange:NSRange(location:0,length:4))
    tail.didChangeText(); tailUndo.endUndoGrouping(); tail.breakUndoCoalescing()
    let token = code.editorToken(for:"tail")
    let key = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.shift,timestamp:0,windowNumber:window.windowNumber,
                              context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
    check(surface.handle(key), "The focused source consumes Shift Return through its real command callback")
    for _ in 0..<200 { if !code.busy && code.document.cells.count == 3 && code.focusedCellID == code.document.cells.last?.id { break }; try await Task.sleep(nanoseconds:10_000_000) }
    try await settle()
    check(code.document.cells.count == 3 && code.focusedCellID == code.document.cells.last?.id && !code.busy,
          "Final-code-cell execution creates and focuses exactly one next cell")
    check(text("tail edited") === tail && text("head") === head && tail.undoManager === tailUndo && tailUndo.canUndo
          && code.editorToken(for:"tail") == token, "Code Shift Enter preserves the running cell's native undo and its unaffected neighbor")
    window.makeFirstResponder(tail); tailUndo.undo(); tail.didChangeText(); try await settle()
    check(tail.string == "tail" && code.document.cells[1].source == "tail" && code.document.cells[0].source == "head",
          "Native text undo after final-cell execution still edits the original cell")
    print("PASS: \(count) Notebook source identity, native undo and callback-lifetime assertions")
    return count
}
