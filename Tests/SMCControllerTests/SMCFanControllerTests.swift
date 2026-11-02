import Foundation
import XCTest
import ToolboxCore
@testable import SMCController

final class SMCFanControllerTests: XCTestCase {
    private func controller(_ transport: MockSMCTransport, root: Bool = true) -> SMCFanController {
        SMCFanController(transport: transport, isRoot: { root }, sleep: { _ in })
    }

    func testNonRootCannotMutateHardware() {
        let transport = MockSMCTransport()
        let controller = controller(transport, root: false)
        XCTAssertThrowsError(try controller.setFan(.fixed(fanID: 0, rpm: 2500))) {
            guard case SMCError.rootRequired = $0 else { return XCTFail("Expected rootRequired, got \($0)") }
        }
        XCTAssertThrowsError(try controller.restoreRecovery(.init(fanIDs: [0], originalFtst: nil, changedFtst: false)))
        XCTAssertTrue(transport.events.isEmpty)
    }

    func testInvalidRPMNeverPersistsOrWrites() {
        for rpm in [Double.nan, .infinity, -.infinity, 1199, 6001] {
            let transport = MockSMCTransport()
            let controller = controller(transport)
            controller.persistRecovery = { _ in transport.events.append(.persist([], false)) }
            XCTAssertThrowsError(try controller.setFan(.fixed(fanID: 0, rpm: rpm)))
            XCTAssertFalse(transport.events.contains { if case .write = $0 { return true }; return false })
            XCTAssertFalse(transport.events.contains { if case .persist = $0 { return true }; return false })
            XCTAssertTrue(controller.touchedFanIDs.isEmpty)
        }
    }

    func testInvalidFanIDsCannotWrite() {
        for id in [-1, 1, Int.max] {
            let transport = MockSMCTransport()
            XCTAssertThrowsError(try controller(transport).setFan(.fixed(fanID: id, rpm: 2500)))
            XCTAssertTrue(transport.writes.isEmpty)
        }
    }

    func testAnotherControllersManualFanBlocksAllNewManualWrites() {
        let transport = MockSMCTransport()
        transport.fans.append(FanReading(id: 1, actualRPM: 2500, minimumRPM: 1200, maximumRPM: 6000, mode: 1))
        XCTAssertThrowsError(try controller(transport).setFan(.fixed(fanID: 0, rpm: 2500))) {
            guard case SMCError.externalController = $0 else { return XCTFail("Expected externalController, got \($0)") }
        }
        XCTAssertTrue(transport.writes.isEmpty)
    }

    func testUnrepresentableTargetIsRejectedBeforeEnteringManualMode() {
        let transport = MockSMCTransport()
        transport.values["F0Tg"] = transport.value(2000, key: "F0Tg", type: "fpe2")
        XCTAssertThrowsError(try controller(transport).setFan(.fixed(fanID: 0, rpm: 2500.1)))
        XCTAssertTrue(transport.writes.isEmpty)
    }

    func testSuccessfulCommandPersistsRecoveryBeforeFirstHardwareMutation() throws {
        let transport = MockSMCTransport()
        let controller = controller(transport)
        controller.persistRecovery = { state in transport.events.append(.persist(state.fanIDs, state.changedFtst)) }
        try controller.setFan(.fixed(fanID: 0, rpm: 2500))
        let persisted = try XCTUnwrap(transport.events.firstIndex(of: .persist([0], false)))
        let enteredManual = try XCTUnwrap(transport.events.firstIndex(of: .write("F0md", 1)))
        let wroteTarget = try XCTUnwrap(transport.events.firstIndex(of: .write("F0Tg", 2500)))
        XCTAssertLessThan(persisted, enteredManual)
        XCTAssertLessThan(enteredManual, wroteTarget)
        XCTAssertTrue(transport.events[(wroteTarget + 1)...].contains(.read("F0Tg")))
        XCTAssertTrue(transport.events[(wroteTarget + 1)...].contains(.read("F0md")))
        XCTAssertEqual(controller.touchedFanIDs, [0])
    }

