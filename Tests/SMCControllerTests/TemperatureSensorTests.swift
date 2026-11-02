import Foundation
import XCTest
import ToolboxCore
@testable import SMCController

final class TemperatureSensorTests: XCTestCase {
    private func raw(_ value: Double, key: String, type: String = "flt ") throws -> SMCKeyValue {
        SMCKeyValue(key: key, type: type, bytes: try SMCNumberCodec.encode(value, type: type))
    }

    func testM4AggregationUsesOnlyRealCPUReadingsAndRetainsSensorIdentity() throws {
        let values = ["Te05": try raw(50, key: "Te05"), "Tp01": try raw(70, key: "Tp01"),
                      "Tg0G": try raw(90, key: "Tg0G"), "Tm0p": try raw(40, key: "Tm0p")]
        let captured = Date(timeIntervalSince1970: 100)
        let snapshot = SMCTemperatureCatalog.read(family: .appleM4, sampledAt: captured) { key in
            guard let value = values[key] else { throw SMCError.keyNotFound(key) }; return value
        }
        XCTAssertEqual(snapshot.cpuAverageCelsius, 60)
        XCTAssertEqual(snapshot.cpuMaximumCelsius, 70)
        XCTAssertEqual(snapshot.cpuSensorCount, 2)
        XCTAssertEqual(snapshot.sensors.map(\.id), ["Te05", "Tp01", "Tg0G", "Tm0p"])
        XCTAssertEqual(snapshot.sampledAt, captured)
        XCTAssertTrue(snapshot.failedKeys.isEmpty)
    }

    func testNoReadingsAreUnavailableRatherThanZeroOrStale() {
        let snapshot = SMCTemperatureCatalog.read(family: .appleM4, sampledAt: Date()) { throw SMCError.keyNotFound($0) }
        XCTAssertTrue(snapshot.sensors.isEmpty)
        XCTAssertNil(snapshot.cpuAverageCelsius)
        XCTAssertNil(snapshot.cpuMaximumCelsius)
        XCTAssertEqual(snapshot.cpuSensorCount, 0)
        XCTAssertEqual(snapshot.unavailableKeys.count, SMCTemperatureCatalog.descriptors(for: .appleM4).count)
        XCTAssertTrue(snapshot.failedKeys.isEmpty)
    }

    func testReadFailureIsDistinguishedFromMissingKey() throws {
        let snapshot = SMCTemperatureCatalog.read(family: .appleM4, sampledAt: Date()) { key in
            if key == "Te05" { throw SMCError.connectionClosed }
            if key == "Te0S" { return try self.raw(55, key: key) }
            throw SMCError.keyNotFound(key)
        }
        XCTAssertEqual(snapshot.failedKeys, ["Te05"])
        XCTAssertFalse(snapshot.unavailableKeys.contains("Te05"))
        XCTAssertEqual(snapshot.cpuAverageCelsius, 55)
    }

    func testWrongTypeWrongLengthAndWrongKeyCannotBecomeTemperatures() throws {
        let snapshot = SMCTemperatureCatalog.read(family: .appleM4, sampledAt: Date()) { key in
            switch key {
            case "Te05": return try self.raw(50, key: key, type: "ui8 ")
            case "Te0S": return SMCKeyValue(key: key, type: "flt ", bytes: [0, 0])
            case "Te09": return try self.raw(50, key: "F0Tg")
            case "Te0H": return try self.raw(51.25, key: key, type: "sp78")
            default: throw SMCError.keyNotFound(key)
            }
        }
        XCTAssertEqual(snapshot.failedKeys, ["Te05", "Te0S", "Te09"])
        XCTAssertEqual(snapshot.sensors.map(\.id), ["Te0H"])
        XCTAssertEqual(snapshot.cpuAverageCelsius, 51.25)
    }

    func testZeroSentinelNonFiniteAndImplausibleTemperaturesAreRejected() {
        let badValues: [Double] = [0, -1, 151, .nan, .infinity]
        let keys = ["Te05", "Te0S", "Te09", "Te0H", "Tp01"]
        let map = Dictionary(uniqueKeysWithValues: zip(keys, badValues))
        let snapshot = SMCTemperatureCatalog.read(family: .appleM4, sampledAt: Date()) { key in
            guard let value = map[key] else { throw SMCError.keyNotFound(key) }
            let bytes = withUnsafeBytes(of: Float(value).bitPattern.littleEndian, Array.init)
            return SMCKeyValue(key: key, type: "flt ", bytes: bytes)
        }
        XCTAssertEqual(snapshot.failedKeys, keys)
        XCTAssertTrue(snapshot.sensors.isEmpty)
        XCTAssertNil(snapshot.cpuAverageCelsius)
    }

    func testUnrecognisedGenerationDoesNotBorrowAnotherCPUCatalog() {
        XCTAssertEqual(SMCTemperatureCatalog.family(brand: "Apple M4 Max"), .appleM4)
        XCTAssertEqual(SMCTemperatureCatalog.family(brand: "Apple M10"), .unknown)
        XCTAssertEqual(SMCTemperatureCatalog.family(brand: "Intel(R) Core(TM) i7"), .intel)
        var attempted = 0
        let result = SMCTemperatureCatalog.read(family: .unknown, sampledAt: Date()) { key in
            attempted += 1; throw SMCError.keyNotFound(key)
        }
        XCTAssertEqual(attempted, 0)
        XCTAssertTrue(result.sensors.isEmpty)
    }

    func testKnownCatalogsAreBoundedUniqueFourCharacterTemperatureKeys() {
        for family in SMCTemperatureFamily.allCases where family != .automatic {
            let points = SMCTemperatureCatalog.descriptors(for: family)
            XCTAssertLessThanOrEqual(points.count, 64)
            XCTAssertEqual(Set(points.map(\.key)).count, points.count)
            XCTAssertTrue(points.allSatisfy { $0.key.utf8.count == 4 && $0.key.first == "T" })
        }
    }

    func testBootElapsedIncludesWallClockDurationAndRejectsFutureOrInvalidTime() {
        let boot = Date(timeIntervalSince1970: 1_000)
        let reading = SystemUptimeSnapshot.validated(bootDate: boot, now: Date(timeIntervalSince1970: 91_061))
        XCTAssertEqual(reading?.elapsedSeconds, 90_061)
        XCTAssertEqual(reading?.bootDate, boot)
        XCTAssertNil(SystemUptimeSnapshot.validated(bootDate: boot, now: Date(timeIntervalSince1970: 999)))
        XCTAssertNil(SystemUptimeSnapshot.validated(bootDate: Date(timeIntervalSince1970: .nan), now: Date()))
    }
}
