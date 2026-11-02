import Foundation
import XCTest
@testable import ToolboxCore

final class WindowCaptureMatcherTests: XCTestCase {
    private let firstFrame = CGRect(x: 10, y: 40, width: 900, height: 600)
    private let secondFrame = CGRect(x: 1000, y: 40, width: 900, height: 600)
    private let pid: Int32 = 42

    private func candidate(_ id: UInt32, pid: Int32 = 42, title: String? = "Document", frame: CGRect? = nil) -> WindowCaptureCandidate {
        .init(id: id, processID: pid, title: title, frame: frame ?? firstFrame)
    }

    func testSameAppSameTitleIsDisambiguatedByFrame() {
        let windows = [candidate(1), candidate(2, frame: secondFrame)]
        XCTAssertEqual(WindowCaptureMatcher.match(candidates: windows, processID: pid, title: "Document", frame: secondFrame), 2)
        XCTAssertNil(WindowCaptureMatcher.match(candidates: windows, processID: pid, title: "Document", frame: nil))
    }

    func testOverlappingWindowsWithSameTitleRemainAmbiguous() {
        XCTAssertNil(WindowCaptureMatcher.match(candidates: [candidate(1), candidate(2)], processID: pid, title: "Document", frame: firstFrame))
    }

    func testExactTitleDisambiguatesOverlappingWindows() {
        let windows = [candidate(1, title: "Alpha"), candidate(2, title: "Beta")]
        XCTAssertEqual(WindowCaptureMatcher.match(candidates: windows, processID: pid, title: "Beta", frame: firstFrame), 2)
        XCTAssertNil(WindowCaptureMatcher.match(candidates: windows, processID: pid, title: nil, frame: firstFrame))
    }

    func testAnotherProcessCanNeverSupplyMatchingThumbnail() {
        let windows = [candidate(1, pid: 99)]
        XCTAssertNil(WindowCaptureMatcher.match(candidates: windows, processID: pid, title: "Document", frame: firstFrame))
        XCTAssertNil(WindowCaptureMatcher.match(candidates: windows, processID: pid, title: "Document", frame: nil))
    }

    func testConflictingTitleAndFrameDoNotFallBackToEitherAlone() {
        let windows = [candidate(1, title: "Alpha"), candidate(2, title: "Beta", frame: secondFrame)]
        XCTAssertNil(WindowCaptureMatcher.match(candidates: windows, processID: pid, title: "Alpha", frame: secondFrame))
    }

    func testUniqueNonblankTitleWorksWhenAXFrameIsUnavailable() {
        let windows = [candidate(1, title: "Alpha"), candidate(2, title: "Beta")]
        XCTAssertEqual(WindowCaptureMatcher.match(candidates: windows, processID: pid, title: " Beta\n", frame: nil), 2)
        XCTAssertNil(WindowCaptureMatcher.match(candidates: windows, processID: pid, title: "beta", frame: nil))
    }

    func testUniqueFrameWorksWhenTitleIsBlank() {
        let windows = [candidate(1, title: nil), candidate(2, title: " ", frame: secondFrame)]
        XCTAssertEqual(WindowCaptureMatcher.match(candidates: windows, processID: pid, title: " \n", frame: secondFrame), 2)
        XCTAssertNil(WindowCaptureMatcher.match(candidates: windows, processID: pid, title: nil, frame: nil))
    }

    func testFrameToleranceIncludesBoundaryButRejectsOutside() {
        let shifted = CGRect(x: 13, y: 37, width: 903, height: 597)
        XCTAssertEqual(WindowCaptureMatcher.match(candidates: [candidate(1, frame: shifted)], processID: pid, title: "Document", frame: firstFrame), 1)
        let outside = CGRect(x: 13.01, y: 40, width: 900, height: 600)
        XCTAssertNil(WindowCaptureMatcher.match(candidates: [candidate(1, frame: outside)], processID: pid, title: "Document", frame: firstFrame))
    }

    func testInvalidTargetFrameCannotAuthorizeTitleOnlyFallback() {
        for frame in [CGRect.zero, CGRect.null, CGRect.infinite,
                      CGRect(x: Double.nan, y: 0, width: 1, height: 1)] {
            XCTAssertNil(WindowCaptureMatcher.match(candidates: [candidate(1)], processID: pid, title: "Document", frame: frame))
        }
    }

    func testInvalidCaptureFramesAndZeroIDsAreExcluded() {
        XCTAssertNil(WindowCaptureMatcher.match(candidates: [candidate(0), candidate(2, frame: .zero)], processID: pid, title: "Document", frame: nil))
    }

    func testIdenticalDuplicatesAreSafeButConflictingRecordsAreRejected() {
        let one = candidate(1)
        XCTAssertEqual(WindowCaptureMatcher.match(candidates: [one, one], processID: pid, title: "Document", frame: firstFrame), 1)
        XCTAssertNil(WindowCaptureMatcher.match(candidates: [one, candidate(1, frame: secondFrame)], processID: pid, title: "Document", frame: firstFrame))
    }

    func testInvalidProcessAndToleranceNeverMatch() {
        for tolerance in [-1, Double.nan, Double.infinity] {
            XCTAssertNil(WindowCaptureMatcher.match(candidates: [candidate(1)], processID: pid, title: "Document", frame: firstFrame, tolerance: tolerance))
        }
        XCTAssertNil(WindowCaptureMatcher.match(candidates: [candidate(1, pid: 0)], processID: 0, title: "Document", frame: firstFrame))
    }

