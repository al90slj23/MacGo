import Foundation
import CoreGraphics

/// Metadata supplied by the public capture API. A result identifies one window,
/// not merely the first window belonging to an application.
public struct WindowCaptureCandidate: Equatable {
    public let id: UInt32
    public let processID: Int32
    public let title: String?
    public let frame: CGRect

    public init(id: UInt32, processID: Int32, title: String?, frame: CGRect) {
        self.id = id
        self.processID = processID
        self.title = title
        self.frame = frame
    }
}

/// Accessibility and WindowServer normally expose the same title. Chromium
/// deliberately decorates its accessible title with the browser/profile name.
/// Callers must opt in using a verified application identity, never a title hint.
public enum WindowCaptureTitlePolicy {
    case exact
    case chromium(browserName: String)
}

public enum WindowCaptureMatcher {
    /// Match the AX window to a capture window without guessing. If AX supplies
    /// a frame, it must agree; a supplied nonblank title must also agree, with
    /// only an explicit Chromium policy accepting its AX decorations. Without a
    /// frame, only a unique exact nonblank title is sufficient. Ambiguous,
    /// conflicting or invalid metadata leaves the UI's icon/title fallback.
    public static func match(
        candidates: [WindowCaptureCandidate],
        processID: Int32,
        title: String?,
        frame: CGRect?,
        tolerance: Double = 3,
        titlePolicy: WindowCaptureTitlePolicy = .exact
    ) -> UInt32? {
        guard processID > 0, tolerance.isFinite, tolerance >= 0 else { return nil }
        if let frame, !isUsable(frame) { return nil }
        let title = normalized(title)
        guard frame != nil || title != nil else { return nil }

        // A duplicated id is harmless only when its metadata is identical. A
        // stale/conflicting record for the same id must not authorize capture.
        let sameProcess = candidates.filter { $0.processID == processID && $0.id != 0 }
        let unique = Dictionary(grouping: sameProcess, by: \.id).values.compactMap { group -> WindowCaptureCandidate? in
            guard let first = group.first, group.allSatisfy({ $0 == first }), isUsable(first.frame) else { return nil }
            return first
        }
        let matches = unique.filter { candidate in
            if let frame, !approximatelyEqual(candidate.frame, frame, tolerance: tolerance) { return false }
            if let title, !titlesMatch(accessible: title, captured: normalized(candidate.title),
                                      hasFrame: frame != nil, policy: titlePolicy) { return false }
            return true
        }
        return matches.count == 1 ? matches[0].id : nil
    }

    private static func normalized(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return title
    }

    private static func titlesMatch(accessible: String, captured: String?, hasFrame: Bool,
                                    policy: WindowCaptureTitlePolicy) -> Bool {
        guard let captured else { return false }
        if accessible == captured { return true }
        // An alias never replaces frame evidence. Multiple windows satisfying
        // the same alias/frame still reach the caller's ambiguity rejection.
        guard hasFrame, case let .chromium(browserName) = policy,
              let browserName = normalized(browserName) else { return false }
        let prefix = captured + " - " + browserName
        guard accessible.hasPrefix(prefix) else { return false }
        let suffix = String(accessible.dropFirst(prefix.count))
        if validChromiumDecoration(suffix) { return true }
        for channel in [" Beta", " Dev", " Canary", " for Testing"] where suffix.hasPrefix(channel) {
            if validChromiumDecoration(String(suffix.dropFirst(channel.count))) { return true }
        }
        return false
    }

    private static func validChromiumDecoration(_ suffix: String) -> Bool {
        if suffix.isEmpty { return true }
        if suffix.hasPrefix(" - ") {
            return normalized(String(suffix.dropFirst(3))) != nil
        }
        let suffix = suffix.trimmingCharacters(in: .whitespaces)
        for (opening, closing) in [("(", ")"), ("（", "）")] {
            if suffix.hasPrefix(opening), suffix.hasSuffix(closing), suffix.count > 2 {
                return normalized(String(suffix.dropFirst().dropLast())) != nil
            }
        }
        return false
    }

    private static func isUsable(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite &&
        frame.size.width.isFinite && frame.size.height.isFinite &&
        frame.size.width > 0 && frame.size.height > 0
    }

    private static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: Double) -> Bool {
        zip([lhs.origin.x, lhs.origin.y, lhs.width, lhs.height],
            [rhs.origin.x, rhs.origin.y, rhs.width, rhs.height]).allSatisfy {
            abs(Double($0.0) - Double($0.1)) <= tolerance
        }
    }
}
