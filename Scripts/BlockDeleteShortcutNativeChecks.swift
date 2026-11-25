import Foundation
import SwiftUI
import WebKit
import PDFKit

@MainActor private final class DeletePreviewResponder: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor func runBlockDeleteShortcutNativeChecks() async throws -> Int {
    _ = NSApplication.shared
    var count = 0
    func check(_ value: Bool, _ label: String) {
        if !value { FileHandle.standardError.write(Data(("FAILED command-delete: " + label + "\n").utf8)) }
        precondition(value, label); count += 1
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereCommandDelete-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(root: root)
    store.create(); store.cancelRename(); let pageID = store.selection!
    let originalData = Data([0, 1, 2, 0xff, 0x80])
    let fileNames = ["paper.pdf", "image.png", "notebook.ipynb", "source.py", "unknown.bin"]
    for name in fileNames { try originalData.write(to: root.appendingPathComponent(name)) }
    var blocks = [Block(.text, frame: Rect(20,20,240,160), text:"text"), Block(.formula, frame: Rect(20,20,240,160), text:"x^2")]
    for name in fileNames {
        var block = Block(name.hasSuffix(".pdf") ? .pdf : .file, frame: Rect(20,20,380,300))
        block.assetName = name; block.relativeFilePath = name; blocks.append(block)
    }
    for mode in LinkDisplayMode.allCases {
        var block = Block(.link, frame: Rect(20,20,380,300))
        block.linkMode = mode; block.linkURL = "https://example.invalid"; blocks.append(block)
    }
    let window = NSWindow(contentRect: NSRect(x: 0,y:0,width:900,height:700), styleMask:[.titled], backing:.buffered, defer:false)
    window.isReleasedWhenClosed = false
    let content = NSView(frame:NSRect(x:0,y:0,width:900,height:700)); window.contentView = content
    let canvas = CanvasScrollView(frame:content.bounds)
    canvas.pointerInteraction = store.canvasPointer
    canvas.update(pageID:pageID,size:CGSize(width:900,height:1600),zoom:1,fitting:false,content:AnyView(Color.white))
    content.addSubview(canvas)
    let keys = CanvasKeyView(frame:.zero); keys.store = store; content.addSubview(keys)
    let preview = DeletePreviewResponder(frame:NSRect(x:30,y:30,width:100,height:40)); content.addSubview(preview)
    defer { window.contentView = nil; window.close() }
    func event(_ code: UInt16 = 51, _ modifiers: NSEvent.ModifierFlags = .command) -> NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,windowNumber:window.windowNumber,
                        context:nil,characters:"\u{7f}",charactersIgnoringModifiers:"\u{7f}",isARepeat:false,keyCode:code)!
    }
    func install(_ selected: [Block]) {
        store.select(pageID)
        store.edit { $0.blocks = selected; $0.anchors = []; $0.ink = Data([7,8,9]) }
        store.multiSelection.select(Set(selected.map(\.id)))
        window.makeFirstResponder(preview)
        store.blockKeyboardFocus = false
        store.message = nil
    }
    check(store.isCanvasPasteWindow(window), "The shortcut fixture is the actual store's main canvas")
    for block in blocks {
        for code: UInt16 in [51,117] {
            install([block])
            check(store.handleBlockDeleteShortcut(event(code),in:window), "Command-Delete is handled for selected \(block.kind)/\(block.assetName) previews")
            check(store.note!.blocks.isEmpty && store.note!.ink == Data([7,8,9]), "Command-Delete removes only the selected block and keeps handwriting")
            store.undo()
            check(store.note!.blocks == [block], "One undo restores the exact deleted special block")
        }
    }
    for name in fileNames {
        check(try Data(contentsOf:root.appendingPathComponent(name)) == originalData, "Deleting \(name) never modifies or removes its original")
    }
    install([blocks[2]])
    window.makeFirstResponder(keys); store.blockKeyboardFocus = true
    keys.keyDown(with:event())
    check(store.note!.blocks.isEmpty, "CanvasKeyView routes Command-Delete even when called directly")
    store.undo(); install([blocks[2]])
    window.makeFirstResponder(keys); store.blockKeyboardFocus = true
    keys.keyDown(with:event(51,[]))
    check(store.note!.blocks.isEmpty, "The existing plain Delete route still works")
    store.undo(); install([blocks[2]])
    check(!store.handleBlockDeleteShortcut(event(51,[.command,.option]),in:window) && !store.note!.blocks.isEmpty,
          "Other modifier combinations are not mistaken for the block command")

    var locked = blocks[2]; locked.locked = true
    install([locked]); let lockedPage = store.note!
    check(store.handleBlockDeleteShortcut(event(),in:window) && store.note == lockedPage && store.message != nil,
          "Locked blocks consume the command with a message and remain untouched")
    install([blocks[0],locked]); let mixed = store.note!
    check(store.handleBlockDeleteShortcut(event(),in:window) && store.note == mixed,
          "A mixed locked selection is preserved as a whole")
    install([blocks[0],blocks[2]])
    check(store.handleBlockDeleteShortcut(event(),in:window) && store.note!.blocks.isEmpty, "Unlocked multiselection deletes as one operation")
    store.undo(); check(store.note!.blocks == [blocks[0],blocks[2]], "One undo restores the complete selected group")

    install([blocks[2]])
    let input = NSTextView(frame:NSRect(x:10,y:10,width:300,height:90)); input.isEditable = true; input.string = "native text"
    content.addSubview(input); window.makeFirstResponder(input)
    check(!store.handleBlockDeleteShortcut(event(),in:window) && store.note!.blocks == [blocks[2]],
          "Native text editing retains its own Command-Delete and cannot remove a block")
    input.isEditable = false
    check(!store.handleBlockDeleteShortcut(event(),in:window), "Native read-only text selection is not reinterpreted as a block command")
    input.isEditable = true; input.setMarkedText("输入中",selectedRange:NSRange(location:3,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
    check(!store.handleBlockDeleteShortcut(event(),in:window) && input.hasMarkedText(), "IME composition remains in its native input")
    input.unmarkText(); window.makeFirstResponder(preview)
    store.beginBlockEditing(blocks[2].id); window.makeFirstResponder(preview)
    check(!store.handleBlockDeleteShortcut(event(),in:window), "An active source/Notebook editor is protected even after a non-text control takes focus")
    store.finishBlockEditing(); store.selectBlock(blocks[2].id); window.makeFirstResponder(preview)
    store.beginRename(pageID)
    check(!store.handleBlockDeleteShortcut(event(),in:window), "Sidebar rename state cannot delete a canvas block")
    store.cancelRename()
    let title = NSTextField(frame:NSRect(x:10,y:110,width:300,height:30)); title.stringValue = "页面标题"; content.addSubview(title)
    title.selectText(nil)
    check(window.firstResponder is NSTextView && !store.handleBlockDeleteShortcut(event(),in:window), "The real title field editor retains Command-Delete")
    window.makeFirstResponder(preview)
    let search = NSSearchField(frame:NSRect(x:10,y:150,width:300,height:30)); content.addSubview(search); search.selectText(nil)
    check(window.firstResponder is NSTextView && !store.handleBlockDeleteShortcut(event(),in:window), "The real search field editor retains Command-Delete")
    window.makeFirstResponder(preview)

    let web = WKWebView(frame:NSRect(x:20,y:200,width:300,height:100)); content.addSubview(web)
    window.makeFirstResponder(web)
    check(!store.handleBlockDeleteShortcut(event(),in:window) && store.note!.blocks == [blocks[2]],
          "Focused WebKit remains native because an HTML input may be active")
    store.selectBlock(blocks[2].id); window.makeFirstResponder(keys)
    check(store.handleBlockDeleteShortcut(event(),in:window) && store.note!.blocks.isEmpty,
          "Selecting the block header restores the canvas command after WebKit interaction")
    store.undo(); install([blocks[2]])
    let pdf = PDFView(frame:NSRect(x:20,y:200,width:300,height:100)); content.addSubview(pdf)
    window.makeFirstResponder(pdf)
    if !(window.firstResponder is NSTextInputClient) {
        check(store.handleBlockDeleteShortcut(event(),in:window) && store.note!.blocks.isEmpty,
              "A read-only PDFView responder does not prevent deleting its selected block")
        store.undo()
    }

    install([blocks[2]])
    let reader = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:500),styleMask:[.titled],backing:.buffered,defer:false)
    reader.isReleasedWhenClosed = false
    let readerViewport = CanvasScrollView(frame:NSRect(x:0,y:0,width:600,height:500))
    readerViewport.update(pageID:UUID(),size:CGSize(width:600,height:1000),zoom:1,fitting:false,content:AnyView(Color.white))
    reader.contentView = readerViewport
    defer { reader.contentView = nil; reader.close() }
    check(!store.handleBlockDeleteShortcut(event(),in:reader) && store.note!.blocks == [blocks[2]], "A standalone reader cannot delete the canvas block behind it")
    store.formulaEditor = blocks[1]
    check(!store.handleBlockDeleteShortcut(event(),in:window), "A pending formula sheet retains ownership before native presentation")
    store.formulaEditor = nil; store.showingQuickSearch = true
    check(!store.handleBlockDeleteShortcut(event(),in:window), "Pending search presentation prevents block deletion")
    store.showingQuickSearch = false
    store.sidebarHasFocus = true
    check(!store.handleBlockDeleteShortcut(event(),in:window), "Sidebar keyboard ownership is not stolen by the canvas monitor")
    let sidebar = SidebarKeyRegion(frame:NSRect(x:0,y:0,width:200,height:700)); sidebar.store = store; content.addSubview(sidebar)
    check(sidebar.handle(event()) && store.workspace.notes.first { $0.id == pageID }?.deleted == true,
          "The existing sidebar Command-Delete still moves the selected page to Trash")
    check(try Data(contentsOf:root.appendingPathComponent(fileNames[0])) == originalData,
          "Sidebar page deletion also leaves the source file untouched")
    print("PASS: \(count) Command-Delete block, editor, lock, undo and source-preservation assertions")
    return count
}
