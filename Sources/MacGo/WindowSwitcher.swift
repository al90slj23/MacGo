import AppKit
import ToolboxCore
import OSLog

@MainActor final class WindowSwitcher: NSObject, ToolboxModule {
    var name: String { L("窗口切换", "Window switcher", "視窗切換") }
    let settings: Settings
    private lazy var catalog = WindowCatalog(settings: settings)
    private let monitor = ShortcutMonitor()
    private var panels: [String: SwitcherPanel] = [:]
    private var invocationDisplayID: String?
    private let thumbnails = WindowThumbnailProvider()
    private var session = SwitcherSession<WindowID>()
    /// The picker may contain only the mouse-only application strip. Keeping
    /// its lifecycle separate prevents those entries entering Tab navigation.
    private var pickerIsActive = false
    private var snapshot: [SwitchableWindow] = []
    private var windowlessSnapshot: [SwitchableWindow] = []
    private var sessionImages: [WindowID: NSImage] = [:]
    private var previewMode = false
    private var interactionGeneration: UInt64 = 0
    private let logger = Logger(subsystem: "local.mactoolbox.app", category: "WindowSwitcher")
    var stateChanged: (() -> Void)?
    var message: ((String) -> Void)?
    var switchCompleted: ((Bool) -> Void)?
    var requestThumbnailPermission: (() -> Void)?
    private(set) var isSwitching = false
    private(set) var lastSwitchSucceeded: Bool?
    var isRunning: Bool { monitor.isRunning }
    var windowCount: Int { catalog.ordered().count }

