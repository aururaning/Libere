#if os(macOS)
import AppKit
@MainActor final class FontPanel: NSObject {
    static let shared = FontPanel()
    private static var rtfFontNames: [String: String] = [:]
    private weak var store: AppStore?
    func show(_ store: AppStore) {
        self.store = store
        let font = selectedFont(in: store)
        let manager = NSFontManager.shared
        manager.setSelectedFont(font, isMultiple: false); manager.target = self; manager.action = #selector(changeFont(_:))
        manager.orderFrontFontPanel(nil)
    }
    @objc func changeFont(_ sender: NSFontManager) {
        guard let store else { return }
        let old = selectedFont(in: store)
        let new = sender.convert(old)
        store.applyFontPanel(family: new.fontName, size: new.pointSize)
    }
    func selectedFont(in store: AppStore) -> NSFont {
        if let view = store.formatting.view, store.formatting.blockID == store.blockSelection {
            if let storage = view.textStorage, storage.length > 0,
               let font = storage.attribute(.font, at: min(view.selectedRange().location, storage.length - 1), effectiveRange: nil) as? NSFont { return font }
            if let font = view.typingAttributes[.font] as? NSFont { return font }
        }
        if let block = store.block, !block.usesMarkdown, let data = block.rtf,
           let value = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
           value.length > 0, let font = value.attribute(.font, at: 0, effectiveRange: nil) as? NSFont { return font }
        let size = store.block?.fontSize ?? 18
        return NSFont(name: store.block?.fontFamily ?? "", size: size) ?? .systemFont(ofSize: size)
    }
    /// RTF normalizes private system font names (for example, the system font may
    /// round-trip as HelveticaNeue). Compare that durable identity so selecting
    /// the same system font again does not create a phantom formatting operation.
    static func persistedFontName(_ font: NSFont) -> String {
        if let name = rtfFontNames[font.fontName] { return name }
        let sample = NSAttributedString(string: "x", attributes: [.font: font])
        let bytes = try? sample.data(from: NSRange(location: 0, length: 1), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let decoded = bytes.flatMap { try? NSAttributedString(data: $0, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) }
        let name = (decoded?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontName ?? font.fontName
        rtfFontNames[font.fontName] = name; return name
    }
}
#endif
