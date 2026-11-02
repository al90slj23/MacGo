import Foundation
import IOKit
import ToolboxCore

// AppleSMC userspace packet protocol and fan-key conventions were cross-checked against
// exelban/stats, SMC/smc.swift (MIT, Copyright 2019 Serhiy Mytrovtsiy).
// The accompanying Stats-MIT.txt preserves its notice. No upstream binary is required.

public enum SMCError: Error, LocalizedError {
    case unavailable
    case connectionClosed
    case kernel(key: String, code: kern_return_t)
    case firmware(key: String, code: UInt8)
    case keyNotFound(String)
    case invalidMetadata(String)
    case rootRequired
    case unsupportedControl
    case unsupportedMode(String)
    case externalController
    case verification(String)
    case recovery(operation: String, restoration: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "此设备没有可用的 AppleSMC 接口。"
        case .connectionClosed: return "SMC 连接已关闭。"
        case let .kernel(key, code): return "读取或写入 \(key) 失败（IOKit \(code)）。"
        case let .firmware(key, code): return "SMC 拒绝 \(key) 请求（0x\(String(code, radix: 16))）。"
        case let .keyNotFound(key): return "此设备没有 \(key) 控制项。"
        case let .invalidMetadata(key): return "\(key) 的 SMC 数据格式不受支持。"
        case .rootRequired: return "调节风扇需要已授权的管理员辅助进程。"
        case .unsupportedControl: return "此版本只支持 Apple 芯片 Mac 的风扇调节。"
        case let .unsupportedMode(key): return "无法确认 \(key) 的风扇控制模式。"
        case .externalController: return "检测到其他程序正在手动控制风扇，请先在该程序中恢复系统自动控制。"
        case let .verification(message): return "风扇设置未通过读回验证：\(message)"
        case let .recovery(operation, restoration): return "\(operation)；恢复系统自动控制时也失败：\(restoration)"
        }
    }
}

struct SMCKeyValue {
    let key: String
    let type: String
    let bytes: [UInt8]
    func number() throws -> Double { try SMCNumberCodec.decode(bytes, type: type) }
}

/// Internal seam for deterministic hardware-boundary tests. Production initializers only
/// accept the real connection; callers outside this module cannot supply a fake writer.
protocol SMCTransport {
    func fanCount() throws -> Int
    func readFans() throws -> [FanReading]
    func modeKey(for fanID: Int) throws -> String
    func readValue(_ key: String) throws -> SMCKeyValue
    func writeNumber(_ number: Double, key: String) throws
}

/// Read operations require no administrator privilege. All hardware mutation is private to
/// SMCFanController, which validates the fan's measured limits and requires a root helper.
public final class SMCConnection: SMCTransport {
    private var connection: io_connect_t = 0
    private let lock = NSRecursiveLock()
    private var metadata: [String: (size: Int, type: String)] = [:]

    public init() throws {
        let device = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard device != 0 else { throw SMCError.unavailable }
        defer { IOObjectRelease(device) }
        let result = IOServiceOpen(device, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else { throw SMCError.kernel(key: "AppleSMC", code: result) }
    }

    deinit { close() }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        if connection != 0 { IOServiceClose(connection); connection = 0 }
        metadata.removeAll()
    }

