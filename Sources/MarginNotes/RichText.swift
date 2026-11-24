import SwiftUI
import Combine
#if SWIFT_PACKAGE
import MarginCore
#endif
#if os(macOS)
import AppKit
typealias NativeFont = NSFont
typealias NativeColor = NSColor
typealias NativeText = NSTextView
#else
import UIKit
typealias NativeFont = UIFont
typealias NativeColor = UIColor
typealias NativeText = UITextView
#endif

enum TextAction { case bold, italic, highlight, grow(Double), font(String), fontStyle(String, Double), inlineFormula, displayFormula }
@MainActor final class TextFormatting: ObservableObject {
    var blockID: UUID?
    weak var view: NativeText?
    var didChange: (() -> Void)?
    var beforeChange: (() -> Void)?
    var markdown = false
    var changeStyle: ((TextAction) -> Void)?
    func clear() { blockID = nil; view = nil; didChange = nil; beforeChange = nil; markdown = false; changeStyle = nil }
    func apply(_ action: TextAction) {
        guard let view else { return }
        #if os(macOS)
        if let window = view.window {
            guard window.firstResponder === view,
                  NSApp.keyWindow === window || NSApp.keyWindow is NSFontPanel else { return }
        }
        guard let storage = view.textStorage else { return }
        let selected = view.selectedRange()
        #else
        let storage = view.textStorage
        let selected = view.selectedRange
        #endif
        beforeChange?()
        if markdown {
            switch action {
            case .grow, .font, .fontStyle: changeStyle?(action)
            case .bold: wrap("**", "**")
            case .italic: wrap("*", "*")
            case .highlight: wrap("==", "==")
            case .inlineFormula: wrap("$", "$")
            case .displayFormula: wrap("\n$$\n", "\n$$\n")
            }
            return
        }
        let range = selected.length > 0 ? selected : NSRange(location: 0, length: storage.length)
        func changed(_ attrs: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var result = attrs
            let font = attrs[.font] as? NativeFont ?? NativeFont.systemFont(ofSize: 18)
            switch action {
            case .highlight:
                if attrs[.backgroundColor] != nil { result.removeValue(forKey: .backgroundColor) }
                else { result[.backgroundColor] = NativeColor.systemYellow.withAlphaComponent(0.40) }
            case .grow(let amount):
                let size = min(96, max(10, font.pointSize + CGFloat(amount)))
                #if os(macOS)
                result[.font] = NSFontManager.shared.convert(font, toSize: size)
                #else
                result[.font] = font.withSize(size)
                #endif
            case .font(let name): result[.font] = name == "system" ? NativeFont.systemFont(ofSize: font.pointSize) : (NativeFont(name: name, size: font.pointSize) ?? font)
            case .fontStyle(let name, let size):
                result[.font] = name == "system" ? NativeFont.systemFont(ofSize: size) : (NativeFont(name: name, size: size) ?? NativeFont.systemFont(ofSize: size))
            case .bold, .italic:
                #if os(macOS)
                let manager = NSFontManager.shared
                let trait: NSFontTraitMask = { if case .bold = action { return .boldFontMask }; return .italicFontMask }()
                result[.font] = manager.traits(of: font).contains(trait) ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
                #else
                let trait: UIFontDescriptor.SymbolicTraits = { if case .bold = action { return .traitBold }; return .traitItalic }()
                var traits = font.fontDescriptor.symbolicTraits
                if traits.contains(trait) { traits.remove(trait) } else { traits.insert(trait) }
                if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { result[.font] = UIFont(descriptor: descriptor, size: font.pointSize) }
                #endif
            case .inlineFormula, .displayFormula: break
            }
            return result
        }
        storage.beginEditing()
        var changes: [(NSRange, [NSAttributedString.Key: Any])] = []
        if range.length > 0 { storage.enumerateAttributes(in: range) { attrs, range, _ in changes.append((range, changed(attrs))) } }
        for (range, attrs) in changes { storage.setAttributes(attrs, range: range) }
        view.typingAttributes = changed(view.typingAttributes)
        storage.endEditing(); didChange?()
        #if os(macOS)
        view.window?.makeFirstResponder(view)
        #else
        view.becomeFirstResponder()
        #endif
    }
    private func wrap(_ prefix: String, _ suffix: String) {
        guard let view else { return }
        #if os(macOS)
        let selected = view.selectedRange()
        let all = view.string as NSString
        #else
        let selected = view.selectedRange
        let all = (view.text ?? "") as NSString
        #endif
        guard selected.location + selected.length <= all.length else { return }
        var replacement = selected
        var value = prefix + all.substring(with: selected) + suffix
        var offset = prefix.utf16.count
        let before = prefix.utf16.count, after = suffix.utf16.count
        if selected.location >= before, selected.location + selected.length + after <= all.length,
           all.substring(with: NSRange(location: selected.location - before, length: before)) == prefix,
           all.substring(with: NSRange(location: selected.location + selected.length, length: after)) == suffix {
            replacement = NSRange(location: selected.location - before, length: selected.length + before + after)
            value = all.substring(with: selected); offset = 0
        }
        #if os(macOS)
        view.insertText(value, replacementRange: replacement)
        view.setSelectedRange(NSRange(location: replacement.location + offset, length: selected.length))
        view.window?.makeFirstResponder(view)
        #else
        if let start = view.position(from: view.beginningOfDocument, offset: replacement.location),
           let end = view.position(from: start, offset: replacement.length), let range = view.textRange(from: start, to: end) {
            view.replace(range, withText: value)
            view.selectedRange = NSRange(location: replacement.location + offset, length: selected.length)
            view.becomeFirstResponder()
        }
        #endif
        didChange?()
    }
}

