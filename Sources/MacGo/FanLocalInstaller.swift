import AppKit
import FanHelperProtocol
import ToolboxCore

/// Presents the concrete operation before macOS displays its own administrator
/// authentication. This code never sees, saves or supplies an admin password.
@MainActor enum FanLocalInstaller {
    enum Action: String { case install, uninstall }
    struct Plan {
        let action: Action
        let appPath: String
        let authorization: LocalFanAuthorization

        var command: String {
            let arguments = ["/usr/bin/env", "-i", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C", "/bin/sh", "-c",
                             LocalFanInstallerScript.source, "mactoolbox-fan-service", action.rawValue,
                             String(authorization.ownerUID), appPath, authorization.appCDHash,
                             authorization.helperCDHash, authorization.generation]
            return arguments.map(LocalFanAuthorization.shellQuote).joined(separator: " ")
        }

        var summary: String {
            let effect = action == .install
                ? L("安装或更新本机控制服务，不会立即改变风扇转速。只允许当前用户的这一版 Mac Go 连接；更新 Mac Go 后需再次确认。", "Install or update the local control service without changing fan speed. Only this build and your current user are allowed to connect; app updates require approval again.")
                : L("停止本机控制服务，恢复它持有的风扇状态，再移除服务。其他软件的手动设置不会被接管。", "Stop the local service, restore only the fan state it owns, and remove it. Manual control owned by another app is not taken over.")
            return effect + "\n\n" + L("服务文件：", "Service files:") + "\n" + LocalFanIdentity.basePath
                + "\n" + LocalFanIdentity.launchPlistPath
                + "\n/private/var/db/local.mactoolbox.fan-control\n\n"
                + L("允许的操作仅限风扇读取、固定转速、最大转速和恢复自动；不提供通用管理员命令。", "The service exposes fan readings, fixed or maximum speed, and automatic recovery only. It cannot run arbitrary administrator commands.")
                + "\n\n" + L("下一步由 macOS 请求管理员确认。", "macOS will request administrator approval next.")
        }
    }

    static func plan(_ action: Action) throws -> Plan {
        let app = Bundle.main.bundleURL
        try LocalFanAuthorization.validateApplicationPath(app.path)
        let appHash = try LocalFanIdentity.currentCDHash(identifier: FanHelperIdentity.appIdentifier)
        guard try LocalFanIdentity.cdHash(at: app, identifier: FanHelperIdentity.appIdentifier) == appHash else {
            throw LocalFanIdentity.Failure.invalidSignature
        }
        let helperHash = try LocalFanIdentity.cdHash(at: app.appendingPathComponent("Contents/MacOS/MacToolboxFanHelper"),
                                                   identifier: FanHelperIdentity.serviceName)
        let authorization = LocalFanAuthorization(ownerUID: getuid(), appCDHash: appHash, helperCDHash: helperHash,
                                                 generation: UUID().uuidString.lowercased())
        try authorization.validate()
        return Plan(action: action, appPath: app.path, authorization: authorization)
    }

    static func execute(_ plan: Plan) throws {
        let source = "do shell script " + LocalFanAuthorization.appleScriptQuote(plan.command) + " with administrator privileges"
        guard let script = NSAppleScript(source: source) else { throw failure("无法准备系统管理员确认请求。") }
        var details: NSDictionary?
        _ = script.executeAndReturnError(&details)
        if let details {
            let number = details[NSAppleScript.errorNumber] as? Int ?? -1
            let message = details[NSAppleScript.errorMessage] as? String ?? "系统未能完成风扇服务操作。"
            throw NSError(domain: "MacToolbox.LocalFanInstaller", code: number,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "MacToolbox.LocalFanInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
