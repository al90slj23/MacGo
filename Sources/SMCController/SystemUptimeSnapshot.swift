import Darwin
import Foundation

/// Wall-clock time since this boot, including sleep. A failed or inconsistent
/// boot-time read stays unavailable rather than displaying an invented zero.
public struct SystemUptimeSnapshot: Equatable {
    public let bootDate: Date
    public let elapsedSeconds: TimeInterval

    public static func read(now: Date = Date()) -> SystemUptimeSnapshot? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0,
              size == MemoryLayout<timeval>.size, boot.tv_sec > 0,
              (0..<1_000_000).contains(Int(boot.tv_usec)) else { return nil }
        let bootDate = Date(timeIntervalSince1970: Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000)
        return validated(bootDate: bootDate, now: now)
    }

    static func validated(bootDate: Date, now: Date) -> SystemUptimeSnapshot? {
        let elapsed = now.timeIntervalSince(bootDate)
        guard bootDate.timeIntervalSince1970.isFinite, elapsed.isFinite, elapsed >= 0 else { return nil }
        return SystemUptimeSnapshot(bootDate: bootDate, elapsedSeconds: elapsed)
    }
}
