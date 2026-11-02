import XCTest
@testable import ToolboxCore

final class WindowRecencyTests: XCTestCase {
    func testMostRecentlyFocusedWindowComesFirst() {
        var recency = WindowRecency<Int>()
        recency.record(1)
        recency.record(3)
        recency.record(2)
        XCTAssertEqual(recency.ordered([1, 2, 3, 4]), [2, 3, 1, 4])
    }

    func testRecordingExistingWindowMovesItToFrontWithoutDuplicate() {
        var recency = WindowRecency<Int>()
        recency.record(1)
        recency.record(2)
        recency.record(1)
        XCTAssertEqual(recency.ordered([1, 2, 3]), [1, 2, 3])
    }

    func testUnknownWindowsKeepEnumerationOrderAndInputIsDeduplicated() {
        var recency = WindowRecency<Int>()
        recency.record(2)
        XCTAssertEqual(recency.ordered([4, 2, 3, 4, 1, 2]), [2, 4, 3, 1])
    }

    func testClosedWindowsAreExcludedFromResults() {
        var recency = WindowRecency<Int>()
        recency.record(1)
        recency.record(2)
        XCTAssertEqual(recency.ordered([1, 3]), [1, 3])
    }

    func testPruningRemovesHistoryForReusedIDs() {
        var recency = WindowRecency<Int>()
        recency.record(2)
        recency.record(1)
        recency.prune(validIDs: [2])
        XCTAssertEqual(recency.ordered([3, 1, 2]), [2, 3, 1])
    }

    func testBoundedHistoryFallsBackToInputOrderForEvictedIDs() {
        var recency = WindowRecency<Int>(capacity: 2)
        recency.record(1)
        recency.record(2)
        recency.record(3)
        recency.record(4)
        XCTAssertEqual(recency.ordered([1, 2, 3, 4]), [4, 3, 1, 2])
    }

    func testNonPositiveCapacityStillTracksMostRecentWindow() {
        var recency = WindowRecency<Int>(capacity: 0)
        recency.record(2)
        recency.record(3)
        XCTAssertEqual(recency.capacity, 1)
        XCTAssertEqual(recency.ordered([1, 2, 3]), [3, 1, 2])
    }
}