    func testPersistenceFailureAbortsBeforeAnyMutation() {
        let transport = MockSMCTransport()
        let controller = controller(transport)
        controller.persistRecovery = { _ in throw InjectedFailure.failure }
        XCTAssertThrowsError(try controller.setFan(.fixed(fanID: 0, rpm: 2500)))
        XCTAssertTrue(transport.writes.isEmpty)
        XCTAssertTrue(controller.touchedFanIDs.isEmpty)
    }

    func testFailedTargetWriteRestoresAutomaticModeAndClearsRecovery() {
        let transport = MockSMCTransport()
        transport.beforeWrite = { key, _ in if key == "F0Tg" { throw InjectedFailure.failure } }
        let controller = controller(transport)
        controller.persistRecovery = { state in transport.events.append(.persist(state.fanIDs, state.changedFtst)) }
        XCTAssertThrowsError(try controller.setFan(.fixed(fanID: 0, rpm: 2500)))
        XCTAssertEqual(transport.writes, [.write("F0md", 1), .write("F0Tg", 2500), .write("F0md", 0)])
        XCTAssertEqual(transport.events.last, .persist([], false))
        XCTAssertTrue(controller.touchedFanIDs.isEmpty)
    }

    func testTargetReadbackMismatchTriggersAutomaticRecovery() {
        let transport = MockSMCTransport()
        transport.readOverrides["F0Tg"] = [2000] + Array(repeating: 2001, count: 40)
        var pauses: [TimeInterval] = []
        let controller = SMCFanController(transport: transport, isRoot: { true }, sleep: { pauses.append($0) })
        XCTAssertThrowsError(try controller.setFan(.fixed(fanID: 0, rpm: 2500))) {
            guard case SMCError.verification = $0 else { return XCTFail("Expected verification, got \($0)") }
            XCTAssertTrue($0.localizedDescription.contains("2001"))
            XCTAssertTrue($0.localizedDescription.contains("2500"))
        }
        // Forty manual observations plus two immediately matching auto-reset
        // observations use 39 manual gaps and one automatic-confirmation gap.
        XCTAssertEqual(pauses.count, 40)
        XCTAssertLessThanOrEqual(pauses.reduce(0, +), 2.01)
        XCTAssertEqual(transport.writes.filter { $0 == .write("F0Tg", 2500) }.count, 1)
        XCTAssertEqual(transport.writes.last, .write("F0md", 0))
        XCTAssertTrue(controller.touchedFanIDs.isEmpty)
    }

    func testDelayedTargetPublicationIsObservedWithoutRewritingOrEarlyReset() throws {
        let transport = MockSMCTransport()
        transport.readOverrides["F0Tg"] = [2000, 2000, 2100, 2400, 2500, 2500]
        let controller = controller(transport)
        try controller.setFan(.fixed(fanID: 0, rpm: 2500))
        XCTAssertEqual(transport.events.filter { $0 == .read("F0md") }.count, 5)
        XCTAssertEqual(transport.writes, [.write("F0md", 1), .write("F0Tg", 2500)])
        XCTAssertEqual(controller.touchedFanIDs, [0])
    }

    func testModeAndTargetMustSettleTogetherForTwoConsecutiveObservations() throws {
        let transport = MockSMCTransport()
        transport.readOverrides["F0md"] = [0, 1, 1, 1, 1]
        transport.readOverrides["F0Tg"] = [2000, 2500, 2500, 2400, 2500, 2500]
        let controller = controller(transport)
        try controller.setFan(.fixed(fanID: 0, rpm: 2500))
        XCTAssertEqual(transport.events.filter { $0 == .read("F0md") }.count, 5)
        XCTAssertEqual(transport.writes.filter { $0 == .write("F0Tg", 2500) }.count, 1)
        XCTAssertFalse(transport.writes.contains(.write("F0md", 0)))
    }

