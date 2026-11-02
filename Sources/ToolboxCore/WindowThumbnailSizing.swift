import Foundation

/// Pixel dimensions for a single-window preview. Display bounds arrive in
/// physical pixels; source dimensions remain in macOS logical points.
public enum WindowThumbnailSizing {
    public static let imageLimit = 24
    public static let maximumWidth = 1600
    public static let maximumHeight = 1000
    public static let maximumCachePixels = 32_000_000

    public struct Dimensions: Equatable {
        public let width: Int
        public let height: Int
        public var pixelCount: Int { width * height }
    }

    public static func pixelsPerImage(candidateCount: Int) -> Int {
        let count = max(1, min(imageLimit, candidateCount))
        return min(maximumWidth * maximumHeight, maximumCachePixels / count)
    }

    /// Fits the original aspect ratio to the actual preview demand, source
    /// resolution, and bounded share of the session's memory budget. Retina
    /// sources may yield more than one pixel per point; low-resolution sources
    /// are never enlarged just to satisfy a higher-density destination screen.
    public static func dimensions(sourcePointSize: CGSize, sourceScale: CGFloat,
                                  maximumPixelSize: CGSize, candidateCount: Int) -> Dimensions? {
        guard sourcePointSize.width.isFinite, sourcePointSize.height.isFinite,
              sourcePointSize.width > 0, sourcePointSize.height > 0,
              sourceScale.isFinite, sourceScale > 0,
              maximumPixelSize.width.isFinite, maximumPixelSize.height.isFinite,
              maximumPixelSize.width > 0, maximumPixelSize.height > 0 else { return nil }
        let area = sourcePointSize.width * sourcePointSize.height
        guard area.isFinite, area > 0 else { return nil }
        let widthBound = min(CGFloat(maximumWidth), maximumPixelSize.width)
        let heightBound = min(CGFloat(maximumHeight), maximumPixelSize.height)
        let budget = CGFloat(pixelsPerImage(candidateCount: candidateCount))
        let scale = min(sourceScale, widthBound / sourcePointSize.width,
                        heightBound / sourcePointSize.height, (budget / area).squareRoot())
        guard scale.isFinite, scale > 0 else { return nil }
        // Rounding down keeps both dimensions and their product inside every
        // bound. A one-pixel edge is the smallest representable thin window.
        let width = max(1, min(maximumWidth, Int((sourcePointSize.width * scale).rounded(.down))))
        let height = max(1, min(maximumHeight, Int((sourcePointSize.height * scale).rounded(.down))))
        return Dimensions(width: width, height: height)
    }
}
