import SwiftUI
#if SWIFT_PACKAGE
import MarginCore
#endif

@MainActor struct CanvasBatchToolbar: View {
    @ObservedObject var selection: CanvasMultiSelection
    var body: some View {
        HStack(spacing: 14) {
            Text("已选 \(selection.selectedIDs.count) 项").font(.caption)
            Menu("对齐与分布") {
                ForEach(CanvasBatch.Alignment.allCases, id: \.self) { alignment in
                    Button(title(alignment)) { selection.align(alignment) }
                }
            }
            Button("锁定") { selection.lock(true) }
            Button("解锁") { selection.lock(false) }
            Button("删除", role: .destructive) { selection.delete() }
        }.buttonStyle(.borderless).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
    private func title(_ alignment: CanvasBatch.Alignment) -> String {
        switch alignment {
        case .left: return "左对齐"; case .right: return "右对齐"; case .top: return "顶对齐"; case .bottom: return "底对齐"
        case .horizontalCenter: return "水平中心对齐"; case .verticalCenter: return "垂直中心对齐"
        case .horizontalSpacing: return "水平等距"; case .verticalSpacing: return "垂直等距"
        }
    }
}

@MainActor struct BranchConnections: View {
    let note: Note
    let frames: [UUID: Rect]
    var body: some View {
        Canvas { context, _ in
            var blocks = note.blocks
            for i in blocks.indices { if let frame = frames[blocks[i].id] { blocks[i].frame = frame } }
            let anchors = Dictionary(note.anchors.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for block in blocks {
                guard let id = block.anchorID, let anchor = anchors[id], let start = CanvasLayout.point(anchor, blocks: blocks) else { continue }
                let end = CGPoint(x: anchor.edge == .leading ? block.frame.x : block.frame.maxX, y: block.frame.y + min(18, block.frame.height/2))
                let origin = CGPoint(x: start.x, y: start.y)
                let bend = max(20, abs(end.x - origin.x) / 2)
                var path = Path(); path.move(to: origin)
                path.addCurve(to: end, control1: CGPoint(x: origin.x + (end.x >= origin.x ? bend : -bend), y: origin.y),
                              control2: CGPoint(x: end.x + (end.x >= origin.x ? -bend : bend), y: end.y))
                context.stroke(path, with: .color(Palette.accent.opacity(0.35)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
            }
        }
    }
}
