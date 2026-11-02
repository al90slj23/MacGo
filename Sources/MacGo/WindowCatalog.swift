import AppKit
import ApplicationServices
import ToolboxCore
import OSLog

struct WindowID: Hashable {
    let pid: pid_t
    let serial: UInt64
}

struct SwitchableWindow {
    let id: WindowID
    let element: AXUIElement?
    let app: NSRunningApplication
    let title: String
    let minimized: Bool
    /// WindowServer top-left coordinates, captured outside the key filter.
    let frame: CGRect?
    var isWindowless: Bool { element == nil }
    var appName: String { app.localizedName ?? L("应用", "Application", "應用程式") }
}

@MainActor final class WindowCatalog {
    private let settings: Settings
    private var known: [SwitchableWindow] = []
    private var serial: UInt64 = 0
    private var recency = WindowRecency<WindowID>()
    private let activation = WindowActivationCoordinator()
    private let logger = Logger(subsystem: "local.mactoolbox.app", category: "WindowActivation")
    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceObserver: NSObjectProtocol?
    private var timer: Timer?
    private var focusTask: Task<Void, Never>?
    private var focusGeneration: UInt64 = 0
    private(set) var currentID: WindowID?
    var isRunning: Bool { timer != nil }
    var didChange: (() -> Void)?

    init(settings: Settings) { self.settings = settings }

    func start() {
        guard timer == nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recordFocusedWindow() }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        cancelFocus()
        timer?.invalidate(); timer = nil
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
        for observer in observers.values { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observers.removeAll(); known.removeAll()
    }

    @discardableResult func refresh() -> [SwitchableWindow] {
        guard AXIsProcessTrusted() else { return [] }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != getpid() &&
            WindowPickerPolicy.includes(bundleIdentifier: $0.bundleIdentifier, excludedBundleIDs: settings.windowSwitcherExcludedBundleIDs)
        }
        var next: [SwitchableWindow] = []
        for app in apps {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.15)
            addObserver(for: app, element: axApp)
            // A failed AX read is not proof that the app has no windows.
            guard let windows = value(axApp, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            var standardWindowCount = 0
            for element in windows {
                // Standard document/browser windows; exclude palettes, popovers and permission dialogs.
                let role = value(element, kAXRoleAttribute) as? String
                let subrole = value(element, kAXSubroleAttribute) as? String
                guard role == kAXWindowRole, subrole == kAXStandardWindowSubrole else { continue }
                standardWindowCount += 1
                let title = (value(element, kAXTitleAttribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let existing = known.first { item in
                    item.id.pid == app.processIdentifier && item.element.map { CFEqual($0, element) } == true
                }
                let id: WindowID
                if let existing { id = existing.id }
                else { serial += 1; id = WindowID(pid: app.processIdentifier, serial: serial) }
                next.append(SwitchableWindow(id: id, element: element, app: app,
                    title: title.isEmpty ? (app.localizedName ?? L("未命名窗口", "Untitled window", "未命名視窗")) : title,
                    minimized: value(element, kAXMinimizedAttribute) as? Bool ?? false,
                    frame: windowFrame(element)))
            }
            if standardWindowCount == 0, settings.showWindowlessApps {
                // Serial zero is reserved for the one application-only entry.
                next.append(SwitchableWindow(id: WindowID(pid: app.processIdentifier, serial: 0),
                    element: nil, app: app,
                    title: L("无窗口 · 打开应用", "No windows · Open application", "無視窗 · 開啟應用程式"),
                    minimized: false, frame: nil))
            }
        }
        let runningPIDs = Set(apps.map(\.processIdentifier))
        for pid in Array(observers.keys) where !runningPIDs.contains(pid) {
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
        known = next
        recency.prune(validIDs: Set(next.map(\.id)))
        recordFocusedWindow(refreshIfMissing: false)
        didChange?()
        return ordered()
    }

    func ordered() -> [SwitchableWindow] {
        let byID = Dictionary(uniqueKeysWithValues: known.map { ($0.id, $0) })
        return recency.ordered(known.map(\.id)).compactMap { byID[$0] }
    }

    var focusedID: WindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.10)
        guard let element = value(axApp, kAXFocusedWindowAttribute) else {
            return known.first { $0.id.pid == app.processIdentifier && $0.isWindowless }?.id
        }
        return known.first { item in
            item.id.pid == app.processIdentifier && item.element.map { CFEqual($0, element) } == true
        }?.id
    }

    func recordFocusedWindow(refreshIfMissing: Bool = true) {
        currentID = focusedID
        if let id = currentID { recency.record(id) }
        else if refreshIfMissing, NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() { refresh() }
    }

