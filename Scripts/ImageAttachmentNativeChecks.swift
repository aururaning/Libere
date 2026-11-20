import Foundation
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

@MainActor func runImageAttachmentNativeChecks() async throws -> Int {
    var count = 0
    func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereImageCheck-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(root: root)
    store.create(); store.cancelRename(); store.snap = false
    let noteID = store.selection!
    let fixtures = root.appendingPathComponent("Fixtures", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)

    // Four distinct quadrants expose real orientation errors; a transparent corner
    // separately checks that decoding does not flatten alpha into the image bytes.
    func raster(width: Int, height: Int, transparent: Bool = false) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        // Fixtures use top-left image coordinates; a raw CGContext starts at the
        // bottom-left, unlike the decoded raster rows checked below.
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        let halfWidth = CGFloat(width) / 2, halfHeight = CGFloat(height) / 2
        let quadrants: [(CGFloat, CGFloat, CGColor)] = [(0, 0, CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
            (halfWidth, 0, CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
            (0, halfHeight, CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
            (halfWidth, halfHeight, CGColor(red: 1, green: 1, blue: 0, alpha: 1))]
        for (x, y, color) in quadrants {
            context.setFillColor(color); context.fill(CGRect(x: x, y: y, width: halfWidth, height: halfHeight))
        }
        if transparent { context.clear(CGRect(x: 0, y: 0, width: width / 8, height: height / 8)) }
        return context.makeImage()!
    }
    func write(_ image: CGImage, name: String, type: UTType, orientation: Int = 1) throws -> URL {
        let url = fixtures.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination), "Image fixture must be encoded")
        return url
    }
    func pixels(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    func rgb(_ image: CGImage, x: Int, y: Int) -> [Int] {
        let data = pixels(image), offset = (y * image.width + x) * 4
        return (0..<3).map { Int(data[offset + $0]) }
    }
    // JPEG color profiles can shift channel values. Classify the distinct primary
    // quadrants without mistaking lossy/color-managed values for a rotation error.
    func near(_ actual: [Int], _ expected: [Int]) -> Bool {
        zip(actual, expected).allSatisfy { $1 == 0 ? $0 < 80 : $0 > 200 }
    }

    let pngURL = try write(raster(width: 400, height: 600, transparent: true), name: "透明.PNG", type: .png)
    let pngBytes = try Data(contentsOf: pngURL)
    let png = try AttachmentImage.load(from: pngURL)
    check(png.size == CGSize(width: 400, height: 600) && png.image.width == 400 && png.image.height == 600,
          "PNG preview preserves the original dimensions and aspect ratio")
    let pngPixels = pixels(png.image)
    let alpha = stride(from: 3, to: pngPixels.count, by: 4).map { pngPixels[$0] }
    check(alpha.filter { $0 == 0 }.count == (400 / 8) * (600 / 8)
          && alpha.filter { $0 == 255 }.count == 400 * 600 - (400 / 8) * (600 / 8),
          "Transparent and opaque PNG pixels survive native decoding")
    check(AttachmentFormat(filename: "透明.PNG") == .image && !AttachmentFormat.image.isTextEditable,
          "Uppercase image extensions resolve to a non-text attachment")
    check(AttachmentFormat.importTypes.contains { $0.identifier == UTType.png.identifier }
          && AttachmentFormat.importTypes.contains { $0.identifier == UTType.jpeg.identifier },
          "The actual file picker's allowed types include PNG and JPEG")

    let jpegURL = try write(raster(width: 80, height: 40), name: "rotated.jpg", type: .jpeg, orientation: 6)
    let jpegBytes = try Data(contentsOf: jpegURL)
    let rotated = try AttachmentImage.load(from: jpegURL)
    check(rotated.size == CGSize(width: 40, height: 80) && rotated.image.width == 40 && rotated.image.height == 80,
          "EXIF orientation swaps both the document dimensions and the decoded bitmap")
    check(near(rgb(rotated.image, x: 10, y: 20), [0, 0, 255])
          && near(rgb(rotated.image, x: 30, y: 20), [255, 0, 0])
          && near(rgb(rotated.image, x: 10, y: 60), [255, 255, 0])
          && near(rgb(rotated.image, x: 30, y: 60), [0, 255, 0]),
          "EXIF rotation moves the actual image quadrants, not only the reported size")

    let longURL = try write(raster(width: 256, height: 9000), name: "long.png", type: .png)
    let long = try AttachmentImage.load(from: longURL)
    check(long.size == CGSize(width: 256, height: 9000) && long.image.width == 256 && long.image.height == 9000,
          "A narrow long image retains its readable full width instead of being reduced to a tiny thumbnail")
    let largeURL = try write(raster(width: 5000, height: 5000), name: "large.png", type: .png)
    let large = try AttachmentImage.load(from: largeURL)
    check(large.size == CGSize(width: 5000, height: 5000) && large.image.width < 5000
          && large.image.width * large.image.height <= 16_777_216 + 2 * 32768
          && large.image.width <= 32768 && large.image.height <= 32768,
          "Large square images respect the decode pixel budget while preserving original document dimensions")
    check(try Data(contentsOf: pngURL) == pngBytes && Data(contentsOf: jpegURL) == jpegBytes,
          "Decoding and orientation correction never rewrite source files")

    // A multi-page TIFF is deliberately presented as one stable first-frame paper.
    let tiffURL = fixtures.appendingPathComponent("multipage.tiff")
    let tiff = CGImageDestinationCreateWithURL(tiffURL as CFURL, UTType.tiff.identifier as CFString, 2, nil)!
    CGImageDestinationAddImage(tiff, raster(width: 80, height: 40), nil)
    CGImageDestinationAddImage(tiff, raster(width: 30, height: 100), nil)
    precondition(CGImageDestinationFinalize(tiff))
    let firstFrame = try AttachmentImage.load(from: tiffURL)
    check(firstFrame.size == CGSize(width: 80, height: 40)
          && near(rgb(firstFrame.image, x: 20, y: 10), [255, 0, 0]),
          "A multi-page image consistently previews the first frame")

    store.importFile(pngURL)
    let original = store.block!
    check(original.kind == .file && original.assetName == pngURL.lastPathComponent && original.assetID == nil && original.relativeFilePath != nil,
          "Import creates a normal persistent image attachment block")
    check(try Data(contentsOf: store.attachmentURL(for: original)!) == pngBytes
          && original.referencedAssets.isEmpty,
          "Imported image bytes and their fingerprint match the unmodified original")
    do { _ = try store.textFileSession(noteID: noteID, blockID: original.id); preconditionFailure("Images must not create text sessions") }
    catch { check(true, "The store refuses to decode an image into an editable text session") }
    func current(_ id: UUID) -> Block { store.workspace.notes.first { $0.id == noteID }!.blocks.first { $0.id == id }! }
    let inside = InkDestination(noteID: noteID, blockID: original.id, page: 0)
    store.saveInk(Data([9, 8, 7]), bounds: Rect(12, 14, 30, 40), to: InkDestination(noteID: noteID))
    store.editBlock(original.id) { $0.locked = true }
    let locked = current(original.id)
    let annotationID = store.insertPageText(at: CGPoint(x: 100, y: 200), paper: CGSize(width: 740, height: 1110),
                                            destination: inside, clickCount: 2)
    store.saveInk(Data([4, 5, 6]), bounds: Rect(20, 30, 80, 90), to: inside)
    check(annotationID != nil && current(original.id).annotations(on: 0).texts.count == 1
          && current(original.id).annotations(on: 0).ink == Data([4, 5, 6]),
          "A locked image still accepts independent page text and handwriting")
    store.setFrame(original.id, Rect(locked.frame.x + 100, locked.frame.y + 100, 500, 700))
    check(current(original.id).frame == locked.frame && current(original.id).locked
          && store.note!.ink == Data([9, 8, 7]), "Image annotations and a rejected locked move leave its frame and outside ink fixed")
    store.addReference(FileReferenceChoice(noteID: noteID, block: current(original.id), title: "图片引用"))
    let reference = store.block!
    check(reference.id != original.id && reference.assetID == original.assetID && reference.fileIdentity == original.fileIdentity
          && reference.pageAnnotations == nil && !reference.locked, "Image references share source bytes but have independent annotations and position")
    store.referenceFile(jpegURL)
    let direct = store.block!
    check(direct.kind == .file && direct.relativeFilePath == "Fixtures/rotated.jpg" && direct.assetID == nil,
          "A library image can be referenced directly without copying it into Assets")
    check(try Data(contentsOf: store.attachmentURL(for: direct)!) == jpegBytes, "Direct image references keep EXIF and original bytes intact")

    let invalidURL = fixtures.appendingPathComponent("not-an-image.png")
    try Data("This is plain text, not a PNG".utf8).write(to: invalidURL)
    let truncatedURL = fixtures.appendingPathComponent("truncated.jpg")
    try jpegBytes.prefix(100).write(to: truncatedURL)
    let beforeInvalid = store.workspace
    let assetsBeforeInvalid = Set((try? FileManager.default.contentsOfDirectory(atPath: store.repository.assets.path)) ?? [])
    for url in [invalidURL, truncatedURL] {
        do { _ = try AttachmentImage.load(from: url); preconditionFailure("An invalid image must be rejected") }
        catch { check(true, "ImageIO rejects unreadable or truncated image content") }
        store.importFile(url); store.referenceFile(url)
    }
    let assetsAfterInvalid = Set((try? FileManager.default.contentsOfDirectory(atPath: store.repository.assets.path)) ?? [])
    check(store.workspace == beforeInvalid && assetsAfterInvalid == assetsBeforeInvalid,
          "Rejected image imports and references create neither blocks nor orphaned assets")

    // The real file-content view must reach its native image paper instead of a
    // text editor or WebKit path, and a tall image must expose internal scrolling.
    store.importFile(longURL)
    let longBlock = store.block!
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: FileBlockContent(store: store, noteID: noteID, block: longBlock).frame(width: 300, height: 240))
    window.contentView = host
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    var imageViewport: CanvasScrollView?
    for _ in 0..<100 {
        host.layoutSubtreeIfNeeded()
        imageViewport = descendants(host).compactMap { $0 as? CanvasScrollView }.first { $0.attachmentBlockID == longBlock.id }
        if imageViewport != nil { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    guard let imageViewport else { preconditionFailure("The loaded image must create an attachment paper viewport") }
    imageViewport.layoutSubtreeIfNeeded(); imageViewport.host.layoutSubtreeIfNeeded()
    check(abs(imageViewport.paper.frame.width - 300) < 1 && abs(imageViewport.paper.frame.height - 9000.0 / 256 * 300) < 1,
          "The native image preview preserves its long aspect ratio rather than cropping or stretching")
    let scrollOrigin = imageViewport.contentView.bounds.origin
    check(imageViewport.scrollPaper(delta: CGSize(width: 0, height: -80), precise: true)
          && imageViewport.contentView.bounds.minY > scrollOrigin.y && current(longBlock.id).frame == longBlock.frame,
          "Wheel input scrolls the long image internally without moving its canvas block")
    check(!descendants(host).contains { $0 is NSTextView }, "Image preview never creates a native source editor")
    window.contentView = nil

    let backup = try store.backup(), backupURL = root.appendingPathComponent("images.marginbackup")
    try backup.data.write(to: backupURL)
    let restored = try AppStore(root: root.appendingPathComponent("Restored"))
    try restored.importBackup(backupURL)
    let restoredNote = restored.workspace.notes.first { $0.id == noteID }!
    let restoredOriginal = restoredNote.blocks.first { $0.id == original.id }!
    let restoredDirect = restoredNote.blocks.first { $0.id == direct.id }!
    check(restoredOriginal == current(original.id) && restoredNote.ink == store.note!.ink,
          "A backup round trip retains the image frame, lock and both annotation layers")
    check(restoredOriginal.relativeFilePath == original.relativeFilePath && restoredDirect.relativeFilePath == direct.relativeFilePath,
          "Index backups retain image paths and never turn direct references into attachments")
    check(!FileManager.default.fileExists(atPath: restored.repository.assets.path)
          && !FileManager.default.fileExists(atPath: restored.attachmentURL(for: restoredOriginal)!.path),
          "Restoring image indexes does not duplicate original files")
    check(store.flush(), "Image fixture saves successfully")
    let reopened = try AppStore(root: root)
    check(reopened.workspace.notes.first { $0.id == noteID }!.blocks == store.note!.blocks,
          "Imported images, references and annotations survive application restart")

    // Exercise the real local Agent service with the same bytes, without opening a
    // network listener. Images cannot accidentally enter the text-file decoder.
    let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/MarginNotes/Resources")
    let service = AgentDocumentService(store: store, resources: resources)
    func call(_ tool: String, _ args: [String: Any], status: Int = 200) throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["tool": tool, "arguments": args, "requestID": UUID().uuidString, "workspaceID": service.workspaceID])
        var wire = Data("POST /v1/call HTTP/1.1\r\nHost: 127.0.0.1:19879\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        wire.append(body)
        let response = service.handle(try AgentHTTPRequest.parse(wire)!)
        check(response.status == status, "Image Agent request \(tool) expected \(status), got \(response.status)")
        return try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
    }
    let agentResult = try call("create_page", ["title": "图片 API 测试", "blocks": [["kind": "file", "filePath": ReferencePath.relative(pngURL, inside: root)!]]])
    let agentNoteID = UUID(uuidString: (agentResult["page"] as! [String: Any])["id"] as! String)!
    let agentBlock = store.workspace.notes.first { $0.id == agentNoteID }!.blocks[0]
    check(try agentBlock.kind == .file && Data(contentsOf: store.attachmentURL(for: agentBlock)!) == pngBytes,
          "Agent attachment creation imports real image bytes without conversion")
    let raw = try call("read_attachment", ["pageID": agentNoteID.uuidString, "blockID": agentBlock.id.uuidString, "format": "base64"])
    check(raw["dataBase64"] as? String == pngBytes.base64EncodedString(), "Agent image reads return the exact original")
    _ = try call("read_attachment", ["pageID": agentNoteID.uuidString, "blockID": agentBlock.id.uuidString, "format": "text"], status: 422)
    let beforeAgentFailure = store.workspace
    _ = try call("create_page", ["title": "不应创建", "blocks": [["kind": "attachment", "filename": "fake.png", "dataBase64": Data("fake PNG".utf8).base64EncodedString()]]], status: 422)
    check(store.workspace == beforeAgentFailure, "An invalid image Agent request leaves no partial page or attachment")

    print("PASS: \(count) image decoding, orientation, alpha, import, scrolling, annotation, reference, backup and Agent assertions")
    return count
}