    func testChromeProfileDecoratedAXTitleMatchesRawCapturedPageTitle() {
        let windows = [candidate(1, title: "商户平台"), candidate(2, title: "外掛程式 | ChatGPT")]
        XCTAssertEqual(WindowCaptureMatcher.match(candidates: windows, processID: pid,
            title: "商户平台 - Google Chrome - Profile 1", frame: firstFrame,
            titlePolicy: .chromium(browserName: "Google Chrome")), 1)
    }

    func testChromeLocalizedIncognitoAndGuestDecorationsMatchWithFrame() {
        for title in ["示例页面 - 示例站点 - Google Chrome（无痕）",
                      "示例页面 - 示例站点 - Google Chrome (Incognito)",
                      "示例页面 - 示例站点 - Google Chrome (Guest)"] {
            XCTAssertEqual(WindowCaptureMatcher.match(candidates: [candidate(1, title: "示例页面 - 示例站点")],
                processID: pid, title: title, frame: firstFrame,
                titlePolicy: .chromium(browserName: "Google Chrome")), 1)
        }
    }

    func testChromeKnownChannelDecorationUsesBrowserBoundary() {
        for title in ["Document - Google Chrome", "Document - Google Chrome Beta - Work",
                      "Document - Google Chrome Canary (Incognito)", "Document - Google Chrome for Testing"] {
            XCTAssertEqual(WindowCaptureMatcher.match(candidates: [candidate(1)], processID: pid,
                title: title, frame: firstFrame, titlePolicy: .chromium(browserName: "Google Chrome")), 1)
        }
    }

    func testChromeAliasIsDisabledUnlessCallerOptsIn() {
        XCTAssertNil(WindowCaptureMatcher.match(candidates: [candidate(1)], processID: pid,
            title: "Document - Google Chrome - Work", frame: firstFrame))
    }

    func testChromeAliasCannotReplaceMissingFrameEvidence() {
        XCTAssertNil(WindowCaptureMatcher.match(candidates: [candidate(1)], processID: pid,
            title: "Document - Google Chrome - Work", frame: nil,
            titlePolicy: .chromium(browserName: "Google Chrome")))
        XCTAssertEqual(WindowCaptureMatcher.match(candidates: [candidate(1)], processID: pid,
            title: "Document", frame: nil, titlePolicy: .chromium(browserName: "Google Chrome")), 1)
    }

    func testChromeAliasRejectsUnrelatedOrLookalikeTitles() {
        for title in ["Other - Google Chrome - Work", "Documentary - Google Chrome - Work",
                      "Document - Google Chromeworthy", "Document - Safari - Work",
                      "Document - Google Chrome Betaish", "Document - Google Chrome - ",
                      "Document - Google Chrome()", "Document - Google Chrome（无痕） extra"] {
            XCTAssertNil(WindowCaptureMatcher.match(candidates: [candidate(1)], processID: pid,
                title: title, frame: firstFrame, titlePolicy: .chromium(browserName: "Google Chrome")))
        }
    }

    func testChromeAliasStillRequiresCorrectProcessAndFrame() {
        let title = "Document - Google Chrome - Work"
        XCTAssertNil(WindowCaptureMatcher.match(candidates: [candidate(1, pid: 99)], processID: pid,
            title: title, frame: firstFrame, titlePolicy: .chromium(browserName: "Google Chrome")))
        XCTAssertNil(WindowCaptureMatcher.match(candidates: [candidate(1, frame: secondFrame)], processID: pid,
            title: title, frame: firstFrame, titlePolicy: .chromium(browserName: "Google Chrome")))
    }

    func testChromeSamePageInOverlappingWindowsRemainsAmbiguous() {
        XCTAssertNil(WindowCaptureMatcher.match(candidates: [candidate(1), candidate(2)], processID: pid,
            title: "Document - Google Chrome - Work", frame: firstFrame,
            titlePolicy: .chromium(browserName: "Google Chrome")))
    }

    func testChromeExactAndDecoratedTitleCollisionRemainsAmbiguous() {
        let title = "Document - Google Chrome - Work"
        let windows = [candidate(1), candidate(2, title: title)]
        XCTAssertNil(WindowCaptureMatcher.match(candidates: windows, processID: pid,
            title: title, frame: firstFrame, titlePolicy: .chromium(browserName: "Google Chrome")))
        let nested = [candidate(1), candidate(2, title: "Document - Google Chrome")]
        XCTAssertNil(WindowCaptureMatcher.match(candidates: nested, processID: pid,
            title: "Document - Google Chrome - Google Chrome - Work", frame: firstFrame,
            titlePolicy: .chromium(browserName: "Google Chrome")))
    }

    func testChromeRepeatedPageTitleCanBeDisambiguatedByFrame() {
        let windows = [candidate(1), candidate(2, frame: secondFrame)]
        XCTAssertEqual(WindowCaptureMatcher.match(candidates: windows, processID: pid,
            title: "Document - Google Chrome - Work", frame: secondFrame,
            titlePolicy: .chromium(browserName: "Google Chrome")), 2)
    }
}
