import AppKit
import ApplicationServices
import OSLog
import ToolboxCore

/// Public accessibility/AppKit operations, with observed focus as the success
/// condition. Sending an activation request or raising a window is not success.
@MainActor final class NativeWindowActivation: WindowActivationBackend {
    private let app: NSRunningApplication
    private let window: AXUIElement
    private let application: AXUIElement
    private let logger = Logger(subsystem: "local.mactoolbox.app", category: "WindowActivation")
    private var attempts = 0

    init?(item: SwitchableWindow) {
        guard let element = item.element else { return nil }
        app = NSRunningApplication(processIdentifier: item.id.pid) ?? item.app
        window = element
        application = AXUIElementCreateApplication(item.id.pid)
        AXUIElementSetMessagingTimeout(window, 0.08)
        AXUIElementSetMessagingTimeout(application, 0.08)
    }

    var isAvailable: Bool { !app.isTerminated && AXIsProcessTrusted() }

    func prepare() -> Bool {
        guard isAvailable else { return false }
        // Read the live value: a cached list can predate minimization.
        if value(window, kAXMinimizedAttribute) as? Bool == true {
            let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            guard result == .success else {
                logger.error("unminimize failed pid=\(self.app.processIdentifier) error=\(result.rawValue)")
                return false
            }
        }
        if app.isHidden { _ = app.unhide() }
        setIfWritable(window, kAXMainAttribute, kCFBooleanTrue)
        return true
    }

    func requestActivation() -> Bool {
        let accepted: Bool
        if #available(macOS 14, *) {
            if NSApp.isActive {
                NSApp.yieldActivation(to: app)
                accepted = app.activate(from: .current, options: [])
            } else { accepted = app.activate(options: []) }
        } else { accepted = app.activate(options: [.activateIgnoringOtherApps]) }
        logger.info("activation request pid=\(self.app.processIdentifier) accepted=\(accepted)")
        return accepted
    }

    func focusTargetWindow() {
        guard isAvailable else { return }
        attempts += 1
        setIfWritable(window, kAXMainAttribute, kCFBooleanTrue)
        // Different applications expose different writable focus attributes.
        setIfWritable(application, kAXFocusedWindowAttribute, window)
        setIfWritable(window, kAXFocusedAttribute, kCFBooleanTrue)
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            setIfWritable(application, kAXFrontmostAttribute, kCFBooleanTrue)
        }
        logger.info("focus attempt=\(self.attempts) pid=\(self.app.processIdentifier) raise=\(raised.rawValue)")
    }

    func observe() -> WindowFocusObservation {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        let focused = value(application, kAXFocusedWindowAttribute).map { CFEqual($0, window) } ?? false
        // A failed read is unknown, not evidence that the window is restored.
        let minimized = value(window, kAXMinimizedAttribute) as? Bool
        let result = WindowFocusObservation(isFrontmost: frontmost, isFocused: focused, isMinimized: minimized != false)
        logger.info("observed pid=\(self.app.processIdentifier) frontmost=\(frontmost) focused=\(focused) restored=\(minimized == false)")
        return result
    }

    private func setIfWritable(_ element: AXUIElement, _ name: String, _ newValue: CFTypeRef) {
        var writable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, name as CFString, &writable) == .success, writable.boolValue else { return }
        let error = AXUIElementSetAttributeValue(element, name as CFString, newValue)
        if error != .success { logger.debug("AX set failed attribute=\(name, privacy: .public) error=\(error.rawValue)") }
    }

    private func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }
}
