import Darwin
import Foundation
import FanHelperProtocol
import IOKit
import IOKit.pwr_mgt
import SMCController
import SystemConfiguration
import ToolboxCore

// IOMessage.h expresses these as function-like C macros that Swift cannot import.
// iokit_common_msg(0x270 / 0x280), stable system-power notification ABI.
private let canSystemSleepMessage: UInt32 = 0xe0000270
private let systemWillSleepMessage: UInt32 = 0xe0000280

/// All SMC operations, journal updates and ownership changes run on one queue.
/// Heartbeats use a separate lock so a slow firmware transaction cannot starve them.
final class FanDaemon: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private let localAuthorization: LocalFanAuthorization?
    private let queue = DispatchQueue(label: "local.mactoolbox.fan-helper.hardware")
    private let connectionLock = NSLock()
    private var activeConnection: NSXPCConnection?
    private var activeID: UUID?
    private var activeUID: uid_t?
    private var lastHeartbeat = ProcessInfo.processInfo.systemUptime
    private let journal = RecoveryJournal()
    private var controller: SMCFanController?
    private var recoveryRecord: SMCRecoveryState?
    private var recoveryError: String?
    private var journalLoadFailure: String?
    private var controlAvailabilityError: String?
    private var watchdog: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    private var powerPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    private var powerConnection: io_connect_t = 0
    private var lastRestoreAttempt: TimeInterval = 0
    private var stopping = false
    private var hardwareLease: FanHardwareLease?

    init(localAuthorization: LocalFanAuthorization? = nil) {
        self.localAuthorization = localAuthorization
        listener = NSXPCListener(machServiceName: localAuthorization == nil
            ? FanHelperIdentity.serviceName : LocalFanIdentity.serviceName)
        super.init()
    }

    func run() throws {
        guard geteuid() == 0 else { throw DaemonError("辅助进程必须由已授权的系统服务启动。") }
        hardwareLease = try FanHardwareLease(timeout: 10)
        let requirement: String
        if let localAuthorization {
            try LocalFanIdentity.validateDaemon(localAuthorization)
            requirement = try LocalFanIdentity.requirementString(identifier: FanHelperIdentity.appIdentifier,
                                                                  cdHash: localAuthorization.appCDHash)
        } else { requirement = try FanHelperIdentity.signingRequirement(identifier: FanHelperIdentity.appIdentifier) }
        // The public XPC requirement API verifies the actual connection peer
        // before this delegate runs, without resolving a recyclable process ID.
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.delegate = self
        // This only writes hardware if an earlier explicit request left a journal.
        queue.sync {
            do { recoveryRecord = try journal.read() }
            catch { journalLoadFailure = error.localizedDescription; recordRecoveryError(error.localizedDescription) }
            if recoveryRecord != nil { _ = restoreOwned(reason: "重启恢复") }
        }
        installWatchdog()
        installSignals()
        installPowerNotifications()
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.thermallyRestricted else { return }
                _ = self.restoreOwned(reason: "系统热状态保护")
            }
        }
        listener.resume()
        RunLoop.main.run()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The listener's public signing-requirement API has already authenticated
        // the code. Bind control to the active console user, never a root client.
        var consoleUID: uid_t = 0
        var consoleGID: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &consoleUID, &consoleGID) as String?,
              name != "loginwindow", consoleUID != 0,
              connection.effectiveUserIdentifier == consoleUID else { return false }
        if let localAuthorization {
            guard connection.effectiveUserIdentifier == localAuthorization.ownerUID,
                  let requirement = try? LocalFanIdentity.requirementString(identifier: FanHelperIdentity.appIdentifier,
                                                                           cdHash: localAuthorization.appCDHash) else { return false }
            // Also enforce the same exact build on subsequent messages, including
            // after exec; the framework invalidates a connection that changes identity.
            connection.setCodeSigningRequirement(requirement)
        }
        connectionLock.lock()
        guard activeConnection == nil, !stopping else { connectionLock.unlock(); return false }
        let id = UUID()
        activeID = id
        activeUID = consoleUID
        activeConnection = connection
        lastHeartbeat = ProcessInfo.processInfo.systemUptime
        connectionLock.unlock()
        connection.exportedInterface = NSXPCInterface(with: FanHelperService.self)
        connection.exportedObject = FanSession(daemon: self, id: id)
        connection.invalidationHandler = { [weak self] in self?.disconnected(id) }
        connection.interruptionHandler = { [weak self] in self?.disconnected(id) }
        connection.resume()
        return true
    }

    func heartbeat(_ id: UUID) -> Bool {
        connectionLock.lock(); defer { connectionLock.unlock() }
        guard activeID == id, activeUID == currentConsoleUID(), !stopping else { return false }
        lastHeartbeat = ProcessInfo.processInfo.systemUptime
        return true
    }

    func ping(_ id: UUID, reply: @escaping (String?, String?) -> Void) {
        guard heartbeat(id) else { reply(nil, "辅助进程连接已失效。"); return }
        // Reply outside the hardware queue, while error status is synchronized below.
        queue.async { [weak self] in
            guard let self else { reply(nil, "辅助进程已停止。"); return }
            reply("1", self.recoveryError ?? self.controlAvailabilityError)
        }
    }

    func readings(_ id: UUID, reply: @escaping (Data?, String?) -> Void) {
        guard heartbeat(id) else { reply(nil, "辅助进程连接已失效。"); return }
        queue.async { [weak self] in
            guard let self, self.isCurrent(id) else { reply(nil, "辅助进程连接已失效。"); return }
            do { reply(try JSONEncoder().encode(self.backend().readFans()), self.recoveryError) }
            catch { reply(nil, error.localizedDescription) }
        }
    }

    func mutate(_ id: UUID, command: FanCommand, reply: @escaping (String?) -> Void) {
        guard heartbeat(id) else { reply("辅助进程连接已失效。"); return }
        queue.async { [weak self] in
            guard let self, self.isCurrent(id) else { reply("辅助进程连接已失效。"); return }
            do {
                // An unverified old recovery cannot be overwritten by a new request.
                if let failure = self.recoveryError { throw DaemonError(failure) }
                switch command {
                case .automatic: break
                case .fixed, .maximum:
                    if let failure = self.controlAvailabilityError { throw DaemonError(failure) }
                    guard !self.thermallyRestricted else { throw DaemonError("系统温度状态较高，已保持自动散热。") }
                }
                let backend = try self.backend()
                // The controller validates fresh limits for manual commands. Auto recovery
                // must remain available even if RPM or limit sensor reads are failing.
                try backend.setFan(command)
                reply(nil)
            } catch {
                // Controller also rolls back partial operations. Retry any remaining
                // ownership here; failures stay visible and keep their durable record.
                let failure = error.localizedDescription
                let restoreFailure = self.restoreOwned(reason: "操作失败恢复")
                reply([failure, restoreFailure].compactMap { $0 }.joined(separator: "；"))
            }
        }
    }

    func restore(_ id: UUID, reply: @escaping (String?) -> Void) {
        guard heartbeat(id) else { reply("辅助进程连接已失效。"); return }
        queue.async { [weak self] in
            guard let self, self.isCurrent(id) else { reply("辅助进程连接已失效。"); return }
            reply(self.restoreOwned(reason: "用户恢复"))
        }
    }

    private var thermallyRestricted: Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }

    private func backend() throws -> SMCFanController {
        if let controller { return controller }
        let created = try SMCFanController()
        created.persistRecovery = { [weak self] state in
            guard let self else { throw DaemonError("辅助进程正在停止。") }
            try self.journal.save(state)
        }
        controller = created
        return created
    }

    @discardableResult
    private func restoreOwned(reason: String) -> String? {
        lastRestoreAttempt = ProcessInfo.processInfo.systemUptime
        // An undecodable record may still describe a manually controlled fan.
        // Never overwrite or clear it using a new controller's empty ownership.
        if let journalLoadFailure { return journalLoadFailure }
        do {
            if let recoveryRecord {
                try backend().restoreRecovery(recoveryRecord)
                self.recoveryRecord = nil
            } else if let controller {
                try controller.restoreAutomatic(fanIDs: Array(controller.touchedFanIDs))
            } else if let recoveryError {
                // A malformed record cannot be discarded or replaced speculatively.
                return recoveryError
            }
            recoveryError = nil
            return nil
        } catch {
            let message = "\(reason)失败：\(error.localizedDescription)"
            recordRecoveryError(message)
            return message
        }
    }

    private func recordRecoveryError(_ message: String) {
        recoveryError = message
        NSLog("Mac Go fan helper: %@", message)
    }

    private func isCurrent(_ id: UUID) -> Bool {
        connectionLock.lock(); defer { connectionLock.unlock() }
        return activeID == id && activeUID == currentConsoleUID() && !stopping
    }

    private func disconnected(_ id: UUID) {
        connectionLock.lock()
        guard activeID == id else { connectionLock.unlock(); return }
        // Immediately invalidate queued commands. Keep the connection slot occupied
        // until restoration finishes, so a new client cannot race ownership handoff.
        activeID = nil
        connectionLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            _ = self.restoreOwned(reason: "客户端断开恢复")
            self.connectionLock.lock()
            let connection = self.activeConnection
            self.activeConnection = nil
            self.activeUID = nil
            self.connectionLock.unlock()
            connection?.invalidate()
        }
    }

    private func installWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.connectionLock.lock()
            let sessionID = self.activeID
            let ownerChanged = self.activeUID != nil && self.activeUID != self.currentConsoleUID()
            let expired = sessionID == nil || ownerChanged || ProcessInfo.processInfo.systemUptime - self.lastHeartbeat > 8
            self.connectionLock.unlock()
            if expired, let sessionID { self.disconnected(sessionID) }
            let needsRetry = self.recoveryRecord != nil || self.recoveryError != nil
            if self.thermallyRestricted || expired || needsRetry {
                if ProcessInfo.processInfo.systemUptime - self.lastRestoreAttempt >= 3 {
                    _ = self.restoreOwned(reason: "心跳或热状态保护")
                }
            }
        }
        timer.resume()
        watchdog = timer
    }

    private func currentConsoleUID() -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) != nil, uid != 0 else { return nil }
        return uid
    }

    private func installSignals() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { exit(1) }
                self.connectionLock.lock(); self.stopping = true; self.connectionLock.unlock()
                let failure = self.restoreOwned(reason: "退出恢复")
                self.listener.invalidate()
                exit(failure == nil ? 0 : 1)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func installPowerNotifications() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        powerConnection = IORegisterForSystemPower(context, &powerPort, { context, _, message, argument in
            guard let context else { return }
            let daemon = Unmanaged<FanDaemon>.fromOpaque(context).takeUnretainedValue()
            let token = Int(bitPattern: argument)
            if message == canSystemSleepMessage {
                IOAllowPowerChange(daemon.powerConnection, token)
            } else if message == systemWillSleepMessage {
                daemon.queue.async {
                    _ = daemon.restoreOwned(reason: "睡眠前恢复")
                    IOAllowPowerChange(daemon.powerConnection, token)
                }
            }
        }, &powerNotifier)
        guard powerConnection != 0, let powerPort, let source = IONotificationPortGetRunLoopSource(powerPort)?.takeUnretainedValue() else {
            // Do not silently continue with missing sleep protection.
            queue.async { [weak self] in self?.controlAvailabilityError = "无法注册系统睡眠保护，已阻止手动调节。" }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }
}

private final class FanSession: NSObject, FanHelperService {
    private weak var daemon: FanDaemon?
    private let id: UUID
    init(daemon: FanDaemon, id: UUID) { self.daemon = daemon; self.id = id }
    func ping(reply: @escaping (String?, String?) -> Void) { daemon?.ping(id, reply: reply) }
    func readings(reply: @escaping (Data?, String?) -> Void) { daemon?.readings(id, reply: reply) }
    func setFan(id: Int, rpm: Double, reply: @escaping (String?) -> Void) {
        daemon?.mutate(self.id, command: .fixed(fanID: id, rpm: rpm), reply: reply)
    }
    func maximum(id: Int, reply: @escaping (String?) -> Void) { daemon?.mutate(self.id, command: .maximum(fanID: id), reply: reply) }
    func automatic(id: Int, reply: @escaping (String?) -> Void) { daemon?.mutate(self.id, command: .automatic(fanID: id), reply: reply) }
    func restoreAll(reply: @escaping (String?) -> Void) { daemon?.restore(id, reply: reply) }
}

struct DaemonError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
