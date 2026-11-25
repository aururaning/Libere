import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor func runSidebarNestingNativeChecks() async throws -> Int {
    var count = 0
    func check(_ value: Bool, _ label: String) {
        if !value { FileHandle.standardError.write(Data(("FAILED sidebar nesting: " + label + "\n").utf8)) }
        precondition(value,label); count += 1
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereSidebarNesting-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let store = try AppStore(root:root)
    store.create(folder:true); store.renameDraft="源目录"; store.commitRename(); let sourceFolder=store.selection!
    store.create(folder:true); store.renameDraft="目标目录"; store.commitRename(); let targetFolder=store.selection!
    let sourceDirectory=store.directories.directory(for:sourceFolder,in:store.workspace)
    let targetDirectory=store.directories.directory(for:targetFolder,in:store.workspace)
    let mainURL=sourceDirectory.appendingPathComponent("主文件.py"), original=Data("print('source')".utf8)
    try original.write(to:mainURL)
    var page=Note(title:"主文件.py",parent:sourceFolder)
    page.managedFilePath=ReferencePath.relative(mainURL,inside:root)
    let companion=sourceDirectory.appendingPathComponent("主文件.py__" + page.id.uuidString.prefix(8),isDirectory:true)
    let companionFile=companion.appendingPathComponent("PDF/资料.pdf")
    try FileManager.default.createDirectory(at:companionFile.deletingLastPathComponent(),withIntermediateDirectories:true)
    try Data("companion-original".utf8).write(to:companionFile)
    page.managedDirectoryPath=ReferencePath.relative(companion,inside:root)
    var primary=Block(.file,frame:Rect(20,20,320,300)); primary.assetName=mainURL.lastPathComponent;primary.relativeFilePath=page.managedFilePath;primary.fileID=UUID()
    var document=Block(.pdf,frame:Rect(380,20,320,300));document.assetName="资料.pdf";document.relativeFilePath=ReferencePath.relative(companionFile,inside:root);document.fileID=UUID()
    page.blocks=[primary,document]
    var aliasPage=Note(title:"跨页引用")
    var primaryAlias=primary;primaryAlias.id=UUID();primaryAlias.reference=FileReference(noteID:page.id,blockID:primary.id)
    var documentAlias=document;documentAlias.id=UUID();documentAlias.reference=FileReference(noteID:page.id,blockID:document.id)
    aliasPage.blocks=[primaryAlias,documentAlias]
    try store.commitIndexedPages([page,aliasPage])
    let editor=try store.textFileSession(noteID:aliasPage.id,blockID:primaryAlias.id)

    func provider(_ id:UUID)->NSItemProvider {
        let item=NSItemProvider()
        item.registerDataRepresentation(forTypeIdentifier:UTType.liberePage.identifier,visibility:.ownProcess) { done in
            done(Data(id.uuidString.utf8),nil);return nil
        }
        return item
    }
    let item=provider(page.id), middle=CGPoint(x:150,y:14)
    let target=PageDropDelegate(store:store,target:targetFolder,height:28)
    check(PageDropDelegate.supportedTypes.contains(.liberePage) && PageDropDelegate.supportedTypes.contains(.fileURL),
          "A single row destination accepts both internal page and Finder-file representations")
    check(item.hasItemConformingToTypeIdentifier(UTType.liberePage.identifier) && !item.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
          "The internal drag payload is a real page provider, not a file URL")
    check(target.placement(at:middle) == .inside(targetFolder) && target.placement(at:CGPoint(x:150,y:2)) == .before(targetFolder)
          && target.placement(at:CGPoint(x:150,y:26)) == .after(targetFolder),
          "The row center nests while top and bottom edges keep sibling insertion")
    store.draggingPageID=page.id
    check(target.accepts([item],at:middle),"A page can be dropped into an unrelated folder's center")
    target.update([item],at:middle)
    check(store.pageDropPlacement == .inside(targetFolder),"The center is highlighted as an inside destination")
    let oldTarget=PageDropDelegate(store:store,target:sourceFolder,height:28)
    oldTarget.clearOwnHighlight()
    check(store.pageDropPlacement == .inside(targetFolder),"A late exit from the old row cannot erase the new row's highlight")
    check(target.perform([item],at:middle),"The production row handler commits page nesting")
    check(store.workspace.notes.first(where:{$0.id==page.id})?.parentID==targetFolder
          && store.expandedPages.contains(targetFolder) && store.selection==page.id,
          "A nested page is selected and its destination ancestry is revealed")
    check(store.draggingPageID==nil && store.pageDropPlacement==nil,"A completed drag clears its transient state")
    let movedMain=store.attachmentURL(for:store.workspace.notes.first(where:{$0.id==page.id})!.blocks[0])!
    let movedDocument=store.attachmentURL(for:store.workspace.notes.first(where:{$0.id==page.id})!.blocks[1])!
    check(movedMain.deletingLastPathComponent()==targetDirectory && !FileManager.default.fileExists(atPath:mainURL.path),
          "Nesting physically moves the primary original into the target directory")
    check(movedDocument.path.hasPrefix(targetDirectory.path+"/") && !FileManager.default.fileExists(atPath:companion.path),
          "The page's companion archive directory moves in the same transaction")
    let movedAlias=store.workspace.notes.first(where:{$0.id==aliasPage.id})!
    check(movedAlias.blocks[0].relativeFilePath==store.workspace.notes.first(where:{$0.id==page.id})!.blocks[0].relativeFilePath
          && movedAlias.blocks[1].relativeFilePath==store.workspace.notes.first(where:{$0.id==page.id})!.blocks[1].relativeFilePath,
          "Every cross-page file reference follows both moved originals")
    editor.edit("print('edited after move')");check(editor.save(),"An already open text editor saves at the relocated file path")
    check(try Data(contentsOf:movedMain)==Data("print('edited after move')".utf8),"The relocated original receives subsequent edits")
    store.undo()
    check(store.workspace.notes.first(where:{$0.id==page.id})?.parentID==sourceFolder
          && store.workspace.notes.first(where:{$0.id==page.id})?.managedDirectoryPath==page.managedDirectoryPath,
          "One undo restores the original parent and exact companion directory")
    check(try Data(contentsOf:mainURL)==Data("print('edited after move')".utf8)
          && Data(contentsOf:companionFile)==Data("companion-original".utf8),
          "Undo restores real originals without rolling back their file contents")
    store.redo()
    check(store.workspace.notes.first(where:{$0.id==page.id})?.parentID==targetFolder && FileManager.default.fileExists(atPath:movedDocument.path),
          "Redo repeats the same hierarchy and physical-file move")
    store.undo()

    // Move a real directory subtree, including an open Notebook working directory.
    store.create(parent:sourceFolder);store.renameDraft="子笔记";store.commitRename();let nested=store.selection!
    let childDirectory=store.directories.directory(for:nested,in:store.workspace)
    let notebookURL=childDirectory.appendingPathComponent("实验.ipynb")
    try Data("{\"nbformat\":4,\"cells\":[],\"metadata\":{}}".utf8).write(to:notebookURL)
    store.importFile(notebookURL)
    let notebook=try store.notebookSession(noteID:nested,blockID:store.block!.id), originalCWD=notebook.workingDirectory
    store.draggingPageID=sourceFolder
    check(target.perform([provider(sourceFolder)],at:middle),"A folder can be dropped into another folder's center")
    check(store.workspace.notes.first(where:{$0.id==sourceFolder})?.parentID==targetFolder
          && store.workspace.notes.first(where:{$0.id==nested})?.parentID==sourceFolder,
          "The complete folder subtree retains its internal hierarchy")
    check(!FileManager.default.fileExists(atPath:sourceDirectory.path)
          && FileManager.default.fileExists(atPath:targetDirectory.appendingPathComponent("源目录/子笔记/实验.ipynb").path),
          "Folder nesting moves its actual directory and descendant files")
    check(notebook.workingDirectory != originalCWD && notebook.workingDirectory.path.hasPrefix(targetDirectory.path+"/源目录/"),
          "An open Notebook session follows its moved working directory")
    store.undo()
    check(store.workspace.notes.first(where:{$0.id==sourceFolder})?.parentID==nil
          && notebook.workingDirectory==originalCWD && FileManager.default.fileExists(atPath:notebookURL.path),
          "Undo restores the entire folder and the Notebook working directory")

    let sameLevel=PageDropDelegate(store:store,target:sourceFolder,height:28)
    store.draggingPageID=targetFolder
    check(sameLevel.perform([provider(targetFolder)],at:CGPoint(x:150,y:2)),"Top-edge dropping still reorders siblings")
    let roots=store.workspace.children(nil).map(\.id)
    check(roots.firstIndex(of:targetFolder)! < roots.firstIndex(of:sourceFolder)!,"Sibling order matches the top-edge placement")
    store.undo()
    store.draggingPageID=sourceFolder
    let childTarget=PageDropDelegate(store:store,target:nested,height:28)
    let beforeCycle=store.workspace
    check(!childTarget.accepts([provider(sourceFolder)],at:middle) && !childTarget.perform([provider(sourceFolder)],at:middle)
          && store.workspace==beforeCycle,"A directory cannot be nested inside its own descendant")
    store.draggingPageID=sourceFolder
    check(!sameLevel.accepts([provider(sourceFolder)],at:middle),"A page cannot become its own parent")
    store.draggingPageID=nil

    // A collision must not overwrite either the source or unrelated destination.
    let collision=targetDirectory.appendingPathComponent("主文件.py");try Data("unrelated destination".utf8).write(to:collision)
    let beforeCollision=store.workspace
    store.draggingPageID=page.id
    check(!target.perform([provider(page.id)],at:middle) && store.workspace==beforeCollision,
          "Destination collisions reject the whole nesting transaction")
    check(try Data(contentsOf:collision)==Data("unrelated destination".utf8)
          && Data(contentsOf:mainURL)==Data("print('edited after move')".utf8)
          && FileManager.default.fileExists(atPath:companion.path),
          "A failed drop preserves both the unrelated destination and every source original")
    store.message=nil

    // Finder drops keep the existing index-only path; this is not clipboard intake.
    let file=root.appendingPathComponent("库内资料.md");try Data("indexed only".utf8).write(to:file)
    let fileProvider=NSItemProvider(item:file as NSURL,typeIdentifier:UTType.fileURL.identifier)
    let childCount=store.workspace.children(targetFolder).count
    check(target.accepts([fileProvider],at:middle) && target.perform([fileProvider],at:middle),
          "The unified center handler still accepts Finder file URLs")
    for _ in 0..<100 {
        if store.workspace.children(targetFolder).count>childCount { break }
        try await Task.sleep(nanoseconds:10_000_000)
    }
    check(store.workspace.children(targetFolder).count==childCount+1
          && store.workspace.children(targetFolder).contains(where:{$0.blocks.first?.relativeFilePath=="库内资料.md"}),
          "A Finder drop creates a child index without moving or copying the original")
    check(try Data(contentsOf:file)==Data("indexed only".utf8),"Finder indexing preserves original bytes")
    let outside=root.deletingLastPathComponent().appendingPathComponent("outside-sidebar-"+UUID().uuidString+".md")
    try Data("outside".utf8).write(to:outside);defer { try? FileManager.default.removeItem(at:outside) }
    let outsideProvider=NSItemProvider(item:outside as NSURL,typeIdentifier:UTType.fileURL.identifier)
    let beforeOutside=store.workspace
    _=target.perform([outsideProvider],at:middle)
    for _ in 0..<100 { if store.message != nil { break };try await Task.sleep(nanoseconds:10_000_000) }
    check(store.workspace==beforeOutside && store.message != nil,"Dragging outside files does not silently invoke the clipboard archive exception")
    let rootTarget=PageDropDelegate(store:store,target:nil,height:28)
    check(!rootTarget.accepts([fileProvider],at:middle),"The root header does not redirect file drops into the current selection")
    check(!target.accepts([NSItemProvider(object:"text" as NSString)],at:middle),"Unrelated pasteboard types do not enter the page/file row handler")
    print("PASS: \(count) sidebar nesting, ordering, original-file, reference, undo and collision assertions")
    return count
}
