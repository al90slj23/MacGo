import AppKit
import ToolboxCore

@MainActor final class FanPreferencesView: NSView, NSTextFieldDelegate {
    private let settings: Settings
    private let animate = NSButton(checkboxWithTitle: L("动态显示风扇图标", "Animate the fan icon"), target: nil, action: nil)
    private let menuTemperature = NSButton(checkboxWithTitle: L("在菜单栏显示 CPU 温度", "Show CPU temperature in the menu bar"), target: nil, action: nil)
    private let unit = NSPopUpButton()
    private let period = NSPopUpButton()
    private let delay = NSTextField(string: "")
    private let start = NSDatePicker()
    private let end = NSDatePicker()
    private let validation = SharedSettingsLayout.hint("")
    var changed: (() -> Void)?

    init(settings: Settings) {
        self.settings = settings
        super.init(frame: .zero)
        animate.target = self; animate.action = #selector(changeAnimation)
        menuTemperature.target = self; menuTemperature.action = #selector(changeMenuTemperature)
        unit.addItems(withTitles: [L("摄氏度 °C", "Celsius °C"), L("华氏度 °F", "Fahrenheit °F")])
        unit.target = self; unit.action = #selector(changeUnit)
        period.addItems(withTitles: [L("始终", "Always"), L("开机后延迟", "After a boot delay"), L("每天指定时段", "Daily schedule")])
        period.target = self; period.action = #selector(changePeriod)
        delay.delegate = self
        delay.target = self; delay.action = #selector(changeDelay)
        delay.alignment = .right
        delay.widthAnchor.constraint(equalToConstant: 75).isActive = true
        delay.setAccessibilityLabel(L("开机后延迟分钟数", "Boot delay in minutes"))
        for picker in [start, end] {
            picker.datePickerElements = .hourMinute
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerMode = .single
            picker.timeZone = .current
            picker.target = self; picker.action = #selector(changeSchedule)
            picker.widthAnchor.constraint(equalToConstant: 115).isActive = true
        }
        start.setAccessibilityLabel(L("每天开始时间", "Daily start time"))
        end.setAccessibilityLabel(L("每天结束时间", "Daily end time"))
        let delayRow = horizontal([delay, NSTextField(labelWithString: L("分钟（0–10080）", "minutes (0–10080)"))])
        let schedule = horizontal([start, NSTextField(labelWithString: L("至", "to")), end])
        let display = SharedSettingsLayout.card(L("显示", "Display"), views: [
            animate, menuTemperature, row(L("温度单位", "Temperature unit"), unit),
            SharedSettingsLayout.hint(L("CPU 温度只显示实际可读取的传感器数据；无读数时显示不可用。菜单栏整体显隐请到“通用 → 基础设置”。",
                "CPU temperature uses real sensor readings and shows unavailable when none can be read. Menu bar visibility is under General → Preferences."))
        ])
        let control = SharedSettingsLayout.card(L("控制时段", "Control period"), views: [
            row(L("执行手动控制", "Apply manual control"), period),
            row(L("开机后等待", "Delay after boot"), delayRow),
            row(L("每天执行时间", "Daily hours"), schedule), validation,
            SharedSettingsLayout.hint(L("时段适用于最大、手动和自定义模式。时段外恢复本工具持有的系统自动控制；跨午夜的时段也可设置。",
                "The period applies to Maximum, Manual and Custom modes. Outside it, Toolbox releases its owned control to the system. A schedule can cross midnight.")),
            SharedSettingsLayout.hint(L("仅在 Mac Go 运行且当前登录会话有效时执行。开机延迟从本次系统启动计时，不提供登录前控制；睡眠、退出或断开服务时恢复本工具持有的控制。",
                "Control runs only while Mac Go is open in the active login session. Boot delay starts at system startup and does not enable pre-login control. Sleep, exit or service disconnection releases control owned by Mac Go."))
        ])
        SharedSettingsLayout.install(on: self, title: L("风扇控制 · 偏好设置", "Fan control · Preferences"),
            explanation: L("只影响风扇工具。语言和登录启动在通用设置中统一管理。", "These preferences affect only the fan tool. Language and login startup stay in General settings."),
            views: [display, control])
        refreshControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refreshControls() {
        animate.state = settings.animateFanIcon ? .on : .off
        menuTemperature.state = settings.showCPUTemperatureInMenuBar ? .on : .off
        unit.selectItem(at: FanTemperatureUnit.allCases.firstIndex(of: settings.temperatureUnit) ?? 0)
        period.selectItem(at: FanControlPeriod.allCases.firstIndex(of: settings.controlPeriod) ?? 0)
        delay.stringValue = String(settings.bootDelayMinutes)
        start.dateValue = date(forMinute: settings.scheduleStartMinute)
        end.dateValue = date(forMinute: settings.scheduleEndMinute)
        updatePeriodControls()
    }

    private func updatePeriodControls() {
        delay.isEnabled = settings.controlPeriod == .afterBootDelay
        start.isEnabled = settings.controlPeriod == .dailySchedule
        end.isEnabled = settings.controlPeriod == .dailySchedule
        if settings.controlPeriod == .dailySchedule, settings.scheduleStartMinute == settings.scheduleEndMinute {
            validation.stringValue = L("开始和结束相同：此时段为空，不会执行手动控制。", "Start and end are equal: this empty schedule does not apply manual control.")
            validation.textColor = .systemOrange
        } else if settings.controlPeriod == .afterBootDelay,
                  Int(delay.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)).map({ (0...10080).contains($0) }) != true {
            validation.stringValue = L("延迟未保存：请输入 0–10080 的整数分钟，当前仍使用上次有效值。", "Delay not saved: enter a whole number from 0 to 10080 minutes. The last valid value remains active.")
            validation.textColor = .systemRed
        } else { validation.stringValue = "" }
        validation.isHidden = validation.stringValue.isEmpty
    }

