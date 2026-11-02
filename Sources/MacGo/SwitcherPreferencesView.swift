import AppKit

@MainActor final class SwitcherPreferencesView: NSView {
    let accessibilityButton = NSButton(title: L("辅助功能授权…", "Accessibility…"), target: nil, action: nil)
    let screenPermissionButton = NSButton(title: L("缩略图授权…", "Thumbnail permission…"), target: nil, action: nil)
    let recordShortcutButton = ShortcutRecorderButton()
    private let settings: Settings
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let enabled = NSButton(checkboxWithTitle: L("启用窗口切换", "Enable window switching"), target: nil, action: nil)
    private let windowless = NSButton(checkboxWithTitle: L("显示底部无窗口应用栏", "Show apps without windows in a bottom bar", "顯示底部無視窗應用程式列"), target: nil, action: nil)
    private let thumbnails = NSButton(checkboxWithTitle: L("显示窗口缩略图", "Show window thumbnails"), target: nil, action: nil)
    private let shortcut = NSPopUpButton()
    private let size = NSPopUpButton()
    private let displays = NSPopUpButton()
    private let selection = NSPopUpButton()
    private let contentMode = NSPopUpButton()
    var settingsChanged: (() -> Void)?
    var requestAccessibility: ((NSButton) -> Void)?
    var requestScreenRecording: ((NSButton) -> Void)?
    var preview: (() -> Void)?
    var recordingChanged: ((Bool) -> Void)?
    var shortcutSelected: ((SwitchShortcut) -> Void)?

    init(settings: Settings) {
        self.settings = settings
        super.init(frame: .zero)
        build()
        refreshControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        let document = PreferencesDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let title = NSTextField(labelWithString: L("窗口切换", "Window switching"))
        title.font = .systemFont(ofSize: 25, weight: .bold)
        let explanation = hint(L("每个独立窗口都能单独选择。按住修饰键选择，松开进入窗口；鼠标移到卡片上即可选中，点击立即切换。Shift 反向，Esc 取消。",
                                 "Choose individual windows. Hold the modifier to browse and release to switch. Hover a card to select it or click to switch immediately. Shift reverses and Esc cancels.",
                                 "每個獨立視窗都能單獨選擇。按住修飾鍵選擇，放開進入視窗；滑鼠移到卡片上即可選取，點擊立即切換。Shift 反向，Esc 取消。"))
        enabled.target = self; enabled.action = #selector(changeEnabled)
        windowless.target = self; windowless.action = #selector(changeWindowless)
        shortcut.addItems(withTitles: SwitchShortcut.allCases.map(\.title))
        shortcut.target = self; shortcut.action = #selector(changeShortcut)
        recordShortcutButton.onShortcutRecorded = { [weak self] value in
            guard let self else { return }
            self.settings.customShortcut = value
            self.settings.shortcut = .custom
            self.shortcut.removeAllItems()
            self.shortcut.addItems(withTitles: SwitchShortcut.allCases.map(\.title))
            self.refreshControls()
            self.settingsChanged?()
        }
        recordShortcutButton.onRecordingChanged = { [weak self] active in
            self?.recordingChanged?(active)
            if !active { self?.refreshControls() }
        }
        let shortcuts = horizontal([shortcut, recordShortcutButton], spacing: 10)
        thumbnails.target = self; thumbnails.action = #selector(changeThumbnails)
        accessibilityButton.target = self; accessibilityButton.action = #selector(authorizeAccessibility)
        screenPermissionButton.target = self; screenPermissionButton.action = #selector(authorizeScreenRecording)
        let previewButton = NSButton(title: L("查看窗口列表", "Preview windows"), target: self, action: #selector(showPreview))
        let actions = horizontal([accessibilityButton, screenPermissionButton, previewButton], spacing: 10)
        statusLabel.font = .systemFont(ofSize: 12); statusLabel.textColor = .secondaryLabelColor
        let switchingGroup = group(L("选择与快捷键", "Selection and shortcut"), views: [
            enabled, row(L("切换快捷键", "Shortcut"), shortcuts), thumbnails, actions, statusLabel
        ])
        size.addItems(withTitles: stride(from: 30, through: 100, by: 10).map { "\($0)%" })
        size.target = self; size.action = #selector(changeSize)
        displays.addItems(withTitles: SwitcherScreenMode.allCases.map(\.title))
        displays.target = self; displays.action = #selector(changeDisplays)
        selection.addItems(withTitles: SwitcherInitialSelection.allCases.map(\.title))
        selection.target = self; selection.action = #selector(changeSelection)
        contentMode.addItems(withTitles: ThumbnailContentMode.allCases.map(\.title))
        contentMode.target = self; contentMode.action = #selector(changeContentMode)
        let appearanceGroup = group(L("缩略图与多屏", "Thumbnails and displays"), views: [
            row(L("面板大小", "Panel size"), size),
            row(L("桌面显示样式", "Display layout"), displays),
            row(L("默认选中", "Initial selection"), selection),
            row(L("缩略图显示模式", "Thumbnail layout"), contentMode),
            hint(L("面板大小按屏幕可用区域的比例设置。分屏幕显示会把窗口放在它所属屏幕的选择面板中。",
                   "Panel size is relative to each display's usable area. Per-display layout groups windows on their own displays.")),
            hint(L("卡片右上角的 × 用于正常退出整个对应应用，由该应用处理未保存内容提示。",
                   "The × at the top right of a card requests a normal quit of the entire app. That app handles any unsaved-work prompts.",
                   "卡片右上角的 × 用於正常結束整個對應應用程式，由該應用程式處理未儲存內容提示。"))
        ])
        let windowlessGroup = group(L("无窗口应用栏", "Apps without windows", "無視窗應用程式列"), views: [
            windowless,
            hint(L("默认开启。在面板底部单独显示，没有标准窗口的应用可用鼠标选择并点击打开；Cmd / Option + Tab 不会切换到这一栏。条目较多时可独立横向滚动。",
                   "On by default. Apps without standard windows appear in a separate bottom bar. Use the pointer to select an app and click to open it; Cmd / Option + Tab skips this bar. Scroll it horizontally when more apps are available.",
                   "預設開啟。在面板底部單獨顯示，沒有標準視窗的應用程式可用滑鼠選取並點擊開啟；Cmd / Option + Tab 不會切換到這一列。項目較多時可獨立橫向捲動。"))
        ])
        let privacy = hint(L("辅助功能用于识别和切换窗口；屏幕录制仅用于缩略图。画面只保存在内存，不录音、不保存文件。未授权录屏仍可按图标和标题切换。",
                             "Accessibility identifies and switches windows. Screen Recording is optional for thumbnails kept in memory, with no audio or saved files. Icons and titles work without it."))
        let stack = NSStackView(views: [title, explanation, switchingGroup, appearanceGroup, windowlessGroup, privacy])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            switchingGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            appearanceGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            windowlessGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            privacy.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    func refreshControls() {
        enabled.state = settings.enabled ? .on : .off
        thumbnails.state = settings.showThumbnails ? .on : .off
        windowless.state = settings.showWindowlessApps ? .on : .off
        shortcut.selectItem(at: SwitchShortcut.allCases.firstIndex(of: settings.shortcut) ?? 0)
        recordShortcutButton.recordedShortcut = settings.customShortcut
        size.selectItem(withTitle: "\(settings.panelSizePercent)%")
        displays.selectItem(at: SwitcherScreenMode.allCases.firstIndex(of: settings.screenMode) ?? 0)
        selection.selectItem(at: SwitcherInitialSelection.allCases.firstIndex(of: settings.initialSelection) ?? 0)
        contentMode.selectItem(at: ThumbnailContentMode.allCases.firstIndex(of: settings.thumbnailContentMode) ?? 0)
        if #unavailable(macOS 14) {
            thumbnails.isEnabled = false
            thumbnails.title = L("窗口缩略图需要 macOS 14 或更新版本", "Thumbnails require macOS 14 or later")
        }
    }

    func updateStatus(_ text: String, accessibilityTrusted: Bool, screenRecordingTrusted: Bool) {
        statusLabel.stringValue = text
        accessibilityButton.isHidden = accessibilityTrusted
        screenPermissionButton.isHidden = !settings.showThumbnails || screenRecordingTrusted
        if #unavailable(macOS 14) { screenPermissionButton.isHidden = true }
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        let stack = horizontal([label, control], spacing: 14)
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }

    private func horizontal(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = .horizontal; result.alignment = .centerY; result.spacing = spacing
        return result
    }

    private func hint(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11); field.textColor = .secondaryLabelColor
        return field
    }

