import Foundation
import SwiftUI
import WebKit
import UniformTypeIdentifiers

@MainActor private struct ClipboardLinkCanvas: View {
    @ObservedObject var store: AppStore
    var body: some View { if let note = store.note { NoteCanvas(store: store, note: note) } }
}

@MainActor func runClipboardLinksNativeChecks() async throws -> Int {
    _ = NSApplication.shared
    var count = 0
    func check(_ result: Bool, _ label: String) { precondition(result, label); count += 1 }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereClipboard-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(root: root)
    store.create(); store.cancelRename(); let sourceID = store.selection!
    var text = Block(.text, frame: Rect(20,20,280,160), text: "富文本原文")
    text.textFormat = .richText; text.fontSize = 27; text.fontFamily = "Songti SC"; text.quote = true; text.tint = "blue"
    let attributed = NSAttributedString(string: text.text, attributes: [.font:NSFont.systemFont(ofSize:27,weight:.bold), .foregroundColor:NSColor.systemRed])
    text.rtf = try attributed.data(from:NSRange(location:0,length:attributed.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf])
    var formula = Block(.formula, frame: Rect(340,20,280,160), text: #"\frac{x_i}{y}"#); formula.fontSize = 31; formula.tint = "gray"
    let anchor = AnnotationAnchor(ownerID:text.id,label:"关联",u:1.2,v:0.5)
    var child = Block(.text,frame:Rect(660,20,260,160),text:"子批注"); child.anchorID = anchor.id
    store.edit { $0.blocks = [text,formula,child]; $0.anchors = [anchor]; $0.canvasWidth = 1400; $0.ink = Data([1,2,3]) }
    let payload = try store.clipboardData(for:[text.id,formula.id,child.id])
    check(store.pasteBlocks(payload),"Mixed text/formula/branch clipboard paste succeeds")
    let pasted = Array(store.note!.blocks.suffix(3))
    check(Set(pasted.map(\.id)).isDisjoint(with:[text.id,formula.id,child.id]),"Pasted blocks get fresh identities")
    check(pasted[0].rtf == text.rtf && pasted[0].fontFamily == text.fontFamily && pasted[0].fontSize == 27
          && pasted[0].quote && pasted[0].tint == "blue" && pasted[0].textFormat == .richText,"Rich text, fonts, quote and tint survive complete block copy")
    check(pasted[1].text == formula.text && pasted[1].fontSize == 31 && pasted[1].kind == .formula,"Formula source and presentation survive clipboard round trip")
    check(pasted[2].anchorID != anchor.id && store.note!.anchors.first(where:{$0.id == pasted[2].anchorID})?.ownerID == pasted[0].id,"Copied branches point to copied owners without affecting original anchors")
    check(store.note?.ink == Data([1,2,3]),"Clipboard insertion leaves page handwriting untouched")
    store.undo(); check(store.note?.blocks == [text,formula,child],"One undo removes the complete pasted group")
    store.redo(); check(store.note?.blocks.count == 6,"One redo restores the complete group")
    store.selectBlock(text.id); store.editBlock(text.id) { $0.locked = true }
    let lockedCount = store.note!.blocks.count
    store.cutFocused(); check(store.note!.blocks.count == lockedCount,"Cut cannot delete locked selections")

    let fileURL = root.appendingPathComponent("original.md"); try Data("原件内容".utf8).write(to:fileURL)
    check(store.indexFileURLs([fileURL]),"Indexing an existing library file succeeds")
    let indexed = store.block!, fileData = try store.clipboardData(for:[indexed.id])
    check(store.pasteBlocks(fileData),"File blocks can be copied as references")
    check(store.block?.relativeFilePath == "original.md" && store.block?.fileIdentity == indexed.fileIdentity,"File copies share the same original path and identity")
    check(!FileManager.default.fileExists(atPath:store.repository.assets.path),"Clipboard and indexing never create attachment copies")
    let other = try AppStore(root:root.appendingPathComponent("OtherLibrary")); other.create(); other.cancelRename()
    let beforeRejected = other.workspace
    check(!other.pasteBlocks(fileData) && other.workspace == beforeRejected,"A copied file cannot silently resolve inside a different library")
    let textOnly = try store.clipboardData(for:[formula.id])
    check(other.pasteBlocks(textOnly) && other.block?.text == formula.text,"Standalone text/formula blocks are portable across libraries")
    check(other.smartPaste("https://example.invalid/reference") && other.block?.kind == .link,"Smart paste makes a URL card")
    check(other.smartPaste("普通文本\n\n**加粗**") && other.block?.text == "普通文本\n\n**加粗**","Smart paste preserves ordinary text and Markdown source")
    check(other.smartPaste("/api/" + UUID().uuidString) && other.block?.kind == .text,"A non-file slash-prefixed string remains ordinary pasted text")
    let beforeOutside = other.note!.blocks.count
    _ = other.smartPaste(fileURL.path)
    check(other.note!.blocks.count == beforeOutside && other.message != nil,"Smart paste refuses an original outside the chosen library")

    store.create(folder:true); store.cancelRename(); let folderID = store.selection!
    check(store.indexFileURLs([fileURL],noteID:folderID),"Dropping onto a folder creates indexed child pages")
    let children = store.workspace.children(folderID)
    check(children.count == 1 && children[0].blocks[0].relativeFilePath == "original.md","Folder drop records a file index without copying its bytes")
    store.undo(); check(store.workspace.children(folderID).isEmpty,"Folder indexing is one undoable action")
    store.select(sourceID)
    let provider = NSItemProvider(item: fileURL as NSURL, typeIdentifier: UTType.fileURL.identifier)
    let capturedCount = store.note!.blocks.count
    check(store.indexDroppedFiles(providers:[provider]),"Finder providers are accepted for index loading")
    store.select(folderID)
    for _ in 0..<100 {
        if store.workspace.notes.first(where:{$0.id == sourceID})!.blocks.count > capturedCount { break }
        try await Task.sleep(nanoseconds:10_000_000)
    }
    check(store.workspace.notes.first(where:{$0.id == sourceID})!.blocks.count == capturedCount + 1 && store.selection == folderID,"A delayed Finder drop stays on its captured page and does not change current navigation")
    check(try Data(contentsOf:fileURL) == Data("原件内容".utf8),"All clipboard/drop operations preserve original file bytes")

    let editor = WikiCompletingTextView(frame:NSRect(x:0,y:0,width:400,height:160))
    editor.isEditable = true; editor.isRichText = false; editor.string = "查看 [["; editor.setSelectedRange(NSRange(location:(editor.string as NSString).length,length:0))
    let target = store.workspace.notes.first(where:{$0.id == folderID})!
    editor.wikiProvider = { query in WikiLinks.candidates(in:store.workspace,query:query).filter{$0.id == target.id} }
    var selected = 0
    guard let choice = editor.completions(forPartialWordRange:editor.rangeForUserCompletion,indexOfSelectedItem:&selected)?.first else { preconditionFailure("Missing wiki completion") }
    let raw = editor.string
    editor.insertCompletion(choice,forPartialWordRange:editor.rangeForUserCompletion,movement:NSReturnTextMovement,isFinal:false)
    check(editor.string == raw,"Completion previews never overwrite typed source")
    editor.insertCompletion(choice,forPartialWordRange:editor.rangeForUserCompletion,movement:NSReturnTextMovement,isFinal:true)
    check(editor.string == "查看 " + PageLink.markdown(title:target.title,id:target.id),"Accepting [[ completion inserts a stable page reference")

    store.select(sourceID); store.fitToWidth = false; store.zoom = 1
    let linkBlock = Block(.text,frame:Rect(40,40,420,240),text:PageLink.markdown(title:"打开目标",id:folderID))
    store.edit { $0.blocks = [linkBlock]; $0.anchors = []; $0.ink = nil }
    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:700),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView:ClipboardLinkCanvas(store:store)); window.contentView = host
    defer { window.contentView = nil }
    func descendants(_ view:NSView)->[NSView] { [view] + view.subviews.flatMap(descendants) }
    var web: WKWebView?, rect: [String:Double]?
    for _ in 0..<200 {
        host.layoutSubtreeIfNeeded()
        web = descendants(host).compactMap{$0 as? WKWebView}.first{$0.navigationDelegate is MarkdownNavigation}
        if let web { rect = try? await web.evaluateJavaScript("(()=>{const a=document.querySelector('a');if(!a)return null;const r=a.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height};})()") as? [String:Double] }
        if rect != nil { break }
        try await Task.sleep(nanoseconds:10_000_000)
    }
    guard let web, let rect else { preconditionFailure("Markdown preview did not render its real page link") }
    let css = CGPoint(x:rect["x"]!+rect["width"]!/2,y:rect["y"]!+rect["height"]!/2)
    let local = CGPoint(x:css.x*web.pageZoom,y:web.isFlipped ? css.y*web.pageZoom : web.bounds.height-css.y*web.pageZoom)
    check(store.openMarkdownLink(at:web.convert(local,to:nil),in:window),"Cmd-click can query a real rendered link below the selection surface")
    for _ in 0..<100 { if store.selection == folderID { break }; try await Task.sleep(nanoseconds:10_000_000) }
    check(store.selection == folderID,"Cmd-click activates an internal page link without requiring text edit mode")
    print("PASS: \(count) clipboard, smart paste, Finder index, wiki completion and Markdown link assertions")
    return count
}
