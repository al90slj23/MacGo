import Darwin
import Foundation
import Security
import ToolboxCore

/// The local development service is separate from the Apple-Team service. It
/// trusts only hashes approved by an administrator, never a bundle identifier alone.
public enum LocalFanIdentity {
    public static let serviceName = "local.mactoolbox.fan-local"
    public static let basePath = "/Library/Application Support/MacToolbox/FanControl"
    public static let configurationPath = basePath + "/authorization.plist"
    public static let launchPlistPath = "/Library/LaunchDaemons/" + serviceName + ".plist"

    public static func helperPath(for authorization: LocalFanAuthorization) throws -> String {
        try authorization.validate()
        return basePath + "/generation-" + authorization.generation + "/MacToolboxFanHelper"
    }

    public static func currentCDHash(identifier: String) throws -> String {
        var current: SecCode?
        guard SecCodeCopySelf([], &current) == errSecSuccess, let current,
              SecCodeCheckValidity(current, [], nil) == errSecSuccess else { throw Failure.invalidSignature }
        var code: SecStaticCode?
        guard SecCodeCopyStaticCode(current, [], &code) == errSecSuccess, let code else { throw Failure.invalidSignature }
        let hash = try hash(of: code, identifier: identifier)
        let requirement = try requirement(identifier: identifier, cdHash: hash)
        // Tie static metadata back to the actual running process. A changed file
        // at the same path must not approve a different executable's identity.
        guard SecCodeCheckValidity(current, [], requirement) == errSecSuccess else { throw Failure.invalidSignature }
        return hash
    }

    public static func cdHash(at url: URL, identifier: String) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { throw Failure.invalidSignature }
        return try hash(of: code, identifier: identifier)
    }

    public static func requirementString(identifier: String, cdHash: String) throws -> String {
        let string = try LocalFanAuthorization.pinnedRequirement(identifier: identifier, cdHash: cdHash)
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(string as CFString, [], &requirement) == errSecSuccess else { throw Failure.invalidSignature }
        return string
    }

    public static func loadAuthorization() throws -> LocalFanAuthorization {
        try validateRootDirectory("/Library")
        try validateRootDirectory("/Library/Application Support")
        try validateRootDirectory("/Library/Application Support/MacToolbox")
        try validateRootDirectory(basePath)
        let descriptor = open(configurationPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.notInstalled }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == 0, (info.st_mode & 0o022) == 0, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= 4096,
              fileHasNoExtendedACL(descriptor) else { throw Failure.insecureInstallation }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var offset = 0
        while offset < bytes.count {
            let remaining = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!.advanced(by: offset), remaining) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw Failure.insecureInstallation }; offset += count
        }
        let authorization = try PropertyListDecoder().decode(LocalFanAuthorization.self, from: Data(bytes))
        try authorization.validate()
        let helper = try helperPath(for: authorization)
        try validateRootDirectory((helper as NSString).deletingLastPathComponent)
        var executable = stat()
        guard lstat(helper, &executable) == 0, (executable.st_mode & S_IFMT) == S_IFREG,
              executable.st_uid == 0, (executable.st_mode & 0o022) == 0,
              (executable.st_mode & 0o111) != 0, executable.st_nlink == 1,
              pathHasNoExtendedACL(helper) else { throw Failure.insecureInstallation }
        return authorization
    }

    public static func authorizationForCurrentApp() throws -> LocalFanAuthorization {
        let approved = try loadAuthorization()
        guard approved.permits(uid: getuid(), appCDHash: try currentCDHash(identifier: FanHelperIdentity.appIdentifier)) else {
            throw Failure.updateRequired
        }
        guard try cdHash(at: URL(fileURLWithPath: helperPath(for: approved)), identifier: FanHelperIdentity.serviceName) == approved.helperCDHash else {
            throw Failure.insecureInstallation
        }
        return approved
    }

    public static func validateDaemon(_ authorization: LocalFanAuthorization) throws {
        guard geteuid() == 0,
              Bundle.main.executableURL?.path == (try helperPath(for: authorization)),
              try currentCDHash(identifier: FanHelperIdentity.serviceName) == authorization.helperCDHash else {
            throw Failure.insecureInstallation
        }
    }

    private static func hash(of code: SecStaticCode, identifier: String) throws -> String {
        guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { throw Failure.invalidSignature }
        var dictionary: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dictionary) == errSecSuccess,
              let info = dictionary as? [String: Any], info[kSecCodeInfoIdentifier as String] as? String == identifier,
              let data = info[kSecCodeInfoUnique as String] as? Data else { throw Failure.invalidSignature }
        let hash = data.map { String(format: "%02x", $0) }.joined()
        guard LocalFanAuthorization.isCDHash(hash) else { throw Failure.invalidSignature }
        return hash
    }

    private static func requirement(identifier: String, cdHash: String) throws -> SecRequirement {
        let string = try requirementString(identifier: identifier, cdHash: cdHash)
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(string as CFString, [], &parsed) == errSecSuccess, let parsed else { throw Failure.invalidSignature }
        return parsed
    }

    private static func validateRootDirectory(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == 0, (info.st_mode & 0o022) == 0,
              pathHasNoExtendedACL(path) else { throw Failure.insecureInstallation }
    }

    public static func fileHasNoExtendedACL(_ descriptor: Int32) -> Bool {
        errno = 0
        guard let acl = acl_get_fd(descriptor) else { return errno == ENOENT }
        return emptyACL(acl)
    }

    private static func pathHasNoExtendedACL(_ path: String) -> Bool {
        errno = 0
        guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        return emptyACL(acl)
    }

    private static func emptyACL(_ acl: acl_t) -> Bool {
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { return false }
        var entry: acl_entry_t?
        errno = 0
        return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1 && errno == EINVAL && entry == nil
    }

    public enum Failure: Error, LocalizedError {
        case notInstalled, updateRequired, invalidSignature, insecureInstallation
        public var errorDescription: String? {
            switch self {
            case .notInstalled: return "尚未安装本机风扇服务。"
            case .updateRequired: return "Mac Go 已更新；请重新确认本机控制服务，只授权当前版本。"
            case .invalidSignature: return "无法确认当前程序的完整代码签名，已阻止管理员安装或连接。"
            case .insecureInstallation: return "本机控制服务的文件、权限或身份不符，已阻止连接；请重新安装。"
            }
        }
    }
}
