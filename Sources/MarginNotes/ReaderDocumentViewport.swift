import SwiftUI

enum ReaderDocumentLayout {
    static func scale(_ value: Double) -> CGFloat { CGFloat(value.isFinite ? min(6, max(0.25, value)) : 1) }
    static func documentSize(viewport: CGSize, zoom: Double) -> CGSize {
        let scale = scale(zoom)
        return CGSize(width: max(1, viewport.width) / scale, height: max(1, viewport.height) / scale)
    }
}

/// Reader controls stay at their ordinary size; magnification belongs only to
/// the document/input area and preserves the existing editor session.
@MainActor struct ReaderDocumentViewport<Content: View>: View {
    var zoom: Binding<Double>? = nil
    @ViewBuilder var content: () -> Content
    @SwiftUI.State private var identity = UUID()
    var body: some View {
        if let zoom {
            GeometryReader { viewport in
                // Native magnification scales these logical points back to the
                // visible viewport. Reflow at the inverse width rather than
                // magnifying a fixed 100%-width document beyond the right edge.
                let size = ReaderDocumentLayout.documentSize(viewport: viewport.size, zoom: zoom.wrappedValue)
                CanvasViewport(pageID: identity, size: size, zoom: Double(ReaderDocumentLayout.scale(zoom.wrappedValue)), fitting: false,
                    didZoom: { zoom.wrappedValue = min(6, max(0.25, $0)) },
                    content: AnyView(content().frame(width: size.width, height: size.height)
                        .environment(\.canvasRenderScale, zoom.wrappedValue).environment(\.colorScheme, .light)),
                    routesMagnification: true)
            }
        } else { content() }
    }
}
