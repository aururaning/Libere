import SwiftUI
import WebKit

private struct CanvasRenderScaleKey: EnvironmentKey { static let defaultValue = 1.0 }
extension EnvironmentValues {
    var canvasRenderScale: Double {
        get { self[CanvasRenderScaleKey.self] }
        set { self[CanvasRenderScaleKey.self] = newValue }
    }
}

/// WebKit lays out the same logical page but rasterizes its fonts, MathML and SVG at the
/// actual on-screen size. The inverse transform only compensates document coordinates;
/// it is cancelled by the enclosing canvas zoom, not used to enlarge a small bitmap.
@MainActor struct VectorWebSurface<Content: View>: View {
    @Environment(\.canvasRenderScale) private var canvasScale
    @ViewBuilder var content: (CGFloat) -> Content
    var body: some View {
        GeometryReader { geometry in
            let scale = CGFloat(max(1, canvasScale))
            content(scale)
                .frame(width: geometry.size.width * scale, height: geometry.size.height * scale)
                .scaleEffect(1 / scale, anchor: .topLeading)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }.clipped()
    }
}

@MainActor enum WebVectorScale {
    static func apply(_ scale: CGFloat, to view: WKWebView) {
        if abs(view.pageZoom - scale) > 0.0001 { view.pageZoom = scale }
        #if os(iOS)
        // The outer canvas owns the two-finger gesture; preserve one-finger web scrolling.
        view.scrollView.pinchGestureRecognizer?.isEnabled = false
        #endif
    }
}
