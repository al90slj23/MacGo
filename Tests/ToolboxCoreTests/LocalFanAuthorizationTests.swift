import Foundation
import XCTest
@testable import ToolboxCore

final class LocalFanAuthorizationTests: XCTestCase {
    private let appHash = String(repeating: "a1", count: 20)
    private let helperHash = String(repeating: "b2", count: 20)
    private let generation = "b9570936-ad98-48a5-8506-c939a05c9451"
    private func record(uid: UInt32 = 501, app: String? = nil, helper: String? = nil,
                        generation: String? = nil, version: Int = 1) -> LocalFanAuthorization {
        .init(ownerUID: uid, appCDHash: app ?? appHash, helperCDHash: helper ?? helperHash,
              generation: generation ?? self.generation, schemaVersion: version)
    }

    func testBuildAndUserMustBothMatchAllowlist() throws {
        let approved = record()
        try approved.validate()
        XCTAssertTrue(approved.permits(uid: 501, appCDHash: appHash))
        XCTAssertFalse(approved.permits(uid: 502, appCDHash: appHash))
        XCTAssertFalse(approved.permits(uid: 0, appCDHash: appHash))
        XCTAssertFalse(approved.permits(uid: 501, appCDHash: helperHash))
    }

    func testMalformedHashCannotWidenCodeRequirement() {
        for hash in ["", String(repeating: "a", count: 39), String(repeating: "a", count: 41),
                     String(repeating: "A", count: 40), "a\" or true", "$(id)"] {
            XCTAssertThrowsError(try record(app: hash).validate())
            XCTAssertThrowsError(try LocalFanAuthorization.pinnedRequirement(identifier: "local.mactoolbox.app", cdHash: hash))
        }
        XCTAssertThrowsError(try LocalFanAuthorization.pinnedRequirement(identifier: "another.app", cdHash: appHash))
    }

    func testInvalidSchemaRootAndGenerationAreRejected() {
        XCTAssertThrowsError(try record(uid: 0).validate())
        XCTAssertThrowsError(try record(uid: .max).validate())
        XCTAssertThrowsError(try record(version: 2).validate())
        for generation in ["../escape", "/tmp/x", "", self.generation.uppercased()] {
            XCTAssertThrowsError(try record(generation: generation).validate())
        }
    }

    func testConfigurationRoundTripKeepsExactPins() throws {
        let original = record()
        let encoded = try PropertyListEncoder().encode(original)
        XCTAssertEqual(try PropertyListDecoder().decode(LocalFanAuthorization.self, from: encoded), original)
    }

    func testOnlyCanonicalUserApplicationLocationsAreAccepted() throws {
        try LocalFanAuthorization.validateApplicationPath("/Users/tester/Applications/Mac 工具箱.app")
        try LocalFanAuthorization.validateApplicationPath("/Users/a ' person/Applications/Mac 工具箱.app")
        for path in ["/tmp/Mac 工具箱.app", "/Applications/Mac 工具箱.app", "/Users/a/../b/Applications/Mac 工具箱.app",
                     "/Users/a/Applications/Other.app", "/Users/a/Applications/Mac 工具箱.app\n", "/Users//a/Applications/Mac 工具箱.app"] {
            XCTAssertThrowsError(try LocalFanAuthorization.validateApplicationPath(path))
        }
    }

    func testMacGoUpgradeKeepsOnlyTheTwoCanonicalAppNames() throws {
        for path in ["/Users/tester/Applications/Mac Go.app", "/Users/a ' person/Applications/Mac Go.app",
                     "/Users/tester/Applications/Mac 工具箱.app"] {
            XCTAssertNoThrow(try LocalFanAuthorization.validateApplicationPath(path))
        }
        for path in ["/Users/tester/Applications/MacGo.app", "/Users/tester/Applications/Mac Go Pro.app",
                     "/tmp/Mac Go.app", "/Applications/Mac Go.app", "/Users/tester/../other/Applications/Mac Go.app",
                     "/Users/tester/Applications/Mac Go.app/Contents", "/Users/tester/Applications/Mac Go.app\n"] {
            XCTAssertThrowsError(try LocalFanAuthorization.validateApplicationPath(path))
        }
    }

    func testShellQuotePreservesLiteralMetacharacters() throws {
        let dangerous = "a ' \" `printf INJECTED` $(printf INJECTED) $HOME\n中文"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "printf '%s' " + LocalFanAuthorization.shellQuote(dangerous)]
        let output = Pipe(); task.standardOutput = output
        try task.run(); task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), dangerous)
    }
}
