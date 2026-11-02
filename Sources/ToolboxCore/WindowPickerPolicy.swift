import Foundation
import CoreGraphics

/// Rules shared by the native catalog and display grouping. These do not read
/// the desktop, modify windows, or depend on a particular monitor arrangement.
public enum WindowPickerPolicy {
    public static func includes(bundleIdentifier: String?, excludedBundleIDs: Set<String>) -> Bool {
        guard let bundleIdentifier else { return true }
        return !excludedBundleIDs.contains(bundleIdentifier)
    }

    /// Frames use the same top-left WindowServer coordinate system. Prefer the
    /// display containing the greatest part of a spanning window; an offscreen
    /// window belongs to its nearest display rather than disappearing entirely.
    public static func displayIndex(windowFrame: CGRect?, displayFrames: [CGRect], fallbackIndex: Int) -> Int? {
        let valid = displayFrames.indices.filter { usable(displayFrames[$0]) }
        guard !valid.isEmpty else { return nil }
        let fallback = valid.contains(fallbackIndex) ? fallbackIndex : valid[0]
        guard let windowFrame, usable(windowFrame) else { return fallback }
        var best = fallback
        var bestArea: CGFloat = 0
        for index in valid {
            let intersection = displayFrames[index].intersection(windowFrame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > bestArea { best = index; bestArea = area }
        }
        if bestArea > 0 { return best }
        return valid.min { distanceSquared(from: windowFrame, to: displayFrames[$0]) < distanceSquared(from: windowFrame, to: displayFrames[$1]) }
    }

    private static func usable(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite &&
        frame.width > 0 && frame.height > 0
    }

    private static func distanceSquared(from window: CGRect, to display: CGRect) -> CGFloat {
        let x = window.midX
        let y = window.midY
        let dx = max(max(display.minX - x, 0), x - display.maxX)
        let dy = max(max(display.minY - y, 0), y - display.maxY)
        return dx * dx + dy * dy
    }
}
