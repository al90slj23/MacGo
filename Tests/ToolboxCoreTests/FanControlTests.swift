import Foundation
import XCTest
@testable import ToolboxCore

final class FanControlTests: XCTestCase {
    func testInclusiveHardwareBoundsAreAccepted() throws {
        try FanControlPolicy.validate(rpm: 1200, minimum: 1200, maximum: 6000)
        try FanControlPolicy.validate(rpm: 6000, minimum: 1200, maximum: 6000)
        try FanControlPolicy.validate(rpm: 3500, minimum: 1200, maximum: 6000)
        try FanControlPolicy.validate(rpm: 0, minimum: 0, maximum: 6000)
    }

    func testOutOfRangeRequestsAreRejectedRatherThanClamped() {
        for rpm in [1199.999, 6000.001, -1, Double.greatestFiniteMagnitude] {
            XCTAssertThrowsError(try FanControlPolicy.validate(rpm: rpm, minimum: 1200, maximum: 6000)) {
                XCTAssertEqual($0 as? FanControlError, .rpmOutOfRange(minimum: 1200, maximum: 6000))
            }
        }
    }

    func testNonFiniteRequestsAreRejected() {
        for rpm in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try FanControlPolicy.validate(rpm: rpm, minimum: 1200, maximum: 6000)) {
                XCTAssertEqual($0 as? FanControlError, .nonFiniteRPM)
            }
        }
    }

    func testInvalidHardwareRangesAreRejected() {
        for bounds in [(0.0, 0.0), (6000, 1200), (-1, 6000), (.nan, 6000), (1200, .infinity)] {
            XCTAssertThrowsError(try FanControlPolicy.validate(rpm: 3000, minimum: bounds.0, maximum: bounds.1)) {
                XCTAssertEqual($0 as? FanControlError, .invalidBounds)
            }
        }
    }

    func testFanIdentityIsCheckedAgainstReportedCount() throws {
        try FanControlPolicy.validate(fanID: 0, fanCount: 2)
        try FanControlPolicy.validate(fanID: 1, fanCount: 2)
        for fanID in [-1, 2, Int.max] {
            XCTAssertThrowsError(try FanControlPolicy.validate(fanID: fanID, fanCount: 2)) {
                XCTAssertEqual($0 as? FanControlError, .invalidFanID(fanID, fanCount: 2))
            }
        }
        for count in [0, -1] {
            XCTAssertThrowsError(try FanControlPolicy.validate(fanID: 0, fanCount: count)) {
                XCTAssertEqual($0 as? FanControlError, .invalidFanCount(count))
            }
        }
    }

    func testStoppedFanAndAutomaticPlaceholderTargetAreValidObservations() throws {
        let reading = FanReading(id: 0, actualRPM: 0, minimumRPM: 1200, maximumRPM: 6000,
                                 targetRPM: 0, mode: 0)
        try FanControlPolicy.validate(reading: reading, fanCount: 1)
    }

    func testInvalidObservedValuesAreRejected() {
        for actual in [Double.nan, .infinity, -1] {
            XCTAssertThrowsError(try FanControlPolicy.validate(reading:
                FanReading(id: 0, actualRPM: actual, minimumRPM: 1200, maximumRPM: 6000), fanCount: 1))
        }
        for target in [Double.nan, .infinity, -1] {
            XCTAssertThrowsError(try FanControlPolicy.validate(reading:
                FanReading(id: 0, actualRPM: 2000, minimumRPM: 1200, maximumRPM: 6000,
                           targetRPM: target), fanCount: 1))
        }
    }

    func testManualCommandsUseSuppliedHardwareBounds() throws {
        let reading = FanReading(id: 0, actualRPM: 2000, minimumRPM: 1400, maximumRPM: 4800)
        try FanControlPolicy.validate(command: .fixed(fanID: 0, rpm: 2500), reading: reading, fanCount: 1)
        try FanControlPolicy.validate(command: .maximum(fanID: 0), reading: reading, fanCount: 1)
        XCTAssertThrowsError(try FanControlPolicy.validate(command: .fixed(fanID: 0, rpm: 5000),
                                                         reading: reading, fanCount: 1))
    }

    func testCommandsCannotUseAnotherFansBounds() {
        let reading = FanReading(id: 1, actualRPM: 2000, minimumRPM: 1400, maximumRPM: 4800)
        XCTAssertThrowsError(try FanControlPolicy.validate(command: .fixed(fanID: 0, rpm: 2500),
                                                         reading: reading, fanCount: 2)) {
            XCTAssertEqual($0 as? FanControlError, .mismatchedReading(expectedFanID: 0, actualFanID: 1))
        }
    }

    func testAutomaticRecoveryIsAllowedAfterFailedSpeedRead() throws {
        let reading = FanReading(id: 0, actualRPM: .nan, minimumRPM: .nan, maximumRPM: .nan)
        try FanControlPolicy.validate(command: .automatic(fanID: 0), reading: reading, fanCount: 1)
        XCTAssertThrowsError(try FanControlPolicy.validate(command: .maximum(fanID: 0),
                                                         reading: reading, fanCount: 1))
        XCTAssertThrowsError(try FanControlPolicy.validate(command: .automatic(fanID: 1),
                                                         reading: reading, fanCount: 1))
    }

    func testReadingAndCommandRoundTripThroughCodable() throws {
        let reading = FanReading(id: 0, actualRPM: 2000, minimumRPM: 1400, maximumRPM: 4800,
                                 targetRPM: 2500, mode: 1)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(FanReading.self, from: encoder.encode(reading)), reading)
        let commands: [FanCommand] = [.automatic(fanID: 0), .fixed(fanID: 0, rpm: 2500), .maximum(fanID: 1)]
        for command in commands {
            XCTAssertEqual(try decoder.decode(FanCommand.self, from: encoder.encode(command)), command)
        }
    }
}
