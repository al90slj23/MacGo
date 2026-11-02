import Darwin
import Foundation
import SMCController
import FanHelperProtocol

/// Fixed root-owned path. All writes are atomic and durable before SMC mutation;
/// a failed restore leaves the record in place for retry, including across crashes.
final class RecoveryJournal {
    private let path = FanRuntimeStorage.journalPath
    private let maximumBytes = 4096

    func read() throws -> SMCRecoveryState? {
        try validateRuntimeDirectory()
        // A legacy record must be restored by its validated old helper during
        // installation. Never silently abandon ownership when moving storage.
        guard try !FanRuntimeStorage.pathExists(FanRuntimeStorage.legacyJournalPath) else {
            throw JournalError.io("发现旧版风扇恢复记录；请先通过旧版服务恢复，再更新控制服务。")
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw failure("打开恢复记录")
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == 0,
              (info.st_mode & 0o077) == 0, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= maximumBytes,
              LocalFanIdentity.fileHasNoExtendedACL(descriptor) else {
            throw JournalError.invalidRecord
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), remaining)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw failure("读取恢复记录") }
            offset += count
        }
        let record = try JSONDecoder().decode(SMCRecoveryState.self, from: Data(bytes))
        guard record.fanIDs.count <= 10, Set(record.fanIDs).count == record.fanIDs.count,
              record.fanIDs.allSatisfy({ (0..<10).contains($0) }),
              !record.changedFtst || record.originalFtst == 0 || record.originalFtst == 1 else {
            throw JournalError.invalidRecord
        }
        return record
    }

    func save(_ state: SMCRecoveryState) throws {
        guard geteuid() == 0 else { throw JournalError.rootRequired }
        try validateRuntimeDirectory()
        // Replacing/removing a record must never follow a pre-existing symlink.
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFREG, existing.st_uid == 0,
                  (existing.st_mode & 0o077) == 0, existing.st_nlink == 1 else {
                throw JournalError.invalidRecord
            }
            let current = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard current >= 0 else { throw JournalError.invalidRecord }
            let noACL = LocalFanIdentity.fileHasNoExtendedACL(current)
            Darwin.close(current)
            guard noACL else { throw JournalError.invalidRecord }
        } else if errno != ENOENT { throw failure("检查恢复记录") }
        if state.fanIDs.isEmpty && !state.changedFtst {
            if unlink(path) != 0, errno != ENOENT { throw failure("清除已恢复记录") }
            return
        }
        let data = try JSONEncoder().encode(state)
        guard data.count <= maximumBytes else { throw JournalError.invalidRecord }
        let temporary = path + "." + UUID().uuidString
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failure("创建恢复记录") }
        defer { Darwin.close(descriptor); unlink(temporary) }
        guard fchmod(descriptor, 0o600) == 0, LocalFanIdentity.fileHasNoExtendedACL(descriptor) else { throw failure("保护恢复记录") }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw failure("保存恢复记录") }
            offset += count
        }
        guard fsync(descriptor) == 0, rename(temporary, path) == 0 else { throw failure("提交恢复记录") }
        let directory = open(FanRuntimeStorage.directoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory >= 0 { _ = fsync(directory); Darwin.close(directory) }
    }

    private func validateRuntimeDirectory() throws {
        try FanRuntimeStorage.prepare()
    }

    private func failure(_ action: String) -> JournalError {
        .io("\(action)失败：\(String(cString: strerror(errno)))")
    }

    enum JournalError: Error, LocalizedError {
        case invalidRecord, rootRequired, io(String)
        var errorDescription: String? {
            switch self {
            case .invalidRecord: return "风扇恢复记录无效或权限不安全；已阻止新的手动调节。"
            case .rootRequired: return "恢复记录只能由管理员辅助进程保存。"
            case .io(let message): return message
            }
        }
    }
}