    func testOneMatchingFrameDoesNotConfirmAReplacedTarget() {
        let transport = MockSMCTransport()
        transport.readOverrides["F0Tg"] = [2000, 2500] + Array(repeating: 2600, count: 39)
        let controller = controller(transport)
        XCTAssertThrowsError(try controller.setFan(.fixed(fanID: 0, rpm: 2500))) {
            guard case SMCError.verification = $0 else { return XCTFail("Expected verification, got \($0)") }
        }
        XCTAssertEqual(transport.writes.last, .write("F0md", 0))
        XCTAssertTrue(controller.touchedFanIDs.isEmpty)
    }

    func testInvalidTargetFramesFailImmediatelyRatherThanSettling() {
        let invalidFrames = [
            SMCKeyValue(key: "F0Tg", type: "flt ", bytes: [0, 0, 128, 127]), // infinity
            SMCKeyValue(key: "F0Tg", type: "flt ", bytes: [0, 0, 128, 191]), // -1
            SMCKeyValue(key: "F0Tg", type: "flt ", bytes: [0]),
            SMCKeyValue(key: "F0Tg", type: "ui8 ", bytes: [1])
        ]
        for invalid in invalidFrames {
            let transport = MockSMCTransport()
            transport.afterWrite = { [unowned transport] key, _ in
                if key == "F0Tg" { transport.values[key] = invalid }
            }
            var pauses: [TimeInterval] = []
            let controller = SMCFanController(transport: transport, isRoot: { true }, sleep: { pauses.append($0) })
            XCTAssertThrowsError(try controller.setFan(.fixed(fanID: 0, rpm: 2500)))
            XCTAssertEqual(pauses, [0.05]) // only the verified auto-reset gap
            XCTAssertEqual(transport.events.filter { $0 == .read("F0Tg") }.count, 2)
            XCTAssertEqual(transport.writes.last, .write("F0md", 0))
            XCTAssertTrue(controller.touchedFanIDs.isEmpty)
        }
    }

    func testUnknownFinalModeFailsImmediatelyRatherThanSettling() {
        let transport = MockSMCTransport()
        transport.readOverrides["F0md"] = [2]
        var pauses: [TimeInterval] = []
        let controller = SMCFanController(transport: transport, isRoot: { true }, sleep: { pauses.append($0) })
        XCTAssertThrowsError(try controller.setFan(.fixed(fanID: 0, rpm: 2500))) {
            guard case SMCError.unsupportedMode = $0 else { return XCTFail("Expected unsupported mode, got \($0)") }
        }
        XCTAssertEqual(pauses, [0.05]) // only the verified auto-reset gap
        XCTAssertEqual(transport.writes.last, .write("F0md", 0))
    }

    func testTargetTransportFailureFailsImmediatelyRatherThanSettling() {
        let transport = MockSMCTransport()
        var targetWritten = false
        transport.afterWrite = { key, _ in if key == "F0Tg" { targetWritten = true } }
        transport.beforeRead = { key in
            if key == "F0Tg", targetWritten { throw SMCError.kernel(key: key, code: -1) }
        }
        var pauses: [TimeInterval] = []
        let controller = SMCFanController(transport: transport, isRoot: { true }, sleep: { pauses.append($0) })
        XCTAssertThrowsError(try controller.setFan(.fixed(fanID: 0, rpm: 2500))) {
            guard case let SMCError.kernel(key, code) = $0 else { return XCTFail("Expected transport failure, got \($0)") }
            XCTAssertEqual(key, "F0Tg"); XCTAssertEqual(code, -1)
        }
        XCTAssertEqual(pauses, [0.05]) // only the verified auto-reset gap
        XCTAssertEqual(transport.writes.last, .write("F0md", 0))
    }

    func testFinalModeReadbackIsVerifiedAndRecovered() {
        let transport = MockSMCTransport()
        transport.readOverrides["F0md"] = Array(repeating: 0, count: 40)
        let controller = controller(transport)
        controller.persistRecovery = { state in transport.events.append(.persist(state.fanIDs, state.changedFtst)) }
        XCTAssertThrowsError(try controller.setFan(.fixed(fanID: 0, rpm: 2500))) {
            guard case SMCError.verification = $0 else { return XCTFail("Expected verification, got \($0)") }
        }
        XCTAssertEqual(transport.events.filter { $0 == .read("F0md") }.count, 42)
        XCTAssertEqual(transport.writes.last, .write("F0md", 0))
        XCTAssertEqual(transport.events.last, .persist([], false))
        XCTAssertTrue(controller.touchedFanIDs.isEmpty)
    }

