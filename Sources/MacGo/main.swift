import AppKit
import SMCController

if CommandLine.arguments.contains("--fan-status") {
    do {
        let connection = try SMCConnection()
        let data = try JSONEncoder().encode(connection.readFans())
        print(String(decoding: data, as: UTF8.self))
    } catch { fputs("Fan read failed: \(error.localizedDescription)\n", stderr); exit(1) }
} else {
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let delegate = AppController()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
