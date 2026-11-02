import AppKit

/// One catalog of actual permissions; each entry explains which tool uses it.
/// Displaying this page never requests access or installs a service.
@MainActor final class PermissionsPreferencesView: NSView {
    let accessibilityButton = NSButton(title: "", target: nil, action: nil)
    let screenPermissionButton = NSButton(title: "", target: nil, action: nil)
    private let fanButton = NSButton(title: "", target: nil, action: nil)
    private let accessibilityStatus = SharedSettingsLayout.hint("")
    private let screenStatus = SharedSettingsLayout.hint("")
    private let fanStatusLabel = SharedSettingsLayout.hint("")
    private let summary = SharedSettingsLayout.hint("")
    private let accessibilityIndicator = NSImageView()
    private let screenIndicator = NSImageView()
    private let fanIndicator = NSImageView()
    private let summaryIndicator = NSImageView()
    private let accessibilityDragFeedback = SharedSettingsLayout.hint("")
    private let screenDragFeedback = SharedSettingsLayout.hint("")
    private var screenRecordingCard: NSView?

    var requestAccessibility: ((NSButton) -> Void)?
    var requestScreenRecording: ((NSButton) -> Void)?
    var requestFanService: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        accessibilityButton.target = self; accessibilityButton.action = #selector(openAccessibility)
        screenPermissionButton.target = self; screenPermissionButton.action = #selector(openScreenRecording)
        fanButton.target = self; fanButton.action = #selector(openFanService)
        for button in [accessibilityButton, screenPermissionButton, fanButton] {
            button.bezelStyle = .rounded
        }
        let bundle = Bundle.main
        let bundleURL = bundle.bundleURL
        let appURL = bundleURL.pathExtension.lowercased() == "app" ? bundleURL : nil
        let appName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? bundleURL.deletingPathExtension().lastPathComponent
        let accessibilityDrag = AppBundleDragView(appURL: appURL, appName: appName)
        let screenDrag = AppBundleDragView(appURL: appURL, appName: appName)
        for source in [accessibilityDrag, screenDrag] {
            source.heightAnchor.constraint(equalToConstant: 68).isActive = true
        }
        let dragInstruction = L("拖入后，请按 macOS 提示开启权限；绿色勾选以实际检测为准。",
            "After dropping, enable access as macOS asks. A green check appears only when access is detected.")
        accessibilityDragFeedback.stringValue = dragInstruction
        screenDragFeedback.stringValue = dragInstruction
        accessibilityDrag.dragEnded = { [weak self] copied in
            self?.accessibilityDragFeedback.stringValue = copied
                ? L("应用图标已投放，请在系统设置中开启权限，等待状态变绿。", "App icon dropped. Enable access in System Settings and wait for a green check.")
                : L("尚未投放到权限列表；可重新拖动，或使用下方授权引导。", "Not dropped into the permission list. Try dragging again or use the guide below.")
        }
        screenDrag.dragEnded = { [weak self] copied in
            self?.screenDragFeedback.stringValue = copied
                ? L("应用图标已投放，请按 macOS 提示开启权限；系统可能要求重启。", "App icon dropped. Enable access as macOS asks; a restart may be required.")
                : L("系统未接受拖入时，请用下方授权引导中的设置与访达入口添加。", "If dragging is not accepted, use the guide's Settings and Finder shortcuts to add the app.")
        }
        let accessibilityState = stateLine(indicator: accessibilityIndicator, label: accessibilityStatus)
        let screenState = stateLine(indicator: screenIndicator, label: screenStatus)
        let fanState = stateLine(indicator: fanIndicator, label: fanStatusLabel)
        let summaryState = stateLine(indicator: summaryIndicator, label: summary)
        summary.font = .systemFont(ofSize: 12, weight: .semibold)
        let accessibility = SharedSettingsLayout.card(L("1 · 辅助功能", "1 · Accessibility"), views: [
            SharedSettingsLayout.hint(L("用于：窗口切换 · 必需", "Used by: Window switching · Required")),
            SharedSettingsLayout.hint(L("允许识别窗口并切换焦点。把这里的应用图标直接拖入系统辅助功能列表。",
                "Allows identifying windows and changing focus. Drag this app icon directly into the Accessibility list.")),
            accessibilityDrag, accessibilityState, accessibilityDragFeedback, accessibilityButton
        ])
        let screenRecording = SharedSettingsLayout.card(L("2 · 屏幕录制", "2 · Screen Recording"), views: [
            SharedSettingsLayout.hint(L("用于：窗口切换的缩略图 · 可选", "Used by: Window thumbnails · Optional")),
            SharedSettingsLayout.hint(L("将图标拖入屏幕录制列表。预览只在内存中，不录音、不保存；未授权仍能按标题切换。",
                "Drag the icon into Screen Recording settings. Previews stay in memory without audio or files; title-based switching works without access.")),
            screenDrag, screenState, screenDragFeedback, screenPermissionButton
        ])
        screenRecordingCard = screenRecording
        let fanSource = fanApplicationRow(appURL: appURL, appName: appName)
        let fanService = SharedSettingsLayout.card(L("3 · 风扇控制服务", "3 · Fan control service"), views: [
            SharedSettingsLayout.hint(L("用于：手动调节风扇 · 必需；读取转速无需授权", "Used by: Manual fan control · Required; reading speeds needs no approval")),
            SharedSettingsLayout.hint(L("点击图标或下方按钮，先审阅安装内容，再由 macOS 确认管理员操作。安装本身不会改变转速。",
                "Click the icon or button to review installation before macOS asks for administrator approval. Installing does not change fan speed.")),
            fanSource, fanState, fanButton
        ])
        let cardRows: [(NSView, [NSView])] = [
            (accessibility, [accessibilityDrag, accessibilityState]),
            (screenRecording, [screenDrag, screenState]),
            (fanService, [fanSource, fanState])
        ]
        for (card, rows) in cardRows {
            for row in rows { row.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -36).isActive = true }
        }
        SharedSettingsLayout.install(on: self, title: L("授权", "Permissions"),
            explanation: L("在这里集中完成各工具所需的授权。按顺序查看并逐项开启，状态会自动更新；以后新增工具需要的权限也会列在这里。",
                "Complete tool permissions in one place. Review and enable each item in order; status updates automatically. Permissions for new tools will also appear here."),
            views: [summaryState, accessibility, screenRecording, fanService,
                SharedSettingsLayout.hint(L("同一项系统权限可供相关工具共用。各工具的启用开关、黑名单和其他功能设置仍由各工具独立管理。",
                    "A system permission can serve the tools that need it. Each tool retains its own enable switch, exclusions and feature settings."))])
        updateStatus(accessibilityTrusted: false, screenRecordingTrusted: false,
            fanStatus: L("正在检查控制服务…", "Checking the control service…"), fanReady: false)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateStatus(accessibilityTrusted: Bool, screenRecordingTrusted: Bool, fanStatus: String, fanReady: Bool) {
        let count = [accessibilityTrusted, screenRecordingTrusted, fanReady].filter { $0 }.count
        summary.stringValue = String(format: L("已就绪 %d / 3 项", "%d / 3 ready"), count)
        setReadiness(count == 3, indicator: summaryIndicator, label: summary)
        accessibilityStatus.stringValue = accessibilityTrusted
            ? L("已授权 · 窗口识别与切换可用", "Granted · Window identification and switching available")
            : L("待授权 · 窗口切换需要辅助功能权限", "Not granted · Window switching requires Accessibility")
        setReadiness(accessibilityTrusted, indicator: accessibilityIndicator, label: accessibilityStatus)
        accessibilityButton.title = accessibilityTrusted
            ? L("查看辅助功能设置…", "View Accessibility settings…") : L("辅助功能授权引导…", "Accessibility permission guide…")
        screenStatus.stringValue = screenRecordingTrusted
            ? L("已授权 · 可显示窗口缩略图", "Granted · Window previews available")
            : L("待授权 · 暂以标题和图标显示窗口", "Not granted · Windows use titles and icons")
        setReadiness(screenRecordingTrusted, indicator: screenIndicator, label: screenStatus)
        screenPermissionButton.title = screenRecordingTrusted
            ? L("查看屏幕录制设置…", "View Screen Recording settings…") : L("屏幕录制授权引导…", "Screen Recording permission guide…")
        if #unavailable(macOS 14) {
            screenStatus.stringValue = L("此系统版本不支持窗口缩略图，需要 macOS 14 或更新版本。", "Window previews require macOS 14 or later.")
            screenPermissionButton.isEnabled = false
        }
        fanStatusLabel.stringValue = (fanReady ? L("已就绪 · ", "Ready · ") : L("未就绪 · ", "Not ready · ")) + fanStatus
        setReadiness(fanReady, indicator: fanIndicator, label: fanStatusLabel)
        fanButton.title = fanReady
            ? L("管理风扇控制服务…", "Manage fan control service…") : L("检查并启用风扇控制…", "Check and enable fan control…")
    }

    /// A thumbnail prompt routes here before opening the shared permission guide.
    /// Layout and scroll first so the popover has a visible, stable anchor.
    func showScreenRecordingGuide() {
        guard let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        if let screenRecordingCard { screenRecordingCard.scrollToVisible(screenRecordingCard.bounds) }
        screenPermissionButton.scrollToVisible(screenPermissionButton.bounds)
        requestScreenRecording?(screenPermissionButton)
    }

    private func stateLine(indicator: NSImageView, label: NSTextField) -> NSStackView {
        indicator.imageScaling = .scaleProportionallyDown
        indicator.widthAnchor.constraint(equalToConstant: 16).isActive = true
        indicator.heightAnchor.constraint(equalToConstant: 16).isActive = true
        label.font = .systemFont(ofSize: 11, weight: .medium)
        let line = NSStackView(views: [indicator, label])
        line.orientation = .horizontal; line.alignment = .centerY; line.spacing = 7
        return line
    }

    private func setReadiness(_ ready: Bool, indicator: NSImageView, label: NSTextField) {
        indicator.image = NSImage(systemSymbolName: ready ? "checkmark.circle.fill" : "clock.fill", accessibilityDescription: nil)
        indicator.contentTintColor = ready ? .systemGreen : .systemOrange
        label.textColor = ready ? .systemGreen : .systemOrange
    }

    private func fanApplicationRow(appURL: URL?, appName: String) -> NSView {
        let source = NSView()
        source.wantsLayer = true
        source.layer?.cornerRadius = 12
        source.layer?.borderWidth = 1
        source.layer?.borderColor = NSColor.separatorColor.cgColor
        source.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        source.heightAnchor.constraint(equalToConstant: 68).isActive = true
        let icon = NSButton(image: AppBundleDragView.applicationIcon(for: appURL), target: self, action: #selector(openFanService))
        icon.isBordered = false; icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityLabel(appName + L("，管理风扇控制授权", ", manage fan control approval"))
        icon.toolTip = L("点击管理风扇控制授权，由 macOS 确认管理员操作", "Click to manage fan control approval; macOS confirms administrator actions")
        let name = NSTextField(labelWithString: appName)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = SharedSettingsLayout.hint(L("点击图标，使用系统管理员确认", "Click the icon for administrator approval"))
        let labels = NSStackView(views: [name, detail])
        labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 5
        let shield = NSImageView(image: NSImage(systemSymbolName: "lock.shield", accessibilityDescription: L("管理员确认", "Administrator approval"))!)
        shield.contentTintColor = .secondaryLabelColor
        for view in [icon, labels, shield] {
            view.translatesAutoresizingMaskIntoConstraints = false; source.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: source.leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: source.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 54), icon.heightAnchor.constraint(equalToConstant: 54),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 13),
            labels.centerYAnchor.constraint(equalTo: source.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: shield.leadingAnchor, constant: -10),
            shield.trailingAnchor.constraint(equalTo: source.trailingAnchor, constant: -16),
            shield.centerYAnchor.constraint(equalTo: source.centerYAnchor),
            shield.widthAnchor.constraint(equalToConstant: 20), shield.heightAnchor.constraint(equalToConstant: 20),
            detail.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor)
        ])
        return source
    }

    @objc private func openAccessibility() { requestAccessibility?(accessibilityButton) }
    @objc private func openScreenRecording() { requestScreenRecording?(screenPermissionButton) }
    @objc private func openFanService() { requestFanService?() }
}
