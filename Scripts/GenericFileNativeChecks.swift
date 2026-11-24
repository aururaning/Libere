import Foundation
import SwiftUI
import WebKit
import UniformTypeIdentifiers

@MainActor func runGenericFileNativeChecks() async throws -> Int {
    _ = NSApplication.shared
    var checks = 0
    func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereGenericFiles-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data([0x00, 0xFF, 0xFE, 0x80, 0x13, 0x37])
    let names = ["报告.docx", "数据.xlsx", "讲稿.pptx", "压缩包.zip", "视频.mp4", "音频.mp3", "图稿.fig", "程序.exe", "unknown.liberefixture", "README"]
    var opened: [URL] = []
    for name in names {
        let url = root.appendingPathComponent(name); try bytes.write(to: url)
        check(AttachmentFormat(filename: name) == nil, "Unsupported \(name) is not misclassified as editable text")
        check(try FileIndexPolicy.path(for: url, inside: root) == name, "Regular file eligibility does not depend on a preview extension")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        let preview = GenericFilePreview(url: url, filename: name, openFile: { opened.append($0) })
        let image = ImageRenderer(content: preview.frame(width: 380, height: 280)).nsImage
        check(image != nil, "Generic \(name) renders its file card without permission to read file contents")
        check(opened.isEmpty, "Rendering a generic file never opens or executes it")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        check(try Data(contentsOf: url) == bytes, "Rendering leaves \(name) bytes unchanged")
    }
    let selected = root.appendingPathComponent("程序.exe")
    GenericFilePreview(url: selected, filename: "程序.exe", openFile: { opened.append($0) }).openOriginal()
    check(opened == [selected], "Only an explicit open action passes the original file URL to the system opener")
    GenericFilePreview(url: URL(string: "https://example.com/program.exe")!, filename: "program.exe", openFile: { opened.append($0) }).openOriginal()
    check(opened == [selected], "The generic file action does not accept a non-file URL")
    check(GenericFileDescriptor(filename: "README").kind == "文件", "Extensionless originals have a neutral file label")
    check(GenericFileDescriptor(filename: "Report.DoCx").kind == "DOCX 文件", "Unknown formats show their type without trying to decode it")
    let folder = root.appendingPathComponent("folder")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    do { _ = try FileIndexPolicy.path(for: folder, inside: root); preconditionFailure("Folder unexpectedly indexed as a regular file") }
    catch { check(true, "Source folders remain subject to the regular-file policy") }
    check([UTType.zip, .movie, .audio, .data].allSatisfy { candidate in AttachmentFormat.importTypes.contains { candidate.conforms(to: $0) } },
          "The file picker admits ordinary archives, media and unknown data")
    check(!AttachmentFormat.importTypes.contains { UTType.folder.conforms(to: $0) }, "The broadened file picker does not turn directories into files")

    let store = try AppStore(root: root.appendingPathComponent("library")); store.create(); store.cancelRename()
    let original = store.repository.root.appendingPathComponent("原件.bin"); try bytes.write(to: original)
    var block = Block(.file, frame: Rect(20,20,380,300)); block.assetName = original.lastPathComponent; block.relativeFilePath = original.lastPathComponent
    store.edit { $0.blocks = [block] }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 340), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: AttachmentSurface(store: store, noteID: store.selection!, block: block, page: 0).frame(width: 380, height: 300))
    window.contentView = host
    defer { window.contentView = nil; store.flush() }
    for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 15_000_000) }
    check(!descendants(host).contains { $0 is WKWebView || $0 is NSTextView }, "The reader fallback creates neither a browser document nor a source editor for unknown binary content")
    check(try Data(contentsOf: original) == bytes && !FileManager.default.fileExists(atPath: store.repository.assets.path),
          "The reader fallback preserves the original without creating an attachment copy")
    print("PASS: \(checks) generic file eligibility, preview fallback and explicit-open assertions")
    return checks
}
