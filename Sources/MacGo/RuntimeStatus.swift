import AppKit
import Darwin

/// Private, replaceable evidence for the local updater. It grants no authority.
/// Consumers must independently verify the live PID, UID and executable path.
@MainActor final class RuntimeStatus {
    private let instanceID = UUID().uuidString
    private let startedAt = Date()
    private var timer: Timer?
    private var fanServiceReady: (() -> Bool)?
    private var didReportFailure = false
    private let formatter: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }()
    private var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacGo", isDirectory: true)
    }
    private var destination: URL { directory.appendingPathComponent("runtime-status.json") }

    func start(fanServiceReady: @escaping () -> Bool) {
        self.fanServiceReady = fanServiceReady
        publish()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
        self.timer = timer
        // Menu tracking and a system modal must not make a live client look stale.
        RunLoop.main.add(timer, forMode: .common)
    }

    func publish() {
        guard fanServiceReady != nil else { return }
        do {
            try preparePrivateDirectory()
            let bundle = Bundle.main
            let state: [String: Any] = [
                "schemaVersion": 1,
                "instanceID": instanceID,
                "pid": ProcessInfo.processInfo.processIdentifier,
                "uid": getuid(),
                "executablePath": bundle.executableURL?.path ?? "",
                "bundlePath": bundle.bundleURL.path,
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                "build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                "sourceRevision": bundle.object(forInfoDictionaryKey: "MacGoSourceRevision") as? String ?? "",
                "sourceFingerprint": bundle.object(forInfoDictionaryKey: "MacGoSourceFingerprint") as? String ?? "",
                "sourceDirty": bundle.object(forInfoDictionaryKey: "MacGoSourceDirty") as? Bool ?? false,
                "startedAt": formatter.string(from: startedAt),
                "updatedAt": formatter.string(from: Date()),
                "accessibilityTrusted": AXIsProcessTrusted(),
                "screenRecordingTrusted": CGPreflightScreenCaptureAccess(),
                "fanServiceReady": fanServiceReady?() ?? false
            ]
            let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            didReportFailure = false
        } catch {
            if !didReportFailure { NSLog("Mac Go: local runtime receipt unavailable: %@", error.localizedDescription) }
            didReportFailure = true
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        fanServiceReady = nil
        // A newer instance may already own the receipt during an explicit restart.
        guard let data = try? Data(contentsOf: destination),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              state["instanceID"] as? String == instanceID else { return }
        try? FileManager.default.removeItem(at: destination)
    }

    private func preparePrivateDirectory() throws {
        let files = FileManager.default
        if !files.fileExists(atPath: directory.path) {
            try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
        }
        let attributes = try files.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if files.fileExists(atPath: destination.path) {
            let existing = try files.attributesOfItem(atPath: destination.path)
            guard existing[.type] as? FileAttributeType == .typeRegular,
                  (existing[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
    }
}
