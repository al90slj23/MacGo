import AppKit
import QuartzCore
import ToolboxCore

/// The dashboard only presents observations and emits user intent. Its host owns
/// authorization, scheduling, and every hardware operation.
@MainActor final class FanDashboardView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var modeSelected: ((FanOperatingMode) -> Void)?
    var manualPercentChanged: ((Double) -> Void)?
    var openRules: (() -> Void)?
    var openPreferences: (() -> Void)?

    private let settings: Settings
    private let compact: Bool
    private let modes = NSSegmentedControl()
    private let glyph = DashboardFanGlyphView()
    private let actualLabel = NSTextField(labelWithString: "— RPM")
    private let actualCaption = NSTextField(labelWithString: "")
    private let hardwareMode = NSTextField(labelWithString: "")
    private let fanRows = NSStackView()
    private let targetHeading = NSTextField(labelWithString: "")
    private let targetValue = NSTextField(labelWithString: "100%")
    private let percentSlider = DashboardPercentSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let apply = NSButton(title: "", target: nil, action: nil)
    private let targetHint = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let temperatureHeading = NSTextField(labelWithString: "")
    private let temperatureEmpty = NSTextField(wrappingLabelWithString: "")
    private let temperatureTable = NSTableView()
    private let temperatureScroll = NSScrollView()
    private let uptimeLabel = NSTextField(labelWithString: "")
    private let rulesButton = NSButton(title: "", target: nil, action: nil)
    private let preferencesButton = NSButton(title: "", target: nil, action: nil)
    private var fanLabels: [Int: NSTextField] = [:]
    private var fans: [FanReading] = []
    private var temperatures: [TemperatureSensorReading] = []
    private var mode: FanOperatingMode = .system
    private var canControl = false
    private var busy = false
    private var message = ""
    private var uptimeSeconds: Double?
    private var lastSuppliedManualPercent: Double?

    init(settings: Settings, compact: Bool = false) {
        self.settings = settings; self.compact = compact
        super.init(frame: .zero)
        buildLayout()
        refreshLocalization()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(fans: [FanReading], temperatures: [TemperatureSensorReading],
                mode: FanOperatingMode, manualPercent: Double, canControl: Bool,
                busy: Bool, message: String, uptimeSeconds: Double?) {
        self.fans = fans.sorted { $0.id < $1.id }
        self.mode = mode; self.canControl = canControl; self.busy = busy
        self.message = message; self.uptimeSeconds = uptimeSeconds

        // A polling observation must not undo a draft or move the knob under
        // the pointer. Sync only when the host actually supplies a new target.
        if manualPercent.isFinite, !percentSlider.isDragging,
           lastSuppliedManualPercent != manualPercent {
            percentSlider.doubleValue = min(100, max(0, manualPercent))
            lastSuppliedManualPercent = manualPercent
        }

        var seen = Set<String>()
        let valid = temperatures.filter { $0.isValid && seen.insert($0.id).inserted }
        let changedRows = valid.map(\.id) != self.temperatures.map(\.id)
        self.temperatures = valid
        if changedRows {
            let origin = temperatureScroll.contentView.bounds.origin
            temperatureTable.reloadData()
            temperatureScroll.contentView.scroll(to: origin)
            temperatureScroll.reflectScrolledClipView(temperatureScroll.contentView)
        } else if !valid.isEmpty {
            temperatureTable.reloadData(forRowIndexes: IndexSet(integersIn: 0..<valid.count),
                                        columnIndexes: IndexSet(integer: 1))
        }
        renderSnapshot()
    }

    func refreshLocalization() {
        for (index, title) in [L("系统", "System", "系統"), L("最大", "Maximum"),
                                L("手动", "Manual", "手動"), L("自定义", "Custom", "自訂")].enumerated() {
            modes.setLabel(title, forSegment: index)
        }
        modes.toolTip = L("选择风扇控制模式", "Choose a fan control mode", "選擇風扇控制模式")
        targetHeading.stringValue = L("手动目标", "Manual target", "手動目標")
        apply.title = L("应用", "Apply", "套用")
        targetHint.stringValue = L("按硬件最高转速的百分比设定，最低不低于硬件允许值。",
                                   "Percentage of hardware maximum, limited by the hardware minimum.",
                                   "依硬體最高轉速的百分比設定，最低不低於硬體允許值。")
        percentSlider.setAccessibilityLabel(L("手动目标转速百分比", "Manual target speed percentage", "手動目標轉速百分比"))
        temperatureHeading.stringValue = L("温度", "Temperatures", "溫度")
        temperatureEmpty.stringValue = L("暂无有效温度读数", "No valid temperature readings", "暫無有效溫度讀數")
        rulesButton.title = L("编辑规则…", "Edit rules…", "編輯規則…")
        preferencesButton.title = L("偏好设置…", "Preferences…", "偏好設定…")
        temperatureTable.reloadData()
        renderSnapshot()
    }

    private func buildLayout() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = DashboardDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        addSubview(scroll)

        modes.segmentCount = 4; modes.trackingMode = .selectOne
        modes.segmentDistribution = .fillEqually
        modes.target = self; modes.action = #selector(selectOperatingMode)
        modes.setContentHuggingPriority(.defaultLow, for: .horizontal)

        actualLabel.font = .monospacedDigitSystemFont(ofSize: compact ? 33 : 40, weight: .medium)
        actualCaption.font = .systemFont(ofSize: 11)
        actualCaption.textColor = .secondaryLabelColor
        hardwareMode.font = .systemFont(ofSize: 12, weight: .medium)
        hardwareMode.textColor = .secondaryLabelColor
        let readings = vertical([actualCaption, actualLabel, hardwareMode], spacing: 3)
        let summary = horizontal([glyph, readings], spacing: compact ? 16 : 22)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: compact ? 72 : 84),
            glyph.heightAnchor.constraint(equalTo: glyph.widthAnchor)
        ])

        fanRows.orientation = .vertical; fanRows.alignment = .leading; fanRows.spacing = 5
        targetHeading.font = .systemFont(ofSize: 12, weight: .semibold)
        targetValue.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let targetTitle = horizontal([targetHeading, spacer, targetValue], spacing: 8)
        percentSlider.isContinuous = false
        percentSlider.target = self; percentSlider.action = #selector(commitPercent)
        percentSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        percentSlider.previewChanged = { [weak self] in self?.renderTarget() }
        apply.bezelStyle = .rounded; apply.target = self; apply.action = #selector(commitPercent)
        let targetControls = horizontal([percentSlider, apply], spacing: 10)
        targetHint.font = .systemFont(ofSize: 10); targetHint.textColor = .secondaryLabelColor
        let target = vertical([targetTitle, targetControls, targetHint], spacing: 7)
        targetTitle.widthAnchor.constraint(equalTo: target.widthAnchor).isActive = true
        targetControls.widthAnchor.constraint(equalTo: target.widthAnchor).isActive = true
        targetHint.widthAnchor.constraint(equalTo: target.widthAnchor).isActive = true

        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor
        temperatureHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        temperatureEmpty.font = .systemFont(ofSize: 11)
        temperatureEmpty.textColor = .secondaryLabelColor
        configureTemperatureTable()
        let temperatureSection = vertical([temperatureHeading, temperatureEmpty, temperatureScroll], spacing: 8)
        temperatureEmpty.widthAnchor.constraint(equalTo: temperatureSection.widthAnchor).isActive = true
        temperatureScroll.widthAnchor.constraint(equalTo: temperatureSection.widthAnchor).isActive = true
        temperatureScroll.heightAnchor.constraint(equalToConstant: compact ? 210 : 190).isActive = true

        uptimeLabel.font = .systemFont(ofSize: 11); uptimeLabel.textColor = .secondaryLabelColor
        for button in [rulesButton, preferencesButton] { button.bezelStyle = .rounded; button.target = self }
        rulesButton.action = #selector(editRules)
        preferencesButton.action = #selector(showPreferences)
        let footerButtons = horizontal([rulesButton, preferencesButton], spacing: 8)
        let footer = vertical([uptimeLabel, footerButtons], spacing: 9)

        let separator = NSBox(); separator.boxType = .separator
        let content = vertical([modes, summary, fanRows, target, messageLabel, separator, temperatureSection, footer], spacing: compact ? 14 : 18)
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        let inset: CGFloat = compact ? 16 : 24
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -inset)
        ])
        for view in [modes, fanRows, target, messageLabel, separator, temperatureSection, footer] {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
    }

    private func configureTemperatureTable() {
        temperatureTable.headerView = nil; temperatureTable.rowHeight = 25
        temperatureTable.backgroundColor = .clear
        temperatureTable.intercellSpacing = NSSize(width: 8, height: 2)
        temperatureTable.selectionHighlightStyle = .none
        temperatureTable.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        name.width = compact ? 218 : 410; name.minWidth = 100
        let value = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("temperature"))
        value.width = 78; value.minWidth = 78; value.maxWidth = 78
        temperatureTable.addTableColumn(name); temperatureTable.addTableColumn(value)
        temperatureTable.delegate = self; temperatureTable.dataSource = self
        temperatureScroll.documentView = temperatureTable
        temperatureScroll.hasVerticalScroller = true
        temperatureScroll.autohidesScrollers = true
        temperatureScroll.drawsBackground = false; temperatureScroll.borderType = .noBorder
    }

    private func renderSnapshot() {
        modes.selectedSegment = FanOperatingMode.allCases.firstIndex(of: mode) ?? 0
        // A System request can queue behind a short in-flight command. The
        // session serializes it and always reevaluates the latest user intent.
        modes.isEnabled = canControl
        apply.isEnabled = canControl && !busy && mode == .manual
        percentSlider.isEnabled = canControl && !busy && mode == .manual
        if let first = fans.first {
            actualCaption.stringValue = fans.count > 1
                ? String(format: L("风扇 %d · 实际转速", "Fan %d · Actual speed", "風扇 %d · 實際轉速"), first.id + 1)
                : L("实际转速", "Actual speed", "實際轉速")
            actualLabel.stringValue = "\(rpmText(first.actualRPM)) RPM"
            let modes = Set(fans.compactMap(\.mode))
            hardwareMode.stringValue = modes == [0] && fans.allSatisfy({ $0.mode != nil })
                ? L("系统自动", "System automatic", "系統自動")
                : modes == [1] && fans.allSatisfy({ $0.mode != nil })
                    ? L("手动控制中", "Manual control active", "手動控制中")
                    : L("混合或未知模式", "Mixed or unknown mode", "混合或未知模式")
            let ratio = first.maximumRPM > 0 && first.actualRPM.isFinite
                ? first.actualRPM / first.maximumRPM : 0
            glyph.setMotion(enabled: settings.animateFanIcon, ratio: ratio)
        } else {
            actualCaption.stringValue = L("实际转速", "Actual speed", "實際轉速")
            actualLabel.stringValue = "— RPM"
            hardwareMode.stringValue = L("等待风扇读数", "Waiting for fan readings", "等待風扇讀數")
            glyph.setMotion(enabled: false, ratio: 0)
        }
        renderFanRows()
        renderTarget()
        messageLabel.stringValue = message
        messageLabel.isHidden = message.isEmpty
        temperatureEmpty.isHidden = !temperatures.isEmpty
        temperatureScroll.isHidden = temperatures.isEmpty
        uptimeLabel.stringValue = formattedUptime()
    }

    private func renderTarget() {
        targetValue.stringValue = "\(Int(percentSlider.doubleValue.rounded()))%"
        percentSlider.setAccessibilityValue(targetValue.stringValue)
    }

    private func renderFanRows() {
        if Set(fanLabels.keys) != Set(fans.map(\.id)) {
            for view in fanRows.arrangedSubviews { fanRows.removeArrangedSubview(view); view.removeFromSuperview() }
            fanLabels.removeAll()
            for fan in fans where fanLabels[fan.id] == nil {
                let label = NSTextField(wrappingLabelWithString: "")
                label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                label.textColor = .secondaryLabelColor
                fanRows.addArrangedSubview(label)
                label.widthAnchor.constraint(equalTo: fanRows.widthAnchor).isActive = true
                fanLabels[fan.id] = label
            }
        }
        for fan in fans {
            let actual = rpmText(fan.actualRPM)
            let minimum = rpmText(fan.minimumRPM), maximum = rpmText(fan.maximumRPM)
            fanLabels[fan.id]?.stringValue = String(format: L("风扇 %d · %@ RPM · 范围 %@–%@", "Fan %d · %@ RPM · Range %@–%@", "風扇 %d · %@ RPM · 範圍 %@–%@"), fan.id + 1, actual, minimum, maximum)
        }
        fanRows.isHidden = fans.isEmpty
    }

    private func formattedUptime() -> String {
        guard let uptimeSeconds, uptimeSeconds.isFinite, uptimeSeconds >= 0,
              uptimeSeconds < Double(Int.max) else {
            return L("开机时间：—", "Uptime: —", "開機時間：—")
        }
        let minutes = Int(uptimeSeconds / 60)
        return String(format: L("开机时间：%d 小时 %d 分钟", "Uptime: %d h %d min", "開機時間：%d 小時 %d 分鐘"), minutes / 60, minutes % 60)
    }

    private func rpmText(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < Double(Int.max) else { return "—" }
        return String(Int(value.rounded()))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { temperatures.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard temperatures.indices.contains(row), let tableColumn else { return nil }
        let reading = temperatures[row]
        let identifier = tableColumn.identifier
        let label = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField) ?? NSTextField(labelWithString: "")
        label.identifier = identifier
        label.font = identifier.rawValue == "temperature"
            ? .monospacedDigitSystemFont(ofSize: 12, weight: .medium) : .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        if identifier.rawValue == "temperature" {
            label.alignment = .right
            label.stringValue = String(format: "%.1f%@", settings.temperatureUnit.displayValue(forCelsius: reading.celsius), settings.temperatureUnit.symbol)
        } else {
            label.alignment = .left
            label.stringValue = reading.name
        }
        label.toolTip = "\(reading.name) · \(reading.id)"
        return label
    }

    private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = .vertical; result.alignment = .leading; result.spacing = spacing
        return result
    }

    private func horizontal(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = .horizontal; result.alignment = .centerY; result.spacing = spacing
        return result
    }

    @objc private func selectOperatingMode() {
        let all = FanOperatingMode.allCases
        guard all.indices.contains(modes.selectedSegment) else { return }
        modeSelected?(all[modes.selectedSegment])
    }

    @objc private func commitPercent() {
        renderTarget()
        manualPercentChanged?(percentSlider.doubleValue)
    }
    @objc private func editRules() { openRules?() }
    @objc private func showPreferences() { openPreferences?() }
}

