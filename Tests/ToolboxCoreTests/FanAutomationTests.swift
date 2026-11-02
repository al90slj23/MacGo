import Foundation
import XCTest
@testable import ToolboxCore

final class FanAutomationTests: XCTestCase {
    private func fan(_ id: Int = 0, mode: Int? = 0, minimum: Double = 1000, maximum: Double = 4900) -> FanReading {
        FanReading(id: id, actualRPM: 2000, minimumRPM: minimum, maximumRPM: maximum, mode: mode)
    }
    private func sensor(_ id: String, _ celsius: Double) -> TemperatureSensorReading {
        TemperatureSensorReading(id: id, name: id, celsius: celsius, category: .cpu)
    }
    private func sensor(_ celsius: Double) -> TemperatureSensorReading { sensor("TC0P", celsius) }

    private func evaluate(_ rules: [FanAutomationRule], temperatures: [TemperatureSensorReading],
                          fans: [FanReading]? = nil, owned: Set<Int> = [], previous: Set<UUID> = [],
                          fresh: Bool = true, allowed: Bool = true) -> FanAutomationEvaluation {
        FanAutomationPolicy.evaluate(rules: rules, temperatures: temperatures, temperaturesFresh: fresh,
            fans: fans ?? [fan()], ownedFanIDs: owned, previouslyActiveRuleIDs: previous, controlAllowed: allowed)
    }

    func testConflictingRulesChooseHighestRPMRegardlessOfOrder() {
        let low = FanAutomationRule(thresholdCelsius: 60, percent: 40)
        let high = FanAutomationRule(sensorID: "TC0P", thresholdCelsius: 75, percent: 90)
        for rules in [[low, high], [high, low]] {
            let result = evaluate(rules, temperatures: [sensor(85)])
            XCTAssertEqual(result.commands, [.fixed(fanID: 0, rpm: 4410)])
            XCTAssertEqual(result.activeRuleIDs, [low.id, high.id])
        }
    }

    func testSingleFanRuleDoesNotOverwriteOtherFanAndAllFansUsesOwnBounds() {
        let all = FanAutomationRule(thresholdCelsius: 70, percent: 50)
        let one = FanAutomationRule(thresholdCelsius: 70, fanID: 1, percent: 100)
        let result = evaluate([all, one], temperatures: [sensor(80)],
            fans: [fan(0), fan(1, minimum: 1400, maximum: 6000)])
        XCTAssertEqual(result.commands, [.fixed(fanID: 0, rpm: 2450), .fixed(fanID: 1, rpm: 6000)])
    }

    func testPercentRespectsRealMinimumAndMaximum() {
        XCTAssertEqual(FanAutomationPolicy.requestedRPM(percent: 0, reading: fan()), 1000)
        XCTAssertEqual(FanAutomationPolicy.requestedRPM(percent: 50, reading: fan()), 2450)
        XCTAssertEqual(FanAutomationPolicy.requestedRPM(percent: 100, reading: fan()), 4900)
        for percent in [Double.nan, .infinity, -1, 101] {
            XCTAssertNil(FanAutomationPolicy.requestedRPM(percent: percent, reading: fan()))
        }
        XCTAssertNil(FanAutomationPolicy.requestedRPM(percent: 50, reading: fan(minimum: 6000, maximum: 4900)))
    }

    func testAnySensorUsesRealMatchingObservationAndIgnoresInvalidReadings() {
        let rule = FanAutomationRule(thresholdCelsius: 70, percent: 80)
        let hot = evaluate([rule], temperatures: [sensor("cold", 25), sensor("hot", 80)])
        XCTAssertEqual(hot.commands, [.fixed(fanID: 0, rpm: 3920)])
        let invalid = evaluate([rule], temperatures: [sensor("bad", .infinity), sensor("cold", 25)], owned: [0])
        XCTAssertEqual(invalid.commands, [.automatic(fanID: 0)])
        XCTAssertTrue(invalid.activeRuleIDs.isEmpty)
    }