@MainActor private func attributed(_ block: Block) -> NSAttributedString {
    if !block.usesMarkdown, let rtf = block.rtf, let result = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) { return result }
    let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
    let font = block.usesMarkdown ? NativeFont.monospacedSystemFont(ofSize: CGFloat(min(block.fontSize, 20)), weight: .regular) : NativeFont.systemFont(ofSize: CGFloat(block.fontSize))
    return NSAttributedString(string: block.text, attributes: [.font: font,
        .foregroundColor: NativeColor(white: 0.17, alpha: 1), .paragraphStyle: paragraph])
}

@MainActor enum TextBlockLayout {
    /// Match the editor's insets and TextKit wrapping in document points, independently of zoom.
    static func height(_ block: Block) -> Double {
        let storage = NSTextStorage(attributedString: attributed(block))
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(30, block.frame.width - 24), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 5
        layout.addTextContainer(container); storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let content = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        return ceil(max(content, block.fontSize * 1.3) + 22)
    }
}

#if os(macOS)
@MainActor struct RichTextEditor: NSViewRepresentable {
    let block: Block
    let formatting: TextFormatting
    let focus: () -> Void
    let checkpoint: () -> Void
    var changeStyle: ((TextAction) -> Void)? = nil
    var editable = true
    var requestFocus = false
    var measuredHeight: ((Block, Double) -> Void)? = nil
    var wikiProvider: ((String) -> [WikiLinkCandidate])? = nil
    var wikiSelectionChanged: ((String, Int) -> Void)? = nil
    let save: (Data?, String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let text = WikiCompletingTextView(frame: NSRect(x: 0, y: 0, width: block.frame.width, height: block.frame.height - 27))
        text.wikiProvider = block.usesMarkdown ? wikiProvider : nil
        text.isRichText = !block.usesMarkdown; text.importsGraphics = false; text.allowsUndo = true; text.drawsBackground = false
        text.isEditable = editable; text.isSelectable = editable
        if block.usesMarkdown {
            text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
            text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
            text.isContinuousSpellCheckingEnabled = false
        }
        text.isHorizontallyResizable = false; text.isVerticallyResizable = true
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: block.frame.width, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 12, height: 10)
        text.textStorage?.setAttributedString(attributed(block)); text.delegate = context.coordinator
        context.coordinator.lastData = block.rtf; context.coordinator.lastText = block.text
        scroll.documentView = text; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        view.isEditable = editable; view.isSelectable = editable
        (view as? WikiCompletingTextView)?.wikiProvider = block.usesMarkdown ? wikiProvider : nil
        guard !view.hasMarkedText() else { return }
        if !requestFocus { context.coordinator.requestedFocus = false }
        if context.coordinator.lastData != block.rtf || context.coordinator.lastText != block.text || context.coordinator.fontSize != block.fontSize {
            let cursor = min(view.selectedRange().location, block.text.utf16.count)
            view.textStorage?.setAttributedString(attributed(block)); view.setSelectedRange(NSRange(location: cursor, length: 0))
            context.coordinator.lastData = block.rtf; context.coordinator.lastText = block.text
            context.coordinator.fontSize = block.fontSize
        }
        context.coordinator.measure()
        if requestFocus && editable && !context.coordinator.requestedFocus {
            context.coordinator.requestedFocus = true
            DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
                guard let view, coordinator?.parent.requestFocus == true, view.isEditable else { return }
                view.window?.makeFirstResponder(view)
                coordinator?.activate(view)
            }
        }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let text = scroll.documentView as? NSTextView, text.hasMarkedText() else { return }
        text.unmarkText(); coordinator.changed(text)
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor; var lastData: Data?; var lastText = ""
        var fontSize = 0.0; var requestedFocus = false
        var lastMeasurement: String?
        init(_ parent: RichTextEditor) { self.parent = parent }
        func textDidBeginEditing(_ notification: Notification) {
            parent.checkpoint(); activate(notification.object as? NSTextView)
        }
        func textViewDidChangeSelection(_ notification: Notification) { activate(notification.object as? NSTextView) }
        func textDidEndEditing(_ notification: Notification) {
            if let view = notification.object as? NSTextView { changed(view) }
        }
        func activate(_ view: NSTextView?) {
            guard parent.editable, let view, view.window?.firstResponder === view else { return }
            parent.focus(); parent.formatting.blockID = parent.block.id
            parent.formatting.view = view; parent.formatting.beforeChange = parent.checkpoint
            parent.formatting.markdown = parent.block.usesMarkdown; parent.formatting.changeStyle = parent.changeStyle
            parent.formatting.didChange = { [weak self, weak view] in if let view { self?.changed(view) } }
        }
        func textDidChange(_ notification: Notification) { if let view = notification.object as? NSTextView { changed(view); (view as? WikiCompletingTextView)?.offerWikiCompletion() } }
        func changed(_ view: NSTextView) {
            guard !view.hasMarkedText() else { return }
            let source = view.string
            if parent.block.usesMarkdown {
                guard lastText != source || lastData != nil else { return }
                lastText = source; lastData = nil; parent.save(nil, source)
            } else if let storage = view.textStorage,
                      let data = try? storage.data(from: NSRange(location: 0, length: storage.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                lastText = source; lastData = data; parent.save(data, source)
            }
            measure(text: source, data: lastData)
        }
        func measure(text: String? = nil, data: Data? = nil) {
            guard let callback = parent.measuredHeight else { return }
            var block = parent.block
            if let text { block.text = text; block.rtf = data }
            let key = "\(block.frame.width)|\(block.fontSize)|\(block.text)|\(block.rtf?.hashValue ?? 0)"
            guard key != lastMeasurement else { return }; lastMeasurement = key
            let height = TextBlockLayout.height(block)
            DispatchQueue.main.async { callback(block, height) }
        }
    }
}
#else
@MainActor struct RichTextEditor: UIViewRepresentable {
    let block: Block
    let formatting: TextFormatting
    let focus: () -> Void
    let checkpoint: () -> Void
    var changeStyle: ((TextAction) -> Void)? = nil
    var editable = true
    var requestFocus = false
    var measuredHeight: ((Block, Double) -> Void)? = nil
    var wikiProvider: ((String) -> [WikiLinkCandidate])? = nil
    var wikiSelectionChanged: ((String, Int) -> Void)? = nil
    let save: (Data?, String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let text = UITextView(); text.backgroundColor = .clear; text.delegate = context.coordinator
        text.isEditable = editable; text.isSelectable = editable
        if block.usesMarkdown {
            text.smartQuotesType = .no; text.smartDashesType = .no; text.autocorrectionType = .no
            text.autocapitalizationType = .none; text.spellCheckingType = .no
        }
        text.allowsEditingTextAttributes = !block.usesMarkdown; text.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        text.attributedText = attributed(block)
        context.coordinator.lastData = block.rtf; context.coordinator.lastText = block.text; return text
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.isEditable = editable; view.isSelectable = editable
        guard view.markedTextRange == nil else { return }
        if !requestFocus { context.coordinator.requestedFocus = false }
        if context.coordinator.lastData != block.rtf || context.coordinator.lastText != block.text || context.coordinator.fontSize != block.fontSize {
            let cursor = min(view.selectedRange.location, block.text.utf16.count)
            view.attributedText = attributed(block); view.selectedRange = NSRange(location: cursor, length: 0)
            context.coordinator.lastData = block.rtf; context.coordinator.lastText = block.text
            context.coordinator.fontSize = block.fontSize
        }
        context.coordinator.measure()
        if requestFocus && editable && !context.coordinator.requestedFocus {
            context.coordinator.requestedFocus = true
            DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
                guard coordinator?.parent.requestFocus == true, view?.isEditable == true else { return }
                view?.becomeFirstResponder()
            }
        }
    }
    static func dismantleUIView(_ text: UITextView, coordinator: Coordinator) {
        guard text.markedTextRange != nil else { return }
        text.unmarkText(); coordinator.textViewDidChange(text)
    }
    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichTextEditor; var lastData: Data?; var lastText = ""
        var fontSize = 0.0; var requestedFocus = false
        var lastMeasurement: String?
        init(_ parent: RichTextEditor) { self.parent = parent }
        func textViewDidBeginEditing(_ view: UITextView) {
            parent.checkpoint(); parent.focus(); parent.formatting.blockID = parent.block.id
            parent.formatting.view = view; parent.formatting.beforeChange = parent.checkpoint
            parent.formatting.markdown = parent.block.usesMarkdown; parent.formatting.changeStyle = parent.changeStyle
            parent.formatting.didChange = { [weak self, weak view] in if let view { self?.textViewDidChange(view) } }
        }
        func textViewDidChangeSelection(_ view: UITextView) {
            guard parent.editable, parent.block.usesMarkdown, view.markedTextRange == nil else { return }
            parent.wikiSelectionChanged?(view.text ?? "", view.selectedRange.location)
        }
        func textViewDidChange(_ view: UITextView) {
            guard view.markedTextRange == nil else { return }
            if parent.editable && parent.block.usesMarkdown { parent.wikiSelectionChanged?(view.text ?? "", view.selectedRange.location) }
            let source = view.text ?? ""
            if parent.block.usesMarkdown {
                guard lastText != source || lastData != nil else { return }
                lastText = source; lastData = nil; parent.save(nil, source)
            } else if let data = try? view.attributedText.data(from: NSRange(location: 0, length: view.attributedText.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                lastText = source; lastData = data; parent.save(data, source)
            }
            measure(text: source, data: lastData)
        }
        func textViewDidEndEditing(_ view: UITextView) {
            if view.text != lastText { textViewDidChange(view) }
        }
        func measure(text: String? = nil, data: Data? = nil) {
            guard let callback = parent.measuredHeight else { return }
            var block = parent.block
            if let text { block.text = text; block.rtf = data }
            let key = "\(block.frame.width)|\(block.fontSize)|\(block.text)|\(block.rtf?.hashValue ?? 0)"
            guard key != lastMeasurement else { return }; lastMeasurement = key
            let height = TextBlockLayout.height(block)
            DispatchQueue.main.async { callback(block, height) }
        }
    }
}
#endif
