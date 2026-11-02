import Darwin
import Foundation
import FanHelperProtocol

/// /var/run is group-writable on some supported macOS installations. Never
/// weaken that check: put persistent ownership state and the stable lock inode
/// inside a private directory below the non-writable system database directory.
enum FanRuntimeStorage {
    static let directoryPath = "/private/var/db/local.mactoolbox.fan-control"
    static let lockPath = directoryPath + "/hardware.lock"
    static let journalPath = directoryPath + "/state.json"
    static let legacyLockPath = "/var/run/local.mactoolbox.fan-hardware.lock"
    static let legacyJournalPath = "/var/run/local.mactoolbox.fan-state.json"
    private static let parentPaths = ["/private", "/private/var", "/private/var/db"]

    static func prepare() throws {
        guard geteuid() == 0 else { throw DaemonError("风扇服务运行目录需要管理员权限。") }
        for path in parentPaths { try validateDirectory(path) }
        if mkdir(directoryPath, 0o700) != 0, errno != EEXIST {
            throw DaemonError("无法创建风扇服务专用运行目录。")
        }
        try validateDirectory(directoryPath, privateOnly: true)
    }

    static func validateDirectory(_ path: String, privateOnly: Bool = false) throws {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DaemonError("无法检查风扇服务运行目录。") }
        defer { Darwin.close(descriptor) }
        var info = stat()
        let forbidden: mode_t = privateOnly ? 0o077 : 0o022
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == 0, (info.st_mode & forbidden) == 0,
              LocalFanIdentity.fileHasNoExtendedACL(descriptor) else {
            throw DaemonError("风扇服务运行目录权限不安全，已阻止控制。")
        }
    }

    static func pathExists(_ path: String) throws -> Bool {
        var info = stat()
        if lstat(path, &info) == 0 { return true }
        guard errno == ENOENT else { throw DaemonError("无法检查旧版风扇服务恢复状态。") }
        return false
    }

    /// Uses exactly the daemon's directory checks without creating a directory,
    /// opening a hardware connection, acquiring a lock or requiring root.
    static func readOnlyDiagnostics() throws -> [String: Any] {
        let parents = parentPaths.map { path in
            ["path": path, "trusted": (try? validateDirectory(path)) != nil] as [String: Any]
        }
        return ["hardwareAccessed": false, "filesystemModified": false,
                "runtimeDirectory": directoryPath, "parentDirectories": parents,
                "runtimeParentDirectoriesTrusted": parents.allSatisfy { $0["trusted"] as? Bool == true },
                "legacyRuntimeDirectoryTrusted": (try? validateDirectory("/private/var/run")) != nil,
                "legacyLockExists": try pathExists(legacyLockPath),
                "legacyRecoveryExists": try pathExists(legacyJournalPath),
                "runtimeDirectoryExists": try pathExists(directoryPath)]
    }
}
