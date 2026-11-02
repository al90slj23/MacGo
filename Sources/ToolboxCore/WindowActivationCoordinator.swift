import Foundation

/// Observed state, rather than an activation/raise request's return code.
public struct WindowFocusObservation: Equatable {
    public let isFrontmost: Bool
    public let isFocused: Bool
    public let isMinimized: Bool

    public init(isFrontmost: Bool, isFocused: Bool, isMinimized: Bool) {
        self.isFrontmost = isFrontmost
        self.isFocused = isFocused
        self.isMinimized = isMinimized
    }

    fileprivate var confirmsSelection: Bool { isFrontmost && isFocused && !isMinimized }
}

/// Platform effects stay in the macOS adapter; this coordinator can be tested
/// without activating apps or sending Accessibility requests to real windows.
@MainActor public protocol WindowActivationBackend: AnyObject {
    var isAvailable: Bool { get }
    func prepare() -> Bool
    func requestActivation() -> Bool
    func focusTargetWindow()
    func observe() -> WindowFocusObservation
}

public enum WindowActivationResult: Equatable {
    case success
    case notAvailable
    case timedOut
    case superseded
}

@MainActor public final class WindowActivationCoordinator {
    private var generation: UInt64 = 0

    public init() {}

    public func cancel() { generation &+= 1 }

    public func activate(
        using backend: any WindowActivationBackend,
        attempts: Int = 12,
        pause: @escaping () async -> Void = { try? await Task.sleep(nanoseconds: 80_000_000) }
    ) async -> WindowActivationResult {
        generation &+= 1
        let request = generation

        // Never perform activation inside a key filter's synchronous callback.
        await Task.yield()
        guard request == generation, !Task.isCancelled else { return .superseded }
        guard attempts > 0 else { return .timedOut }
        guard backend.isAvailable, backend.prepare() else { return .notAvailable }

        for attempt in 0..<attempts {
            guard request == generation, !Task.isCancelled else { return .superseded }
            guard backend.isAvailable else { return .notAvailable }
            let before = backend.observe()
            if before.confirmsSelection { return .success }

            // An accepted request is not proof of activation. Retry requests
            // sparsely while continuing to check the specific window's focus.
            if !before.isFrontmost, attempt % 3 == 0 {
                _ = backend.requestActivation()
            }
            backend.focusTargetWindow()
            if backend.observe().confirmsSelection { return .success }

            if attempt + 1 < attempts {
                await pause()
                guard request == generation, !Task.isCancelled else { return .superseded }
            }
        }
        return .timedOut
    }
}
