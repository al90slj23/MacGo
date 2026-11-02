import Darwin
import Foundation
import ToolboxCore

/// Known temperature-key families. A key can change meaning between generations,
/// so an unrecognised processor never borrows another generation's CPU labels.
public enum SMCTemperatureFamily: String, CaseIterable {
    case automatic, intel, appleM1, appleM2, appleM3, appleM4, appleM5, unknown
}

public struct TemperatureSnapshot: Equatable {
    public let sensors: [TemperatureSensorReading]
    public let sampledAt: Date
    /// Absent documented keys are normal across different hardware variants.
    public let unavailableKeys: [String]
    /// Read failures and invalid metadata/values are distinct from absent keys.
    public let failedKeys: [String]

    public var cpuAverageCelsius: Double? {
        let values = cpuValues
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    public var cpuMaximumCelsius: Double? { cpuValues.max() }
    public var cpuSensorCount: Int { cpuValues.count }

    private var cpuValues: [Double] {
        sensors.filter { $0.category == .cpu && SMCTemperatureCatalog.isValid($0.celsius) }.map(\.celsius)
    }
}

public extension SMCConnection {
    /// Reads a fixed, bounded list of documented temperature keys. It never
    /// enumerates arbitrary keys, writes hardware, or substitutes zero/stale data.
    func readTemperatureSnapshot(family: SMCTemperatureFamily = .automatic) -> TemperatureSnapshot {
        SMCTemperatureCatalog.read(family: family, sampledAt: Date(), readValue: readValue)
    }

    func readTemperatureSensors(family: SMCTemperatureFamily = .automatic) -> [TemperatureSensorReading] {
        readTemperatureSnapshot(family: family).sensors
    }
}

struct SMCTemperatureDescriptor {
    let key: String
    let name: String
    let category: TemperatureSensorCategory
}

/// Key names cross-checked against exelban/stats Modules/Sensors/values.swift
/// (MIT; accompanying Stats-MIT.txt). Labels describe temperature measurement
/// points, not a promise that every point corresponds to a separate CPU core.
enum SMCTemperatureCatalog {
    static let hostFamily: SMCTemperatureFamily = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0,
              (1...256).contains(size) else { return .unknown }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return .unknown }
        return family(brand: String(cString: bytes))
    }()

    static func family(brand: String) -> SMCTemperatureFamily {
        let words = brand.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if words.contains("intel") { return .intel }
        guard words.contains("apple") else { return .unknown }
        for (name, value) in [("m1", SMCTemperatureFamily.appleM1), ("m2", .appleM2),
                              ("m3", .appleM3), ("m4", .appleM4), ("m5", .appleM5)] {
            if words.contains(name) { return value }
        }
        return .unknown
    }

    static func descriptors(for family: SMCTemperatureFamily) -> [SMCTemperatureDescriptor] {
        let resolved = family == .automatic ? hostFamily : family
        func points(_ keys: [String], _ label: String, _ category: TemperatureSensorCategory) -> [SMCTemperatureDescriptor] {
            keys.enumerated().map { SMCTemperatureDescriptor(key: $0.element, name: "\(label) \($0.offset + 1)", category: category) }
        }
        switch resolved {
        case .appleM1:
            return points(["Tp09", "Tp0T"], "CPU efficiency", .cpu)
                + points(["Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"], "CPU performance", .cpu)
                + points(["Tg05", "Tg0D", "Tg0L", "Tg0T"], "GPU", .gpu)
        case .appleM2:
            return points(["Tp1h", "Tp1t", "Tp1p", "Tp1l"], "CPU efficiency", .cpu)
                + points(["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"], "CPU performance", .cpu)
                + points(["Tg0f", "Tg0j"], "GPU", .gpu)
        case .appleM3:
            return points(["Te05", "Te0L", "Te0P", "Te0S"], "CPU efficiency", .cpu)
                + points(["Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"], "CPU performance", .cpu)
                + points(["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"], "GPU", .gpu)
        case .appleM4:
            return points(["Te05", "Te0S", "Te09", "Te0H"], "CPU efficiency", .cpu)
                + points(["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"], "CPU performance", .cpu)
                + points(["Tg0G", "Tg0H"], "GPU", .gpu)
                + points(["Tg1U", "Tg1k"], "GPU Pro/Max", .gpu)
                + points(["Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"], "GPU additional", .gpu)
                + points(["Tm0p", "Tm1p", "Tm2p"], "Memory proximity", .memory)
        case .appleM5:
            return points(["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K"], "CPU super", .cpu)
                + points(["Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"], "CPU performance", .cpu)
                + points(["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"], "GPU", .gpu)
        case .intel:
            // Use documented CPU die measurements; proximity readings are not
            // mixed into a CPU average under an interchangeable label.
            return [SMCTemperatureDescriptor(key: "TC0D", name: "CPU die", category: .cpu),
                    SMCTemperatureDescriptor(key: "TCAC", name: "CPU A die", category: .cpu),
                    SMCTemperatureDescriptor(key: "TCBC", name: "CPU B die", category: .cpu),
                    SMCTemperatureDescriptor(key: "TC0P", name: "CPU proximity", category: .other),
                    SMCTemperatureDescriptor(key: "TG0P", name: "GPU proximity", category: .other),
                    SMCTemperatureDescriptor(key: "Tm0P", name: "Memory proximity", category: .memory)]
        case .automatic, .unknown:
            return []
        }
    }

    static func isValid(_ celsius: Double) -> Bool { celsius.isFinite && celsius > 0 && celsius <= 150 }

    static func read(family: SMCTemperatureFamily, sampledAt: Date,
                     readValue: (String) throws -> SMCKeyValue) -> TemperatureSnapshot {
        var sensors: [TemperatureSensorReading] = []
        var unavailable: [String] = [], failed: [String] = []
        // This is intentionally not an unrestricted all-key scan.
        for point in descriptors(for: family).prefix(64) {
            do {
                let raw = try readValue(point.key)
                guard raw.key == point.key, raw.type == "flt " || raw.type == "sp78" else {
                    failed.append(point.key); continue
                }
                let temperature = try raw.number()
                guard isValid(temperature) else { failed.append(point.key); continue }
                sensors.append(TemperatureSensorReading(id: point.key, name: point.name,
                    celsius: temperature, category: point.category))
            } catch SMCError.keyNotFound(let key) where key == point.key {
                unavailable.append(point.key)
            } catch { failed.append(point.key) }
        }
        return TemperatureSnapshot(sensors: sensors, sampledAt: sampledAt,
            unavailableKeys: unavailable, failedKeys: failed)
    }
}