    func testMissingSelectedSensorReleasesOnlyOwnedControl() {
        let rule = FanAutomationRule(sensorID: "missing", thresholdCelsius: 70)
        let result = evaluate([rule], temperatures: [sensor("other", 90)],
                              fans: [fan(0, mode: 1), fan(1)], owned: [0], previous: [rule.id])
        XCTAssertEqual(result.commands, [.automatic(fanID: 0)])
        XCTAssertTrue(result.activeRuleIDs.isEmpty)
    }

    func testStaleAndDisabledAutomationReleaseOwnedFanWithoutReusingLastHeat() {
        let rule = FanAutomationRule(thresholdCelsius: 70)
        for (fresh, allowed) in [(false, true), (true, false)] {
            let result = evaluate([rule], temperatures: [sensor(95)], fans: [fan(0, mode: 1)],
                                  owned: [0], previous: [rule.id], fresh: fresh, allowed: allowed)
            XCTAssertEqual(result.commands, [.automatic(fanID: 0)])
            XCTAssertTrue(result.activeRuleIDs.isEmpty)
        }
    }

    func testRecoveryDoesNotNeedAnAvailableFanSpeedSnapshot() {
        let rule = FanAutomationRule(thresholdCelsius: 70)
        let result = evaluate([rule], temperatures: [], fans: [], owned: [0], fresh: false)
        XCTAssertEqual(result.commands, [.automatic(fanID: 0)])
    }

    func testNoMatchLeavesUntouchedFansAlone() {
        let result = evaluate([FanAutomationRule(thresholdCelsius: 80)], temperatures: [sensor(50)])
        XCTAssertTrue(result.commands.isEmpty)
        XCTAssertTrue(result.requestedRPMByFanID.isEmpty)
    }

    func testExternalManualOwnerBlocksNewControlAndRestoresOnlyOurFan() {
        let result = evaluate([FanAutomationRule(thresholdCelsius: 70)], temperatures: [sensor(95)],
                              fans: [fan(0, mode: 1), fan(1, mode: 1)], owned: [0])
        XCTAssertEqual(result.blockedFanIDs, [1])
        XCTAssertEqual(result.commands, [.automatic(fanID: 0)])
        XCTAssertTrue(result.activeRuleIDs.isEmpty)
    }

    func testUnknownModeOrInvalidHardwareBoundsCannotGenerateManualCommand() {
        for reading in [fan(mode: nil), fan(mode: 2), fan(minimum: .nan)] {
            let result = evaluate([FanAutomationRule(thresholdCelsius: 70)], temperatures: [sensor(95)],
                                  fans: [reading], owned: [0])
            XCTAssertEqual(result.commands, [.automatic(fanID: 0)])
            XCTAssertEqual(result.blockedFanIDs, [0])
        }
    }

    func testDuplicateFanIdentityCannotProduceCompetingCommands() {
        let result = evaluate([FanAutomationRule(thresholdCelsius: 70)], temperatures: [sensor(95)],
                              fans: [fan(0), fan(0)], owned: [0])
        XCTAssertEqual(result.commands, [.automatic(fanID: 0)])
        XCTAssertEqual(result.blockedFanIDs, [0])
    }

    func testAboveThresholdHysteresisDoesNotStartEarlyAndReleasesAtLowerBoundary() {
        let rule = FanAutomationRule(thresholdCelsius: 70, percent: 100)
        XCTAssertTrue(evaluate([rule], temperatures: [sensor(70)]).commands.isEmpty)
        XCTAssertTrue(evaluate([rule], temperatures: [sensor(71)]).activeRuleIDs.contains(rule.id))
        let retained = evaluate([rule], temperatures: [sensor(69)], owned: [0], previous: [rule.id])
        XCTAssertEqual(retained.commands, [.fixed(fanID: 0, rpm: 4900)])
        let released = evaluate([rule], temperatures: [sensor(68)], owned: [0], previous: [rule.id])
        XCTAssertEqual(released.commands, [.automatic(fanID: 0)])
    }

    func testBelowThresholdHysteresisUsesOppositeBoundary() {
        let rule = FanAutomationRule(comparison: .below, thresholdCelsius: 40, percent: 30)
        XCTAssertTrue(evaluate([rule], temperatures: [sensor(40)]).commands.isEmpty)
        XCTAssertTrue(evaluate([rule], temperatures: [sensor(39)]).activeRuleIDs.contains(rule.id))
        XCTAssertEqual(evaluate([rule], temperatures: [sensor(41)], owned: [0], previous: [rule.id]).commands,
                       [.fixed(fanID: 0, rpm: 1470)])
        XCTAssertEqual(evaluate([rule], temperatures: [sensor(42)], owned: [0], previous: [rule.id]).commands,
                       [.automatic(fanID: 0)])
    }

