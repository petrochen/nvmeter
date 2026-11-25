import Foundation

/// Made-up results for screenshots only (never stored).
enum SpeedDemo {
    static func results() -> [SpeedResult] {
        let stat = { (a: Double) in PhaseStat(avgMBps: a, minMBps: a * 0.95, maxMBps: a * 1.03, seconds: 4, bytes: 5_000_000_000) }
        var q = SpeedResult(mode: .quick, driveKey: "demo", driveName: "Demo SSD", fileSystem: "APFS", volumeTotalBytes: 1_000_000_000_000,
                            volumeFreeBytes: 550_000_000_000, testBytes: 5_000_000_000, bytesWritten: 5_000_000_000)
        q.write = stat(1360); q.read = stat(1685); q.tempMaxC = 52
        var s = q; s.mode = .sustained; s.id = UUID(); s.date = Date().addingTimeInterval(-3600)
        s.cliff = CliffInfo(fullSpeedGB: 120, fullSpeedMBps: 1350, afterMBps: 520)
        return [q, s]
    }
}