    public func fanCount() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let rawCount = try readValue("FNum").number()
        guard rawCount.isFinite, rawCount.rounded() == rawCount, (0...10).contains(rawCount) else {
            throw SMCError.invalidMetadata("FNum")
        }
        return Int(rawCount)
    }

    public func readFans() throws -> [FanReading] {
        lock.lock(); defer { lock.unlock() }
        return try (0..<fanCount()).map { id in
            let prefix = "F\(id)"
            let actual = try readValue(prefix + "Ac").number()
            let minimum = try readValue(prefix + "Mn").number()
            let maximum = try readValue(prefix + "Mx").number()
            guard actual.isFinite, actual >= 0, minimum.isFinite, maximum.isFinite,
                  minimum >= 0, maximum > minimum else { throw SMCError.invalidMetadata(prefix) }
            let target = try? readValue(prefix + "Tg").number()
            let rawMode = try? readValue(modeKey(for: id)).number()
            let mode = rawMode.flatMap { $0.isFinite && (0...255).contains($0) && $0.rounded() == $0 ? Int($0) : nil }
            return FanReading(id: id, actualRPM: actual, minimumRPM: minimum, maximumRPM: maximum,
                              targetRPM: target, mode: mode)
        }
    }

    func modeKey(for fanID: Int) throws -> String {
        for key in ["F\(fanID)md", "F\(fanID)Md"] {
            do {
                let value = try readValue(key)
                guard value.type == "ui8 ", value.bytes.count == 1 else { throw SMCError.invalidMetadata(key) }
                return key
            } catch SMCError.keyNotFound { continue }
        }
        throw SMCError.keyNotFound("F\(fanID)md / F\(fanID)Md")
    }

    func readValue(_ key: String) throws -> SMCKeyValue {
        lock.lock(); defer { lock.unlock() }
        let info = try keyInfo(key)
        var packet = try request(key: key, command: 5)
        writeUInt32(UInt32(info.size), to: &packet, at: 28)
        let response = try call(packet, key: key)
        return SMCKeyValue(key: key, type: info.type, bytes: Array(response[48..<(48 + info.size)]))
    }

    func writeNumber(_ number: Double, key: String) throws {
        guard geteuid() == 0 else { throw SMCError.rootRequired }
        lock.lock(); defer { lock.unlock() }
        let info = try keyInfo(key)
        let bytes = try SMCNumberCodec.encode(number, type: info.type)
        guard bytes.count == info.size else { throw SMCError.invalidMetadata(key) }
        var packet = try request(key: key, command: 6)
        writeUInt32(UInt32(info.size), to: &packet, at: 28)
        packet.replaceSubrange(48..<(48 + bytes.count), with: bytes)
        _ = try call(packet, key: key)
    }

    private func keyInfo(_ key: String) throws -> (size: Int, type: String) {
        if let cached = metadata[key] { return cached }
        let response = try call(request(key: key, command: 9), key: key)
        let size = Int(readUInt32(response, at: 28))
        let code = readUInt32(response, at: 32)
        let chars = [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)]
        guard (1...32).contains(size), let type = String(bytes: chars, encoding: .ascii) else {
            throw SMCError.invalidMetadata(key)
        }
        metadata[key] = (size, type)
        return (size, type)
    }

    private func request(key: String, command: UInt8) throws -> [UInt8] {
        let chars = Array(key.utf8)
        guard chars.count == 4, chars.allSatisfy({ $0 < 128 }) else { throw SMCError.invalidMetadata(key) }
        var packet = [UInt8](repeating: 0, count: 80)
        let code = chars.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        writeUInt32(code, to: &packet, at: 0)
        packet[42] = command
        return packet
    }

    private func call(_ packet: [UInt8], key: String) throws -> [UInt8] {
        guard connection != 0 else { throw SMCError.connectionClosed }
        // AppleSMC's 80-byte ABI: result@40, command@42, data-size@28, payload@48.
        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = 80
        let result = packet.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer in
                IOConnectCallStructMethod(connection, 2, input.baseAddress, 80, buffer.baseAddress, &outputSize)
            }
        }
        guard result == kIOReturnSuccess else { throw SMCError.kernel(key: key, code: result) }
        guard outputSize == 80 else { throw SMCError.invalidMetadata(key) }
        if output[40] == 0x84 { throw SMCError.keyNotFound(key) }
        guard output[40] == 0 else { throw SMCError.firmware(key: key, code: output[40]) }
        return output
    }

    private func writeUInt32(_ value: UInt32, to bytes: inout [UInt8], at offset: Int) {
        for i in 0..<4 { bytes[offset + i] = UInt8((value >> (8 * i)) & 255) }
    }
    private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | (UInt32(bytes[offset + $1]) << (8 * $1)) }
    }
}

