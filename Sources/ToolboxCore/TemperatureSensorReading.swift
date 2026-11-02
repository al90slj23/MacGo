import Foundation

public enum TemperatureSensorCategory: String, Codable, CaseIterable {
    case cpu, gpu, memory, storage, wireless, other
}

/// A real sensor observation in the canonical unit. Invalid/missing observations
/// are omitted by readers or rejected by the automation policy, never replaced
/// with zero degrees.
public struct TemperatureSensorReading: Codable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let celsius: Double
    public let category: TemperatureSensorCategory

    public init(id: String, name: String, celsius: Double,
                category: TemperatureSensorCategory = .other) {
        self.id = id; self.name = name; self.celsius = celsius; self.category = category
    }

    public var isValid: Bool {
        !id.isEmpty && celsius.isFinite && (-40...150).contains(celsius)
    }
}

public enum FanTemperatureUnit: String, Codable, CaseIterable {
    case celsius, fahrenheit

    public var symbol: String { self == .celsius ? "°C" : "°F" }

    public func displayValue(forCelsius value: Double) -> Double {
        self == .celsius ? value : value * 9 / 5 + 32
    }

    public func celsius(fromDisplayValue value: Double) -> Double {
        self == .celsius ? value : (value - 32) * 5 / 9
    }
}
