import Foundation

public enum FanOperatingMode: String, Codable, CaseIterable {
    case system, maximum, manual, custom
}

/// The application supplies actual login/startup state to controlAllowed when
/// evaluating rules. Persisting a period never starts hardware control itself.
public enum FanControlPeriod: String, Codable, CaseIterable {
    case always, afterBootDelay, dailySchedule

    /// Scheduling controls only the application's live session. It does not
    /// promise pre-login control or install a background schedule by itself.
    /// Daily start is inclusive and end exclusive; equal times are an empty
    /// interval, not an accidental grant of round-the-clock control.
    public func allowsControl(uptimeSeconds: Double, localMinuteOfDay: Int,
                              bootDelayMinutes: Int, startMinute: Int, endMinute: Int) -> Bool {
        switch self {
        case .always: return true
        case .afterBootDelay:
            guard uptimeSeconds.isFinite, uptimeSeconds >= 0,
                  (0...10080).contains(bootDelayMinutes) else { return false }
            return uptimeSeconds >= Double(bootDelayMinutes) * 60
        case .dailySchedule:
            guard (0..<1440).contains(localMinuteOfDay), (0..<1440).contains(startMinute),
                  (0..<1440).contains(endMinute), startMinute != endMinute else { return false }
            if startMinute < endMinute { return (startMinute..<endMinute).contains(localMinuteOfDay) }
            return localMinuteOfDay >= startMinute || localMinuteOfDay < endMinute
        }
    }
}

public enum FanTemperatureComparison: String, Codable, CaseIterable {
    case above, below
}

public struct FanAutomationRule: Codable, Equatable, Identifiable {
    public var id: UUID
    public var enabled: Bool
    /// nil means any valid, currently available temperature sensor.
    public var sensorID: String?
    public var comparison: FanTemperatureComparison
    public var thresholdCelsius: Double
    /// nil means all eligible fans, not all toolbox modules.
    public var fanID: Int?
    public var percent: Double

    public init(id: UUID = UUID(), enabled: Bool = true, sensorID: String? = nil,
                comparison: FanTemperatureComparison = .above,
                thresholdCelsius: Double = 75, fanID: Int? = nil, percent: Double = 100) {
        self.id = id; self.enabled = enabled; self.sensorID = sensorID
        self.comparison = comparison; self.thresholdCelsius = thresholdCelsius
        self.fanID = fanID; self.percent = percent
    }

    public var isValid: Bool {
        (sensorID.map { !$0.isEmpty } ?? true) &&
        (fanID.map { (0..<10).contains($0) } ?? true) &&
        thresholdCelsius.isFinite && (-40...150).contains(thresholdCelsius) &&
        percent.isFinite && (0...100).contains(percent)
    }
}

/// Recommendations only. The caller must validate fresh hardware state again,
/// obtain service approval and perform writes through its authenticated helper.
public struct FanAutomationEvaluation: Equatable {
    public let commands: [FanCommand]
    public let activeRuleIDs: Set<UUID>
    public let blockedFanIDs: Set<Int>
    public let invalidRuleIDs: Set<UUID>
    public let requestedRPMByFanID: [Int: Double]

    public init(commands: [FanCommand], activeRuleIDs: Set<UUID>, blockedFanIDs: Set<Int>,
                invalidRuleIDs: Set<UUID>, requestedRPMByFanID: [Int: Double]) {
        self.commands = commands; self.activeRuleIDs = activeRuleIDs
        self.blockedFanIDs = blockedFanIDs; self.invalidRuleIDs = invalidRuleIDs
        self.requestedRPMByFanID = requestedRPMByFanID
    }
}

public enum FanAutomationPolicy {
    /// Percent is relative to maximum RPM. Zero percent still respects the
    /// hardware's nonzero minimum; it is not a fan-stop or automatic command.
    public static func requestedRPM(percent: Double, reading: FanReading) -> Double? {
        guard percent.isFinite, (0...100).contains(percent),
              reading.minimumRPM.isFinite, reading.maximumRPM.isFinite,
              reading.minimumRPM >= 0, reading.maximumRPM > reading.minimumRPM else { return nil }
        return min(reading.maximumRPM, max(reading.minimumRPM, reading.maximumRPM * (percent / 100)))
    }