    func focus(_ item: SwitchableWindow, completion: @escaping (Bool) -> Void) {
        cancelFocus()
        let generation = focusGeneration
        if item.isWindowless {
            focusTask = Task { [weak self] in
                guard let self else { return }
                let success = await self.activateApplication(item, generation: generation)
                guard generation == self.focusGeneration, !Task.isCancelled else { return }
                if success { self.recency.record(item.id); self.currentID = item.id }
                self.logger.info("application-completed pid=\(item.id.pid) frontmostVerified=\(success)")
                completion(success)
            }
            return
        }
        guard let backend = NativeWindowActivation(item: item) else { completion(false); return }
        focusTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.activation.activate(using: backend)
            guard generation == self.focusGeneration, !Task.isCancelled, result != .superseded else { return }
            let success = result == .success
            if success { self.recency.record(item.id); self.currentID = item.id }
            self.logger.info("completed pid=\(item.id.pid) verified=\(success)")
            completion(success)
        }
    }

    func cancelFocus() {
        focusGeneration &+= 1
        focusTask?.cancel(); focusTask = nil
        activation.cancel()
    }

    /// Application-only choices are reopened through Launch Services. Their
    /// success condition is the observed frontmost app, not a fabricated window.
    private func activateApplication(_ item: SwitchableWindow, generation: UInt64) async -> Bool {
        await Task.yield()
        let app = NSRunningApplication(processIdentifier: item.id.pid) ?? item.app
        guard generation == focusGeneration, !Task.isCancelled, !app.isTerminated,
              AXIsProcessTrusted(), let url = app.bundleURL else { return false }
        if app.isHidden { _ = app.unhide() }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        let reopened = await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
        logger.info("application-reopen pid=\(item.id.pid, privacy: .public) accepted=\(reopened, privacy: .public)")
        guard reopened, generation == focusGeneration, !Task.isCancelled, !app.isTerminated else { return false }
        let application = AXUIElementCreateApplication(item.id.pid)
        AXUIElementSetMessagingTimeout(application, 0.08)
        for attempt in 0..<12 {
            guard generation == focusGeneration, !Task.isCancelled, !app.isTerminated,
                  AXIsProcessTrusted() else { return false }
            let observedPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            let frontmost = observedPID == item.id.pid
            logger.info("application-observed pid=\(item.id.pid, privacy: .public) attempt=\(attempt, privacy: .public) observedPID=\(observedPID, privacy: .public) frontmost=\(frontmost, privacy: .public)")
            if frontmost { return true }
            // Reopening an already-running windowless app may deliver its
            // reopen event without transferring activation. Request activation
            // explicitly, at most twice, while continuing to observe the PID.
            if attempt == 0 || attempt == 6 {
                let accepted: Bool
                if #available(macOS 14, *) {
                    if NSApp.isActive {
                        NSApp.yieldActivation(to: app)
                        accepted = app.activate(from: .current, options: [])
                    } else { accepted = app.activate(options: []) }
                } else { accepted = app.activate(options: [.activateIgnoringOtherApps]) }
                logger.info("application-activation pid=\(item.id.pid, privacy: .public) attempt=\(attempt, privacy: .public) accepted=\(accepted, privacy: .public)")
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != item.id.pid {
                    var writable = DarwinBoolean(false)
                    let query = AXUIElementIsAttributeSettable(application, kAXFrontmostAttribute as CFString, &writable)
                    if query == .success, writable.boolValue {
                        let result = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                        logger.info("application-frontmost-request pid=\(item.id.pid, privacy: .public) attempt=\(attempt, privacy: .public) error=\(result.rawValue, privacy: .public)")
                    } else {
                        logger.info("application-frontmost-unavailable pid=\(item.id.pid, privacy: .public) query=\(query.rawValue, privacy: .public) writable=\(writable.boolValue, privacy: .public)")
                    }
                }
            }
            if attempt + 1 < 12 { try? await Task.sleep(nanoseconds: 80_000_000) }
        }
        return false
    }

    private func windowFrame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetType(position as! AXValue) == .cgPoint, AXValueGetType(size as! AXValue) == .cgSize,
              AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func addObserver(for app: NSRunningApplication, element: AXUIElement) {
        guard observers[app.processIdentifier] == nil else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            let catalog = Unmanaged<WindowCatalog>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in catalog.recordFocusedWindow() }
        }
        guard AXObserverCreate(app.processIdentifier, callback, &observer) == .success, let observer else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, element, kAXFocusedWindowChangedNotification as CFString, context)
        AXObserverAddNotification(observer, element, kAXWindowCreatedNotification as CFString, context)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[app.processIdentifier] = observer
    }

    private func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }
}