    func testInvalidAndDuplicateRulesCannotRemainActiveFromPreviousEvaluation() {
        let sharedID = UUID()
        let duplicated = FanAutomationRule(id: sharedID, thresholdCelsius: 70)
        let malformed = FanAutomationRule(thresholdCelsius: .nan)
        let result = evaluate([duplicated, duplicated, malformed], temperatures: [sensor(95)],
                              owned: [0], previous: [sharedID, malformed.id])
        XCTAssertEqual(result.invalidRuleIDs, [sharedID, malformed.id])
        XCTAssertTrue(result.activeRuleIDs.isEmpty)
        XCTAssertEqual(result.commands, [.automatic(fanID: 0)])
    }

    func testDisabledRuleIsNotReactivatedByHysteresis() {
        let rule = FanAutomationRule(enabled: false, thresholdCelsius: 70)
        let result = evaluate([rule], temperatures: [sensor(95)], owned: [0], previous: [rule.id])
        XCTAssertEqual(result.commands, [.automatic(fanID: 0)])
        XCTAssertTrue(result.activeRuleIDs.isEmpty)
    }

    func testRulesAndReadingsRoundTripAndTemperatureUnitsShareCanonicalCelsius() throws {
        let rule = FanAutomationRule(sensorID: "Tp01", comparison: .below,
                                     thresholdCelsius: 45, fanID: 0, percent: 50)
        let reading = sensor("Tp01", 42)
        XCTAssertEqual(try JSONDecoder().decode(FanAutomationRule.self, from: JSONEncoder().encode(rule)), rule)
        XCTAssertEqual(try JSONDecoder().decode(TemperatureSensorReading.self, from: JSONEncoder().encode(reading)), reading)
        XCTAssertEqual(FanTemperatureUnit.fahrenheit.displayValue(forCelsius: 100), 212, accuracy: 0.0001)
        XCTAssertEqual(FanTemperatureUnit.fahrenheit.celsius(fromDisplayValue: 32), 0, accuracy: 0.0001)
        XCTAssertEqual(FanTemperatureUnit.celsius.displayValue(forCelsius: 42), 42)
    }

    func testDailyScheduleBoundariesAndOvernightWindow() {
        func permitted(_ now: Int, _ start: Int, _ end: Int) -> Bool {
            FanControlPeriod.dailySchedule.allowsControl(uptimeSeconds: 100,
                localMinuteOfDay: now, bootDelayMinutes: 0, startMinute: start, endMinute: end)
        }
        XCTAssertFalse(permitted(539, 540, 1080))
        XCTAssertTrue(permitted(540, 540, 1080))
        XCTAssertFalse(permitted(1080, 540, 1080))
        XCTAssertTrue(permitted(1380, 1320, 420))
        XCTAssertTrue(permitted(0, 1320, 420))
        XCTAssertTrue(permitted(419, 1320, 420))
        XCTAssertFalse(permitted(420, 1320, 420))
        XCTAssertFalse(permitted(800, 1320, 420))
        XCTAssertFalse(permitted(100, 100, 100))
        XCTAssertFalse(permitted(1440, 540, 1080))
    }

    func testBootDelayUsesUptimeAndRejectsInvalidScheduleInputs() {
        func permitted(_ uptime: Double, _ delay: Int) -> Bool {
            FanControlPeriod.afterBootDelay.allowsControl(uptimeSeconds: uptime,
                localMinuteOfDay: 0, bootDelayMinutes: delay, startMinute: 0, endMinute: 0)
        }
        XCTAssertFalse(permitted(599, 10))
        XCTAssertTrue(permitted(600, 10))
        XCTAssertTrue(permitted(0, 0))
        XCTAssertFalse(permitted(.nan, 10))
        XCTAssertFalse(permitted(-1, 10))
        XCTAssertFalse(permitted(500, -1))
    }
}
