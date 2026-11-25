import Foundation
import SwiftUI

@MainActor func runClipboardMoveNativeChecks() async throws -> Int {
    _ = NSApplication.shared
    var count = 0
    func check(_ value: Bool, _ label: String) {
        if !value { FileHandle.standardError.write(Data(("FAILED clipboard move: " + label + "\n").utf8)) }
        precondition(value, label); count += 1
    }
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("LibereMoveIntegration-" + UUID().uuidString)
    let root = base.appendingPathComponent("Library"), outside = base.appendingPathComponent("Outside"), receipts = base.appendingPathComponent("Receipts")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let store = try AppStore(root: root)
    store.clipboardMoves = ClipboardMoveCoordinator(store: store, receiptDirectory: receipts)
    store.create(); store.cancelRename(); let first = store.selection!
    let source = outside.appendingPathComponent("source.txt"), bytes = Data("original file\n".utf8)
    try bytes.write(to: source)
    check(store.clipboardMoves.moveFiles([source], at: CGPoint(x:180,y:210), noteID: first), "External move is accepted")
    await store.clipboardMoves.waitUntilIdle()
    guard let moved = store.block, let archived = store.attachmentURL(for: moved) else { preconditionFailure(store.message ?? "Missing moved block") }
    check(moved.frame.x == 180 && moved.frame.y == 210, "Move placement uses the captured pointer")
    check(!FileManager.default.fileExists(atPath: source.path) && (try? Data(contentsOf: archived)) == bytes,
          "A committed move removes the source only after the archived bytes are intact")
    let history = try Data(contentsOf: root.appendingPathComponent("History-" + store.device + ".json"))
    check(!(String(data: history, encoding: .utf8) ?? "").contains(outside.path), "Synced undo history never contains absolute external paths")
    store.undo(); await store.clipboardMoves.waitUntilIdle()
    check((try? Data(contentsOf: source)) == bytes && !FileManager.default.fileExists(atPath: archived.path),
          "Undo physically restores the external source")
    check(store.workspace.notes.first { $0.id == first }!.blocks.isEmpty, "Undo removes the inserted occurrence")
    store.redo(); await store.clipboardMoves.waitUntilIdle()
    check(!FileManager.default.fileExists(atPath: source.path) && (try? Data(contentsOf: archived)) == bytes,
          "Redo moves the same original back into the library")
    let fileID = moved.fileIdentity
    store.create(); store.cancelRename(); let second = store.selection!
    check(store.indexFileURLs([archived]), "Fixture creates a second alias")
    let aliasID = store.block!.id
    let session = try store.textFileSession(noteID: second, blockID: aliasID)
    store.create(); store.cancelRename(); let third = store.selection!
    check(store.clipboardMoves.moveFiles([archived], at: CGPoint(x:60,y:90), noteID: third), "A library original can move to another page")
    await store.clipboardMoves.waitUntilIdle()
    let newOriginal = store.attachmentURL(for: store.block!)!
    let aliases = store.workspace.notes.flatMap(\.blocks).filter { $0.fileIdentity == fileID }
    check(aliases.count == 3 && Set(aliases.compactMap(\.relativeFilePath)).count == 1,
          "All aliases follow the moved original, without being removed")
    check(!FileManager.default.fileExists(atPath: archived.path) && (try? Data(contentsOf: newOriginal)) == bytes,
          "Library move changes the original's physical location")
    session.edit("edited after moving"); check(session.save(), "An existing text editor saves through the updated index")
    store.undo(); await store.clipboardMoves.waitUntilIdle()
    check((try? String(contentsOf: archived, encoding: .utf8)) == "edited after moving", "Move undo keeps the latest original bytes rather than restoring a snapshot")
    store.redo(); await store.clipboardMoves.waitUntilIdle()
    check((try? String(contentsOf: newOriginal, encoding: .utf8)) == "edited after moving", "Move redo preserves edits and active file identity")

    store.select(second)
    let payload = try store.clipboardData(for: [aliasID])
    store.select(third)
    check(store.clipboardMoves.moveBlocks(payload, at: CGPoint(x:450,y:350), noteID: third), "An internal alias occurrence can be cut into another page")
    await store.clipboardMoves.waitUntilIdle()
    check(!store.workspace.notes.first { $0.id == second }!.blocks.contains { $0.id == aliasID }
          && store.workspace.notes.first { $0.id == third }!.blocks.contains { $0.id == aliasID },
          "Internal cut preserves block identity and removes only the selected occurrence")
    check(store.workspace.notes.flatMap(\.blocks).filter { $0.fileIdentity == fileID }.count == 3,
          "Internal cut does not delete the other file appearances")
    store.undo(); await store.clipboardMoves.waitUntilIdle()
    check(store.workspace.notes.first { $0.id == second }!.blocks.contains { $0.id == aliasID }, "Internal occurrence move is one undoable action")

    store.select(first); store.insert(.text)
    let originalText = store.block!
    let textPayload = try store.clipboardData(for: [originalText.id])
    store.select(second); check(store.pasteBlocks(textPayload), "Fixture creates a source-linked text copy")
    let copiedText = store.block!.id
    store.select(third)
    check(store.clipboardMoves.moveBlocks(textPayload, at: CGPoint(x:500,y:800), noteID: third), "Text block cut moves its original occurrence")
    check(store.workspace.notes.first { $0.id == second }!.blocks.first { $0.id == copiedText }?.reference?.noteID == third,
          "Source links follow an internal moved block")
    store.undo()
    check(store.workspace.notes.first { $0.id == first }!.blocks.contains { $0.id == originalText.id }, "Text move undo restores the original occurrence")

    let conflictSource = outside.appendingPathComponent("source.txt"); try Data("conflict source".utf8).write(to: conflictSource)
    store.select(third); let beforeConflict = store.workspace
    _ = store.clipboardMoves.moveFiles([conflictSource], at: .zero, noteID: third)
    await store.clipboardMoves.waitUntilIdle()
    check(store.workspace == beforeConflict && (try? String(contentsOf: conflictSource, encoding:.utf8)) == "conflict source",
          "Destination conflict preserves source and all page indexes")
    check((try? String(contentsOf: newOriginal, encoding:.utf8)) == "edited after moving", "A conflicting move never replaces the existing target")

    // Saved equality is a cheap guard against re-reading and writing a large
    // iCloud index merely because its window lost focus.
    check(store.flush(), "Fixture is saved")
    let fixed = Date(timeIntervalSince1970: 1_600_000_000)
    try FileManager.default.setAttributes([.modificationDate: fixed], ofItemAtPath: store.repository.workspaceURL.path)
    check(store.flush(), "A changed disk stamp is checked once")
    let saved = try Data(contentsOf: store.repository.workspaceURL)
    let stamp = try FileManager.default.attributesOfItem(atPath: store.repository.workspaceURL.path)[.modificationDate] as? Date
    check(store.flush() && (try? Data(contentsOf: store.repository.workspaceURL)) == saved
          && (try? FileManager.default.attributesOfItem(atPath: store.repository.workspaceURL.path)[.modificationDate] as? Date) == stamp,
          "An unchanged flush leaves the actual index bytes and modification time untouched")
    print("PASS: \(count) clipboard move, physical undo, aliases, source links and persistence assertions")
    return count
}