/// Single-session, bounded fan control for the bundled administrator helper. Callers must
/// serialize operations and call restoreAutomatic on disconnect, timeout, sleep and shutdown.
public struct SMCRecoveryState: Codable {
    public let fanIDs: [Int]
    public let originalFtst: Double?
    public let changedFtst: Bool
    public init(fanIDs: [Int], originalFtst: Double?, changedFtst: Bool) {
        self.fanIDs = fanIDs; self.originalFtst = originalFtst; self.changedFtst = changedFtst
    }
}

public final class SMCFanController {
    private let connection: any SMCTransport
    private let isRoot: () -> Bool
    private let sleep: (TimeInterval) -> Void
    public private(set) var touchedFanIDs = Set<Int>()
    private var originalFtst: Double?
    private var changedFtst = false
    /// The helper persists this to a root-owned recovery file before any hardware change.
    /// Throwing prevents that change; no UI-supplied paths or arbitrary keys are involved.
    public var persistRecovery: ((SMCRecoveryState) throws -> Void)?
    public var recoveryState: SMCRecoveryState {
        SMCRecoveryState(fanIDs: touchedFanIDs.sorted(), originalFtst: originalFtst, changedFtst: changedFtst)
    }

    public init(connection: SMCConnection) {
        self.connection = connection
        self.isRoot = { geteuid() == 0 }
        self.sleep = { Thread.sleep(forTimeInterval: $0) }
    }

    init(transport: any SMCTransport, isRoot: @escaping () -> Bool,
         sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.connection = transport; self.isRoot = isRoot; self.sleep = sleep
    }

    public convenience init() throws { self.init(connection: try SMCConnection()) }

    public func readFans() throws -> [FanReading] { try connection.readFans() }

    public func setFan(_ command: FanCommand) throws {
        guard isRoot() else { throw SMCError.rootRequired }
        #if !arch(arm64)
        throw SMCError.unsupportedControl
        #else
        let fanID: Int
        let requestedRPM: Double?
        switch command {
        case let .automatic(id): fanID = id; requestedRPM = nil
        case let .fixed(id, rpm): fanID = id; requestedRPM = rpm
        case let .maximum(id): fanID = id; requestedRPM = .infinity
        }
        guard let requestedRPM else {
            // Recovery cannot depend on temperature/RPM sensors or valid speed bounds.
            try FanControlPolicy.validate(fanID: fanID, fanCount: connection.fanCount())
            try restoreOne(fanID)
            touchedFanIDs.remove(fanID)
            try restoreUnlockIfIdle()
            try persistRecovery?(recoveryState)
            return
        }
        let fans = try readFans()
        try FanControlPolicy.validate(fanID: fanID, fanCount: fans.count)
        let reading = fans[fanID]
        guard !fans.contains(where: { $0.mode == 1 && !touchedFanIDs.contains($0.id) }) else {
            throw SMCError.externalController
        }
        let rpm: Double
        switch command { case .maximum: rpm = reading.maximumRPM; default: rpm = requestedRPM }
        try FanControlPolicy.validate(rpm: rpm, minimum: reading.minimumRPM, maximum: reading.maximumRPM)
        let modeKey = try connection.modeKey(for: fanID)
        let targetKey = "F\(fanID)Tg"
        let target = try connection.readValue(targetKey)
        guard ["flt ", "fpe2"].contains(target.type) else { throw SMCError.invalidMetadata(targetKey) }
        // Validate representation before entering manual mode.
        _ = try SMCNumberCodec.encode(rpm, type: target.type)
        let alreadyTouched = touchedFanIDs.contains(fanID)
        touchedFanIDs.insert(fanID)
        do { try persistRecovery?(recoveryState) }
        catch {
            if !alreadyTouched { touchedFanIDs.remove(fanID) }
            throw error
        }
        do {
            try enterManualMode(fanID, modeKey: modeKey)
            try connection.writeNumber(rpm, key: targetKey)
            try verifyRequestedState(modeKey: modeKey, targetKey: targetKey, rpm: rpm)
        } catch {
            let originalError = error
            do {
                try restoreOne(fanID)
                touchedFanIDs.remove(fanID)
                try restoreUnlockIfIdle()
                try persistRecovery?(recoveryState)
            } catch {
                throw SMCError.recovery(operation: originalError.localizedDescription, restoration: error.localizedDescription)
            }
            throw originalError
        }
        #endif
    }

