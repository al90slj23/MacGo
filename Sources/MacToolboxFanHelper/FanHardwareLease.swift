import Darwin
import Foundation
import FanHelperProtocol

/// Both service modes and the administrator recovery command share one kernel
/// lock. A launchd job disappearing does not prove that its old process has
/// finished restoring hardware; this lease does. The file is never unlinked,
/// preventing a second inode from creating a second independent lock.
final class FanHardwareLease {
    private let descriptor: Int32
    private var legacyDescriptor: Int32?
    init(timeout: TimeInterval = 0) throws {
        guard geteuid() == 0 else { throw DaemonError("风扇服务硬件锁需要管理员权限。") }
        try FanRuntimeStorage.prepare()
        // Preserve mutual exclusion while an older helper is still terminating.
        // Never create a legacy inode in a group-writable system directory.
        var legacy: Int32?
        let legacyDirectorySafe = (try? FanRuntimeStorage.validateDirectory("/private/var/run")) != nil
        if legacyDirectorySafe {
            // Also cover a draining old process that has not created its lock yet.
            legacy = try Self.acquire(path: FanRuntimeStorage.legacyLockPath, create: true, timeout: timeout)
        } else if try FanRuntimeStorage.pathExists(FanRuntimeStorage.legacyLockPath) {
            throw DaemonError("旧版风扇硬件锁位于不安全的系统运行目录，已停止更新；需先由管理员恢复旧版服务。")
        }
        do { descriptor = try Self.acquire(path: FanRuntimeStorage.lockPath, create: true, timeout: timeout) }
        catch { if let legacy { _ = flock(legacy, LOCK_UN); Darwin.close(legacy) }; throw error }
        legacyDescriptor = legacy
    }

    private static func acquire(path: String, create: Bool, timeout: TimeInterval) throws -> Int32 {
        let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT : 0)
        let file = open(path, flags, 0o600)
        guard file >= 0 else { throw DaemonError("无法打开风扇服务硬件锁。") }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == 0, (info.st_mode & 0o077) == 0, info.st_nlink == 1,
              LocalFanIdentity.fileHasNoExtendedACL(file) else {
            Darwin.close(file); throw DaemonError("风扇硬件锁权限不安全，已阻止控制。")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, min(timeout, 10))
        while flock(file, LOCK_EX | LOCK_NB) != 0 {
            guard (errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR),
                  ProcessInfo.processInfo.systemUptime < deadline else {
                Darwin.close(file); throw DaemonError("另一个 Mac Go 服务仍在操作或恢复风扇；请稍后重试。")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return file
    }
    deinit {
        _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor)
        if let legacyDescriptor { _ = flock(legacyDescriptor, LOCK_UN); Darwin.close(legacyDescriptor) }
    }
}