    func testModeAcceptedBeforeTargetCanPublishManualModeWithoutFtst() throws {
        let transport = MockSMCTransport()
        transport.afterWrite = { [unowned transport] key, number in
            if key == "F0md", number == 1 {
                transport.values[key] = transport.value(0, key: key, type: "ui8 ")
            } else if key == "F0Tg" {
                transport.values["F0md"] = transport.value(1, key: "F0md", type: "ui8 ")
            }
        }
        let controller = controller(transport)
        controller.persistRecovery = { state in transport.events.append(.persist(state.fanIDs, state.changedFtst)) }
        try controller.setFan(.fixed(fanID: 0, rpm: 2500))
        let targetWrite = try XCTUnwrap(transport.events.firstIndex(of: .write("F0Tg", 2500)))
        let modeRead = try XCTUnwrap(transport.events.firstIndex(of: .read("F0md")))
        XCTAssertLessThan(targetWrite, modeRead)
        XCTAssertFalse(transport.events.contains(.read("Ftst")))
        XCTAssertEqual(transport.events.first(where: { if case .persist = $0 { return true }; return false }), .persist([0], false))
        XCTAssertEqual(controller.recoveryState.fanIDs, [0])
        XCTAssertFalse(controller.recoveryState.changedFtst)
    }

    func testModePublicationCanBeDelayedButRequiresVerifiedTargetAtCompletion() throws {
        let transport = MockSMCTransport()
        transport.readOverrides["F0md"] = [0, 0, 1]
        let controller = controller(transport)
        try controller.setFan(.fixed(fanID: 0, rpm: 2500))
        XCTAssertEqual(transport.events.filter { $0 == .read("F0md") }.count, 4)
        XCTAssertEqual(transport.events.last, .read("F0md"))
        XCTAssertFalse(transport.events.contains(.read("Ftst")))
    }

    func testTargetChangedWhileModeWasPublishingStillFailsAndRestores() {
        let transport = MockSMCTransport()
        transport.readOverrides["F0md"] = [0, 1]
        transport.readOverrides["F0Tg"] = [2000, 2500] + Array(repeating: 2600, count: 39)
        let controller = controller(transport)
        XCTAssertThrowsError(try controller.setFan(.fixed(fanID: 0, rpm: 2500))) {
            guard case SMCError.verification = $0 else { return XCTFail("Expected verification, got \($0)") }
        }
        XCTAssertEqual(transport.writes.last, .write("F0md", 0))
        XCTAssertTrue(controller.touchedFanIDs.isEmpty)
    }

    func testFirmwareModeRejectionWithoutFtstPreservesOriginalError() {
        let transport = MockSMCTransport()
        transport.beforeWrite = { key, number in
            if key == "F0md", number == 1 { throw SMCError.firmware(key: key, code: 0x85) }
        }
        let controller = controller(transport)
        XCTAssertThrowsError(try controller.setFan(.fixed(fanID: 0, rpm: 2500))) {
            guard case let SMCError.firmware(key, code) = $0 else { return XCTFail("Expected original firmware rejection, got \($0)") }
            XCTAssertEqual(key, "F0md"); XCTAssertEqual(code, 0x85)
        }
        XCTAssertTrue(transport.events.contains(.read("Ftst")))
        XCTAssertFalse(transport.writes.contains(.write("F0Tg", 2500)))
        XCTAssertFalse(transport.writes.contains(.write("Ftst", 1)))
        XCTAssertTrue(controller.touchedFanIDs.isEmpty)
    }