private final class DashboardDocumentView: NSView { override var isFlipped: Bool { true } }

/// NSSlider's noncontinuous action commits once after tracking. While tracking,
/// polling updates may refresh every other observation without resetting it.
@MainActor private final class DashboardPercentSlider: NSSlider {
    private(set) var isDragging = false
    var previewChanged: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        super.mouseDown(with: event)
        isDragging = false
        previewChanged?()
    }
}

/// Core Animation supplies the motion; no background animation timer is kept.
@MainActor private final class DashboardFanGlyphView: NSView {
    private let blades = CALayer()
    private var motionEnabled = false
    private var speedRatio = 0.0
    private var animationStep: Int?
    private var observations: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        blades.contentsGravity = .resizeAspect
        layer?.addSublayer(blades)
        refreshImage()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { for observer in observations { NotificationCenter.default.removeObserver(observer) } }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        blades.bounds = CGRect(origin: .zero, size: bounds.size)
        blades.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshImage()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observations { NotificationCenter.default.removeObserver(observer) }
        observations.removeAll()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshMotion() }
                })
            }
        }
        refreshMotion()
    }

    func setMotion(enabled: Bool, ratio: Double) {
        motionEnabled = enabled
        speedRatio = ratio.isFinite ? min(1, max(0, ratio)) : 0
        refreshMotion()
    }

    private func refreshImage() {
        let symbol = NSImage(systemSymbolName: "fanblades.fill", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "fanblades", accessibilityDescription: nil)
        let configuration = NSImage.SymbolConfiguration(pointSize: 96, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemBlue]))
        let image = symbol?.withSymbolConfiguration(configuration)
        blades.contentsScale = window?.backingScaleFactor ?? 2
        blades.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func refreshMotion() {
        guard motionEnabled, speedRatio > 0,
              let window, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            blades.removeAnimation(forKey: "fanRotation"); animationStep = nil
            return
        }
        let step = Int((speedRatio * 10).rounded())
        guard animationStep != step else { return }
        animationStep = step
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0; animation.toValue = Double.pi * 2
        animation.duration = 1.8 - 1.4 * Double(step) / 10
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = true
        blades.add(animation, forKey: "fanRotation")
    }
}
