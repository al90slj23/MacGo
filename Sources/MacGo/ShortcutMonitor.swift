import AppKit
import Carbon.HIToolbox
import OSLog

/// An active session event filter. We never modify system symbolic-hotkey preferences.
@MainActor final class ShortcutMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowed = Set<Int64>()
    private var healthTimer: Timer?
    private var commitGeneration: UInt64 = 0
    private var commitScheduled = false
    private let logger = Logger(subsystem: "local.mactoolbox.app", category: "ShortcutMonitor")
    // Resolve persisted custom bindings when settings change, not in the
    // synchronous global event callback for every keystroke.
    private var triggerKeyCode: Int64 = 48
    private var requiredModifiers: CGEventFlags = .maskCommand
    var shortcut: SwitchShortcut = .commandTab {
        didSet {
            triggerKeyCode = shortcut.keyCode
            requiredModifiers = shortcut.modifier
        }
    }
    var canBegin: () -> Bool = { false }
    var isSelecting: () -> Bool = { false }
    /// Preview lists accept confirmation/navigation, but must not commit merely
    /// because their modifier was never held.
    var commitOnModifierRelease: () -> Bool = { true }
    var keyboardTrigger: () -> Void = {}
    var cycle: (Bool) -> Void = { _ in }
    var commit: () -> Void = {}
    var cancel: () -> Void = {}
    var stateChanged: (() -> Void)?
    var isRunning: Bool { tap != nil }

    @discardableResult func start() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                Unmanaged<ShortcutMonitor>.fromOpaque(context).takeUnretainedValue().handle(type, event)
            }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        healthTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !AXIsProcessTrusted() { self.stop(); self.stateChanged?(); return }
                // Password fields can hide the modifier-release event. Never leave the picker stuck.
                if IsSecureEventInputEnabled() {
                    self.invalidatePendingCommit(); self.cancel(); self.swallowed.removeAll()
                }
                else if self.isSelecting(), self.commitOnModifierRelease(),
                        !CGEventSource.flagsState(.combinedSessionState).contains(self.requiredModifiers) {
                    self.scheduleCommit(reason: "modifier-poll")
                }
            }
        }
        return true
    }

    func stop() {
        invalidatePendingCommit()
        cancel(); swallowed.removeAll()
        healthTimer?.invalidate(); healthTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil
    }

    /// Called when the owning picker is cancelled, replaced or closed by mouse.
    /// A queued release must never commit a newly opened selection session.
    func invalidatePendingCommit() {
        commitGeneration &+= 1
        commitScheduled = false
    }

    private func scheduleCommit(reason: String) {
        guard isSelecting(), !commitScheduled else { return }
        commitScheduled = true
        let generation = commitGeneration
        logger.info("commit-request reason=\(reason, privacy: .public)")
        // Activation must run after the event-tap callback returns and the
        // modifier-release event has continued through the system event stream.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.commitGeneration == generation,
                  self.commitScheduled, self.isSelecting() else { return }
            self.commitScheduled = false
            guard !IsSecureEventInputEnabled() else {
                self.invalidatePendingCommit(); self.cancel(); return
            }
            self.commit()
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logger.error("event tap disabled type=\(type.rawValue)")
            invalidatePendingCommit()
            cancel(); swallowed.removeAll()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp, swallowed.remove(code) != nil { return nil }
        if type == .flagsChanged {
            if isSelecting(), commitOnModifierRelease(), !event.flags.contains(requiredModifiers) {
                scheduleCommit(reason: "modifier-release")
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let modifiers = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl])
        if code == triggerKeyCode, modifiers == requiredModifiers {
            logger.info("trigger keyCode=\(code) selecting=\(self.isSelecting())")
            guard isSelecting() || canBegin() else { return Unmanaged.passUnretained(event) }
            swallowed.insert(code)
            // Holding Tab should not race through the entire list via key repeat.
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                invalidatePendingCommit()
                keyboardTrigger()
                cycle(event.flags.contains(.maskShift))
            }
            return nil
        }
        if isSelecting() {
            if code == 53 {
                swallowed.insert(code); invalidatePendingCommit(); cancel(); return nil
            }
            if code == 36 || code == 76 {
                swallowed.insert(code); scheduleCommit(reason: "enter"); return nil
            }
            if [123, 124, 125, 126].contains(code) {
                swallowed.insert(code); invalidatePendingCommit()
                cycle(code == 123 || code == 126); return nil
            }
        }
        return Unmanaged.passUnretained(event)
    }
}