    func testExplicitModeRejectionCanUseJournalledFtstAndRestoreBoth() throws {
        let transport = MockSMCTransport()
        transport.values["Ftst"] = transport.value(0, key: "Ftst", type: "ui8 ")
        transport.beforeWrite = { [unowned transport] key, number in
            if key == "F0md", number == 1,
               try transport.values["Ftst"]?.number() == 0 {
                throw SMCError.firmware(key: key, code: 0x85)
            }
        }
        let controller = controller(transport)
        controller.persistRecovery = { state in transport.events.append(.persist(state.fanIDs, state.changedFtst)) }
        try controller.setFan(.fixed(fanID: 0, rpm: 2500))
        let globalPersist = try XCTUnwrap(transport.events.firstIndex(of: .persist([0], true)))
        let globalWrite = try XCTUnwrap(transport.events.firstIndex(of: .write("Ftst", 1)))
        let targetWrite = try XCTUnwrap(transport.events.firstIndex(of: .write("F0Tg", 2500)))
        XCTAssertLessThan(globalPersist, globalWrite)
        XCTAssertLessThan(globalWrite, targetWrite)
        XCTAssertTrue(controller.recoveryState.changedFtst)
        try controller.restoreAutomatic(fanIDs: [0])
        let modeReset = try XCTUnwrap(transport.events.firstIndex(of: .write("F0md", 0)))
        let globalReset = try XCTUnwrap(transport.events.firstIndex(of: .write("Ftst", 0)))
        XCTAssertLessThan(modeReset, globalReset)
        XCTAssertEqual(transport.events.last, .persist([], false))
        XCTAssertFalse(controller.recoveryState.changedFtst)
    }

    func testUnconfirmedFinalModeAndFailedResetKeepRecoveryJournal() {
        let transport = MockSMCTransport()
        transport.readOverrides["F0md"] = Array(repeating: 0, count: 40)
        transport.beforeWrite = { key, number in
            if key == "F0md", number == 0 { throw InjectedFailure.failure }
        }
        let controller = controller(transport)
        var persisted: [[Int]] = []
        controller.persistRecovery = { state in persisted.append(state.fanIDs) }
        XCTAssertThrowsError(try controller.setFan(.fixed(fanID: 0, rpm: 2500))) {
            guard case SMCError.recovery = $0 else { return XCTFail("Expected combined recovery error, got \($0)") }
        }
        XCTAssertEqual(controller.recoveryState.fanIDs, [0])
        XCTAssertEqual(persisted, [[0]])
    }

    func testAutomaticRecoveryDoesNotDependOnSpeedReads() throws {
        let transport = MockSMCTransport()
        let controller = controller(transport)
        try controller.setFan(.fixed(fanID: 0, rpm: 2500))
        transport.failSpeedReads = true
        transport.events.removeAll()
        try controller.setFan(.automatic(fanID: 0))
        XCTAssertFalse(transport.events.contains(.readFans))
        XCTAssertEqual(transport.writes, [.write("F0md", 0)])
        XCTAssertTrue(controller.touchedFanIDs.isEmpty)
    }

    func testDelayedAutomaticPublicationWritesOnceAndClearsJournalAfterTwoConfirmations() throws {
        for automaticMode: Double in [0, 3] {
            let transport = MockSMCTransport()
            let controller = controller(transport)
            controller.persistRecovery = { state in transport.events.append(.persist(state.fanIDs, state.changedFtst)) }
            try controller.setFan(.fixed(fanID: 0, rpm: 2500))
            transport.events.removeAll()
            transport.readOverrides["F0md"] = [1, 1, automaticMode, automaticMode]
            try controller.setFan(.automatic(fanID: 0))
            XCTAssertEqual(transport.writes, [.write("F0md", 0)])
            XCTAssertEqual(transport.events.filter { $0 == .read("F0md") }.count, 4)
            XCTAssertFalse(transport.events.contains(.read("F0Tg")))
            XCTAssertEqual(transport.events.last, .persist([], false))
            XCTAssertTrue(controller.touchedFanIDs.isEmpty)
        }
    }

