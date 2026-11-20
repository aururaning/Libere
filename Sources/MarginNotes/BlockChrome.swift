import SwiftUI
#if SWIFT_PACKAGE
import MarginCore
#endif

struct BlockMoveHandle: View {
    var locked = false
    var active = false
    #if os(macOS)
    static let hitSize: CGFloat = 28
    #else
    static let hitSize: CGFloat = 36
    #endif

    /// Keep both the visible badge and its hit area outside the content. At a paper
    /// edge, choose another side without changing the block's document coordinates.
    static func offset(for frame: CGRect, in paper: CGSize?) -> CGSize {
        let placement = CanvasItemGeometry.moveHandle(for: Rect(frame.minX, frame.minY, frame.width, frame.height),
            paperWidth: Double(paper?.width ?? .greatestFiniteMagnitude), paperHeight: Double(paper?.height ?? .greatestFiniteMagnitude), size: hitSize)
        return CGSize(width: placement.x - frame.minX, height: placement.y - frame.minY)
    }
    var body: some View {
        Image(systemName: locked ? "lock.fill" : "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(active ? Palette.accent : Color.secondary)
            .frame(width: 20, height: 20)
            .background(Palette.accent.opacity(active ? 0.13 : 0.055), in: RoundedRectangle(cornerRadius: 5))
            .background(.white, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.accent.opacity(active ? 0.4 : 0.16), lineWidth: 0.75))
            .frame(width: Self.hitSize, height: Self.hitSize)
            .contentShape(Rectangle())
            .help(locked ? "已锁定：右键解锁后可拖动" : "按住拖动，移动整个内容块")
            .accessibilityLabel(locked ? "内容块已锁定" : "移动内容块")
            .accessibilityHint(locked ? "右键解锁后可拖动" : "按住四向箭头拖动")
    }
}

struct ResizeCorner: View {
    let length: CGFloat
    var radius: CGFloat = 8
    var hitSize: CGFloat = 44
    var body: some View {
        CornerArc(length: length, radius: radius)
            .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            .overlay(CornerArc(length: length, radius: radius).stroke(Palette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round)))
            .frame(width: hitSize, height: hitSize).contentShape(Rectangle())
            .accessibilityLabel("调整内容块大小")
    }
}
private struct CornerArc: Shape {
    let length: CGFloat
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let x = rect.maxX - 2, y = rect.maxY - 2, r = radius - 2
        return Path { p in
            p.move(to: CGPoint(x: x - length, y: y))
            p.addLine(to: CGPoint(x: x - r, y: y))
            p.addQuadCurve(to: CGPoint(x: x, y: y - r), control: CGPoint(x: x, y: y))
            p.addLine(to: CGPoint(x: x, y: y - length))
        }
    }
}
struct BlockBorder: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: 8)
        path.addPath(Path(roundedRect: rect.insetBy(dx: 8, dy: 8), cornerRadius: 2))
        return path
    }
}

/// A small line-art badge shares one visual language across imported file types.
struct FileTypeBadge: View {
    let block: Block
    private var symbol: String {
        if block.kind == .link { return "globe" }
        if block.kind == .pdf { return "doc.richtext" }
        if block.kind == .formula { return "function" }
        switch AttachmentFormat(filename: block.assetName) {
        case .notebook: return "book.closed"
        case .source: return "chevron.left.forwardslash.chevron.right"
        case .html: return "globe"
        case .markdown: return "text.alignleft"
        case .image: return "photo"
        default: return "doc.text"
        }
    }
    private var color: Color {
        block.kind == .link || AttachmentFormat(filename:block.assetName) == .notebook ? Palette.accent : Palette.ink
    }
    var body: some View {
        Image(systemName: symbol).font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(color).frame(width: 23, height: 23)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }
}
