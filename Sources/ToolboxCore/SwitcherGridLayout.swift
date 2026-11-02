import Foundation

/// Packs independent window previews at their own aspect ratio. A portrait
/// window should not inherit the empty sides of a landscape-sized grid cell.
public struct SwitcherGridLayout {
    public let frames: [CGRect]
    public let contentHeight: CGFloat
    public let previewHeight: CGFloat

    /// Panel percentage is a preference, while the screen edge and enough room
    /// to see one choice are bounds. The mouse-only lane must not consume the
    /// whole window viewport at 30% on a laptop display.
    public static func panelHeight(contentHeight: CGFloat, minimumContentHeight: CGFloat,
                                   chromeHeight: CGFloat, availableHeight: CGFloat,
                                   percent: Int) -> CGFloat {
        let hardLimit = max(1, availableHeight - 32)
        let desired = chromeHeight + max(0, contentHeight)
        let minimum = min(desired, chromeHeight + max(0, minimumContentHeight))
        let preferred = availableHeight * CGFloat(min(100, max(30, percent))) / 100
        return min(hardLimit, max(minimum, min(desired, preferred)))
    }

    public static func make(windowSizes: [CGSize?], width: CGFloat,
                            preferredPreviewHeight: CGFloat, spacing: CGFloat = 8,
                            inset: CGFloat = 6, captionHeight: CGFloat = 32) -> Self {
        let width = width.isFinite ? max(1, width) : 1
        let previewHeight = preferredPreviewHeight.isFinite ? max(48, preferredPreviewHeight) : 180
        let spacing = max(0, spacing)
        let inset = max(0, inset)
        let cardHeight = previewHeight + inset * 2 + captionHeight
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        for size in windowSizes {
            let ratio: CGFloat
            if let size, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 {
                ratio = size.width / size.height
            } else { ratio = 1.5 }
            let desiredWidth = previewHeight * min(2.4, max(0.55, ratio)) + inset * 2
            let cardWidth = min(width, max(min(156, width), desiredWidth))
            if x > 0, x + cardWidth > width + 0.1 {
                x = 0
                y += cardHeight + spacing
            }
            frames.append(CGRect(x: x, y: y, width: cardWidth, height: cardHeight))
            x += cardWidth + spacing
        }
        return Self(frames: frames, contentHeight: frames.isEmpty ? 0 : y + cardHeight,
                    previewHeight: previewHeight)
    }
}
