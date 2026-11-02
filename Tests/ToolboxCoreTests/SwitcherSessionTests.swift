import XCTest
@testable import ToolboxCore

final class SwitcherSessionTests: XCTestCase {
    func testForwardStartsAtPreviousWindowAndWraps() {
        var session = SwitcherSession<String>()
        session.begin(items: ["current", "previous", "older"], currentID: "current")
        XCTAssertEqual(session.selectedID, "previous")
        session.advance()
        XCTAssertEqual(session.selectedID, "older")
        session.advance()
        XCTAssertEqual(session.selectedID, "current")
    }

    func testReverseStartsBeforeCurrentAndWraps() {
        var session = SwitcherSession<Int>()
        session.begin(items: [1, 2, 3], currentID: 1, backwards: true)
        XCTAssertEqual(session.selectedID, 3)
        session.advance(backwards: true)
        XCTAssertEqual(session.selectedID, 2)
        session.advance(backwards: true)
        XCTAssertEqual(session.selectedID, 1)
        session.advance(backwards: true)
        XCTAssertEqual(session.selectedID, 3)
    }

    func testNoCurrentWindowStartsAtListBoundary() {
        var session = SwitcherSession<Int>()
        session.begin(items: [1, 2, 3], currentID: 9)
        XCTAssertEqual(session.selectedID, 1)
        session.cancel()
        session.begin(items: [1, 2, 3], currentID: nil, backwards: true)
        XCTAssertEqual(session.selectedID, 3)
    }

    func testBeginFindsCurrentAwayFromFirstPosition() {
        var session = SwitcherSession<Int>()
        session.begin(items: [1, 2, 3], currentID: 2)
        XCTAssertEqual(session.selectedID, 3)
    }

    func testRepeatedBeginKeepsOrderFrozen() {
        var session = SwitcherSession<Int>()
        session.begin(items: [1, 2, 3], currentID: 1)
        session.begin(items: [2, 3, 4, 1], currentID: 2)
        XCTAssertEqual(session.items, [1, 2, 3])
        XCTAssertEqual(session.selectedID, 3)
    }

    func testFinishReturnsSelectionAndClearsSession() {
        var session = SwitcherSession<Int>()
        session.begin(items: [1, 2], currentID: 1)
        XCTAssertEqual(session.finish(), 2)
        XCTAssertFalse(session.isActive)
        XCTAssertTrue(session.items.isEmpty)
        XCTAssertNil(session.selectedIndex)
        XCTAssertNil(session.finish())
    }

    func testCancelDoesNotProduceASelection() {
        var session = SwitcherSession<Int>()
        session.begin(items: [1, 2], currentID: 1)
        session.cancel()
        XCTAssertFalse(session.isActive)
        XCTAssertNil(session.selectedID)
        XCTAssertNil(session.finish())
    }

    func testEmptyAndSingletonListsAreSafe() {
        var session = SwitcherSession<Int>()
        session.begin(items: [], currentID: nil)
        session.advance()
        session.advance(backwards: true)
        session.remove(1)
        XCTAssertFalse(session.isActive)
        XCTAssertNil(session.selectedID)
        session.begin(items: [7], currentID: 7)
        XCTAssertEqual(session.selectedID, 7)
        session.advance(backwards: true)
        XCTAssertEqual(session.finish(), 7)
    }

    func testDuplicateIDsAreRemovedBeforeCycling() {
        var session = SwitcherSession<Int>()
        session.begin(items: [1, 1, 2, 2, 3], currentID: 1)
        XCTAssertEqual(session.items, [1, 2, 3])
        XCTAssertEqual(session.selectedID, 2)
        session.advance()
        XCTAssertEqual(session.selectedID, 3)
    }

    func testRemovingEarlierWindowPreservesSelection() {
        var session = SwitcherSession<Int>()
        session.begin(items: [1, 2, 3, 4], currentID: 2)
        session.remove(1)
        XCTAssertEqual(session.items, [2, 3, 4])
        XCTAssertEqual(session.selectedID, 3)
        XCTAssertEqual(session.selectedIndex, 1)
    }

    func testRemovingSelectedWindowChoosesSuccessor() {
        var session = SwitcherSession<Int>()
        session.begin(items: [1, 2, 3], currentID: 1)
        session.remove(2)
        XCTAssertEqual(session.selectedID, 3)
        session.remove(3)
        XCTAssertEqual(session.selectedID, 1)
        session.remove(1)
        XCTAssertFalse(session.isActive)
        XCTAssertNil(session.selectedID)
    }

    func testRemovingLaterOrMissingWindowPreservesSelection() {
        var session = SwitcherSession<Int>()
        session.begin(items: [1, 2, 3], currentID: 1)
        session.remove(3)
        session.remove(99)
        XCTAssertEqual(session.selectedID, 2)
        XCTAssertEqual(session.selectedIndex, 1)
    }

    func testQuickInvocationsAlternateBetweenRecentWindows() {
        var recency = WindowRecency<String>()
        recency.record("B")
        recency.record("A")
        var session = SwitcherSession<String>()
        session.begin(items: recency.ordered(["A", "B", "C"]), currentID: "A")
        let first = session.finish()
        XCTAssertEqual(first, "B")
        recency.record(first!)
        session.begin(items: recency.ordered(["A", "B", "C"]), currentID: "B")
        XCTAssertEqual(session.finish(), "A")
    }

    func testHoverSelectionBecomesTheModifierReleaseChoice() {
        var session = SwitcherSession<String>()
        session.begin(items: ["current", "previous", "hovered"], currentID: "current")
        XCTAssertTrue(session.select("hovered"))
        XCTAssertEqual(session.selectedID, "hovered")
        XCTAssertEqual(session.finish(), "hovered")
        XCTAssertFalse(session.isActive)
    }

    func testTabContinuesFromHoveredWindowWithoutReordering() {
        var session = SwitcherSession<Int>()
        session.begin(items: [1, 2, 3, 4], currentID: 1)
        XCTAssertTrue(session.select(4))
        session.advance()
        XCTAssertEqual(session.selectedID, 1)
        session.advance(backwards: true)
        XCTAssertEqual(session.selectedID, 4)
        XCTAssertEqual(session.items, [1, 2, 3, 4])
    }

    func testMouseOnlyApplicationCannotReplaceKeyboardChoice() {
        var session = SwitcherSession<String>()
        session.begin(items: ["window-a", "window-b"], currentID: "window-a")
        XCTAssertFalse(session.select("application-without-window"))
        XCTAssertEqual(session.items, ["window-a", "window-b"])
        XCTAssertEqual(session.finish(), "window-b")
        XCTAssertFalse(session.select("window-a"))
        XCTAssertNil(session.selectedID)
    }

    func testClosingHoveredChoiceUsesItsFrozenSuccessor() {
        var session = SwitcherSession<Int>()
        session.begin(items: [1, 2, 3, 4], currentID: 1)
        session.select(3)
        session.remove(3)
        XCTAssertEqual(session.selectedID, 4)
        session.remove(1)
        XCTAssertEqual(session.finish(), 4)
    }
}
