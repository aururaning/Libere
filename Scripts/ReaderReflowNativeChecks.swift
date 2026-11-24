import Foundation
import SwiftUI

@MainActor private final class ReaderReflowState: ObservableObject {
    @Published var zoom = 1.0
    let text: TextFileSession
    let notebook: NotebookSession
    init(root: URL, source: String) throws {
        text = try TextFileSession(data: Data(source.utf8)) { _ in }
        let notebookBytes = try JSONSerialization.data(withJSONObject: ["nbformat": 4, "metadata": [:],
            "cells": [["id": "wrap", "cell_type": "code", "source": source, "metadata": [:], "outputs": []]]])
        notebook = try NotebookSession(data: notebookBytes, directory: root) { _ in }
    }
}
@MainActor private struct ReaderTextReflowFixture: View {
    @ObservedObject var state: ReaderReflowState
    var notebook = false
    var body: some View {
        if notebook { NotebookEditor(session: state.notebook, filename: "wrap.ipynb", documentZoom: $state.zoom) }
        else { TextFileEditor(session: state.text, filename: "wrap.py", documentZoom: $state.zoom) }
    }
}

@MainActor func runReaderReflowNativeChecks() async throws -> Int {
    var count = 0
    func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1 }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func lines(_ text: NSTextView) -> Int {
        guard let manager = text.layoutManager, let container = text.textContainer else { return 0 }
        manager.ensureLayout(for: container)
        var count = 0
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, _, _ in count += 1 }
        return count
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderReflow-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = String(repeating: "alpha beta gamma delta 中文文字、长代码注释应该随可见宽度折行。 ", count: 30)
    let state = try ReaderReflowState(root: root, source: source)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: ReaderTextReflowFixture(state: state))
    window.contentView = host
    defer { window.contentView = nil; state.text.save(); state.notebook.save() }
    func settle() async throws {
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 15_000_000) }
        host.layoutSubtreeIfNeeded()
    }
    func viewport() -> CanvasScrollView? { descendants(host).compactMap { $0 as? CanvasScrollView }.first }
    func textView() -> NSTextView? { descendants(host).compactMap { $0 as? SourceInputHost }.first.flatMap { $0.textView(in: $0.host) } }
    try await settle()
    guard let text = textView(), let outer = viewport(), let undo = text.undoManager else { preconditionFailure("Missing production source editor viewport") }
    window.makeFirstResponder(text)
    let nativeIdentity = ObjectIdentifier(text), undoIdentity = ObjectIdentifier(undo), originalFontSize = text.font?.pointSize
    text.undoManager?.removeAllActions()
    undo.beginUndoGrouping(); text.insertText("Z", replacementRange: NSRange(location: (text.string as NSString).length, length: 0)); text.didChangeText(); undo.endUndoGrouping()
    text.setSelectedRange(NSRange(location: 8, length: 20))
    let selection = text.selectedRange(), initialLines = lines(text), initialWidth = text.textContainer!.containerSize.width
    var previousWidth = CGFloat.greatestFiniteMagnitude, previousLines = 0
    for zoom in [1.0, 1.5, 2.0] {
        state.zoom = zoom; try await settle()
        guard let current = textView(), let viewport = viewport() else { preconditionFailure("Reader disappeared during magnification") }
        let width = current.textContainer!.containerSize.width, lineCount = lines(current)
        check(abs(viewport.magnification - zoom) < 0.001, "Reader retains native magnification at \(zoom)")
        check(abs(viewport.paper.frame.width * viewport.magnification - viewport.contentView.frame.width) < 1.5,
              "The scaled source document exactly fits visible width at \(zoom)")
        check(abs(viewport.paper.frame.height * viewport.magnification - viewport.contentView.frame.height) < 1.5,
              "Source input viewport height stays inside its unscaled controls at \(zoom)")
        check(viewport.paper.frame.width <= viewport.contentView.bounds.width + 1.5 && abs(viewport.contentView.bounds.minX) < 1.5,
              "A settled source reader has no horizontal document overflow at \(zoom)")
        check(width < previousWidth && lineCount >= previousLines, "Native TextKit reflows into narrower logical width at \(zoom)")
        check(ObjectIdentifier(current) == nativeIdentity && current.undoManager.map(ObjectIdentifier.init) == undoIdentity,
              "Zoom reuses the native text editor and undo manager at \(zoom)")
        check(window.firstResponder === current && current.selectedRange() == selection && current.font?.pointSize == originalFontSize,
              "Zoom preserves focus and the selected range without rewriting the logical font at \(zoom)")
        previousWidth = width; previousLines = lineCount
    }
    check(previousWidth < initialWidth * 0.6 && previousLines > initialLines, "200% text visibly wraps more lines instead of extending beyond the right edge")
    check(undo.canUndo, "Editing undo remains available after reflow")
    undo.undo(); try await settle()
    check(text.string == source && state.text.document.text == source, "Undo after zoom restores both the native text and saved document model")
    text.setSelectedRange(NSRange(location: 8, length: 0))
    text.setMarkedText("pinyin", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: 8, length: 0))
    let markedRange = text.markedRange()
    state.zoom = 1.5; try await settle()
    check(textView() === text && text.hasMarkedText() && text.markedRange() == markedRange && window.firstResponder === text,
          "Changing reflow width preserves in-progress Chinese composition in the same native editor")
    check(state.text.document.text == source, "Reflow never commits an unfinished IME candidate into the model")
    if let nativeViewport = viewport() {
        let center = CGPoint(x: nativeViewport.paper.bounds.midX, y: nativeViewport.paper.bounds.midY)
        nativeViewport.applyMagnification(1.0 / 3.0, at: center, phase: .began)
        nativeViewport.applyMagnification(0, at: center, phase: .ended)
        try await settle()
        check(abs(state.zoom - 2) < 0.001
              && abs(nativeViewport.paper.frame.width * nativeViewport.magnification - nativeViewport.contentView.frame.width) < 1.5,
              "Finishing a native pinch commits the zoom and reflows the document back to the visible width")
        check(textView() === text && text.hasMarkedText() && text.markedRange() == markedRange && window.firstResponder === text,
              "Native pinch completion preserves IME composition and the original editor instead of rebuilding it")
    } else { preconditionFailure("Missing native viewport during pinch check") }
    text.insertText("拼音", replacementRange: NSRange(location: NSNotFound, length: 0)); text.didChangeText(); try await settle()
    check(!text.hasMarkedText() && state.text.document.text.contains("拼音"), "Composition still commits normally after width reflow")

    window.makeFirstResponder(nil); state.zoom = 1
    host.rootView = ReaderTextReflowFixture(state: state, notebook: true); try await settle()
    guard let notebookText = textView(), let notebookViewport = viewport() else { preconditionFailure("Missing production Notebook input") }
    let notebookID = ObjectIdentifier(notebookText), notebookWidth = notebookText.textContainer!.containerSize.width
    let controlsHeight = host.bounds.height - notebookViewport.frame.height
    for zoom in [1.5, 2.0] {
        state.zoom = zoom; try await settle()
        guard let current = textView(), let viewport = viewport() else { preconditionFailure("Missing reflowed Notebook") }
        check(abs(viewport.paper.frame.width * zoom - viewport.contentView.frame.width) < 1.5,
              "Notebook document width reflows to the visible viewport at \(zoom)")
        check(current.textContainer!.containerSize.width < notebookWidth && ObjectIdentifier(current) == notebookID,
              "Notebook cells rewrap in their existing native editor at \(zoom)")
        check(abs((host.bounds.height - viewport.frame.height) - controlsHeight) < 1.5,
              "Notebook controls retain their unscaled height at \(zoom)")
    }
    check(state.notebook.document.cells[0].source == source, "Notebook reflow never changes cell source")
    let invalid = ReaderDocumentLayout.documentSize(viewport: CGSize(width: 960, height: 680), zoom: .nan)
    check(invalid == CGSize(width: 960, height: 680), "Invalid stored zoom cannot create an invalid document size")
    withExtendedLifetime(outer) {}
    print("PASS: \(count) reader width reflow, native selection, IME and undo assertions")
    return count
}
