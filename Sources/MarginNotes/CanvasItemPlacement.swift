import SwiftUI
#if SWIFT_PACKAGE
import MarginCore
#endif

/// A bounded item, positioned by its top-left corner. Neither `.position` nor a
/// full-paper frame may wrap gestures or context menus: both enlarge their hit region.
struct CanvasItemPlacement<Content: View, Handle: View>: View {
    let geometry: CanvasItemGeometry
    @ViewBuilder var content: () -> Content
    @ViewBuilder var handle: () -> Handle
    var body: some View {
        let bounds = geometry.bounds
        ZStack(alignment: .topLeading) {
            content().frame(width: geometry.body.width, height: geometry.body.height)
                .offset(x: geometry.body.x - bounds.x, y: geometry.body.y - bounds.y)
            if let frame = geometry.handle {
                handle().frame(width: frame.width, height: frame.height)
                    .offset(x: frame.x - bounds.x, y: frame.y - bounds.y)
            }
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        .contentShape(CanvasItemHitShape(geometry: geometry))
        .offset(x: bounds.x, y: bounds.y)
    }
}

struct CanvasItemHitShape: Shape {
    let geometry: CanvasItemGeometry
    func path(in rect: CGRect) -> Path {
        let bounds = geometry.bounds
        var path = Path()
        for frame in [geometry.body, geometry.handle].compactMap({ $0 }) {
            path.addRect(CGRect(x: frame.x - bounds.x, y: frame.y - bounds.y, width: frame.width, height: frame.height))
        }
        return path
    }
}