    func testAutomaticTimeoutKeepsExistingJournalAndReportsLastMode() throws {
        let transport = MockSMCTransport()
        var pauses: [TimeInterval] = []
        let controller = SMCFanController(transport: transport, isRoot: { true }, sleep: { pauses.append($0) })
        var persisted: [[Int]] = []
        controller.persistRecovery = { state in persisted.append(state.fanIDs) }
        try controller.setFan(.fixed(fanID: 0, rpm: 2500))
        transport.events.removeAll(); pauses.removeAll()
        transport.readOverrides["F0md"] = Array(repeating: 1, count: 40)
        XCTAssertThrowsError(try controller.setFan(.automatic(fanID: 0))) {
            guard case SMCError.verification = $0 else { return XCTFail("Expected reset timeout, got \($0)") }
            XCTAssertTrue($0.localizedDescription.contains("F0md = 1"))
            XCTAssertTrue($0.localizedDescription.contains("40"))
        }
        XCTAssertEqual(transport.writes, [.write("F0md", 0)])
        XCTAssertEqual(transport.events.filter { $0 == .read("F0md") }.count, 40)
        XCTAssertEqual(pauses.count, 39)
        XCTAssertLessThanOrEqual(pauses.reduce(0, +), 2)
        XCTAssertEqual(controller.recoveryState.fanIDs, [0])
        XCTAssertEqual(persisted, [[0]])
    }

    func testOneAutomaticFrameCannotClearJournalIfManualModeReturns() throws {
        let transport = MockSMCTransport()
        let controller = controller(transport)
        try controller.setFan(.fixed(fanID: 0, rpm: 2500))
        transport.events.removeAll()
        transport.readOverrides["F0md"] = [0] + Array(repeating: 1, count: 39)
        XCTAssertThrowsError(try controller.setFan(.automatic(fanID: 0)))
        XCTAssertEqual(transport.writes, [.write("F0md", 0)])
        XCTAssertEqual(controller.recoveryState.fanIDs, [0])
    }

    func testAutomaticReadTransportFailureFailsImmediatelyAndKeepsJournal() throws {
        let transport = MockSMCTransport()
        var pauses: [TimeInterval] = []
        let controller = SMCFanController(transport: transport, isRoot: { true }, sleep: { pauses.append($0) })
        var persisted: [[Int]] = []
        controller.persistRecovery = { state in persisted.append(state.fanIDs) }
        try controller.setFan(.fixed(fanID: 0, rpm: 2500))
        transport.events.removeAll(); pauses.removeAll()
        transport.beforeRead = { key in
            if key == "F0md" { throw SMCError.kernel(key: key, code: -1) }
        }
        XCTAssertThrowsError(try controller.setFan(.automatic(fanID: 0))) {
            guard case let SMCError.kernel(key, code) = $0 else { return XCTFail("Expected transport failure, got \($0)") }
            XCTAssertEqual(key, "F0md"); XCTAssertEqual(code, -1)
        }
        XCTAssertTrue(pauses.isEmpty)
        XCTAssertEqual(transport.writes, [.write("F0md", 0)])
        XCTAssertEqual(transport.events.filter { $0 == .read("F0md") }.count, 1)
        XCTAssertEqual(controller.recoveryState.fanIDs, [0])
        XCTAssertEqual(persisted, [[0]])
    }

    func testUnknownAutomaticReadbackFailsImmediatelyAndKeepsJournal() throws {
        let transport = MockSMCTransport()
        var pauses: [TimeInterval] = []
        let controller = SMCFanController(transport: transport, isRoot: { true }, sleep: { pauses.append($0) })
        try controller.setFan(.fixed(fanID: 0, rpm: 2500))
        transport.events.removeAll(); pauses.removeAll()
        transport.readOverrides["F0md"] = [2]
        XCTAssertThrowsError(try controller.setFan(.automatic(fanID: 0))) {
            guard case SMCError.unsupportedMode = $0 else { return XCTFail("Expected unsupported mode, got \($0)") }
        }
        XCTAssertTrue(pauses.isEmpty)
        XCTAssertEqual(controller.recoveryState.fanIDs, [0])
    }

