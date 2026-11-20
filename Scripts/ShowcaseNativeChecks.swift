import Foundation
import SwiftUI
import PDFKit

@MainActor func runShowcaseNativeChecks() throws -> Int {
    var count = 0
    func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
    let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/MarginNotes/Resources/Showcase.json")
    let data = try Data(contentsOf: source)
    let catalog = try JSONDecoder().decode(ShowcaseCatalog.self, from: data)
    try catalog.validate()
    let pages = catalog.backup.workspace.notes, ids = Set(pages.map(\.id))
    let blocks = pages.flatMap(\.blocks)
    check(catalog.scenarios.count == 4 && pages.count == 13 && blocks.count == 47 && catalog.backup.assets.count == 8,
          "Four complete scenarios contain 13 real pages, 47 blocks and eight attachments")
    check(Set(catalog.scenarios.flatMap(\.pages)) == ids.subtracting([catalog.rootID]),
          "Every example page is reachable through a scenario's navigation")
    var overflow: [String] = []
    for page in pages where !page.isFolder {
        check(page.blocks.allSatisfy { $0.frame.x >= 0 && $0.frame.maxX <= page.width && $0.frame.maxY <= page.height },
              "Example block stays inside its page")
        for (i, block) in page.blocks.enumerated() {
            check(!page.blocks.dropFirst(i + 1).contains { block.frame.intersects($0.frame, gap: 0) },
                  "Example blocks never overlap")
            if block.kind == .text {
                let needed = TextBlockLayout.height(block) + 30
                if needed > block.frame.height { overflow.append("\(block.id): needs \(needed), has \(block.frame.height)") }
            }
        }
        for anchor in page.anchors {
            let child = page.blocks.first { $0.anchorID == anchor.id }!
            let point = CanvasLayout.point(anchor, blocks: page.blocks)!
            check(abs(point.x - child.frame.x) < 0.01 && abs(point.y - child.frame.y) < 0.01,
                  "Independent annotation anchors match their attached text positions")
        }
    }
    for line in overflow { print("SHOWCASE TEXT OVERFLOW: " + line) }
    check(overflow.isEmpty, "All example text fits while editing without automatic growth or overlapping neighbours")
    for block in blocks where block.kind == .pdf && block.reference == nil {
        let pdf = PDFDocument(data: catalog.backup.assets[block.assetID!.uuidString]!)!
        check(pdf.pageCount == 2 && (0..<2).allSatisfy { (pdf.page(at: $0)?.string?.count ?? 0) > 150 },
              "Original demo PDFs contain two readable text pages")
    }
    let paper = blocks.first { $0.kind == .pdf && $0.locked }!
    check(paper.pageAnnotations?["0"]?.texts.count == 1 && paper.pdfPage == 0,
          "Locked paper retains its fixed preview page and editable annotations")
    let notebookBlock = blocks.first { $0.assetName.hasSuffix(".ipynb") }!
    let notebook = try NotebookDocument(data: catalog.backup.assets[notebookBlock.assetID!.uuidString]!)
    check(notebook.cells.count == 3 && NotebookDocument.text(notebook.cells[1].outputs.first?["text"]).contains("9 分（模拟）"),
          "Notebook opens with original cells and readable saved output without execution")
    for block in blocks where block.reference != nil {
        let owner = pages.first { $0.id == block.reference!.noteID }!.blocks.first { $0.id == block.reference!.blockID }!
        check(block.assetID == owner.assetID, "Cross-page examples reference the same underlying file")
    }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereShowcaseCheck-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(root: root)
    store.create(); store.cancelRename(); store.insert(.text)
    store.editBlock(store.block!.id) { $0.text = "我的既有笔记，不可覆盖。" }
    check(store.flush(), "Original user content is saved before installing examples")
    let original = store.workspace.notes, selection = store.selection
    check(try store.installShowcaseIfNeeded(catalog: catalog), "First open installs the scenario tree")
    check(store.workspace.notes.filter { !ids.contains($0.id) } == original && store.selection == catalog.rootID,
          "Installation preserves existing pages byte-for-byte and opens the gallery")
    check(try store.repository.load()?.notes.count == original.count + pages.count,
          "The gallery is durable before it is displayed")
    check(!FileManager.default.fileExists(atPath: store.repository.assets.path), "Installing examples never creates attachments")
    check(store.workspace.notes.filter { ids.contains($0.id) }.flatMap(\.blocks).allSatisfy { $0.referencedAssets.isEmpty },
          "New examples keep guidance placeholders instead of duplicated file bytes")
    store.undo()
    check(store.workspace.notes.filter { ids.contains($0.id) }.allSatisfy(\.deleted) && store.selection == selection,
          "One undo removes the whole gallery and restores the previous selection")
    check(try !store.installShowcaseIfNeeded(catalog: catalog), "Undo does not trigger an automatic reinstall")
    store.redo()
    check(store.workspace.notes.filter { ids.contains($0.id) }.allSatisfy { !$0.deleted },
          "One redo restores the same complete example tree")
    let scene = catalog.scenarios[0]
    store.select(scene.pageID)
    let editedID = store.note!.blocks.first { $0.kind == .text }!.id
    store.editBlock(editedID) { $0.text = "我对示例的修改必须保留。" }
    check(store.flush(), "A sample page can be edited and saved like any normal page")
    let edited = store.workspace.notes
    check(try !store.installShowcaseIfNeeded(catalog: catalog), "Repeated opening never duplicates sample pages")
    check(store.workspace.notes == edited && store.selection == scene.pageID,
          "Repeated installation preserves edits and current selection")
    let reopened = try AppStore(root: root)
    check(try !reopened.installShowcaseIfNeeded(catalog: catalog), "Reopening the saved library keeps existing examples")
    check(reopened.workspace.notes.first { $0.id == scene.pageID }!.blocks.first { $0.id == editedID }!.text == "我对示例的修改必须保留。",
          "User edits survive application restart")
    check(store.trash(catalog.rootID), "Gallery can be moved to Trash as a normal subtree")
    check(try !store.installShowcaseIfNeeded(catalog: catalog), "Deleted examples remain deleted on ordinary restart")
    store.openShowcase()
    check(store.workspace.notes.filter { ids.contains($0.id) }.allSatisfy { !$0.deleted } && store.selection == catalog.rootID,
          "Explicit gallery entry can recover its deleted tree")
    check(store.workspace.notes.first { $0.id == scene.pageID }!.blocks.first { $0.id == editedID }!.text == "我对示例的修改必须保留。",
          "Recovering examples preserves the user's edits")

    // Render our own SwiftUI content offscreen; this is not a captured application window.
    let previewStore = try AppStore(root: root.appendingPathComponent("preview"))
    try previewStore.installShowcaseIfNeeded(catalog: catalog)
    let preview = ImageRenderer(content: ShowcaseHome(store: previewStore, catalog: catalog).content(columns: 2)
        .frame(width: 1080).fixedSize(horizontal: false, vertical: true)
        .background(Palette.desk).environment(\.colorScheme, .light))
    preview.scale = 1
    if let image = preview.nsImage, let tiff = image.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/validation/showcase-home.png")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: output)
        check(bitmap.pixelsWide == 1080, "Gallery SwiftUI layout renders at desktop width")
    } else { preconditionFailure("Gallery rendering failed") }

    // A partially conflicting library must never have its content silently replaced.
    let collisionRoot = root.appendingPathComponent("collision")
    let collision = try AppStore(root: collisionRoot)
    var existing = collision.workspace
    existing.notes.append(pages.first { $0.id == scene.pageID }!)
    try collision.repository.save(existing); collision.workspace = existing
    do { try collision.installShowcaseIfNeeded(catalog: catalog); preconditionFailure("Expected a collision") }
    catch ShowcaseCatalog.ContentError.collision { check(collision.workspace == existing, "Conflicting page IDs leave the library unchanged") }
    let assetFiles = (try? FileManager.default.contentsOfDirectory(at: collision.repository.assets, includingPropertiesForKeys: nil)) ?? []
    check(assetFiles.isEmpty, "ID conflicts cannot leave partial demo assets")
    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var backup = object["backup"] as! [String: Any], assets = backup["assets"] as! [String: Any]
    assets[paper.assetID!.uuidString] = Data("incorrect".utf8).base64EncodedString()
    backup["assets"] = assets; object["backup"] = backup
    let invalid = try JSONDecoder().decode(ShowcaseCatalog.self, from: JSONSerialization.data(withJSONObject: object))
    do { try invalid.validate(); preconditionFailure("Expected invalid attachment bytes") }
    catch ShowcaseCatalog.ContentError.invalid { check(true, "Corrupt embedded assets are rejected before installation") }
    print("PASS: \(count) showcase installation, persistence, undo, navigation, layout and asset assertions")
    return count
}
