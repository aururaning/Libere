import SwiftUI
import PencilKit
#if SWIFT_PACKAGE
import MarginCore
#endif

enum InkStyle: String, CaseIterable, Codable {
    case pen, monoline, marker, eraser
    var title: String {
        switch self { case .pen: return "压感笔"; case .monoline: return "均匀线条"; case .marker: return "荧光笔"; case .eraser: return "整笔橡皮" }
    }
    var type: PKInk.InkType { self == .marker ? .marker : self == .monoline ? .monoline : .pen }
}
enum InkColor: String, CaseIterable, Codable {
    case blue, black, red, green, purple, orange
    var title: String {
        switch self { case .blue: return "蓝色"; case .black: return "黑色"; case .red: return "红色"; case .green: return "绿色"; case .purple: return "紫色"; case .orange: return "橙色" }
    }
    var native: NativeColor {
        switch self { case .blue: return .systemBlue; case .black: return NativeColor(white: 0.12, alpha: 1)
        case .red: return .systemRed; case .green: return .systemGreen; case .purple: return .systemPurple; case .orange: return .systemOrange }
    }
}
struct InkOptions: Equatable, Codable {
    var style = InkStyle.pen
    var color = InkColor.blue
    var width = 3.0
    var opacity: CGFloat { style == .marker ? 0.32 : 1 }
    func pointWidth(pressure: CGFloat) -> CGFloat {
        CGFloat(width) * (style == .pen ? 0.4 + 0.9 * pressure : style == .marker ? 2.5 : 1)
    }
    var tool: PKTool {
        style == .eraser ? PKEraserTool(.vector) : PKInkingTool(style.type, color: color.native, width: CGFloat(width) * (style == .marker ? 2.5 : 1))
    }
}

@MainActor struct InkControls: View {
    @ObservedObject var store: AppStore
    var body: some View {
        HStack(spacing: 10) {
            Picker("笔型", selection: $store.inkOptions.style) {
                ForEach(InkStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }.frame(width: 144)
            Picker("颜色", selection: $store.inkOptions.color) {
                ForEach(InkColor.allCases, id: \.self) { Text($0.title).tag($0) }
            }.frame(width: 112).disabled(store.inkOptions.style == .eraser)
            Circle().fill(Color(store.inkOptions.color.native)).frame(width: 12, height: 12)
            Text("粗细").font(.caption)
            Slider(value: $store.inkOptions.width, in: 1...18, step: 0.5).frame(width: 100)
                .accessibilityLabel("笔画粗细")
            Text(String(format: "%.1f", store.inkOptions.width)).font(.caption.monospacedDigit()).frame(width: 30)
        }.font(.system(size: 12))
    }
}

/// Callbacks retain the destination captured at pen-down, independent of selection or page turns.
struct InkDestination: Equatable {
    let noteID: UUID
    var blockID: UUID? = nil
    var page = 0
}

enum InkClip {
    /// Disjoint rectangles for the canvas minus attachment frames, including overlapping frames.
    static func areas(in bounds: CGRect, excluding exclusions: [CGRect]) -> [CGRect] {
        let cuts = exclusions.map { $0.intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty }
        let xs = Set([bounds.minX, bounds.maxX] + cuts.flatMap { [$0.minX, $0.maxX] }).sorted()
        var result: [CGRect] = []
        for index in 1..<xs.count {
            let left = xs[index - 1], right = xs[index]
            let strips = cuts.filter { $0.minX < right && $0.maxX > left }.sorted { $0.minY < $1.minY }
            var y = bounds.minY
            for strip in strips {
                if strip.minY > y { result.append(CGRect(x: left, y: y, width: right - left, height: strip.minY - y)) }
                y = max(y, strip.maxY)
            }
            if y < bounds.maxY { result.append(CGRect(x: left, y: y, width: right - left, height: bounds.maxY - y)) }
        }
        return result
    }
}
