import XCTest
@testable import ToolboxCore

final class SMCNumberCodecTests: XCTestCase {
    func testFloatUsesLittleEndianIEEE754() throws {
        // 2000.0f is 0x44fa0000; the SMC flt payload is little-endian.
        XCTAssertEqual(try SMCNumberCodec.decode([0x00, 0x00, 0xfa, 0x44], type: "flt "), 2000)
        XCTAssertEqual(try SMCNumberCodec.encode(2000, type: "flt "), [0x00, 0x00, 0xfa, 0x44])
        XCTAssertEqual(try SMCNumberCodec.decode([0, 0, 0x20, 0xc1], type: "flt"), -10)
    }

    func testFloatRejectsNonFinitePayloadsAndUnencodableValues() {
        XCTAssertThrowsError(try SMCNumberCodec.decode([0, 0, 0x80, 0x7f], type: "flt "))
        XCTAssertThrowsError(try SMCNumberCodec.decode([0, 0, 0xc0, 0x7f], type: "flt "))
        for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, .leastNonzeroMagnitude] {
            XCTAssertThrowsError(try SMCNumberCodec.encode(value, type: "flt "))
        }
    }

    func testFloatPreservesSignedZero() throws {
        XCTAssertEqual(try SMCNumberCodec.encode(-0.0, type: "flt "), [0, 0, 0, 0x80])
        XCTAssertEqual(try SMCNumberCodec.decode([0, 0, 0, 0x80], type: "flt ").sign, .minus)
    }

    func testFPE2UsesBigEndianQuarterRPMUnits() throws {
        XCTAssertEqual(try SMCNumberCodec.encode(2000, type: "fpe2"), [0x1f, 0x40])
        XCTAssertEqual(try SMCNumberCodec.decode([0x1f, 0x41], type: "fpe2"), 2000.25)
        XCTAssertEqual(try SMCNumberCodec.decode([0xff, 0xff], type: "fpe2"), 16383.75)
        XCTAssertEqual(try SMCNumberCodec.encode(16383.75, type: "fpe2"), [0xff, 0xff])
    }

    func testFPE2RejectsOverflowNegativeAndPrecisionLoss() {
        for value in [-0.25, 16384, 2000.1, Double.nan, .infinity] {
            XCTAssertThrowsError(try SMCNumberCodec.encode(value, type: "fpe2"))
        }
        XCTAssertThrowsError(try SMCNumberCodec.encode(2000.1, type: "fpe2")) {
            XCTAssertEqual($0 as? SMCNumberCodecError, .notRepresentable(type: "fpe2"))
        }
    }

    func testUnsignedIntegerFormatsUseExactWidthsAndBigEndian() throws {
        XCTAssertEqual(try SMCNumberCodec.encode(255, type: "ui8"), [0xff])
        XCTAssertEqual(try SMCNumberCodec.decode([2], type: "ui8 "), 2)
        XCTAssertEqual(try SMCNumberCodec.encode(0x1234, type: "ui16"), [0x12, 0x34])
        XCTAssertEqual(try SMCNumberCodec.decode([0x12, 0x34], type: "ui16"), 0x1234)
        XCTAssertEqual(try SMCNumberCodec.encode(0x12345678, type: "ui32"), [0x12, 0x34, 0x56, 0x78])
        XCTAssertEqual(try SMCNumberCodec.decode([0xff, 0xff, 0xff, 0xff], type: "ui32"), Double(UInt32.max))
    }

    func testUnsignedIntegerOverflowAndFractionsAreRejected() {
        for pair in [("ui8", 256.0), ("ui16", 65536), ("ui32", Double(UInt32.max) + 1)] {
            XCTAssertThrowsError(try SMCNumberCodec.encode(pair.1, type: pair.0))
        }
        for type in ["ui8", "ui16", "ui32"] {
            XCTAssertThrowsError(try SMCNumberCodec.encode(-1, type: type))
            XCTAssertThrowsError(try SMCNumberCodec.encode(2.5, type: type))
            XCTAssertThrowsError(try SMCNumberCodec.encode(.infinity, type: type))
        }
    }

    func testSigned78FixedPointTemperatureEncoding() throws {
        XCTAssertEqual(try SMCNumberCodec.decode([0x19, 0x80], type: "sp78"), 25.5)
        XCTAssertEqual(try SMCNumberCodec.decode([0xff, 0x80], type: "sp78"), -0.5)
        XCTAssertEqual(try SMCNumberCodec.encode(-128, type: "sp78"), [0x80, 0x00])
        XCTAssertEqual(try SMCNumberCodec.encode(127.99609375, type: "sp78"), [0x7f, 0xff])
        XCTAssertThrowsError(try SMCNumberCodec.encode(128, type: "sp78"))
        XCTAssertThrowsError(try SMCNumberCodec.encode(25.1, type: "sp78"))
    }

    func testPayloadLengthsMustMatchTypeExactly() {
        let fixtures: [(String, Int)] = [("ui8 ", 1), ("ui16", 2), ("fpe2", 2), ("sp78", 2), ("ui32", 4), ("flt ", 4)]
        for (type, length) in fixtures {
            for badLength in [0, length + 1] {
                XCTAssertThrowsError(try SMCNumberCodec.decode(Array(repeating: 0, count: badLength), type: type)) {
                    XCTAssertEqual($0 as? SMCNumberCodecError,
                                   .invalidByteCount(type: type, expected: length, actual: badLength))
                }
            }
        }
    }

    func testUnknownTypesCannotBeEncodedOrDecoded() {
        XCTAssertThrowsError(try SMCNumberCodec.encode(1, type: "ch8*")) {
            XCTAssertEqual($0 as? SMCNumberCodecError, .unsupportedType("ch8*"))
        }
        XCTAssertThrowsError(try SMCNumberCodec.decode([1], type: "")) {
            XCTAssertEqual($0 as? SMCNumberCodecError, .unsupportedType(""))
        }
    }
}