    func testInvalidAutomaticMetadataFailsImmediatelyAndKeepsJournal() throws {
        let transport = MockSMCTransport()
        var pauses: [TimeInterval] = []
        let controller = SMCFanController(transport: transport, isRoot: { true }, sleep: { pauses.append($0) })
        try controller.setFan(.fixed(fanID: 0, rpm: 2500))
        transport.events.removeAll(); pauses.removeAll()
        transport.afterWrite = { [unowned transport] key, number in
            if key == "F0md", number == 0 { transport.values[key] = transport.value(0, key: key, type: "flt ") }
        }
        XCTAssertThrowsError(try controller.setFan(.automatic(fanID: 0))) {
            guard case SMCError.invalidMetadata = $0 else { return XCTFail("Expected invalid metadata, got \($0)") }
        }
        XCTAssertTrue(pauses.isEmpty)
        XCTAssertEqual(transport.writes, [.write("F0md", 0)])
        XCTAssertEqual(controller.recoveryState.fanIDs, [0])
    }

    func testFailedAutomaticResetKeepsFanInRecoveryState() {
        let transport = MockSMCTransport()
        transport.beforeWrite = { key, value in
            if key == "F0Tg" || (key == "F0md" && value == 0) { throw InjectedFailure.failure }
        }
        let controller = controller(transport)
        var persisted: [[Int]] = []
        controller.persistRecovery = { state in persisted.append(state.fanIDs) }
        XCTAssertThrowsError(try controller.setFan(.fixed(fanID: 0, rpm: 2500))) {
            guard case SMCError.recovery = $0 else { return XCTFail("Expected combined recovery error, got \($0)") }
        }
        XCTAssertEqual(controller.recoveryState.fanIDs, [0])
        XCTAssertEqual(persisted, [[0]])
    }

    func testAutomaticResetMustPassReadbackBeforeClearingSentinel() {
        let transport = MockSMCTransport()
        transport.beforeWrite = { key, _ in if key == "F0Tg" { throw InjectedFailure.failure } }
        transport.readOverrides["F0md"] = Array(repeating: 1, count: 40)
        let controller = controller(transport)
        var persisted: [[Int]] = []
        controller.persistRecovery = { state in persisted.append(state.fanIDs) }
        XCTAssertThrowsError(try controller.setFan(.fixed(fanID: 0, rpm: 2500)))
        XCTAssertEqual(transport.writes.last, .write("F0md", 0))
        XCTAssertEqual(controller.recoveryState.fanIDs, [0])
        XCTAssertEqual(persisted, [[0]])
    }

    func testRestoreRecoveryClearsSentinelOnlyAfterVerifiedFanAndGlobalReset() throws {
        let transport = MockSMCTransport()
        transport.values["Ftst"] = transport.value(1, key: "Ftst", type: "ui8 ")
        let controller = controller(transport)
        controller.persistRecovery = { state in transport.events.append(.persist(state.fanIDs, state.changedFtst)) }
        try controller.restoreRecovery(.init(fanIDs: [0], originalFtst: 0, changedFtst: true))
        let fanReset = try XCTUnwrap(transport.events.firstIndex(of: .write("F0md", 0)))
        let globalReset = try XCTUnwrap(transport.events.firstIndex(of: .write("Ftst", 0)))
        let cleared = try XCTUnwrap(transport.events.firstIndex(of: .persist([], false)))
        XCTAssertLessThan(fanReset, globalReset)
        XCTAssertLessThan(globalReset, cleared)
        XCTAssertEqual(transport.events.last, .persist([], false))
        XCTAssertFalse(controller.recoveryState.changedFtst)
    }

