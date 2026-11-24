import SwiftUI

/// Reader controls stay at their ordinary size; magnification belongs only to
/// the document/input area and preserves the existing editor session.
@MainActor struct ReaderDocumentViewport<Content: View>: View {
    var zoom: Binding<Double>? = nil
    @ViewBuilder var content: () -> Content
    @SwiftUI.State private var identity = UUID()
    var body: some View {
        if let zoom {
            GeometryReader { viewport in
                CanvasViewport(pageID: identity, size: viewport.size, zoom: zoom.wrappedValue, fitting: false,
                    didZoom: { zoom.wrappedValue = min(6, max(0.25, $0)) },
                    content: AnyView(content().frame(width: viewport.size.width, height: viewport.size.height)
                        .environment(\.canvasRenderScale, zoom.wrappedValue).environment(\.colorScheme, .light)),
                    routesMagnification: true)
            }
        } else { content() }
    }
}
