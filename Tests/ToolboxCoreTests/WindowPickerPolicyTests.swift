import XCTest
import CoreGraphics
@testable import ToolboxCore

final class WindowPickerPolicyTests: XCTestCase {
    private let displays = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                            CGRect(x: 1440, y: -200, width: 1920, height: 1080)]

    func testBlacklistIsPerApplicationAndDoesNotHideOtherApplications() {
        let excluded: Set<String> = ["com.google.Chrome"]
        XCTAssertFalse(WindowPickerPolicy.includes(bundleIdentifier: "com.google.Chrome", excludedBundleIDs: excluded))
        XCTAssertTrue(WindowPickerPolicy.includes(bundleIdentifier: "com.apple.finder", excludedBundleIDs: excluded))
        XCTAssertTrue(WindowPickerPolicy.includes(bundleIdentifier: nil, excludedBundleIDs: excluded))
        XCTAssertTrue(WindowPickerPolicy.includes(bundleIdentifier: "com.google.Chrome", excludedBundleIDs: []))
    }

    func testSpanningWindowBelongsToDisplayWithLargestIntersection() {
        XCTAssertEqual(WindowPickerPolicy.displayIndex(windowFrame: CGRect(x: 1300, y: 100, width: 700, height: 600),
            displayFrames: displays, fallbackIndex: 0), 1)
        XCTAssertEqual(WindowPickerPolicy.displayIndex(windowFrame: CGRect(x: 900, y: 100, width: 700, height: 600),
            displayFrames: displays, fallbackIndex: 1), 0)
    }

    func testWindowlessAndUnknownFramesUseInvocationDisplay() {
        XCTAssertEqual(WindowPickerPolicy.displayIndex(windowFrame: nil, displayFrames: displays, fallbackIndex: 1), 1)
        XCTAssertEqual(WindowPickerPolicy.displayIndex(windowFrame: .null, displayFrames: displays, fallbackIndex: 1), 1)
    }

    func testDisconnectedInvocationDisplayFallsBackToAnExistingDisplay() {
        XCTAssertEqual(WindowPickerPolicy.displayIndex(windowFrame: nil, displayFrames: [displays[0]], fallbackIndex: 1), 0)
        XCTAssertNil(WindowPickerPolicy.displayIndex(windowFrame: nil, displayFrames: [], fallbackIndex: 1))
    }

    func testOffscreenWindowUsesNearestDisplayInsteadOfBeingLost() {
        XCTAssertEqual(WindowPickerPolicy.displayIndex(windowFrame: CGRect(x: 3500, y: 0, width: 300, height: 200),
            displayFrames: displays, fallbackIndex: 0), 1)
        XCTAssertEqual(WindowPickerPolicy.displayIndex(windowFrame: CGRect(x: -500, y: 0, width: 300, height: 200),
            displayFrames: displays, fallbackIndex: 1), 0)
    }

    func testInvalidDisplaysAreNotChosen() {
        XCTAssertEqual(WindowPickerPolicy.displayIndex(windowFrame: nil,
            displayFrames: [.zero, displays[1]], fallbackIndex: 0), 1)
        XCTAssertNil(WindowPickerPolicy.displayIndex(windowFrame: nil, displayFrames: [.zero, .infinite], fallbackIndex: 0))
    }

    func testCurrentDefaultSelectionDoesNotAdvanceUntilNextPress() {
        var session = SwitcherSession<Int>()
        session.begin(items: [1, 2, 3], currentID: 2, initialSelection: .currentWindow)
        XCTAssertEqual(session.selectedID, 2)
        session.advance()
        XCTAssertEqual(session.selectedID, 3)
        session.cancel()
        session.begin(items: [1, 2, 3], currentID: 2, backwards: true, initialSelection: .currentWindow)
        XCTAssertEqual(session.selectedID, 2)
        session.advance(backwards: true)
        XCTAssertEqual(session.selectedID, 1)
    }

    func testFirstDefaultSelectionRespectsReverseInvocationAndFrozenOrder() {
        var session = SwitcherSession<Int>()
        session.begin(items: [1, 2, 3], currentID: 2, initialSelection: .firstWindow)
        XCTAssertEqual(session.selectedID, 1)
        session.begin(items: [4, 3, 2], currentID: 3, initialSelection: .currentWindow)
        XCTAssertEqual(session.items, [1, 2, 3])
        XCTAssertEqual(session.selectedID, 2)
        session.cancel()
        session.begin(items: [1, 2, 3], currentID: 2, backwards: true, initialSelection: .firstWindow)
        XCTAssertEqual(session.selectedID, 3)
    }

    func testMissingCurrentItemWithCurrentDefaultRemainsUsable() {
        var session = SwitcherSession<Int>()
        session.begin(items: [1, 2, 3], currentID: 99, initialSelection: .currentWindow)
        XCTAssertEqual(session.selectedID, 1)
        session.remove(1)
        XCTAssertEqual(session.finish(), 2)
    }
}
