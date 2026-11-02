#!/usr/bin/env swift
// Native lifecycle companion for gogogo.sh. No privileged service or TCC writes.
// Scope: only the current user's two canonical Mac Go installation paths.
// Run in the logged-in GUI session. A restricted sandbox can hide applications;
// the installer must also independently refuse replacement while either is live.
import AppKit
import Darwin

enum LifecycleError: Error, CustomStringConvertible {
    case refused(String)
    var description: String {
        switch self { case let .refused(message): return message }
    }
}

let bundleID = "local.mactoolbox.app"
let applications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
let canonical = applications.appendingPathComponent("Mac Go.app", isDirectory: true)
let legacy = applications.appendingPathComponent("Mac 工具箱.app", isDirectory: true)
let allowedExecutables = [canonical.path: "MacGo", legacy.path: "MacToolbox"]

func owner(of pid: pid_t) throws -> uid_t {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
          size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else {
        throw LifecycleError.refused("Unable to verify the running application's owner.")
    }
    return info.kp_eproc.e_ucred.cr_uid
}

func validate(_ app: NSRunningApplication) throws {
    guard let path = app.bundleURL?.standardizedFileURL.path,
          let executable = allowedExecutables[path],
          app.bundleIdentifier == bundleID,
          app.executableURL?.standardizedFileURL.path == path + "/Contents/MacOS/" + executable,
          try owner(of: app.processIdentifier) == getuid() else {
        throw LifecycleError.refused("A Mac Go instance is outside the current user's canonical installation. Quit it manually before updating.")
    }
}

func instances() throws -> [NSRunningApplication] {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
    for app in apps { try validate(app) }
    return apps
}

func descriptor(_ app: NSRunningApplication) throws -> [String: Any] {
    try validate(app)
    return ["pid": app.processIdentifier, "uid": getuid(),
            "bundlePath": app.bundleURL!.path, "executablePath": app.executableURL!.path]
}

func emit(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

func wait(until deadline: Date, _ predicate: () -> Bool) -> Bool {
    while !predicate() {
        if Date() >= deadline { return false }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    return true
}

do {
    guard getuid() != 0 else { throw LifecycleError.refused("Run the local updater as the logged-in user, without sudo.") }
    guard CommandLine.arguments.count == 2 else { throw LifecycleError.refused("Usage: app-lifecycle.swift status|quit|launch") }
    switch CommandLine.arguments[1] {
    case "status":
        try emit(["applications": try instances().map(descriptor)])
    case "quit":
        let apps = try instances()
        let descriptors = try apps.map(descriptor)
        for app in apps {
            // A native quit runs applicationWillTerminate, including owned-fan recovery.
            try validate(app)
            guard app.terminate() else { throw LifecycleError.refused("Mac Go declined to quit. Close its modal dialog and retry.") }
        }
        guard wait(until: Date(timeIntervalSinceNow: 30), { apps.allSatisfy(\.isTerminated) }) else {
            throw LifecycleError.refused("Mac Go did not quit within 30 seconds. No files were replaced.")
        }
        guard try instances().isEmpty else { throw LifecycleError.refused("A new Mac Go instance started while quitting. Update stopped.") }
        try emit(["quit": true, "applications": descriptors])
    case "launch":
        guard try instances().isEmpty else { throw LifecycleError.refused("A Mac Go instance is already running; refusing to reuse it as a new launch.") }
        guard let bundle = Bundle(url: canonical), bundle.bundleIdentifier == bundleID,
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "MacGo" else {
            throw LifecycleError.refused("The canonical Mac Go application is missing or invalid.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        var completed = false
        var launched: NSRunningApplication?
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: canonical, configuration: configuration) { app, error in
            launched = app; launchError = error; completed = true
        }
        guard wait(until: Date(timeIntervalSinceNow: 30), { completed }) else {
            throw LifecycleError.refused("Application launch timed out. Check the local app before retrying.")
        }
        if let launchError { throw launchError }
        guard let launched else { throw LifecycleError.refused("Launch Services did not return a running application.") }
        try emit(["launched": true, "application": try descriptor(launched)])
    default:
        throw LifecycleError.refused("Usage: app-lifecycle.swift status|quit|launch")
    }
} catch {
    fputs("Mac Go lifecycle: \(error)\n", stderr)
    exit(1)
}
