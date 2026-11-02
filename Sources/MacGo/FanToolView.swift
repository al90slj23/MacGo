import AppKit
import ServiceManagement
import SMCController
import ToolboxCore
import FanHelperProtocol

/// One authenticated fan session feeds both this settings page and the menu bar.
/// Dashboard views emit intent; only this host schedules the closed helper RPCs.
@MainActor final class FanToolView: NSView {
    private let settings: Settings
    private let dashboard: FanDashboardView
    private let serviceStatus = NSTextField(wrappingLabelWithString: "")
    private let privacy = NSTextField(wrappingLabelWithString: "")
    private let authorize = NSButton(title: "", target: nil, action: nil)
    private let restore = NSButton(title: "", target: nil, action: nil)
    private let uninstall = NSButton(title: "", target: nil, action: nil)
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var connection: NSXPCConnection?
    private var connectionEpoch = UUID()
    private var commandEpoch = UUID()
    private var pingToken: UUID?
    private var reading = false
    private var snapshotEpoch = UUID()
    private var busy = false
    private var maintenance = false
    private var stopping = false
    private var sessionSuspended = false
    private var sleepSuspended = false
    private var controlSuspended: Bool { sessionSuspended || sleepSuspended }
    private var verifiedPeer = false
    private var lastServiceError: String?
    private var commandFailure: String?
    private var readFailure: String?
    private var plannerMessage = ""
    private var sampleUptime: TimeInterval?
    private var temperatureSampleUptime: TimeInterval?
    private var ownedIDs = Set<Int>()
    private var lastAppliedTargets: [Int: Double] = [:]
    private var successfulCommandUptime: [Int: TimeInterval] = [:]
    private var activeRuleIDs = Set<UUID>()
    private var controlConfiguration: ControlConfiguration
    private weak var authorizationWindow: NSWindow?

    private(set) var readings: [FanReading] = []
    private(set) var temperatures: [TemperatureSensorReading] = []
    private(set) var uptimeSeconds: Double?
    var stateChanged: (() -> Void)?
    var openRules: (() -> Void)?
    var openPreferences: (() -> Void)?
    var authorizationRequested: (() -> Void)?