    /// Restores only fans this controller changed. It never resets other utilities' fans.
    public func restoreAutomatic(fanIDs: [Int]) throws {
        guard isRoot() else { throw SMCError.rootRequired }
        var errors: [String] = []
        for id in Set(fanIDs).intersection(touchedFanIDs).sorted() {
            do { try restoreOne(id); touchedFanIDs.remove(id) }
            catch { errors.append(error.localizedDescription) }
        }
        do { try restoreUnlockIfIdle() } catch { errors.append(error.localizedDescription) }
        do { try persistRecovery?(recoveryState) } catch { errors.append(error.localizedDescription) }
        if !errors.isEmpty { throw SMCError.verification(errors.joined(separator: "；")) }
    }

    /// Recovery is only for a trusted sentinel written by the administrator helper.
    /// Every recorded ID and global flag is validated before the first write.
    public func restoreRecovery(_ state: SMCRecoveryState) throws {
        guard isRoot() else { throw SMCError.rootRequired }
        let count = try connection.fanCount()
        for id in state.fanIDs { try FanControlPolicy.validate(fanID: id, fanCount: count) }
        if state.changedFtst {
            guard let value = state.originalFtst, value == 0 || value == 1 else {
                throw SMCError.invalidMetadata("恢复记录中的 Ftst")
            }
        }
        touchedFanIDs.formUnion(state.fanIDs)
        originalFtst = state.originalFtst
        changedFtst = state.changedFtst
        try restoreAutomatic(fanIDs: state.fanIDs)
    }

    private func enterManualMode(_ fanID: Int, modeKey: String) throws {
        let directRejection: SMCError
        do {
            try connection.writeNumber(1, key: modeKey)
            // The firmware can acknowledge mode entry before publishing mode=1.
            // iFan's standalone SMC CLI likewise writes the target after this ACK.
            // Ownership is already journalled; success is still conditional on
            // both target and mode readback after the complete transaction below.
            return
        } catch let error as SMCError {
            // A firmware rejection of this mode key can mean thermalmonitord owns it.
            // Kernel transport failures and unrelated read errors must stop immediately.
            guard case let .firmware(key, _) = error, key == modeKey else { throw error }
            directRejection = error
        }
        let ftst: SMCKeyValue
        do { ftst = try connection.readValue("Ftst") }
        catch SMCError.keyNotFound(let key) where key == "Ftst" {
            // An unavailable optional fallback must not hide the actual firmware
            // rejection and its key/code behind a misleading missing-key error.
            throw directRejection
        }
        guard ftst.type == "ui8 ", ftst.bytes.count == 1 else { throw SMCError.invalidMetadata("Ftst") }
        let value = try ftst.number()
        guard value == 0 || value == 1 else { throw SMCError.invalidMetadata("Ftst") }
        if originalFtst == nil { originalFtst = value }
        if value != 1 {
            // Persist the original global flag before the write, so a killed helper can
            // restore thermal-manager ownership on its next launch.
            changedFtst = true
            try persistRecovery?(recoveryState)
            try connection.writeNumber(1, key: "Ftst")
            guard try connection.readValue("Ftst").number() == 1 else { throw SMCError.verification("Ftst 未接受控制请求") }
            sleep(3)
        }
        var lastError: Error = directRejection
        for attempt in 0..<20 {
            do {
                try connection.writeNumber(1, key: modeKey)
                return
            } catch let error as SMCError {
                guard case let .firmware(key, _) = error, key == modeKey else { throw error }
                lastError = error
            }
            if attempt < 19 { sleep(0.1) }
        }
        throw lastError
    }