    func testFailedGlobalResetRetainsSentinelUntilLaterSuccessfulRetry() throws {
        let transport = MockSMCTransport()
        transport.values["Ftst"] = transport.value(1, key: "Ftst", type: "ui8 ")
        transport.beforeWrite = { key, _ in if key == "Ftst" { throw InjectedFailure.failure } }
        let controller = controller(transport)
        controller.persistRecovery = { state in transport.events.append(.persist(state.fanIDs, state.changedFtst)) }
        XCTAssertThrowsError(try controller.restoreRecovery(.init(fanIDs: [0], originalFtst: 0, changedFtst: true)))
        XCTAssertTrue(controller.recoveryState.changedFtst)
        XCTAssertEqual(controller.recoveryState.originalFtst, 0)
        XCTAssertEqual(transport.events.last, .persist([], true))
        transport.beforeWrite = nil
        try controller.restoreAutomatic(fanIDs: [])
        XCTAssertEqual(transport.events.last, .persist([], false))
        XCTAssertFalse(controller.recoveryState.changedFtst)
    }

    func testMalformedRecoveryStateIsRejectedBeforeAnyWrite() {
        let states = [
            SMCRecoveryState(fanIDs: [0, 4], originalFtst: nil, changedFtst: false),
            SMCRecoveryState(fanIDs: [0], originalFtst: nil, changedFtst: true),
            SMCRecoveryState(fanIDs: [0], originalFtst: 2, changedFtst: true)
        ]
        for state in states {
            let transport = MockSMCTransport()
            XCTAssertThrowsError(try controller(transport).restoreRecovery(state))
            XCTAssertTrue(transport.writes.isEmpty)
        }
    }

    func testKernelModeWriteFailureDoesNotAttemptGlobalUnlock() {
        let transport = MockSMCTransport()
        transport.beforeWrite = { key, value in
            if key == "F0md", value == 1 { throw SMCError.kernel(key: key, code: -1) }
        }
        XCTAssertThrowsError(try controller(transport).setFan(.fixed(fanID: 0, rpm: 2500)))
        XCTAssertFalse(transport.events.contains(.read("Ftst")))
        XCTAssertFalse(transport.writes.contains { if case .write("Ftst", _) = $0 { return true }; return false })
    }
}

private enum InjectedFailure: Error { case failure }

private final class MockSMCTransport: SMCTransport {
    enum Event: Equatable {
        case readFans
        case read(String)
        case write(String, Double)
        case persist([Int], Bool)
    }
    var fans = [FanReading(id: 0, actualRPM: 2000, minimumRPM: 1200, maximumRPM: 6000, targetRPM: 2000, mode: 0)]
    var values: [String: SMCKeyValue] = [:]
    var readOverrides: [String: [Double]] = [:]
    var events: [Event] = []
    var failSpeedReads = false
    var beforeWrite: ((String, Double) throws -> Void)?
    var afterWrite: ((String, Double) -> Void)?
    var beforeRead: ((String) throws -> Void)?
    var writes: [Event] { events.filter { if case .write = $0 { return true }; return false } }

    init() {
        values["F0md"] = value(0, key: "F0md", type: "ui8 ")
        values["F0Tg"] = value(2000, key: "F0Tg")
    }
    func fanCount() throws -> Int { fans.count }
    func readFans() throws -> [FanReading] {
        events.append(.readFans)
        if failSpeedReads { throw InjectedFailure.failure }
        return fans
    }
    func modeKey(for fanID: Int) throws -> String { "F\(fanID)md" }
    func readValue(_ key: String) throws -> SMCKeyValue {
        events.append(.read(key))
        try beforeRead?(key)
        guard let stored = values[key] else { throw SMCError.keyNotFound(key) }
        if var remaining = readOverrides[key], !remaining.isEmpty {
            let number = remaining.removeFirst()
            readOverrides[key] = remaining
            return value(number, key: key, type: stored.type)
        }
        return stored
    }
    func writeNumber(_ number: Double, key: String) throws {
        events.append(.write(key, number))
        try beforeWrite?(key, number)
        guard let stored = values[key] else { throw SMCError.keyNotFound(key) }
        values[key] = SMCKeyValue(key: key, type: stored.type, bytes: try SMCNumberCodec.encode(number, type: stored.type))
        afterWrite?(key, number)
    }
    func value(_ number: Double, key: String, type: String = "flt ") -> SMCKeyValue {
        // Test fixtures always use known, representable constants.
        SMCKeyValue(key: key, type: type, bytes: try! SMCNumberCodec.encode(number, type: type))
    }
}