    var selectedMode: FanOperatingMode { settings.selectedFanMode }
    var manualPercent: Double { settings.manualFanPercent }
    var isBusy: Bool { busy || maintenance }
    var authorizationSummary: String { serviceStatus.stringValue }
    var isControlServiceReady: Bool { verifiedPeer && lastServiceError == nil }
    var controlMessage: String {
        if let commandFailure { return L("操作已暂停：", "Control paused: ") + commandFailure }
        if let readFailure { return readFailure }
        return plannerMessage
    }
    var cpuTemperatureCelsius: Double? {
        guard temperatureSnapshotIsFresh else { return nil }
        let values = temperatures.filter { $0.category == .cpu && $0.isValid }.map(\.celsius)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    private var signingAvailable: Bool { (try? FanHelperIdentity.signingRequirement(identifier: FanHelperIdentity.serviceName)) != nil }
    private var service: SMAppService { .daemon(plistName: FanHelperIdentity.plistName) }
    private var thermallyRestricted: Bool {
        ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
    }
    private var fanSnapshotIsFresh: Bool { isFresh(sampleUptime) && !readings.isEmpty }
    private var temperatureSnapshotIsFresh: Bool { isFresh(temperatureSampleUptime) && !temperatures.isEmpty }

    init(settings: Settings) {
        self.settings = settings
        dashboard = FanDashboardView(settings: settings)
        controlConfiguration = ControlConfiguration(settings)
        super.init(frame: .zero)
        dashboard.modeSelected = { [weak self] in self?.selectMode($0) }
        dashboard.manualPercentChanged = { [weak self] in self?.setManualPercent($0) }
        dashboard.openRules = { [weak self] in self?.openRules?() }
        dashboard.openPreferences = { [weak self] in self?.openPreferences?() }
        authorize.target = self; authorize.action = #selector(requestAuthorizationPage)
        restore.target = self; restore.action = #selector(restoreAll)
        uninstall.target = self; uninstall.action = #selector(uninstallService)
        serviceStatus.font = .systemFont(ofSize: 11); serviceStatus.textColor = .secondaryLabelColor
        privacy.font = .systemFont(ofSize: 11); privacy.textColor = .secondaryLabelColor
        let controls = NSStackView(views: [authorize, restore, uninstall]); controls.spacing = 10
        let stack = NSStackView(views: [dashboard, controls, serviceStatus, privacy])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            dashboard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dashboard.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
            serviceStatus.widthAnchor.constraint(equalTo: stack.widthAnchor),
            privacy.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        dashboard.setContentHuggingPriority(.defaultLow, for: .vertical)
        for field in [serviceStatus, privacy] { field.setContentHuggingPriority(.required, for: .vertical) }
        // Tracking a slider or keeping the menu open must not starve the helper's
        // eight-second watchdog. Polling/heartbeats run in common run-loop modes.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        observeSession()
        refreshLocalization(); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func selectMode(_ mode: FanOperatingMode) {
        guard !stopping else { return }
        guard mode == .system || isControlServiceReady else {
            plannerMessage = L("请先在“通用 → 授权”中启用风扇控制服务。", "Enable the fan service under General → Permissions first.")
            publish(); authorizationRequested?(); return
        }
        settings.selectedFanMode = mode
        explicitControlChange()
    }

    func setManualPercent(_ value: Double) {
        guard !stopping, value.isFinite, (0...100).contains(value) else { return }
        guard isControlServiceReady else {
            plannerMessage = L("请先在“通用 → 授权”中启用风扇控制服务。", "Enable the fan service under General → Permissions first.")
            publish(); authorizationRequested?(); return
        }
        settings.manualFanPercent = value
        settings.selectedFanMode = .manual
        explicitControlChange()
    }

    /// Display changes do not clear a failed-command latch or silently re-arm
    /// control. Only a changed control configuration or explicit mode/Apply does.
    func applySettings() {
        let next = ControlConfiguration(settings)
        if next != controlConfiguration {
            controlConfiguration = next
            commandFailure = nil; activeRuleIDs.removeAll(); lastAppliedTargets.removeAll()
            reconcile()
        }
        dashboard.refreshLocalization(); publish()
    }

    private func explicitControlChange() {
        commandFailure = nil; activeRuleIDs.removeAll(); lastAppliedTargets.removeAll()
        controlConfiguration = ControlConfiguration(settings)
        // If a request is in flight, its reply still records successful ownership.
        // Reconciliation then uses the newest mode, including a queued System.
        reconcile(); publish()
    }

    func refreshLocalization() {
        authorize.title = L("管理风扇授权…", "Manage fan authorization…")
        restore.title = L("全部恢复系统自动", "Restore owned fans")
        uninstall.title = L("移除控制服务…", "Remove service…")
        privacy.stringValue = L("读取无需管理员权限。手动控制只在 Mac Go 运行、会话有效且处于设定时段时执行。退出、睡眠、断联或系统热状态过高时恢复本工具持有的控制。", "Readings need no administrator access. Manual control runs only while Mac Go is open in an active session and within its control period. Exit, sleep, disconnection or high thermal pressure releases control owned by Mac Go.")
        dashboard.refreshLocalization(); publish()
    }

    func shutdown() {
        guard !stopping else { return }
        stopping = true; timer?.invalidate(); timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        // Connection invalidation is a durable recovery trigger in the daemon;
        // it also cancels queued operations before releasing the ownership slot.
        resetConnection(); publish()
    }

    private func observeSession() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if name == NSWorkspace.willSleepNotification { self.sleepSuspended = true }
                    else { self.sessionSuspended = true }
                    self.snapshotEpoch = UUID()
                    self.sampleUptime = nil; self.temperatureSampleUptime = nil
                    self.resetConnection(); self.publish()
                }
            }
            observers.append((workspace, token))
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if name == NSWorkspace.didWakeNotification { self.sleepSuspended = false }
                    else { self.sessionSuspended = false }
                    self.snapshotEpoch = UUID()
                    self.sampleUptime = nil; self.temperatureSampleUptime = nil
                    self.refresh()
                }
            }
            observers.append((workspace, token))
        }
        let center = NotificationCenter.default
        let token = center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.thermallyRestricted {
                    self.snapshotEpoch = UUID(); self.sampleUptime = nil; self.temperatureSampleUptime = nil
                    self.resetConnection()
                }
                self.refresh()
            }
        }
        observers.append((center, token))
    }

    private func isFresh(_ captured: TimeInterval?) -> Bool {
        guard let captured else { return false }
        let elapsed = ProcessInfo.processInfo.systemUptime - captured
        return elapsed >= 0 && elapsed <= 6
    }

    private func refresh() {
        guard !stopping else { return }
        if !isFresh(temperatureSampleUptime) { temperatures = [] }
        if !isFresh(sampleUptime) { readings = [] }
        if !controlSuspended, !thermallyRestricted, canConnect, !busy, !maintenance, pingToken == nil {
            checkServiceHealth()
        } else if !canConnect, connection != nil { resetConnection() }
        requestSnapshot()
        reconcile(); publish()
    }

    private struct HardwareSnapshot {
        let fans: [FanReading]
        let temperatures: TemperatureSnapshot
        let uptime: Double?
        let capturedUptime: TimeInterval
    }

    private func requestSnapshot() {
        guard !reading, !stopping else { return }; reading = true
        let epoch = snapshotEpoch
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { () throws -> HardwareSnapshot in
                let captured = ProcessInfo.processInfo.systemUptime
                let smc = try SMCConnection()
                let fans = try smc.readFans()
                let temperatures = smc.readTemperatureSnapshot()
                return HardwareSnapshot(fans: fans, temperatures: temperatures,
                    uptime: SystemUptimeSnapshot.read()?.elapsedSeconds,
                    capturedUptime: captured)
            }
            DispatchQueue.main.async { self?.render(result, epoch: epoch) }
        }
    }

    private func render(_ result: Result<HardwareSnapshot, Error>, epoch: UUID) {
        reading = false
        guard !stopping else { return }
        guard snapshotEpoch == epoch else {
            if !controlSuspended { requestSnapshot() }
            return
        }
        switch result {
        case .failure(let error):
            readings = []; temperatures = []; sampleUptime = nil; temperatureSampleUptime = nil
            uptimeSeconds = SystemUptimeSnapshot.read()?.elapsedSeconds
            readFailure = L("硬件读取失败：", "Hardware readings failed: ") + error.localizedDescription
        case .success(let snapshot):
            readings = snapshot.fans; temperatures = snapshot.temperatures.sensors
            uptimeSeconds = snapshot.uptime; sampleUptime = snapshot.capturedUptime
            temperatureSampleUptime = snapshot.temperatures.sensors.isEmpty ? nil : snapshot.capturedUptime
            readFailure = nil
            if let changed = observedControlChange(in: snapshot) {
                pauseAfterFailure(changed)
                return
            }
        }
        reconcile(); publish()
    }

    /// A snapshot started before an acknowledged command can legitimately show
    /// the old state. Inspect only later observations, outside in-flight writes.
    /// A system/foreign override pauses control instead of fighting it every poll.
    private func observedControlChange(in snapshot: HardwareSnapshot) -> String? {
        guard !busy, !maintenance, !controlSuspended, !thermallyRestricted,
              selectedMode != .system, controlPeriodAllows() else { return nil }
        for id in ownedIDs.sorted() {
            guard let acceptedAt = successfulCommandUptime[id],
                  snapshot.capturedUptime >= acceptedAt,
                  let expected = lastAppliedTargets[id] else { continue }
            guard let fan = snapshot.fans.first(where: { $0.id == id }), fan.mode == 1,
                  let target = fan.targetRPM, target.isFinite,
                  abs(target - expected) <= max(1, expected * 0.001) else {
                return L("风扇 \(id + 1) 的手动控制状态已改变；已释放控制并暂停，重新选择模式或应用后重试。",
                         "Fan \(id + 1)'s manual control state changed. Control was released and paused; select a mode or Apply to retry.")
            }
        }
        return nil
    }

    private func controlPeriodAllows() -> Bool {
        let calendar = Calendar.current, now = Date()
        let minutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        return settings.controlPeriod.allowsControl(uptimeSeconds: uptimeSeconds ?? .nan,
            localMinuteOfDay: minutes, bootDelayMinutes: settings.bootDelayMinutes,
            startMinute: settings.scheduleStartMinute, endMinute: settings.scheduleEndMinute)
    }

    /// Each invocation derives the next request from current intent. There is no
    /// old multi-fan batch to survive a profile change while an RPC is in flight.
    private func reconcile() {
        guard !busy, !maintenance, !stopping, pingToken == nil else { return }
        if controlSuspended || thermallyRestricted {
            plannerMessage = L("控制已暂停，由系统管理散热。", "Control is paused; macOS manages cooling.")
            return
        }
        guard commandFailure == nil else { return }
        let releases = ownedIDs.sorted().map { FanCommand.automatic(fanID: $0) }
        var desired = releases
        if selectedMode == .system {
            activeRuleIDs.removeAll()
            plannerMessage = L("系统自动管理散热。", "macOS manages cooling automatically.")
        } else if !isControlServiceReady {
            plannerMessage = L("等待已验证的风扇控制服务。", "Waiting for the verified fan control service.")
        } else if !fanSnapshotIsFresh {
            activeRuleIDs.removeAll()
            plannerMessage = L("等待新的硬件读数；已释放本工具的手动控制。", "Waiting for fresh readings; releasing control owned by Mac Go.")
        } else if !controlPeriodAllows() {
            activeRuleIDs.removeAll()
            plannerMessage = L("当前不在控制时段，由系统管理散热。", "Outside the control period; macOS manages cooling.")
        } else if readings.contains(where: { $0.mode == 1 && !ownedIDs.contains($0.id) }) {
            activeRuleIDs.removeAll()
            plannerMessage = L("检测到其他工具正在手动控制风扇，请先在原工具恢复系统自动。", "Another tool is controlling a fan. Restore automatic mode in that tool first.")
        } else if selectedMode == .custom {
            let decision = FanAutomationPolicy.evaluate(rules: settings.fanRules, temperatures: temperatures,
                temperaturesFresh: temperatureSnapshotIsFresh, fans: readings, ownedFanIDs: ownedIDs,
                previouslyActiveRuleIDs: activeRuleIDs)
            activeRuleIDs = decision.activeRuleIDs; desired = decision.commands
            if !temperatureSnapshotIsFresh {
                plannerMessage = L("温度读数不可用，已释放本工具的手动控制。", "Temperature readings are unavailable; releasing control owned by Mac Go.")
            } else if !decision.invalidRuleIDs.isEmpty {
                plannerMessage = L("部分规则无效，已跳过；有效规则继续按真实温度判断。", "Invalid rules are skipped; valid rules use current temperatures.")
            } else {
                plannerMessage = String(format: L("已匹配 %d 条规则；未匹配的风扇由系统管理。", "%d rules match; unmatched fans use automatic control."), decision.activeRuleIDs.count)
            }
        } else {
            activeRuleIDs.removeAll()
            desired = readings.compactMap { fan in
                guard fan.mode == 0 || fan.mode == 3 || (fan.mode == 1 && ownedIDs.contains(fan.id)),
                      (try? FanControlPolicy.validate(reading: fan, fanCount: readings.count)) != nil else { return nil }
                if selectedMode == .maximum { return .maximum(fanID: fan.id) }
                guard let rpm = FanAutomationPolicy.requestedRPM(percent: manualPercent, reading: fan) else { return nil }
                return .fixed(fanID: fan.id, rpm: min(fan.maximumRPM, max(fan.minimumRPM, rpm.rounded())))
            }
            let requestedIDs = Set(desired.map(\.fanID))
            desired += ownedIDs.subtracting(requestedIDs).sorted().map { .automatic(fanID: $0) }
            plannerMessage = selectedMode == .maximum ? L("最大转速模式。", "Maximum fan speed mode.")
                : String(format: L("手动目标：各风扇最高转速的 %.0f%%，遵守硬件最低值。", "Manual target: %.0f%% of each fan's maximum, respecting hardware minimums."), manualPercent)
        }
        guard verifiedPeer else { return }
        let next = desired.first { command in
            switch command {
            case .automatic(let id): return ownedIDs.contains(id)
            case .fixed(let id, let rpm):
                return !ownedIDs.contains(id) || lastAppliedTargets[id].map { abs($0 - rpm) > 0.5 } != false
            case .maximum(let id):
                guard let maximum = readings.first(where: { $0.id == id })?.maximumRPM else { return false }
                return !ownedIDs.contains(id) || lastAppliedTargets[id].map { abs($0 - maximum) > 0.5 } != false
            }
        }
        if let next { send(next) }
    }

    private func send(_ command: FanCommand) {
        guard !busy, verifiedPeer, !stopping, !maintenance else { return }
        do {
            let proxy = try helper()
            let connectionID = connectionEpoch, requestID = UUID(); commandEpoch = requestID; busy = true
            let target: Double?
            switch command {
            case .fixed(_, let rpm): target = rpm
            case .maximum(let id): target = readings.first(where: { $0.id == id })?.maximumRPM
            case .automatic: target = nil
            }
            publish()
            let reply: (String?) -> Void = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.connectionEpoch == connectionID, self.commandEpoch == requestID else { return }
                    self.busy = false
                    if let error {
                        self.pauseAfterFailure(error)
                    } else {
                        switch command {
                        case .automatic(let id):
                            self.ownedIDs.remove(id); self.lastAppliedTargets.removeValue(forKey: id)
                            self.successfulCommandUptime.removeValue(forKey: id)
                        case .fixed(let id, _), .maximum(let id):
                            self.ownedIDs.insert(id); self.lastAppliedTargets[id] = target
                            self.successfulCommandUptime[id] = ProcessInfo.processInfo.systemUptime
                        }
                        self.reconcile(); self.requestSnapshot(); self.publish()
                    }
                }
            }
            switch command {
            case .automatic(let id): proxy.automatic(id: id, reply: reply)
            case .fixed(let id, let rpm): proxy.setFan(id: id, rpm: rpm, reply: reply)
            case .maximum(let id): proxy.maximum(id: id, reply: reply)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.connectionEpoch == connectionID, self.commandEpoch == requestID, self.busy else { return }
                self.pauseAfterFailure(L("风扇操作超时；已断开连接并触发恢复。重新选择模式或应用后重试。", "Fan request timed out; disconnection triggered recovery. Select a mode or Apply to retry."))
            }
        } catch { pauseAfterFailure(error.localizedDescription) }
    }

    private func pauseAfterFailure(_ error: String) {
        commandFailure = error
        // Do not re-apply a failed target on the next two-second poll. Dropping
        // the authenticated session triggers the daemon's journalled recovery.
        resetConnection(); activeRuleIDs.removeAll(); requestSnapshot(); publish()
    }

    private func checkServiceHealth() {
        do {
            let proxy = try helper()
            let connectionID = connectionEpoch, requestID = UUID(); pingToken = requestID
            proxy.ping { [weak self] _, error in
                Task { @MainActor in
                    guard let self, self.connectionEpoch == connectionID, self.pingToken == requestID else { return }
                    self.pingToken = nil
                    self.verifiedPeer = self.connection?.effectiveUserIdentifier == 0
                    self.lastServiceError = self.verifiedPeer ? error
                        : L("控制服务身份不是管理员，连接已拒绝。", "The service is not running as root; connection rejected.")
                    if !self.verifiedPeer { self.resetConnection() }
                    self.reconcile(); self.publish()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.connectionEpoch == connectionID, self.pingToken == requestID else { return }
                self.connectionFailed(L("控制服务响应超时，请重试或重新确认服务。", "The control service timed out. Retry or reauthorize it."))
            }
        } catch { connectionFailed(error.localizedDescription) }
    }

    private func connectionFailed(_ error: String) {
        let hadControl = busy || !ownedIDs.isEmpty
        resetConnection(); lastServiceError = error
        if hadControl { commandFailure = error }
        publish()
    }

    private func helper() throws -> FanHelperService {
        if connection == nil {
            let requirement: String, name: String
            if signingAvailable {
                requirement = try FanHelperIdentity.signingRequirement(identifier: FanHelperIdentity.serviceName)
                name = FanHelperIdentity.serviceName
            } else {
                let approved = try LocalFanIdentity.authorizationForCurrentApp()
                requirement = try LocalFanIdentity.requirementString(identifier: FanHelperIdentity.serviceName, cdHash: approved.helperCDHash)
                name = LocalFanIdentity.serviceName
            }
            let c = NSXPCConnection(machServiceName: name, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: FanHelperService.self)
            c.setCodeSigningRequirement(requirement)
            let epoch = UUID(); connectionEpoch = epoch
            c.invalidationHandler = { [weak self] in Task { @MainActor in
                guard let self, self.connectionEpoch == epoch else { return }
                self.connectionFailed(L("控制服务连接已断开。重新选择模式或应用后重试。", "The control service disconnected. Select a mode or Apply to retry."))
            } }
            c.interruptionHandler = c.invalidationHandler
            c.resume(); connection = c
        }
        let epoch = connectionEpoch
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            Task { @MainActor in
                guard let self, self.connectionEpoch == epoch else { return }
                self.connectionFailed(L("控制服务连接失败：", "Control service connection failed: ") + error.localizedDescription)
            }
        }) as? FanHelperService else {
            throw NSError(domain: "MacToolbox", code: 1, userInfo: [NSLocalizedDescriptionKey: L("风扇控制服务不可用。", "Fan service is unavailable.")])
        }
        return proxy
    }

    private func resetConnection() {
        connectionEpoch = UUID(); commandEpoch = UUID(); pingToken = nil
        verifiedPeer = false; busy = false; ownedIDs.removeAll(); lastAppliedTargets.removeAll()
        successfulCommandUptime.removeAll(); activeRuleIDs.removeAll()
        connection?.invalidate(); connection = nil
    }

    private var canConnect: Bool {
        signingAvailable ? service.status == .enabled : (try? LocalFanIdentity.authorizationForCurrentApp()) != nil
    }

    private func publish() {
        updateServiceStatus()
        dashboard.update(fans: readings, temperatures: temperatureSnapshotIsFresh ? temperatures : [],
            mode: selectedMode, manualPercent: manualPercent, canControl: isControlServiceReady,
            busy: isBusy, message: controlMessage, uptimeSeconds: uptimeSeconds)
        stateChanged?()
    }

    private func updateServiceStatus() {
        let installed = try? LocalFanIdentity.loadAuthorization()
        restore.isEnabled = !stopping && !maintenance
        uninstall.isEnabled = !isBusy && ((installed?.ownerUID == getuid()) || (signingAvailable && service.status == .enabled))
        authorize.isEnabled = !isBusy
        if maintenance { serviceStatus.stringValue = L("正在完成控制服务操作…", "Completing control service operation…") }
        else if let lastServiceError { serviceStatus.stringValue = L("控制服务：", "Control service: ") + lastServiceError }
        else if !signingAvailable {
            if (try? LocalFanIdentity.authorizationForCurrentApp()) != nil {
                serviceStatus.stringValue = verifiedPeer
                    ? L("本机控制服务身份已确认。", "Local control service identity verified.")
                    : L("本机控制服务已安装，正在验证连接…", "Local service installed; verifying its connection…")
            } else {
                serviceStatus.stringValue = installed == nil
                    ? L("点击管理授权，审阅后由 macOS 确认管理员安装。", "Manage authorization to review and approve installation in macOS.")
                    : L("Mac Go 已更新，请重新确认当前版本的控制服务。", "Mac Go has changed. Reauthorize the service for this build.")
            }
        } else {
            switch service.status {
            case .enabled: serviceStatus.stringValue = L("控制服务已授权。", "Control service approved.")
            case .requiresApproval: serviceStatus.stringValue = L("请在系统设置 → 通用 → 登录项与扩展允许 Mac Go 后台服务。", "Allow Mac Go service in System Settings → General → Login Items & Extensions.")
            default: serviceStatus.stringValue = L("控制服务尚未启用。", "Control service is not enabled.")
            }
        }
    }

    @objc private func restoreAll() { selectMode(.system) }
    @objc private func requestAuthorizationPage() { authorizationRequested?() }
    func requestAuthorization() { installService() }
    func requestAuthorization(presenting window: NSWindow) { authorizationWindow = window; installService() }

    @objc private func installService() {
        guard !isBusy else { return }
        if !signingAvailable { reviewLocalOperation(.install); return }
        do {
            guard (try? LocalFanIdentity.loadAuthorization()) == nil else {
                showError(L("请先移除本机服务，再启用 Apple 签名服务。", "Remove the local service before enabling the Apple-signed service.")); return
            }
            _ = try FanHelperIdentity.signingRequirement(identifier: FanHelperIdentity.serviceName)
            settings.selectedFanMode = .system
            controlConfiguration = ControlConfiguration(settings)
            try service.register()
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            lastServiceError = nil; refresh()
        } catch { showError(error.localizedDescription) }
    }

    @objc private func uninstallService() {
        guard !isBusy else { return }
        if (try? LocalFanIdentity.loadAuthorization()) != nil { reviewLocalOperation(.uninstall); return }
        do {
            settings.selectedFanMode = .system; controlConfiguration = ControlConfiguration(settings)
            resetConnection(); try service.unregister(); lastServiceError = nil; refresh()
        } catch { showError(error.localizedDescription) }
    }

    private func reviewLocalOperation(_ action: FanLocalInstaller.Action) {
        guard !isBusy, let host = window ?? authorizationWindow else { return }
        do {
            let plan = try FanLocalInstaller.plan(action)
            let alert = NSAlert()
            alert.messageText = action == .install ? L("安装本机风扇控制服务", "Install local fan service") : L("移除本机风扇控制服务", "Remove local fan service")
            alert.informativeText = plan.summary
            alert.addButton(withTitle: action == .install ? L("继续，使用系统管理员确认", "Continue with administrator approval") : L("恢复并移除服务", "Restore and remove service"))
            alert.addButton(withTitle: L("取消", "Cancel"))
            alert.beginSheetModal(for: host) { [weak self] response in
                guard response == .alertFirstButtonReturn, let self else { return }
                // Installing/rebinding a service grants capability only. It
                // must not silently resume a saved manual/custom profile.
                self.settings.selectedFanMode = .system
                self.controlConfiguration = ControlConfiguration(self.settings)
                self.maintenance = true; self.resetConnection(); self.publish()
                DispatchQueue.main.async {
                    do { try FanLocalInstaller.execute(plan); self.lastServiceError = nil }
                    catch { if (error as NSError).code != -128 { self.showError(error.localizedDescription) } }
                    self.maintenance = false; self.refresh()
                }
            }
        } catch { showError(error.localizedDescription) }
    }

    private func showError(_ message: String) {
        let alert = NSAlert(); alert.messageText = L("风扇控制", "Fan control"); alert.informativeText = message
        if let host = window ?? authorizationWindow { alert.beginSheetModal(for: host) }
    }

    private struct ControlConfiguration: Equatable {
        let mode: FanOperatingMode
        let percent: Double
        let rules: [FanAutomationRule]
        let period: FanControlPeriod
        let delay: Int
        let start: Int
        let end: Int
        @MainActor init(_ settings: Settings) {
            mode = settings.selectedFanMode; percent = settings.manualFanPercent; rules = settings.fanRules
            period = settings.controlPeriod; delay = settings.bootDelayMinutes
            start = settings.scheduleStartMinute; end = settings.scheduleEndMinute
        }
    }
}