    /// Pass temperaturesFresh=false on failed/stale polling, and
    /// controlAllowed=false on disabled custom control, logout or schedule gaps.
    /// Either condition releases only fans owned by this tool.
    public static func evaluate(
        rules: [FanAutomationRule], temperatures: [TemperatureSensorReading],
        temperaturesFresh: Bool, fans: [FanReading], ownedFanIDs: Set<Int>,
        previouslyActiveRuleIDs: Set<UUID> = [], hysteresisCelsius: Double = 2,
        controlAllowed: Bool = true
    ) -> FanAutomationEvaluation {
        // Recovery must not require a fresh RPM/limits snapshot. The helper
        // validates real fan identity separately when processing automatic.
        let restorableIDs = ownedFanIDs.filter { (0..<10).contains($0) }
        let duplicateRuleIDs = Set(Dictionary(grouping: rules, by: \.id)
            .filter { $0.value.count > 1 }.map(\.key))
        let invalidIDs = Set(rules.filter { !$0.isValid }.map(\.id)).union(duplicateRuleIDs)
        let externalManualIDs = Set(fans.filter { $0.mode == 1 && !ownedFanIDs.contains($0.id) }.map(\.id))

        func released(blocked: Set<Int> = []) -> FanAutomationEvaluation {
            FanAutomationEvaluation(commands: restorableIDs.sorted().map { .automatic(fanID: $0) },
                activeRuleIDs: [], blockedFanIDs: blocked, invalidRuleIDs: invalidIDs,
                requestedRPMByFanID: [:])
        }
        // This matches the hardware controller's global external-owner gate.
        // Never compete with another utility, even on an otherwise idle fan.
        guard externalManualIDs.isEmpty else { return released(blocked: externalManualIDs) }
        guard controlAllowed, temperaturesFresh else { return released() }

        let validTemperatures = temperatures.filter(\.isValid)
        guard !validTemperatures.isEmpty else { return released() }
        let hysteresis = hysteresisCelsius.isFinite && (0...20).contains(hysteresisCelsius)
            ? hysteresisCelsius : 2
        let duplicateFanIDs = Set(Dictionary(grouping: fans, by: \.id)
            .filter { $0.value.count > 1 }.map(\.key))
        var activeIDs = Set<UUID>()
        var requested: [Int: Double] = [:]
        var blocked = Set<Int>()

        for rule in rules where rule.enabled && !invalidIDs.contains(rule.id) {
            let sensors = validTemperatures.filter { rule.sensorID == nil || $0.id == rule.sensorID }
            guard !sensors.isEmpty else { continue }
            let wasActive = previouslyActiveRuleIDs.contains(rule.id)
            let matches = sensors.contains { sensor in
                switch rule.comparison {
                case .above:
                    return sensor.celsius > rule.thresholdCelsius - (wasActive ? hysteresis : 0)
                case .below:
                    return sensor.celsius < rule.thresholdCelsius + (wasActive ? hysteresis : 0)
                }
            }
            guard matches else { continue }
            var appliedToEligibleFan = false
            for fan in fans where rule.fanID == nil || rule.fanID == fan.id {
                guard (0..<10).contains(fan.id), !duplicateFanIDs.contains(fan.id),
                      fan.mode == 0 || fan.mode == 3 || (fan.mode == 1 && ownedFanIDs.contains(fan.id)),
                      (try? FanControlPolicy.validate(reading: fan, fanCount: fans.count)) != nil,
                      let rpm = requestedRPM(percent: rule.percent, reading: fan) else {
                    blocked.insert(fan.id); continue
                }
                requested[fan.id] = max(requested[fan.id] ?? rpm, rpm)
                appliedToEligibleFan = true
            }
            if appliedToEligibleFan { activeIDs.insert(rule.id) }
        }

        var commands = requested.keys.sorted().map { FanCommand.fixed(fanID: $0, rpm: requested[$0]!) }
        commands += restorableIDs.subtracting(requested.keys).sorted().map { .automatic(fanID: $0) }
        commands.sort { $0.fanID < $1.fanID }
        return FanAutomationEvaluation(commands: commands, activeRuleIDs: activeIDs,
            blockedFanIDs: blocked, invalidRuleIDs: invalidIDs, requestedRPMByFanID: requested)
    }
}
