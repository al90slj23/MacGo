import Foundation
import Security

/// A deliberately closed interface: the privileged process never accepts paths,
/// shell commands, or arbitrary SMC keys supplied by the app.
@objc public protocol FanHelperService {
    func ping(reply: @escaping (String?, String?) -> Void)
    func readings(reply: @escaping (Data?, String?) -> Void)
    func setFan(id: Int, rpm: Double, reply: @escaping (String?) -> Void)
    func maximum(id: Int, reply: @escaping (String?) -> Void)
    func automatic(id: Int, reply: @escaping (String?) -> Void)
    func restoreAll(reply: @escaping (String?) -> Void)
}

public enum FanHelperIdentity {
    public static let serviceName = "local.mactoolbox.fan-helper"
    public static let plistName = "local.mactoolbox.fan-helper.plist"
    public static let appIdentifier = "local.mactoolbox.app"

    /// The same code is used by the app to authenticate the helper and by the
    /// helper to authenticate the app. Ad-hoc builds are explicitly unsupported.
    public static func signingRequirement(identifier: String) throws -> String {
        guard !identifier.isEmpty,
              identifier.utf8.allSatisfy({ $0 == 45 || $0 == 46 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            throw IdentityError.invalidIdentifier
        }
        let team = try currentTeamIdentifier()
        let requirement = "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess else {
            throw IdentityError.invalidRequirement
        }
        return requirement
    }

    public static func currentTeamIdentifier() throws -> String {
        guard let url = Bundle.main.executableURL else { throw IdentityError.missingExecutable }
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard created == errSecSuccess, let code else { throw IdentityError.invalidSignature(created) }
        let checked = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        guard checked == errSecSuccess else { throw IdentityError.invalidSignature(checked) }
        var information: CFDictionary?
        let result = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        guard result == errSecSuccess, let data = information as? [String: Any],
              let team = data[kSecCodeInfoTeamIdentifier as String] as? String,
              team.count == 10,
              team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else {
            throw IdentityError.teamSignatureRequired
        }
        // A TeamIdentifier alone is not enough: require an Apple-anchored signature.
        let ownRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(ownRequirement as CFString, [], &parsed) == errSecSuccess,
              SecStaticCodeCheckValidity(code, [], parsed) == errSecSuccess else {
            throw IdentityError.teamSignatureRequired
        }
        return team
    }

    public enum IdentityError: Error, LocalizedError {
        case invalidIdentifier, invalidRequirement, missingExecutable, teamSignatureRequired
        case invalidSignature(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .invalidIdentifier: return "辅助进程标识无效。"
            case .invalidRequirement: return "辅助进程签名条件无效。"
            case .missingExecutable: return "找不到当前可执行程序。"
            case .invalidSignature(let status): return "签名验证失败（\(status)）。"
            case .teamSignatureRequired:
                return "风扇调节需要同一 Apple 开发者团队签名的主程序和辅助进程；临时签名版本只支持读取。"
            }
        }
    }
}