    init(settings: Settings) {
        self.settings = settings
        super.init()
        monitor.canBegin = { [weak self] in self?.catalog.ordered().contains(where: { !$0.isWindowless }) ?? false }
        monitor.isSelecting = { [weak self] in self?.pickerIsActive ?? false }
        monitor.commitOnModifierRelease = { [weak self] in !(self?.previewMode ?? false) }
        monitor.keyboardTrigger = { [weak self] in self?.previewMode = false }
        monitor.cycle = { [weak self] in self?.cycle(backwards: $0) }
        monitor.commit = { [weak self] in self?.commit() }
        monitor.cancel = { [weak self] in self?.cancel() }
        monitor.stateChanged = { [weak self] in self?.stateChanged?() }
        catalog.didChange = { [weak self] in
            guard let self else { return }
            if self.pickerIsActive {
                let currentItems = self.catalog.ordered()
                let current = Dictionary(uniqueKeysWithValues: currentItems.map { ($0.id, $0) })
                let valid = Set(current.keys)
                for id in self.session.items where !valid.contains(id) { self.session.remove(id) }
                // Freeze order, but refresh titles, minimized flags and frames.
                self.snapshot = self.snapshot.compactMap { current[$0.id] }.filter { !$0.isWindowless }
                // Unlike keyboard order, this separate strip follows the live
                // catalog, including apps whose last window has just closed.
                self.windowlessSnapshot = self.settings.showWindowlessApps
                    ? currentItems.filter(\.isWindowless) : []
                self.sessionImages = self.sessionImages.filter {
                    guard let item = current[$0.key] else { return false }
                    return !item.minimized && !item.isWindowless
                }
                if self.session.isActive || !self.windowlessSnapshot.isEmpty {
                    self.showPanel()
                } else { self.cancel() }
            }
            self.stateChanged?()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func start() {
        guard settings.enabled, AXIsProcessTrusted() else { stateChanged?(); return }
        catalog.start()
        monitor.shortcut = settings.shortcut
        if !monitor.start() { message?(L("无法启用全局快捷键，请检查辅助功能权限后重新启用。", "Could not enable the shortcut. Check Accessibility access and enable it again.", "無法啟用全域快捷鍵，請檢查輔助使用權限後重新啟用。")) }
        stateChanged?()
    }

    func stop() { monitor.stop(); catalog.stop(); cancel(); thumbnails.clearCache(); stateChanged?() }
    func applySettings() {
        guard settings.enabled, AXIsProcessTrusted() else { stop(); return }
        // Preference changes keep the catalog and its MRU identities alive.
        // Only the keyboard filter needs to be restarted for a new shortcut.
        monitor.stop()
        cancel()
        if catalog.isRunning { catalog.refresh() }
        start()
    }

    /// Shortcut recording must not consume its own keystrokes or discard MRU.
    func suspendShortcut() { monitor.stop(); cancel(); stateChanged?() }
    func cancel() {
        catalog.cancelFocus()
        thumbnails.clearCache()
        monitor.invalidatePendingCommit()
        interactionGeneration &+= 1
        session.cancel(); snapshot.removeAll(); windowlessSnapshot.removeAll()
        pickerIsActive = false; previewMode = false
        sessionImages.removeAll()
        for panel in panels.values { panel.clearThumbnails(); panel.orderOut(nil) }
        invocationDisplayID = nil
        isSwitching = false
    }

    private func cycle(backwards: Bool) {
        let first = !pickerIsActive
        if session.isActive { session.advance(backwards: backwards) }
        else {
            catalog.cancelFocus()
            interactionGeneration &+= 1
            isSwitching = false
            let items = catalog.ordered()
            snapshot = items.filter { !$0.isWindowless }
            windowlessSnapshot = settings.showWindowlessApps ? items.filter(\.isWindowless) : []
            captureInvocationDisplay()
            session.begin(items: snapshot.map(\.id), currentID: catalog.currentID, backwards: backwards,
                          initialSelection: selectionPolicy)
            pickerIsActive = session.isActive || !windowlessSnapshot.isEmpty
        }
        guard pickerIsActive else { return }
        showPanel()
        if first { refreshThumbnails() }
    }

    private func commit(id: WindowID? = nil) {
        let selected = id ?? session.selectedID
        let item = (snapshot + windowlessSnapshot).first { $0.id == selected }
        cancel()
        guard let item else { return }
        let generation = interactionGeneration
        isSwitching = true
        lastSwitchSucceeded = nil
        logger.info("commit selectedPID=\(item.id.pid, privacy: .public)")
        stateChanged?()
        // This also defers the mouse-click path. The chosen AX element is saved
        // before closing the picker and never re-derived from a cleared session.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.interactionGeneration == generation else { return }
            self.catalog.focus(item) { [weak self] success in
                guard let self, self.interactionGeneration == generation else { return }
                self.isSwitching = false
                self.lastSwitchSucceeded = success
                self.logger.info("commit-completed selectedPID=\(item.id.pid, privacy: .public) success=\(success, privacy: .public)")
                self.switchCompleted?(success)
                self.stateChanged?()
                if !success { self.message?(L("未能确认选中的窗口或应用已进入前台，请重试。", "Could not confirm the selected window or app is in front. Try again.", "未能確認選取的視窗或應用程式已進入前景，請重試。")) }
            }
        }
    }

    private func hover(id: WindowID) {
        guard pickerIsActive, session.selectedID != id, session.select(id) else { return }
        showPanel()
    }

    private func terminateApplication(id: WindowID) {
        guard pickerIsActive,
              let item = (snapshot + windowlessSnapshot).first(where: { $0.id == id }) else { return }
        // Closing the picker invalidates a queued modifier release. Request a
        // normal application quit so its own unsaved-document prompts apply.
        // Never force-terminate and never activate a different selected card.
        cancel()
        guard !item.app.isTerminated else { return }
        if !item.app.terminate() {
            message?(L("未能请求退出 \(item.appName)，请在该应用中退出。",
                       "Could not request quitting \(item.appName). Quit from the app itself.",
                       "未能要求結束 \(item.appName)，請在該應用程式中結束。"))
        }
    }

    /// Opens a static picker for visual inspection without intercepting any system shortcut.
    func preview() {
        guard AXIsProcessTrusted() else { message?(L("请先授予辅助功能权限，再查看窗口列表。", "Grant Accessibility access before opening the window list.", "請先授予輔助使用權限，再查看視窗列表。")); return }
        cancel()
        let items = catalog.refresh()
        snapshot = items.filter { !$0.isWindowless }
        windowlessSnapshot = settings.showWindowlessApps ? items.filter(\.isWindowless) : []
        previewMode = true
        captureInvocationDisplay()
        session.begin(items: snapshot.map(\.id), currentID: catalog.currentID, initialSelection: selectionPolicy)
        pickerIsActive = session.isActive || !windowlessSnapshot.isEmpty
        if pickerIsActive { showPanel(); refreshThumbnails() }
        else { message?(L("当前没有可切换的窗口或应用。", "There are no windows or apps to switch to.", "目前沒有可切換的視窗或應用程式。")) }
    }

    private var selectionPolicy: SwitcherSelectionPolicy {
        switch settings.initialSelection {
        case .previousWindow: return .previousWindow
        case .currentWindow: return .currentWindow
        case .firstWindow: return .firstWindow
        }
    }

    private struct Display {
        let id: String
        let screen: NSScreen
        let captureFrame: CGRect
    }

    private var displays: [Display] {
        let screens = NSScreen.screens
        let primaryTop = screens.first?.frame.maxY ?? 0
        return screens.enumerated().map { index, screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { "display:\($0.uint32Value)" } ?? "index:\(index)"
            return Display(id: id, screen: screen,
                captureFrame: CGRect(x: screen.frame.minX, y: primaryTop - screen.frame.maxY,
                                     width: screen.frame.width, height: screen.frame.height))
        }
    }

    private func captureInvocationDisplay() {
        let displays = displays
        invocationDisplayID = (displays.first { $0.screen.frame.contains(NSEvent.mouseLocation) } ?? displays.first)?.id
    }

    @objc private func displaysChanged() {
        if pickerIsActive { showPanel() }
        else {
            for panel in panels.values { panel.orderOut(nil) }
            panels.removeAll()
        }
    }

    private func panel(for display: Display) -> SwitcherPanel {
        if let panel = panels[display.id] { return panel }
        let panel = SwitcherPanel()
        panel.choose = { [weak self] in self?.commit(id: $0) }
        panel.hover = { [weak self] in self?.hover(id: $0) }
        panel.terminateApplication = { [weak self] in self?.terminateApplication(id: $0) }
        panel.dismiss = { [weak self] in self?.cancel() }
        panel.requestThumbnailPermission = { [weak self] in self?.requestThumbnailPermission?() }
        panels[display.id] = panel
        return panel
    }

    private func showPanel() {
        let displays = displays
        guard !displays.isEmpty else { cancel(); return }
        let fallbackIndex = displays.firstIndex { $0.id == invocationDisplayID } ?? 0
        invocationDisplayID = displays[fallbackIndex].id
        var groups: [String: [SwitchableWindow]] = [:]
        if settings.screenMode == .perScreen {
            for item in snapshot {
                let index = WindowPickerPolicy.displayIndex(windowFrame: item.frame,
                    displayFrames: displays.map(\.captureFrame), fallbackIndex: fallbackIndex) ?? fallbackIndex
                groups[displays[index].id, default: []].append(item)
            }
        } else { groups[displays[fallbackIndex].id] = snapshot }
        let windowlessDisplayID = displays[fallbackIndex].id
        if !windowlessSnapshot.isEmpty, groups[windowlessDisplayID] == nil {
            groups[windowlessDisplayID] = []
        }
        for id in Array(panels.keys) where groups[id] == nil {
            panels.removeValue(forKey: id)?.orderOut(nil)
        }
        let indices = Dictionary(uniqueKeysWithValues: snapshot.enumerated().map { ($0.element.id, $0.offset + 1) })
        for display in displays {
            guard let items = groups[display.id] else { continue }
            let windowlessItems = display.id == windowlessDisplayID ? windowlessSnapshot : []
            guard !items.isEmpty || !windowlessItems.isEmpty else { continue }
            let panel = panel(for: display)
            panel.thumbnailsEnabled = settings.showThumbnails && thumbnails.isSupported
            panel.thumbnailPermissionGranted = thumbnails.isAuthorized
            panel.panelSizePercent = settings.panelSizePercent
            panel.thumbnailContentMode = settings.thumbnailContentMode
            panel.show(items: items, windowlessItems: windowlessItems,
                       selected: session.selectedID, shortcut: settings.shortcut,
                       on: display.screen, globalIndices: indices,
                       displayName: settings.screenMode == .perScreen ? display.screen.localizedName : nil)
            for item in items {
                if let image = sessionImages[item.id] { panel.setThumbnail(image, for: item.id) }
                else { panel.removeThumbnail(for: item.id) }
            }
        }
    }

    func refreshThumbnails() {
        thumbnails.clearCache()
        sessionImages.removeAll()
        // Each new capture request starts with icons. A previous session's
        // image must not survive when a window is now minimized or unmatched.
        for panel in panels.values { panel.clearThumbnails() }
        guard settings.showThumbnails, session.isActive else {
            if pickerIsActive { showPanel() }
            return
        }
        showPanel()
        let visiblePanels = panels.values.filter(\.isVisible)
        let pixelSize = visiblePanels.reduce(NSSize(width: 1, height: 1)) { size, panel in
            NSSize(width: max(size.width, panel.maximumThumbnailPixelSize.width),
                   height: max(size.height, panel.maximumThumbnailPixelSize.height))
        }
        let backingScale = visiblePanels.map(\.thumbnailBackingScaleFactor).max() ?? 2
        thumbnails.request(items: snapshot, selected: session.selectedID,
                           maximumPixelSize: pixelSize, backingScaleFactor: backingScale) { [weak self] id, image in
            guard let self, self.pickerIsActive, self.session.isActive else { return }
            guard let item = self.snapshot.first(where: { $0.id == id }), !item.minimized, !item.isWindowless else { return }
            self.sessionImages[id] = image
            for panel in self.panels.values { panel.setThumbnail(image, for: id) }
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
