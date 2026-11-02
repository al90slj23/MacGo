import XCTest
@testable import ToolboxCore

final class SwitcherGridLayoutTests: XCTestCase {
    func testPortraitDoesNotGetLandscapeSideGutters() {
        let layout = SwitcherGridLayout.make(windowSizes: [CGSize(width: 700, height: 1000), CGSize(width: 1600, height: 1000)], width: 1000, preferredPreviewHeight: 200)
        XCTAssertEqual(layout.frames[0].width, 156)
        XCTAssertEqual(layout.frames[1].width, 332)
        XCTAssertEqual(layout.frames[1].minX - layout.frames[0].maxX, 8)
        XCTAssertEqual(layout.frames[0].minY, layout.frames[1].minY)
    }

    func testWrapsWithoutOverflowAndPreservesSourceOrder() {
        let layout = SwitcherGridLayout.make(windowSizes: Array(repeating: CGSize(width: 1600, height: 1000), count: 7), width: 700, preferredPreviewHeight: 200)
        XCTAssertEqual(layout.frames.count, 7)
        XCTAssertEqual(layout.frames[2].minX, 0)
        XCTAssertGreaterThan(layout.frames[2].minY, layout.frames[1].maxY)
        for frame in layout.frames {
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThanOrEqual(frame.maxX, 700)
        }
        XCTAssertEqual(layout.contentHeight, layout.frames.last?.maxY)
    }

    func testNarrowDisplayAndMissingGeometryRemainUsable() {
        let layout = SwitcherGridLayout.make(windowSizes: [nil, CGSize(width: CGFloat.nan, height: 1), CGSize(width: 0, height: 0)], width: 110, preferredPreviewHeight: 100)
        XCTAssertEqual(layout.frames.map(\.width), [110, 110, 110])
        XCTAssertTrue(layout.frames.allSatisfy { $0.height.isFinite && $0.height > 0 })
    }

    func testVeryWideWindowDoesNotConsumeUnboundedRowWidth() {
        let layout = SwitcherGridLayout.make(windowSizes: [CGSize(width: 10000, height: 100)], width: 1600, preferredPreviewHeight: 200)
        XCTAssertEqual(layout.frames[0].width, 492)
    }

    func testEmptyWindowsDoNotCreatePhantomGridRow() {
        let layout = SwitcherGridLayout.make(windowSizes: [], width: 800, preferredPreviewHeight: 200)
        XCTAssertTrue(layout.frames.isEmpty)
        XCTAssertEqual(layout.contentHeight, 0)
    }

    func testSmallPanelKeepsOneCompleteChoiceAboveAppLane() {
        for chromeHeight: CGFloat in [220, 250] {
            let height = SwitcherGridLayout.panelHeight(contentHeight: 700, minimumContentHeight: 172,
                chromeHeight: chromeHeight, availableHeight: 700, percent: 30)
            XCTAssertGreaterThanOrEqual(height - chromeHeight, 172)
            XCTAssertLessThanOrEqual(height, 668)
        }
    }

    func testWindowlessOnlyAndSmallScreensStayInsideScreenEdges() {
        let emptyHeight = SwitcherGridLayout.panelHeight(contentHeight: 60, minimumContentHeight: 60,
            chromeHeight: 220, availableHeight: 700, percent: 70)
        XCTAssertEqual(emptyHeight, 280)
        let tinyHeight = SwitcherGridLayout.panelHeight(contentHeight: 700, minimumContentHeight: 172,
            chromeHeight: 250, availableHeight: 360, percent: 30)
        XCTAssertEqual(tinyHeight, 328)
    }
}
