import Foundation
#if SWIFT_PACKAGE
import MarginCore
#endif
#if os(macOS)
import AppKit
import UniformTypeIdentifiers

struct ClipboardBinaryFile {
    let data: Data
    let suggestedFilename: String
}

/// Reads representations already supplied by the pasteboard. File promises and
/// image conversion never create temporary files here; storage belongs to the
/// caller's captured page/archive transaction.
@MainActor enum CanvasPasteboardContents {
    static let legacyFilenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    static let canvasBlocks = NSPasteboard.PasteboardType("app.libere.canvas-blocks")
    static let legacyBlocks = NSPasteboard.PasteboardType("app.marginnotes.block-reference")

    static func blockData(from pasteboard: NSPasteboard) -> Data? {
        pasteboard.data(forType: canvasBlocks) ?? pasteboard.data(forType: legacyBlocks)
    }
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var result: [URL] = [], seen: Set<String> = []
        func append(_ url: URL?) {
            guard let url, url.isFileURL, url.path.hasPrefix("/") else { return }
            let normalized = url.standardizedFileURL
            let identity = normalized.resolvingSymlinksInPath().path
            // Retain the URL supplied by AppKit, including any access scope it
            // carries. Canonicalization is only for deduplication, not a rewrite.
            if seen.insert(identity).inserted { result.append(url) }
        }
        let types = pasteboard.types ?? []
        if types.contains(.fileURL) || types.contains(.URL),
           let values = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly:true]) {
            for value in values { append(value as? URL) }
        }
        // Some apps advertise only item-level fileURL strings/data, or the older
        // Finder filename property list. Keep their order while merging aliases.
        for item in pasteboard.pasteboardItems ?? [] {
            for type in [NSPasteboard.PasteboardType.fileURL, .URL] {
                let value = item.string(forType: type) ?? item.data(forType: type).flatMap { String(data:$0,encoding:.utf8) }
                if let value { append(fileURL(value, acceptsPath:type == .fileURL)) }
            }
            if let paths = item.propertyList(forType: legacyFilenames) as? [String] {
                for path in paths { append(fileURL(path, acceptsPath:true)) }
            }
        }
        if let paths = pasteboard.propertyList(forType: legacyFilenames) as? [String] {
            for path in paths { append(fileURL(path, acceptsPath:true)) }
        }
        return result
    }
    private static func fileURL(_ value: String, acceptsPath: Bool) -> URL? {
        if let url = URL(string:value), url.isFileURL { return url }
        guard acceptsPath, value.hasPrefix("/") || value.hasPrefix("~/") else { return nil }
        return URL(fileURLWithPath:(value as NSString).expandingTildeInPath)
    }
    static func binaryFile(from pasteboard: NSPasteboard) -> ClipboardBinaryFile? {
        let representations: [(String,String)] = [
            (UTType.png.identifier,"剪贴板图片.png"),
            (UTType.jpeg.identifier,"剪贴板图片.jpg"),
            (UTType.tiff.identifier,"剪贴板图片.tiff"),
            (UTType.heic.identifier,"剪贴板图片.heic"),
            (UTType.gif.identifier,"剪贴板图片.gif"),
            (UTType.pdf.identifier,"剪贴板文档.pdf")
        ]
        for (type, filename) in representations {
            if let data = pasteboard.data(forType:NSPasteboard.PasteboardType(type)), !data.isEmpty {
                return ClipboardBinaryFile(data:data,suggestedFilename:filename)
            }
        }
        return nil
    }
    static func textFileURLs(_ text: String, libraryRoot: URL) -> [URL]? {
        let lines = text.components(separatedBy:.newlines).filter { !$0.trimmingCharacters(in:.whitespaces).isEmpty }
        guard !lines.isEmpty else { return nil }
        var urls: [URL] = []
        for line in lines {
            var value = line.trimmingCharacters(in:.whitespaces)
            if value.count > 1, (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") { value = String(value.dropFirst().dropLast()) }
            guard let url = fileURL(value,acceptsPath:true), url.isFileURL else { return nil }
            // A slash-prefixed sentence/API route is still ordinary text. An
            // explicit file URL or a path within the library may report missing.
            guard value.hasPrefix("file://") || ReferencePath.relative(url,inside:libraryRoot) != nil || FileManager.default.fileExists(atPath:url.path) else { return nil }
            urls.append(url)
        }
        return urls
    }
}
#endif
