import Foundation
import FanHelperProtocol
import SMCController
import ToolboxCore
import Darwin

func printJSON(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
       let string = String(data: data, encoding: .utf8) { print(string) }
}

do {
    switch Array(CommandLine.arguments.dropFirst()) {
    case ["--local-daemon"]:
        let approved = try LocalFanIdentity.loadAuthorization()
        try FanDaemon(localAuthorization: approved).run()
    case ["--restore-owned"]:
        guard geteuid() == 0 else { throw DaemonError("恢复本工具持有的风扇状态需要管理员权限。") }
        let lease = try FanHardwareLease(timeout: 10)
        try withExtendedLifetime(lease) {
            let journal = RecoveryJournal()
            if let record = try journal.read() {
                let controller = try SMCFanController()
                controller.persistRecovery = { try journal.save($0) }
                try controller.restoreRecovery(record)
                try journal.save(controller.recoveryState)
            }
        }
        printJSON(["restoredOwnedState": true])
    case let arguments where arguments.count == 3 && arguments[0] == "--local-install-plan":
        let appPath = arguments[1]
        let user = arguments[2]
        try LocalFanAuthorization.validateApplicationPath(appPath)
        guard let uid = UInt32(user) else { throw LocalFanAuthorization.ValidationError.owner }
        let app = URL(fileURLWithPath: appPath, isDirectory: true)
        let appHash = try LocalFanIdentity.cdHash(at: app, identifier: FanHelperIdentity.appIdentifier)
        let helperHash = try LocalFanIdentity.cdHash(at: app.appendingPathComponent("Contents/MacOS/MacToolboxFanHelper"),
                                                   identifier: FanHelperIdentity.serviceName)
        let authorization = LocalFanAuthorization(ownerUID: uid, appCDHash: appHash, helperCDHash: helperHash,
                                                 generation: UUID().uuidString.lowercased())
        try authorization.validate()
        printJSON(["requiresAdministratorApproval": true, "hardwareAccessed": false, "ownerUID": uid,
                   "appPath": appPath, "appCDHash": appHash, "helperCDHash": helperHash,
                   "serviceName": LocalFanIdentity.serviceName, "configurationPath": LocalFanIdentity.configurationPath,
                   "helperPath": try LocalFanIdentity.helperPath(for: authorization),
                   "launchPlistPath": LocalFanIdentity.launchPlistPath])
    case ["--check-authorization"]:
        do {
            let team = try FanHelperIdentity.currentTeamIdentifier()
            printJSON(["supported": true, "teamIdentifier": team,
                       "clientRequirement": try FanHelperIdentity.signingRequirement(identifier: FanHelperIdentity.appIdentifier),
                       "hardwareAccessed": false])
        } catch {
            printJSON(["supported": false, "error": error.localizedDescription, "hardwareAccessed": false])
            exit(1)
        }
    case ["--diagnose-read-only"]:
        let fans = try SMCConnection().readFans()
        let data = try JSONEncoder().encode(fans)
        print(String(decoding: data, as: UTF8.self))
    case ["--diagnose-runtime-read-only"]:
        printJSON(try FanRuntimeStorage.readOnlyDiagnostics())
    case [], ["--daemon"]:
        let daemon = FanDaemon()
        try daemon.run()
    default:
        fputs("usage: MacToolboxFanHelper [--daemon | --local-daemon | --restore-owned | --check-authorization | --diagnose-read-only | --diagnose-runtime-read-only | --local-install-plan APP UID]\n", stderr)
        exit(2)
    }
} catch {
    NSLog("Mac Go fan helper startup/command failed: %@", error.localizedDescription)
    fputs("Mac Go fan helper: \(error.localizedDescription)\n", stderr)
    exit(1)
}
