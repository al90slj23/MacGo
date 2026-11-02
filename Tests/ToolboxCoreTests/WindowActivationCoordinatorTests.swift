import XCTest
@testable import ToolboxCore

final class WindowActivationCoordinatorTests: XCTestCase {
    @MainActor func testAcceptedActivationAndRaiseDoNotProveFrontmostWindow() async {
        let backend = FakeActivationBackend()
        backend.observation = .init(isFrontmost: false, isFocused: true, isMinimized: false)
        backend.activationAccepted = true
        let result = await WindowActivationCoordinator().activate(using: backend, attempts: 4, pause: {})
        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(backend.requests, 2)
        XCTAssertEqual(backend.focuses, 4)
    }

    @MainActor func testCorrectApplicationButWrongWindowStillRetries() async {
        let backend = FakeActivationBackend()
        backend.observation = .init(isFrontmost: true, isFocused: false, isMinimized: false)
        backend.onFocus = { backend in
            if backend.focuses == 3 { backend.observation = .focused }
        }
        let result = await WindowActivationCoordinator().activate(using: backend, attempts: 5, pause: {})
        XCTAssertEqual(result, .success)
        XCTAssertEqual(backend.focuses, 3)
        XCTAssertEqual(backend.requests, 0, "Do not reactivate an already foreground app.")
    }

    @MainActor func testMinimizedTargetCannotBeReportedAsFocused() async {
        let backend = FakeActivationBackend()
        backend.observation = .init(isFrontmost: true, isFocused: true, isMinimized: true)
        let result = await WindowActivationCoordinator().activate(using: backend, attempts: 3, pause: {})
        XCTAssertEqual(result, .timedOut)
    }

    @MainActor func testPreparationCanRestoreMinimizedWindowBeforeVerification() async {
        let backend = FakeActivationBackend()
        backend.observation = .init(isFrontmost: true, isFocused: true, isMinimized: true)
        backend.onPrepare = { backend in backend.observation = .focused }
        let result = await WindowActivationCoordinator().activate(using: backend, pause: {})
        XCTAssertEqual(result, .success)
        XCTAssertEqual(backend.prepares, 1)
        XCTAssertEqual(backend.requests, 0)
        XCTAssertEqual(backend.focuses, 0)
    }

    @MainActor func testRejectedActivationCanSucceedWhenObservedStateConfirmsFocus() async {
        let backend = FakeActivationBackend()
        backend.activationAccepted = false
        backend.onFocus = { backend in backend.observation = .focused }
        let result = await WindowActivationCoordinator().activate(using: backend, pause: {})
        XCTAssertEqual(result, .success)
        XCTAssertEqual(backend.requests, 1)
    }

    @MainActor func testEventuallyObservedActivationIsVerifiedAfterRunloopPause() async {
        let backend = FakeActivationBackend()
        var waits = 0
        let result = await WindowActivationCoordinator().activate(using: backend, attempts: 4) {
            waits += 1
            if waits == 2 { backend.observation = .focused }
        }
        XCTAssertEqual(result, .success)
        XCTAssertEqual(waits, 2)
        XCTAssertEqual(backend.requests, 1)
    }

    @MainActor func testCancelWhileWaitingPreventsAnyLaterMutation() async {
        let coordinator = WindowActivationCoordinator()
        let backend = FakeActivationBackend()
        let result = await coordinator.activate(using: backend, attempts: 8) {
            coordinator.cancel()
        }
        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(backend.focuses, 1)
        XCTAssertEqual(backend.requests, 1)
    }

    @MainActor func testNewSelectionSupersedesOldRequestWithoutLaterOldFocus() async {
        let coordinator = WindowActivationCoordinator()
        let old = FakeActivationBackend()
        let replacement = FakeActivationBackend()
        replacement.observation = .focused
        var replacementResult: WindowActivationResult?
        let result = await coordinator.activate(using: old, attempts: 8) {
            replacementResult = await coordinator.activate(using: replacement, pause: {})
        }
        XCTAssertEqual(result, .superseded)
        XCTAssertEqual(replacementResult, .success)
        XCTAssertEqual(old.focuses, 1)
        XCTAssertEqual(old.requests, 1)
    }

    @MainActor func testUnavailableTargetNeverReceivesMutation() async {
        let backend = FakeActivationBackend()
        backend.isAvailable = false
        let result = await WindowActivationCoordinator().activate(using: backend, pause: {})
        XCTAssertEqual(result, .notAvailable)
        XCTAssertEqual(backend.prepares, 0)
        XCTAssertEqual(backend.requests, 0)
        XCTAssertEqual(backend.focuses, 0)
    }

    @MainActor func testFailedPreparationDoesNotAttemptActivation() async {
        let backend = FakeActivationBackend()
        backend.preparationAccepted = false
        let result = await WindowActivationCoordinator().activate(using: backend, pause: {})
        XCTAssertEqual(result, .notAvailable)
        XCTAssertEqual(backend.prepares, 1)
        XCTAssertEqual(backend.requests, 0)
        XCTAssertEqual(backend.focuses, 0)
    }

    @MainActor func testWindowClosingDuringWaitStopsFurtherFocusAttempts() async {
        let backend = FakeActivationBackend()
        let result = await WindowActivationCoordinator().activate(using: backend, attempts: 6) {
            backend.isAvailable = false
        }
        XCTAssertEqual(result, .notAvailable)
        XCTAssertEqual(backend.focuses, 1)
    }

    @MainActor func testZeroAttemptsNeverTouchesPlatform() async {
        let backend = FakeActivationBackend()
        let result = await WindowActivationCoordinator().activate(using: backend, attempts: 0, pause: {})
        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(backend.prepares, 0)
        XCTAssertEqual(backend.focuses, 0)
    }
}

@MainActor private final class FakeActivationBackend: WindowActivationBackend {
    var isAvailable = true
    var observation = WindowFocusObservation(isFrontmost: false, isFocused: false, isMinimized: false)
    var preparationAccepted = true
    var activationAccepted = true
    var prepares = 0
    var requests = 0
    var focuses = 0
    var onPrepare: ((FakeActivationBackend) -> Void)?
    var onFocus: ((FakeActivationBackend) -> Void)?

    func prepare() -> Bool { prepares += 1; onPrepare?(self); return preparationAccepted }
    func requestActivation() -> Bool { requests += 1; return activationAccepted }
    func focusTargetWindow() { focuses += 1; onFocus?(self) }
    func observe() -> WindowFocusObservation { observation }
}

private extension WindowFocusObservation {
    static var focused: Self { .init(isFrontmost: true, isFocused: true, isMinimized: false) }
}
