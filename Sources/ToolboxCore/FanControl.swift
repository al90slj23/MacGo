import Foundation

/// A snapshot from the hardware reader. Mode preserves the controller's raw value:
/// normally 0 means automatic and 1 means forced. Missing keys remain nil.
public struct FanReading: Codable, Equatable, Identifiable {
    public let id: Int
    public let actualRPM: Double
    public let minimumRPM: Double
    public let maximumRPM: Double
    public let targetRPM: Double?
    public let mode: Int?

    public init(id: Int, actualRPM: Double, minimumRPM: Double, maximumRPM: Double,
                targetRPM: Double? = nil, mode: Int? = nil) {
        self.id = id
        self.actualRPM = actualRPM
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.targetRPM = targetRPM
        self.mode = mode
    }
}

public enum FanCommand: Codable, Equatable {
    case automatic(fanID: Int)
    case fixed(fanID: Int, rpm: Double)
    case maximum(fanID: Int)

    public var fanID: Int {
        switch self {
        case .automatic(let id), .fixed(let id, _), .maximum(let id): return id
        }
    }
}

public enum FanControlError: Error, Equatable, LocalizedError {
    case invalidFanCount(Int)
    case invalidFanID(Int, fanCount: Int)
    case nonFiniteRPM
    case invalidBounds
    case rpmOutOfRange(minimum: Double, maximum: Double)
    case negativeActualRPM
    case negativeTargetRPM
    case mismatchedReading(expectedFanID: Int, actualFanID: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidFanCount: return "无法确认风扇数量。"
        case .invalidFanID: return "指定的风扇不存在。"
        case .nonFiniteRPM: return "风扇转速必须为有效数字。"
        case .invalidBounds: return "硬件报告的风扇转速范围无效。"
        case .rpmOutOfRange(let minimum, let maximum):
            return "转速必须在 \(minimum)–\(maximum) RPM 范围内。"
        case .negativeActualRPM: return "硬件报告的风扇实际转速无效。"
        case .negativeTargetRPM: return "硬件报告的风扇目标转速无效。"
        case .mismatchedReading: return "风扇命令与硬件读数不匹配。"
        }
    }
}

/// Validation is shared by the interface and the privileged hardware boundary.
/// Every caller must validate again immediately before a hardware write.
public enum FanControlPolicy {
    public static func validate(rpm: Double, minimum: Double, maximum: Double) throws {
        guard rpm.isFinite else { throw FanControlError.nonFiniteRPM }
        try validateBounds(minimum: minimum, maximum: maximum)
        guard rpm >= minimum, rpm <= maximum else {
            throw FanControlError.rpmOutOfRange(minimum: minimum, maximum: maximum)
        }
    }

    public static func validate(fanID: Int, fanCount: Int) throws {
        guard fanCount > 0 else { throw FanControlError.invalidFanCount(fanCount) }
        guard fanID >= 0, fanID < fanCount else {
            throw FanControlError.invalidFanID(fanID, fanCount: fanCount)
        }
    }

    public static func validate(reading: FanReading, fanCount: Int) throws {
        try validate(fanID: reading.id, fanCount: fanCount)
        try validateBounds(minimum: reading.minimumRPM, maximum: reading.maximumRPM)
        guard reading.actualRPM.isFinite else { throw FanControlError.nonFiniteRPM }
        // A stopped or coasting fan can legitimately be below its controllable minimum.
        guard reading.actualRPM >= 0 else { throw FanControlError.negativeActualRPM }
        if let targetRPM = reading.targetRPM {
            // In automatic mode some controllers report a placeholder target of zero.
            // Observations need not satisfy manual-control bounds; write requests do.
            guard targetRPM.isFinite else { throw FanControlError.nonFiniteRPM }
            guard targetRPM >= 0 else { throw FanControlError.negativeTargetRPM }
        }
    }

    public static func validate(command: FanCommand, reading: FanReading, fanCount: Int) throws {
        try validate(fanID: command.fanID, fanCount: fanCount)
        try validate(fanID: reading.id, fanCount: fanCount)
        guard command.fanID == reading.id else {
            throw FanControlError.mismatchedReading(expectedFanID: command.fanID, actualFanID: reading.id)
        }
        switch command {
        case .automatic:
            // Restoring hardware automatic mode must remain possible even when
            // a speed/bounds read has failed. Only the fan identity is required.
            return
        case .fixed(_, let rpm):
            try validate(rpm: rpm, minimum: reading.minimumRPM, maximum: reading.maximumRPM)
        case .maximum:
            try validate(rpm: reading.maximumRPM, minimum: reading.minimumRPM, maximum: reading.maximumRPM)
        }
    }

    private static func validateBounds(minimum: Double, maximum: Double) throws {
        guard minimum.isFinite, maximum.isFinite, minimum >= 0, maximum > minimum else {
            throw FanControlError.invalidBounds
        }
    }
}
