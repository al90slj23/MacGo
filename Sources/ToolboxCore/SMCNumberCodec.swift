import Foundation

public enum SMCNumberCodecError: Error, Equatable, LocalizedError {
    case unsupportedType(String)
    case invalidByteCount(type: String, expected: Int, actual: Int)
    case nonFiniteValue
    case valueOutOfRange(type: String)
    case notRepresentable(type: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let type): return "不支持的 SMC 数值类型：\(type)。"
        case .invalidByteCount(let type, let expected, let actual):
            return "SMC 数据长度无效（\(type)：需要 \(expected) 字节，收到 \(actual) 字节）。"
        case .nonFiniteValue: return "SMC 数值不是有限数字。"
        case .valueOutOfRange(let type): return "数值超出了 SMC 类型 \(type) 的范围。"
        case .notRepresentable(let type): return "数值无法按 SMC 类型 \(type) 的精度表示。"
        }
    }
}

/// Codec for numeric SMC payloads only; it never opens a connection or accesses hardware.
/// Apple-silicon `flt ` payloads are little-endian IEEE Float. Fixed-point and
/// unsigned integer payloads are big-endian. Integer/fixed-point encoders reject
/// precision loss instead of truncating, rounding or clamping a requested RPM.
public enum SMCNumberCodec {
    public static func decode(_ bytes: [UInt8], type: String) throws -> Double {
        let type = canonical(type)
        let length = try byteCount(type)
        guard bytes.count == length else {
            throw SMCNumberCodecError.invalidByteCount(type: type, expected: length, actual: bytes.count)
        }
        let result: Double
        switch type {
        case "flt ":
            let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
            result = Double(Float(bitPattern: bits))
        case "fpe2": result = Double(unsignedBigEndian(bytes)) / 4
        case "ui8 ", "ui16", "ui32": result = Double(unsignedBigEndian(bytes))
        case "sp78": result = Double(Int16(bitPattern: UInt16(unsignedBigEndian(bytes)))) / 256
        default: throw SMCNumberCodecError.unsupportedType(type)
        }
        guard result.isFinite else { throw SMCNumberCodecError.nonFiniteValue }
        return result
    }

    public static func encode(_ value: Double, type: String) throws -> [UInt8] {
        let type = canonical(type)
        _ = try byteCount(type)
        guard value.isFinite else { throw SMCNumberCodecError.nonFiniteValue }
        switch type {
        case "flt ":
            let converted = Float(value)
            guard converted.isFinite else { throw SMCNumberCodecError.valueOutOfRange(type: type) }
            // Preserve all representable float values, including signed zero.
            guard value == 0 || converted != 0 else { throw SMCNumberCodecError.notRepresentable(type: type) }
            return littleEndian(converted.bitPattern)
        case "fpe2":
            let encoded = try unsigned(value, scale: 4, maximum: UInt32(UInt16.max), type: type)
            return bigEndian(encoded, count: 2)
        case "ui8 ":
            return bigEndian(try unsigned(value, scale: 1, maximum: UInt32(UInt8.max), type: type), count: 1)
        case "ui16":
            return bigEndian(try unsigned(value, scale: 1, maximum: UInt32(UInt16.max), type: type), count: 2)
        case "ui32":
            return bigEndian(try unsigned(value, scale: 1, maximum: UInt32.max, type: type), count: 4)
        case "sp78":
            let scaled = value * 256
            guard scaled >= Double(Int16.min), scaled <= Double(Int16.max) else {
                throw SMCNumberCodecError.valueOutOfRange(type: type)
            }
            guard scaled.rounded(.towardZero) == scaled else {
                throw SMCNumberCodecError.notRepresentable(type: type)
            }
            return bigEndian(UInt32(UInt16(bitPattern: Int16(scaled))), count: 2)
        default: throw SMCNumberCodecError.unsupportedType(type)
        }
    }

    private static func canonical(_ type: String) -> String {
        // Accept familiar unpadded names as well as the hardware's four-character codes.
        switch type { case "flt": return "flt "; case "ui8": return "ui8 "; default: return type }
    }

    private static func byteCount(_ type: String) throws -> Int {
        switch type {
        case "ui8 ": return 1
        case "fpe2", "ui16", "sp78": return 2
        case "flt ", "ui32": return 4
        default: throw SMCNumberCodecError.unsupportedType(type)
        }
    }

    private static func unsigned(_ value: Double, scale: Double, maximum: UInt32, type: String) throws -> UInt32 {
        let scaled = value * scale
        guard scaled >= 0, scaled <= Double(maximum) else {
            throw SMCNumberCodecError.valueOutOfRange(type: type)
        }
        guard scaled.rounded(.towardZero) == scaled else {
            throw SMCNumberCodecError.notRepresentable(type: type)
        }
        return UInt32(scaled)
    }

    private static func unsignedBigEndian(_ bytes: [UInt8]) -> UInt32 {
        bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func bigEndian(_ bits: UInt32, count: Int) -> [UInt8] {
        (0..<count).reversed().map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
    }

    private static func littleEndian(_ bits: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
    }
}
