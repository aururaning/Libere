import SwiftUI

enum AppBrand {
    static let name = "Libere"
    static var resources: Bundle {
        #if SWIFT_PACKAGE
        .module
        #else
        .main
        #endif
    }
}

struct AppLogo: View {
    var body: some View {
        Image("BrandLogo", bundle: AppBrand.resources)
            .resizable().interpolation(.high).scaledToFit()
            .accessibilityHidden(true)
    }
}
