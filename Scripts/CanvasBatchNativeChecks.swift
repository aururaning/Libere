import SwiftUI

@MainActor func runCanvasBatchNativeChecks() throws -> Int {
    var count = 0
    func check(_ value: Bool, _ message: String) { precondition(value,message); count += 1 }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibereMulti-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try AppStore(root: root); store.create(); store.cancelRename(); store.snap = false
    let a = Block(.text,frame:Rect(40,60,200,100),text:"一"), b = Block(.formula,frame:Rect(300,200,200,100),text:"x^2")
    store.edit { $0.blocks = [a,b] }
    let pointer = store.canvasPointer
    check(pointer.down(at:CGPoint(x:100,y:100),area:.body(a.id),clickCount:1,scale:1),"Single selection starts")
    pointer.up(at:CGPoint(x:100,y:100))
    check(pointer.down(at:CGPoint(x:350,y:240),area:.body(b.id),clickCount:1,scale:1,extendingSelection:true),"Shift adds another block")
    check(store.multiSelection.selectedIDs == [a.id,b.id],"Shift selection retains both IDs")
    pointer.down(at:CGPoint(x:100,y:100),area:.body(a.id),clickCount:1,scale:1)
    pointer.dragged(to:CGPoint(x:130,y:150))
    check(store.note!.blocks == [a,b] && store.multiSelection.previewFrames.count == 2,"Group drag only previews until release")
    pointer.up(at:CGPoint(x:130,y:150))
    check(store.note!.blocks[0].frame == Rect(70,110,200,100) && store.note!.blocks[1].frame == Rect(330,250,200,100),"Group drag commits one common translation")
    store.undo();check(store.note!.blocks == [a,b],"One undo restores the complete group")
    pointer.down(at:CGPoint(x:650,y:600),area:.paper,clickCount:1,scale:1)
    pointer.dragged(to:CGPoint(x:20,y:20));pointer.up(at:CGPoint(x:20,y:20))
    check(store.multiSelection.selectedIDs == [a.id,b.id] && store.note!.blocks == [a,b],"Blank-paper marquee selects blocks without moving content")
    store.multiSelection.lock(true);store.multiSelection.delete()
    check(store.note!.blocks.count == 2 && store.note!.blocks.allSatisfy(\.locked),"Batch delete never removes locked members")
    store.multiSelection.lock(false);store.multiSelection.align(.left)
    check(store.note!.blocks.allSatisfy { $0.frame.x == 40 },"Batch alignment applies atomically")
    store.undo();check(store.note!.blocks.map(\.frame) == [a.frame,b.frame],"Alignment is one undo operation")
    store.multiSelection.select([a.id,b.id]);store.multiSelection.delete()
    check(store.note!.blocks.isEmpty,"Batch delete removes the selected group")
    store.undo();check(store.note!.blocks.count == 2,"One undo restores the deleted group")
    store.selectBlock(b.id)
    check(pointer.selectedScrollBlockID == nil,"A selected static formula leaves wheel ownership with the outer page")
    let viewport = CanvasScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let target = CGRect(x: 600, y: 4000, width: 200, height: 160)
    for scale in [0.25, 0.5, 1.0, 2.0, 6.0] {
        viewport.update(pageID: store.selection!, size: CGSize(width: 1000, height: 6000), zoom: scale, fitting: false, content: AnyView(Color.white))
        viewport.layoutSubtreeIfNeeded(); viewport.reveal(target)
        check(viewport.paper.convert(viewport.contentView.bounds, from: viewport.contentView).contains(CGPoint(x: target.midX, y: target.midY)),
              "Search reveal centers a distant block in native document coordinates at every zoom")
    }
    print("PASS: \(count) multi-selection, group transactions and static wheel assertions")
    return count
}