    private func row(_ title: String, _ view: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 155).isActive = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return horizontal([label, view], spacing: 12)
    }
    private func horizontal(_ views: [NSView], spacing: CGFloat = 9) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = spacing
        return stack
    }
    private func date(forMinute value: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2024, month: 1, day: 15, hour: value / 60, minute: value % 60)) ?? Date()
    }
    private func minute(of date: Date) -> Int {
        let calendar = Calendar.current
        return calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }

    @objc private func changeAnimation() { settings.animateFanIcon = animate.state == .on; changed?() }
    @objc private func changeMenuTemperature() { settings.showCPUTemperatureInMenuBar = menuTemperature.state == .on; changed?() }
    @objc private func changeUnit() {
        guard FanTemperatureUnit.allCases.indices.contains(unit.indexOfSelectedItem) else { return }
        settings.temperatureUnit = FanTemperatureUnit.allCases[unit.indexOfSelectedItem]; changed?()
    }
    @objc private func changePeriod() {
        guard FanControlPeriod.allCases.indices.contains(period.indexOfSelectedItem) else { return }
        settings.controlPeriod = FanControlPeriod.allCases[period.indexOfSelectedItem]
        updatePeriodControls(); changed?()
    }
    @objc private func changeDelay() {
        let text = delay.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(text), (0...10080).contains(value) else {
            validation.stringValue = L("延迟未保存：请输入 0–10080 的整数分钟，当前仍使用上次有效值。", "Delay not saved: enter a whole number from 0 to 10080 minutes. The last valid value remains active.")
            validation.textColor = .systemRed; validation.isHidden = false; return
        }
        let differs = settings.bootDelayMinutes != value
        settings.bootDelayMinutes = value
        delay.stringValue = String(value)
        updatePeriodControls(); if differs { changed?() }
    }
    func controlTextDidEndEditing(_ obj: Notification) { if obj.object as? NSTextField === delay { changeDelay() } }
    @objc private func changeSchedule() {
        settings.scheduleStartMinute = minute(of: start.dateValue)
        settings.scheduleEndMinute = minute(of: end.dateValue)
        updatePeriodControls(); changed?()
    }
}
