import Foundation
import CoreGraphics
import ImageIO

/// The original file stays unchanged. Rendering is bounded while annotation
/// paper scaling uses the oriented original dimensions, independent of decoding size.
struct AttachmentImage {
    let image: CGImage
    let size: CGSize
    static let maximumPreviewPixelCount = 16_777_216
    static let maximumPreviewDimension = 32_768
    // ImageIO identifies the actual bytes, including extensionless repository
    // assets. Do not depend on a LaunchServices conformance lookup to accept them.
    private static let supportedTypeIdentifiers: Set<String> = [
        "public.png", "public.jpeg", "public.heic", "public.heics", "public.heif",
        "com.compuserve.gif", "public.tiff", "com.microsoft.bmp", "org.webmproject.webp"
    ]

    enum ReadError: LocalizedError {
        case unreadable, invalidDimensions, extremeAspectRatio
        var errorDescription: String? {
            switch self {
            case .unreadable: return "无法读取此图片，请检查文件是否完整且格式受支持。"
            case .invalidDimensions: return "图片尺寸无效，无法预览。"
            case .extremeAspectRatio: return "图片长宽比例超过 128:1，请裁剪或分成多张后导入。"
            }
        }
    }

    static func load(from url: URL) throws -> Self {
        try load(source: source(at: url))
    }

    private static func source(at url: URL) throws -> CGImageSource {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { throw ReadError.unreadable }
        return source
    }

    private static func load(source: CGImageSource, validationOnly: Bool = false) throws -> Self {
        guard let identifier = CGImageSourceGetType(source),
              supportedTypeIdentifiers.contains(identifier as String),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw ReadError.unreadable
        }
        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 1_000_000, height <= 1_000_000 else { throw ReadError.invalidDimensions }
        guard width / height <= 128, height / width <= 128 else { throw ReadError.extremeAspectRatio }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsAxes = (5...8).contains(orientation)
        let size = CGSize(width: swapsAxes ? height : width, height: swapsAxes ? width : height)
        let longest = max(width, height)
        let scale = min(1, sqrt(Double(maximumPreviewPixelCount) / (width * height)), Double(maximumPreviewDimension) / longest)
        let previewDimension = max(1, Int(floor(longest * scale)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: validationOnly ? min(256, previewDimension) : previewDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        // Animated GIFs and multipage TIFFs share a stable first-frame paper.
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0, image.height > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw ReadError.unreadable }
        return Self(image: image, size: size)
    }

    static func validate(at url: URL) throws { _ = try load(source: source(at: url), validationOnly: true) }
    static func validate(data: Data) throws {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { throw ReadError.unreadable }
        _ = try load(source: source, validationOnly: true)
    }
}
