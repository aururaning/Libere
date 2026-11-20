#if os(macOS)
import AppKit
@MainActor final class FontPanel: NSObject {
    static let shared = FontPanel()
    private weak var store: AppStore?
    func show(_ store: AppStore) {
        self.store = store
        let size = store.block?.fontSize ?? 18
        let font = NSFont(name: store.block?.fontFamily ?? "", size: size) ?? .systemFont(ofSize: size)
        let manager = NSFontManager.shared
        manager.setSelectedFont(font, isMultiple: false); manager.target = self; manager.action = #selector(changeFont(_:))
        manager.orderFrontFontPanel(nil)
    }
    @objc func changeFont(_ sender: NSFontManager) {
        guard let store else { return }
        let old = NSFont(name: store.block?.fontFamily ?? "", size: store.block?.fontSize ?? 18) ?? .systemFont(ofSize: store.block?.fontSize ?? 18)
        let new = sender.convert(old)
        store.formatText(.font(new.fontName)); store.formatText(.grow(new.pointSize - old.pointSize))
    }
}
#endif