    private func verifyRequestedState(modeKey: String, targetKey: String, rpm: Double) throws {
        // Both publications can lag the acknowledged transaction. Observe pairs
        // without rewriting the target, and require two consecutive confirmed
        // pairs so a single matching frame cannot hide an immediate overwrite.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        let tolerance = max(1, rpm * 0.001)
        var lastTarget: Double = 0
        var lastMode: Double = 0
        var consecutiveMatches = 0
        var observations = 0
        for attempt in 0..<40 {
            if attempt > 0, ProcessInfo.processInfo.systemUptime >= deadline { break }
            let target = try connection.readValue(targetKey)
            guard ["flt ", "fpe2"].contains(target.type) else { throw SMCError.invalidMetadata(targetKey) }
            lastTarget = try target.number()
            guard lastTarget.isFinite, lastTarget >= 0 else { throw SMCError.invalidMetadata(targetKey) }
            let mode = try connection.readValue(modeKey)
            guard mode.type == "ui8 ", mode.bytes.count == 1 else { throw SMCError.invalidMetadata(modeKey) }
            lastMode = try mode.number()
            guard lastMode == 0 || lastMode == 1 || lastMode == 3 else { throw SMCError.unsupportedMode(modeKey) }
            observations += 1
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            if lastMode == 1, abs(lastTarget - rpm) <= tolerance { consecutiveMatches += 1 }
            else { consecutiveMatches = 0 }
            if consecutiveMatches == 2 { return }
            if attempt < 39 {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if remaining <= 0 { break }
                sleep(min(0.05, remaining))
            }
        }
        throw SMCError.verification("\(modeKey) = \(lastMode)，\(targetKey) = \(lastTarget)，请求值 \(rpm)；2 秒内观察 \(observations) 次，未连续确认手动模式和目标转速")
    }

    private func restoreOne(_ fanID: Int) throws {
        let key = try connection.modeKey(for: fanID)
        try connection.writeNumber(0, key: key)
        // Mode publication can lag the accepted reset just as it can lag manual
        // entry. Write once, then retain ownership until automatic is confirmed
        // twice; recovery never depends on target/actual RPM sensor availability.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var lastMode: Double = 1
        var consecutiveMatches = 0
        var observations = 0
        for attempt in 0..<40 {
            if attempt > 0, ProcessInfo.processInfo.systemUptime >= deadline { break }
            let mode = try connection.readValue(key)
            guard mode.type == "ui8 ", mode.bytes.count == 1 else { throw SMCError.invalidMetadata(key) }
            lastMode = try mode.number()
            guard lastMode == 0 || lastMode == 1 || lastMode == 3 else { throw SMCError.unsupportedMode(key) }
            observations += 1
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            if lastMode == 0 || lastMode == 3 { consecutiveMatches += 1 }
            else { consecutiveMatches = 0 }
            if consecutiveMatches == 2 { return }
            if attempt < 39 {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if remaining <= 0 { break }
                sleep(min(0.05, remaining))
            }
        }
        throw SMCError.verification("\(key) = \(lastMode)；2 秒内观察 \(observations) 次，未连续确认自动模式")
    }

    private func restoreUnlockIfIdle() throws {
        guard touchedFanIDs.isEmpty, changedFtst, let originalFtst else { return }
        try connection.writeNumber(originalFtst, key: "Ftst")
        guard try connection.readValue("Ftst").number() == originalFtst else {
            throw SMCError.verification("Ftst 未恢复到原值")
        }
        changedFtst = false
        self.originalFtst = nil
    }
}
