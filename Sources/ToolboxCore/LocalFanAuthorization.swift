import Foundation

/// An administrator-approved, build-specific allowlist. These values never come
/// from an XPC request; the daemon loads them from its root-owned configuration.
public struct LocalFanAuthorization: Codable, Equatable {
    public let schemaVersion: Int
    public let ownerUID: UInt32
    public let appCDHash: String
    public let helperCDHash: String
    public let generation: String

    public init(ownerUID: UInt32, appCDHash: String, helperCDHash: String, generation: String,
                schemaVersion: Int = 1) {
        self.schemaVersion = schemaVersion; self.ownerUID = ownerUID
        self.appCDHash = appCDHash; self.helperCDHash = helperCDHash; self.generation = generation
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw ValidationError.schema }
        guard ownerUID > 0, ownerUID <= UInt32(Int32.max) else { throw ValidationError.owner }
        guard Self.isCDHash(appCDHash), Self.isCDHash(helperCDHash) else { throw ValidationError.hash }
        guard let uuid = UUID(uuidString: generation), uuid.uuidString.lowercased() == generation else {
            throw ValidationError.generation
        }
    }

    public func permits(uid: UInt32, appCDHash: String) -> Bool {
        (try? validate()) != nil && ownerUID == uid && self.appCDHash == appCDHash
    }

    public static func isCDHash(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func pinnedRequirement(identifier: String, cdHash: String) throws -> String {
        guard ["local.mactoolbox.app", "local.mactoolbox.fan-helper"].contains(identifier), isCDHash(cdHash) else {
            throw ValidationError.hash
        }
        return "identifier \"\(identifier)\" and cdhash H\"\(cdHash)\""
    }

    public static func validateApplicationPath(_ path: String) throws {
        // Keep the previous canonical filename only for upgrades and recovery.
        // Renaming the product does not broaden this to arbitrary .app bundles.
        let canonicalSuffixes = ["/Applications/Mac Go.app", "/Applications/Mac 工具箱.app"]
        guard path.hasPrefix("/Users/"), canonicalSuffixes.contains(where: { path.hasSuffix($0) }),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !(path as NSString).pathComponents.contains(".."),
              !(path as NSString).pathComponents.contains("."),
              (path as NSString).standardizingPath == path else { throw ValidationError.path }
    }

    /// Shell quoting is required even for paths validated above (user names may
    /// contain spaces or quote characters). No command substitution is expanded.
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    public static func appleScriptQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r") + "\""
    }

    public enum ValidationError: Error, LocalizedError {
        case schema, owner, hash, generation, path
        public var errorDescription: String? { "本机风扇服务授权记录无效；请重新确认当前版本。" }
    }
}
