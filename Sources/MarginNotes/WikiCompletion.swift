import SwiftUI
#if SWIFT_PACKAGE
import MarginCore
#endif

#if os(macOS)
/// AppKit supplies keyboard navigation and a nonmodal completion panel. Only the
/// final choice changes source, keeping previews and IME candidates out of saves.
@MainActor final class WikiCompletingTextView: NSTextView {
    var wikiProvider: ((String) -> [WikiLinkCandidate])?
    private var choices: [String: WikiLinkCandidate] = [:]
    override var rangeForUserCompletion: NSRange {
        WikiLinks.completion(in: string, caretUTF16: selectedRange().location)?.range ?? super.rangeForUserCompletion
    }
    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String]? {
        guard !hasMarkedText(), let completion = WikiLinks.completion(in: string, caretUTF16: selectedRange().location), let wikiProvider else { return nil }
        let candidates = Array(wikiProvider(completion.query).prefix(20))
        choices = Dictionary(uniqueKeysWithValues: candidates.map { candidate in
            (candidate.title + " — " + candidate.path + " [" + candidate.id.uuidString.prefix(8) + "]", candidate)
        })
        index?.pointee = candidates.isEmpty ? -1 : 0
        return candidates.map { $0.title + " — " + $0.path + " [" + $0.id.uuidString.prefix(8) + "]" }
    }
    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal: Bool) {
        guard isFinal, movement != NSCancelTextMovement, !hasMarkedText(), let candidate = choices[word],
              let completion = WikiLinks.completion(in: string, caretUTF16: selectedRange().location) else { return }
        insertText(PageLink.markdown(title: candidate.title, id: candidate.id), replacementRange: completion.range)
    }
    func offerWikiCompletion() {
        guard isEditable, !hasMarkedText(), wikiProvider != nil,
              WikiLinks.completion(in: string, caretUTF16: selectedRange().location) != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.firstResponder === self, self.isEditable, !self.hasMarkedText(),
                  WikiLinks.completion(in: self.string, caretUTF16: self.selectedRange().location) != nil else { return }
            self.complete(nil)
        }
    }
}
#endif