    private func group(_ title: String, views: [NSView]) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        let stack = NSStackView(views: [heading] + views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 17),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -17)
        ])
        for view in views { view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true }
        return container
    }

    @objc private func changeEnabled() { settings.enabled = enabled.state == .on; settingsChanged?() }
    @objc private func changeWindowless() { settings.showWindowlessApps = windowless.state == .on; settingsChanged?() }
    @objc private func changeThumbnails() { settings.showThumbnails = thumbnails.state == .on; settingsChanged?() }
    @objc private func changeShortcut() {
        let chosen = SwitchShortcut.allCases[shortcut.indexOfSelectedItem]
        if chosen == .custom, settings.customShortcut == nil {
            recordShortcutButton.performClick(nil)
            return
        }
        if let shortcutSelected { shortcutSelected(chosen) }
        else { settings.shortcut = chosen; settingsChanged?() }
    }
    @objc private func changeSize() { settings.panelSizePercent = 30 + 10 * size.indexOfSelectedItem; settingsChanged?() }
    @objc private func changeDisplays() { settings.screenMode = SwitcherScreenMode.allCases[displays.indexOfSelectedItem]; settingsChanged?() }
    @objc private func changeSelection() { settings.initialSelection = SwitcherInitialSelection.allCases[selection.indexOfSelectedItem]; settingsChanged?() }
    @objc private func changeContentMode() { settings.thumbnailContentMode = ThumbnailContentMode.allCases[contentMode.indexOfSelectedItem]; settingsChanged?() }
    @objc private func authorizeAccessibility() { requestAccessibility?(accessibilityButton) }
    @objc private func authorizeScreenRecording() { requestScreenRecording?(screenPermissionButton) }
    @objc private func showPreview() { preview?() }
}

private final class PreferencesDocumentView: NSView { override var isFlipped: Bool { true } }
