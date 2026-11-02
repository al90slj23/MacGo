import AppKit
import ServiceManagement

@MainActor final class AppController: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private lazy var switcher = WindowSwitcher(settings: settings)
    private var statusItem: NSStatusItem?
    private var window: NSWindow!
    private var permissionTimer: Timer?
    private var fanView: FanToolView!
    private var fanMenu: FanMenuBarController?
    private var fanPreferences: FanPreferencesView!
    private var fanRules: FanRulesPreferencesView!
    private var preferences: SwitcherPreferencesView!
    private var blacklist: BlacklistPreferencesView!
    private var general: GeneralPreferencesView!
    private var permissions: PermissionsPreferencesView!
    private var navigation: SettingsNavigationView!
    private var settingsContainer: NSView?
    private var pageHost: NSView!
    private var pages: [SettingsPage: NSView] = [:]
    private var selectedPage: SettingsPage = .switcher
    private let permissionGuide = PermissionGuide()
    private let screenGuide = PermissionGuide(kind: .screenRecording)
    private var lastAccessibilityTrusted = false
    private var lastScreenRecordingTrusted = false
    private var recordingShortcut = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The Dock remains a reliable reopen path, even if the menu icon is hidden.
        NSApp.setActivationPolicy(.regular)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        configureMenus(); buildSettings()
        switcher.stateChanged = { [weak self] in self?.updateStatus() }
        switcher.message = { [weak self] in self?.showMessage($0) }
        switcher.requestThumbnailPermission = { [weak self] in self?.authorizeScreenRecording() }
        switcher.start()
        lastAccessibilityTrusted = AXIsProcessTrusted()
        lastScreenRecordingTrusted = CGPreflightScreenCaptureAccess()
        permissionGuide.authorized = { [weak self] in
            guard let self else { return }
            self.lastAccessibilityTrusted = true
            if !self.recordingShortcut { self.switcher.start() }
            self.updateStatus()
        }
        permissionGuide.restartRequested = { [weak self] in self?.restartApplication() }
        screenGuide.restartRequested = { [weak self] in self?.restartApplication() }
        screenGuide.authorized = { [weak self] in
            self?.lastScreenRecordingTrusted = true
            self?.switcher.refreshThumbnails(); self?.updateStatus()
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let trusted = AXIsProcessTrusted()
                if trusted != self.lastAccessibilityTrusted {
                    self.lastAccessibilityTrusted = trusted
                    if trusted && !self.recordingShortcut { self.switcher.start() }
                    else { self.switcher.stop() }
                }
                let screenTrusted = CGPreflightScreenCaptureAccess()
                if screenTrusted != self.lastScreenRecordingTrusted {
                    self.lastScreenRecordingTrusted = screenTrusted
                    self.switcher.refreshThumbnails()
                }
                self.updateStatus()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(cancelSwitching), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(cancelSwitching), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        showSettings()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate(); permissionGuide.close(); screenGuide.close()
        switcher.stop(); fanMenu?.shutdown(); fanView.shutdown()
    }
    @objc private func cancelSwitching() { switcher.cancel() }

    private func configureMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Mac Go")
        let open = NSMenuItem(title: L("打开 Mac Go…", "Open Mac Go…"), action: #selector(showSettings), keyEquivalent: ",")
        open.target = self; appMenu.addItem(open); appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: L("退出 Mac Go", "Quit Mac Go"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; appMenu.addItem(quitItem)
        appItem.submenu = appMenu; main.addItem(appItem); NSApp.mainMenu = main
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: L("帮助", "Help"))
        addMenu(L("使用说明", "Usage guide"), action: #selector(showGuide), to: helpMenu)
        helpItem.submenu = helpMenu; main.addItem(helpItem); NSApp.helpMenu = helpMenu

        if statusItem == nil { statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) }
        guard let statusItem else { return }
        let icon = NSImage(systemSymbolName: "wrench.and.screwdriver.fill", accessibilityDescription: "Mac Go")
        icon?.size = NSSize(width: 17, height: 17); icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.title = " " + L("Mac Go", "Mac Go")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.setAccessibilityLabel(L("Mac Go：点击打开工具菜单", "Mac Go: open tools menu"))
        statusItem.button?.toolTip = L("Mac Go · 窗口切换 / 风扇控制", "Mac Go · Window switching / Fans")
        let menu = NSMenu()
        let title = NSMenuItem(title: "Mac Go", action: nil, keyEquivalent: "")
        title.isEnabled = false; menu.addItem(title)
        addMenu(L("打开 Mac Go…", "Open Mac Go…"), action: #selector(showSettings), to: menu)
        addMenu(L("查看窗口列表", "Preview windows"), action: #selector(preview), to: menu)
        addMenu(L("窗口切换黑名单…", "Window switcher exclusions…"), action: #selector(showBlacklist), to: menu)
        addMenu(L("风扇控制…", "Fan control…"), action: #selector(showFans), to: menu)
        addMenu(L("温控规则…", "Temperature rules…"), action: #selector(showFanRules), to: menu)
        addMenu(L("通用授权…", "Permissions…"), action: #selector(showPermissions), to: menu)
        menu.addItem(.separator())
        addMenu(L("退出 Mac Go", "Quit Mac Go"), action: #selector(quit), to: menu)
        statusItem.menu = menu
        statusItem.isVisible = settings.showMenuBarIcon
        fanMenu?.refreshLocalization()
    }

    private func addMenu(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menu.addItem(item)
    }

    private func buildSettings() {
        permissionGuide.close(); screenGuide.close()
        if window == nil {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Mac Go"; window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 960, height: 600); window.center()
        }
        if fanView == nil {
            fanView = FanToolView(settings: settings)
            fanMenu = FanMenuBarController(settings: settings, session: fanView)
        }
        fanView.authorizationRequested = { [weak self] in self?.showPermissions() }
        fanView.openRules = { [weak self] in self?.showFanRules() }
        fanView.openPreferences = { [weak self] in self?.showFanPreferences() }
        fanMenu?.openRules = { [weak self] in self?.showFanRules() }
        fanMenu?.openPreferences = { [weak self] in self?.showFanPreferences() }
        fanView.stateChanged = { [weak self] in self?.updateFanState() }
        fanPreferences = FanPreferencesView(settings: settings)
        fanPreferences.changed = { [weak self] in
            self?.fanView.applySettings(); self?.updateFanState()
        }
        fanRules = FanRulesPreferencesView(settings: settings)
        fanRules.changed = { [weak self] in
            self?.fanView.applySettings(); self?.updateFanState()
        }
        preferences = SwitcherPreferencesView(settings: settings)
        preferences.settingsChanged = { [weak self] in self?.applySwitcherSettings() }
        general = GeneralPreferencesView(settings: settings)
        general.menuVisibilityChanged = { [weak self] in
            guard let self else { return }
            self.statusItem?.isVisible = self.settings.showMenuBarIcon
            self.fanMenu?.update()
        }
        general.languageChanged = { [weak self] in
            guard let self else { return }
            self.configureMenus()
            self.fanView.refreshLocalization()
            self.buildSettings()
            self.applySwitcherSettings()
        }
        general.loginChanged = { [weak self] in self?.setLogin($0) }
        permissions = PermissionsPreferencesView(frame: .zero)
        permissions.requestAccessibility = { [weak self] anchor in
            if AXIsProcessTrusted() {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
            } else { self?.permissionGuide.show(relativeTo: anchor) }
        }
        permissions.requestScreenRecording = { [weak self] anchor in
            if CGPreflightScreenCaptureAccess() {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
            } else { self?.screenGuide.show(relativeTo: anchor) }
        }
        permissions.requestFanService = { [weak self] in
            guard let self else { return }
            if self.fanView.isControlServiceReady { self.selectPage(.fans) }
            else { self.fanView.requestAuthorization(presenting: self.window) }
        }
        preferences.requestAccessibility = { [weak self] _ in self?.showPermissions() }
        preferences.requestScreenRecording = { [weak self] _ in self?.authorizeScreenRecording() }
        preferences.preview = { [weak self] in self?.switcher.preview() }
        preferences.recordingChanged = { [weak self] active in
            guard let self else { return }
            self.recordingShortcut = active
            if active { self.switcher.suspendShortcut() } else { self.switcher.start() }
            self.updateStatus()
        }
        preferences.shortcutSelected = { [weak self] value in
            self?.settings.shortcut = value
            self?.applySwitcherSettings()
        }
        blacklist = BlacklistPreferencesView(settings: settings)
        blacklist.changed = { [weak self] in self?.applySwitcherSettings() }

        fanView.removeFromSuperview()
        settingsContainer?.removeFromSuperview()
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        settingsContainer = container
        navigation = SettingsNavigationView(page: selectedPage)
        navigation.selected = { [weak self] page in self?.selectPage(page) }
        let divider = NSBox(); divider.boxType = .separator
        pageHost = NSView()
        for view in [navigation!, divider, pageHost!] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        pages = [.general: general, .permissions: permissions, .switcher: preferences,
                 .switcherBlacklist: blacklist, .fans: fanView, .fanRules: fanRules,
                 .fanPreferences: fanPreferences, .guide: UsageGuideView(frame: .zero)]
        window.contentView?.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            container.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            container.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            navigation.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            navigation.topAnchor.constraint(equalTo: container.topAnchor),
            navigation.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            navigation.widthAnchor.constraint(equalToConstant: 218),
            divider.leadingAnchor.constraint(equalTo: navigation.trailingAnchor),
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            pageHost.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            pageHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pageHost.topAnchor.constraint(equalTo: container.topAnchor),
            pageHost.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        selectPage(selectedPage)
        updateStatus(); updateFanState()
    }

    private func updateFanState() {
        fanMenu?.update()
        fanRules?.update(sensors: fanView.temperatures, fans: fanView.readings)
        if permissions != nil {
            permissions.updateStatus(accessibilityTrusted: AXIsProcessTrusted(),
                                     screenRecordingTrusted: CGPreflightScreenCaptureAccess(),
                                     fanStatus: fanView.authorizationSummary, fanReady: fanView.isControlServiceReady)
        }
    }

    private func applySwitcherSettings() {
        if recordingShortcut { switcher.suspendShortcut() } else { switcher.applySettings() }
        preferences.refreshControls()
        updateStatus()
    }

    private func updateStatus() {
        guard preferences != nil else { return }
        let text: String
        if recordingShortcut { text = L("正在录制快捷键；Esc 取消。", "Recording shortcut; Esc cancels.") }
        else if !settings.enabled { text = L("窗口切换已关闭。", "Window switching is off.") }
        else if !AXIsProcessTrusted() { text = L("等待辅助功能授权；授权前使用系统原有快捷键。", "Waiting for Accessibility permission. macOS shortcuts remain active.") }
        else if switcher.isRunning {
            let result: String
            if switcher.isSwitching { result = L(" · 正在切换…", " · Switching…") }
            else if let success = switcher.lastSwitchSucceeded {
                result = success ? L(" · 最近切换已确认", " · Last switch verified") : L(" · 最近切换未成功", " · Last switch failed")
            } else { result = "" }
            text = String(format: L("已启用 · %d 个条目 · %@", "Enabled · %d items · %@"), switcher.windowCount, settings.shortcut.display) + result
        } else { text = L("全局快捷键尚未启用，请检查权限后重试。", "Global shortcut is unavailable. Check permissions and retry.") }
        let accessibility = AXIsProcessTrusted(), screenRecording = CGPreflightScreenCaptureAccess()
        preferences.updateStatus(text, accessibilityTrusted: accessibility, screenRecordingTrusted: screenRecording)
        permissions.updateStatus(accessibilityTrusted: accessibility, screenRecordingTrusted: screenRecording,
                                 fanStatus: fanView.authorizationSummary, fanReady: fanView.isControlServiceReady)
        general.refreshControls()
    }

    @objc func showSettings() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateStatus()
    }
    private func authorizeScreenRecording() {
        switcher.cancel(); showSettings()
        selectPage(.permissions)
        permissions.showScreenRecordingGuide()
    }
    private func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { showMessage(L("登录启动设置失败：", "Could not update login startup: ") + error.localizedDescription) }
        general.refreshControls(); updateStatus()
    }
    @objc private func preview() { switcher.preview() }
    private func selectPage(_ page: SettingsPage) {
        guard let view = pages[page], pageHost != nil else { return }
        if selectedPage != page { permissionGuide.close(); screenGuide.close() }
        selectedPage = page; navigation.select(page)
        for child in pageHost.subviews { child.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false; pageHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: pageHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor)
        ])
        updateStatus()
    }
    @objc private func showFans() { showSettings(); selectPage(.fans) }
    @objc private func showFanRules() { showSettings(); selectPage(.fanRules) }
    @objc private func showFanPreferences() { showSettings(); selectPage(.fanPreferences) }
    @objc private func showBlacklist() { showSettings(); selectPage(.switcherBlacklist) }
    @objc private func showPermissions() { showSettings(); selectPage(.permissions) }
    @objc private func showGuide() { showSettings(); selectPage(.guide) }
    @objc private func quit() { NSApp.terminate(nil) }
    private func restartApplication() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true; config.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            Task { @MainActor in
                if let error { self.showMessage(L("重新启动失败：", "Could not restart: ") + error.localizedDescription) }
                else { NSApp.terminate(nil) }
            }
        }
    }
    private func showMessage(_ message: String) {
        let alert = NSAlert(); alert.messageText = "Mac Go"; alert.informativeText = message
        if window.isVisible { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
