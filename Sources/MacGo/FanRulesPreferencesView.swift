import AppKit
import ToolboxCore

@MainActor final class FanRulesPreferencesView: NSView {
    private let settings: Settings
    private let list = NSStackView()
    private let availability = SharedSettingsLayout.hint("")
    private let modeStatus = SharedSettingsLayout.hint("")
    private let empty = SharedSettingsLayout.hint(L("还没有规则。添加规则后，选择“自定义”模式才会执行。", "No rules yet. Add a rule, then select Custom mode to use it."))
    private var rows: [UUID: FanRuleEditorView] = [:]
    private var sensors: [TemperatureSensorReading] = []
    private var fans: [FanReading] = []
    var changed: (() -> Void)?

    init(settings: Settings) {
        self.settings = settings
        super.init(frame: .zero)
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 15
        let add = NSButton(title: L("添加规则", "Add rule"), target: self, action: #selector(addRule))
        let actions = NSStackView(views: [add, NSView()])
        actions.orientation = .horizontal; actions.spacing = 10
        SharedSettingsLayout.install(on: self, title: L("风扇控制 · 自定义规则", "Fan control · Custom rules"),
            explanation: L("按真实温度传感器设定条件。规则保存后，仅在选择自定义模式、当前会话和控制时段允许且服务可用时执行。",
                "Set conditions using real temperature sensors. Saved rules run only in Custom mode, during the permitted session and control period, with an available service."),
            views: [modeStatus, availability, actions, list,
                SharedSettingsLayout.hint(L("百分比按风扇最高转速计算，并保留硬件允许的最低转速；0% 不代表停转。同一风扇命中多条规则时取较高转速，条件解除或传感器失效时恢复本工具持有的自动控制。",
                    "Percentages use maximum RPM while respecting the hardware minimum; 0% does not stop the fan. Matching rules use the higher speed for each fan. Cleared conditions or unavailable sensors release control owned by Mac Go."))])
        synchronizeRows()
        update(sensors: [], fans: [])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(sensors: [TemperatureSensorReading], fans: [FanReading]) {
        self.sensors = Array(Dictionary(grouping: sensors.filter(\.isValid), by: \.id).values.compactMap(\.first))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.fans = Array(Dictionary(grouping: fans, by: \.id).values.compactMap(\.first)).sorted { $0.id < $1.id }
        availability.stringValue = String(format: L("当前可用：%d 个温度传感器 · %d 个风扇", "Available now: %d temperature sensors · %d fans"), self.sensors.count, self.fans.count)
        modeStatus.stringValue = settings.selectedFanMode == .custom
            ? L("当前为自定义模式；实际执行状态见“转速控制”。", "Custom mode is selected. See Fan speeds for actual control status.")
            : L("当前未选择自定义模式；编辑规则不会切换模式或立即调速。", "Custom mode is not selected. Editing rules does not change mode or immediately adjust fans.")
        synchronizeRows()
    }

    private func synchronizeRows() {
        let rules = settings.fanRules
        let ids = Set(rules.map(\.id))
        for id in Array(rows.keys) where !ids.contains(id) {
            if let row = rows.removeValue(forKey: id) { list.removeArrangedSubview(row); row.removeFromSuperview() }
        }
        empty.removeFromSuperview()
        if rules.isEmpty {
            list.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            return
        }
        var handled = Set<UUID>()
        for (index, rule) in rules.enumerated() where handled.insert(rule.id).inserted {
            let row: FanRuleEditorView
            if let existing = rows[rule.id] { row = existing }
            else {
                row = FanRuleEditorView(rule: rule, unit: settings.temperatureUnit)
                row.edited = { [weak self] updated in
                    guard let self else { return }
                    var rules = self.settings.fanRules
                    guard let index = rules.firstIndex(where: { $0.id == updated.id }) else { return }
                    rules[index] = updated; self.settings.fanRules = rules
                    self.changed?()
                }
                row.deleted = { [weak self] in self?.removeRule(rule.id) }
                rows[rule.id] = row
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            row.update(rule: rule, index: index + 1, unit: settings.temperatureUnit, sensors: sensors, fans: fans)
        }
    }

    @objc private func addRule() {
        var rules = settings.fanRules
        rules.append(FanAutomationRule(thresholdCelsius: 50, percent: 100))
        settings.fanRules = rules
        synchronizeRows(); changed?()
        window?.contentView?.layoutSubtreeIfNeeded()
        if let id = rules.last?.id, let row = rows[id] { row.scrollToVisible(row.bounds) }
    }

    private func removeRule(_ id: UUID) {
        settings.fanRules = settings.fanRules.filter { $0.id != id }
        synchronizeRows(); changed?()
    }
}

@MainActor private final class FanRuleEditorView: NSView, NSTextFieldDelegate {
    private var rule: FanAutomationRule
    private var unit: FanTemperatureUnit
    private let enabled = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let sensor = NSPopUpButton()
    private let comparison = NSPopUpButton()
    private let threshold = NSTextField(string: "")
    private let unitLabel = NSTextField(labelWithString: "")
    private let fan = NSPopUpButton()
    private let percent = NSTextField(string: "")
    private let validation = SharedSettingsLayout.hint("")
    private let missing = SharedSettingsLayout.hint("")
    private var displayedThreshold = ""
    private var displayedPercent = ""
    private var sensorChoices: [String] = []
    private var fanChoices: [Int] = []
    private var draftSensorID: String?
    private var draftFanID: Int?
    var edited: ((FanAutomationRule) -> Void)?
    var deleted: (() -> Void)?

    init(rule: FanAutomationRule, unit: FanTemperatureUnit) {
        self.rule = rule; self.unit = unit
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
        enabled.target = self; enabled.action = #selector(toggleEnabled)
        let remove = NSButton(title: L("删除规则", "Delete rule"), target: self, action: #selector(deleteRule))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = horizontal([enabled, spacer, remove])
        sensor.target = self; sensor.action = #selector(commit)
        comparison.addItems(withTitles: [L("高于 >", "Above >"), L("低于 <", "Below <")])
        comparison.target = self; comparison.action = #selector(commit)
        fan.target = self; fan.action = #selector(commit)
        for field in [threshold, percent] {
            field.delegate = self; field.target = self; field.action = #selector(commit)
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        }
        threshold.setAccessibilityLabel(L("规则温度阈值", "Rule temperature threshold"))
        percent.setAccessibilityLabel(L("规则风扇转速百分比", "Rule fan speed percentage"))
        sensor.setAccessibilityLabel(L("规则温度传感器", "Rule temperature sensor"))
        comparison.setAccessibilityLabel(L("规则温度比较条件", "Rule temperature comparison"))
        fan.setAccessibilityLabel(L("规则控制的风扇", "Fan controlled by the rule"))
        sensor.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sensor.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        fan.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        let when = horizontal([NSTextField(labelWithString: L("当", "When")), sensor, comparison, threshold, unitLabel])
        let action = horizontal([NSTextField(labelWithString: L("将", "Set")), fan,
            NSTextField(labelWithString: L("设为", "to")), percent, NSTextField(labelWithString: "%")])
        validation.textColor = .systemRed
        missing.textColor = .systemOrange
        let stack = NSStackView(views: [header, when, action, validation, missing])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 15),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -15),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            when.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            action.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            validation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            missing.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        refreshValues()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(rule: FanAutomationRule, index: Int, unit: FanTemperatureUnit,
                sensors: [TemperatureSensorReading], fans: [FanReading]) {
        enabled.title = String(format: L("启用规则 %d", "Enable rule %d"), index)
        if self.rule != rule || self.unit != unit {
            self.rule = rule; self.unit = unit; refreshValues()
        }
        // Keep numeric drafts and keyboard focus during periodic sensor polling.
        // Menus only change when the actual choices change.
        let choices = sensors.map { $0.id + "|" + $0.name } + ["selected:" + (draftSensorID ?? "")]
        if choices != sensorChoices || sensor.numberOfItems == 0 {
            sensorChoices = choices; sensor.removeAllItems()
            sensor.addItem(withTitle: L("任意温度传感器", "Any temperature sensor"))
            for reading in sensors {
                sensor.addItem(withTitle: reading.name + " · " + reading.id)
                sensor.lastItem?.representedObject = reading.id
            }
        }
        let fanIDs = fans.map(\.id)
        let fanChoiceSignature = fanIDs + [draftFanID ?? -1]
        if fanChoiceSignature != fanChoices || fan.numberOfItems == 0 {
            fanChoices = fanChoiceSignature; fan.removeAllItems()
            fan.addItem(withTitle: L("全部风扇", "All fans")); fan.lastItem?.tag = -1
            for reading in fans {
                fan.addItem(withTitle: String(format: L("风扇 %d", "Fan %d"), reading.id + 1))
                fan.lastItem?.tag = reading.id
            }
        }
        if let id = draftSensorID {
            if let item = sensor.itemArray.first(where: { $0.representedObject as? String == id }) { sensor.select(item) }
            else {
                sensor.addItem(withTitle: String(format: L("不可用传感器 · %@", "Unavailable sensor · %@"), id))
                sensor.lastItem?.representedObject = id; sensor.lastItem?.isEnabled = false
                sensor.select(sensor.lastItem)
            }
        } else { sensor.selectItem(at: 0) }
        if let id = draftFanID {
            if !fan.selectItem(withTag: id) {
                fan.addItem(withTitle: String(format: L("不可用风扇 · %d", "Unavailable fan · %d"), id + 1))
                fan.lastItem?.tag = id; fan.lastItem?.isEnabled = false
                fan.select(fan.lastItem)
            }
        } else { fan.selectItem(withTag: -1) }
        let sensorMissing = draftSensorID.map { id in !sensors.contains(where: { $0.id == id }) } ?? sensors.isEmpty
        let fanMissing = draftFanID.map { id in !fans.contains(where: { $0.id == id }) } ?? fans.isEmpty
        if sensorMissing || fanMissing {
            let targetIsDraft = draftSensorID != rule.sensorID || draftFanID != rule.fanID
            missing.stringValue = targetIsDraft
                ? L("草稿所选传感器或风扇当前不可用；修改未保存，已保存规则保持不变。", "The draft sensor or fan is unavailable. Changes are unsaved; the saved rule is unchanged.")
                : L("所选传感器或风扇当前不可用；本规则暂不执行。", "The selected sensor or fan is unavailable; this rule will not run now.")
        } else { missing.stringValue = "" }
        missing.isHidden = missing.stringValue.isEmpty
    }

    private func refreshValues() {
        draftSensorID = rule.sensorID; draftFanID = rule.fanID
        enabled.state = rule.enabled ? .on : .off
        comparison.selectItem(at: rule.comparison == .above ? 0 : 1)
        displayedThreshold = number(unit.displayValue(forCelsius: rule.thresholdCelsius))
        displayedPercent = number(rule.percent)
        threshold.stringValue = displayedThreshold; percent.stringValue = displayedPercent
        unitLabel.stringValue = unit.symbol
        validation.stringValue = rule.isValid ? "" : L("已保存规则的数据无效，请修正温度、百分比或目标后再使用。", "The saved rule contains invalid data. Correct its temperature, percentage or target before use.")
        validation.isHidden = validation.stringValue.isEmpty
    }

    @objc private func commit() {
        // A failed numeric edit leaves all of this row's choices as a draft.
        // Polling may refresh available hardware, but must not restore targets
        // from the last saved rule while the user is correcting that draft.
        draftSensorID = sensor.selectedItem?.representedObject as? String
        draftFanID = fan.selectedTag() < 0 ? nil : fan.selectedTag()
        guard let displayed = parse(threshold.stringValue), let value = parse(percent.stringValue) else {
            showInvalid(L("修改未保存：温度和百分比必须是有效数字。", "Changes not saved: temperature and percentage must be valid numbers.")); return
        }
        let celsius = threshold.stringValue == displayedThreshold ? rule.thresholdCelsius : unit.celsius(fromDisplayValue: displayed)
        guard celsius.isFinite, (-40...150).contains(celsius) else {
            showInvalid(String(format: L("修改未保存：温度应在 %@–%@ %@ 之间。", "Changes not saved: temperature must be between %@ and %@ %@."),
                number(unit.displayValue(forCelsius: -40)), number(unit.displayValue(forCelsius: 150)), unit.symbol)); return
        }
        guard value.isFinite, (0...100).contains(value) else {
            showInvalid(L("修改未保存：风扇百分比必须在 0–100 之间。", "Changes not saved: fan percentage must be between 0 and 100.")); return
        }
        var updated = rule
        updated.sensorID = draftSensorID
        updated.comparison = comparison.indexOfSelectedItem == 0 ? .above : .below
        updated.thresholdCelsius = celsius
        updated.fanID = draftFanID
        updated.percent = percent.stringValue == displayedPercent ? rule.percent : value
        guard updated.isValid else {
            showInvalid(L("修改未保存：规则目标或数值无效。", "Changes not saved: the rule target or value is invalid.")); return
        }
        let differs = updated != rule
        rule = updated; refreshValues()
        if differs { edited?(updated) }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === threshold || field === percent else { return }
        commit()
    }

    @objc private func toggleEnabled() {
        rule.enabled = enabled.state == .on
        edited?(rule)
    }
    @objc private func deleteRule() { deleted?() }
    private func showInvalid(_ message: String) { validation.stringValue = message; validation.isHidden = false }
    private func parse(_ text: String) -> Double? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^[+-]?(?:[0-9]+(?:[.,][0-9]*)?|[.,][0-9]+)$"#, options: .regularExpression) != nil else { return nil }
        return Double(value.replacingOccurrences(of: ",", with: "."))
    }
    private func number(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal; formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0; formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
    private func horizontal(_ views: [NSView]) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = .horizontal; result.alignment = .centerY; result.spacing = 9
        return result
    }
}
