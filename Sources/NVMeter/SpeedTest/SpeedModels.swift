import Foundation

enum SpeedMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case quick, sustained, random, live
    var id: String { rawValue }
    var title: String {
        switch self { case .quick: "Quick"; case .sustained: "Sustained write"; case .random: "Random 4K"; case .live: "Live loop" }
    }
}

/// Phase of a running test, used to colour the live chart.
enum SpeedPhase: String, Codable, Sendable {
    case write, read, sustainedWrite, randomQD1, randomQD32
    var title: String {
        switch self {
        case .write: "Sequential write"
        case .read: "Sequential read"
        case .sustainedWrite: "Sustained write"
        case .randomQD1: "Random 4K read, QD1"
        case .randomQD32: "Random 4K read, QD32"
        }
    }
}

/// One live sample (every 0.5 s).
struct SpeedSample: Identifiable, Sendable {
    var id: Int
    var phase: SpeedPhase
    /// Seconds since the start of the phase.
    var t: Double
    var mbps: Double
    var iops: Double
    /// Bytes handled in this phase so far.
    var bytes: Int64
    /// Live loop only: cycle number (from 1) and bytes written in the whole run so far.
    var cycle = 0
    var totalWritten: Int64 = 0
}

/// One write + read pass of the live loop.
struct LiveCycle: Codable, Equatable, Sendable {
    var writeMBps: Double
    var readMBps: Double
}

struct PhaseStat: Codable, Equatable, Sendable {
    var avgMBps: Double
    var minMBps: Double
    var maxMBps: Double
    var seconds: Double
    var bytes: Int64
}

struct RandomStat: Codable, Equatable, Sendable {
    var queueDepth: Int
    var iops: Double
    var mbps: Double
    var meanLatencyUs: Double
    var seconds: Double
}

struct CliffInfo: Codable, Equatable, Sendable {
    var fullSpeedGB: Double
    var fullSpeedMBps: Double
    var afterMBps: Double
}

struct SpeedResult: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var date = Date()
    var mode: SpeedMode
    var driveKey: String
    var driveName: String
    var fileSystem: String?
    var volumeTotalBytes: Int64
    var volumeFreeBytes: Int64
    /// Size of the test file in bytes.
    var testBytes: Int64
    /// Everything written to the drive by this run.
    var bytesWritten: Int64
    var write: PhaseStat?
    var read: PhaseStat?
    var random: [RandomStat]?
    /// Sustained write: MB/s every 0.5 s.
    var series: [Double]?
    var cliff: CliffInfo?
    /// Live loop: one entry per completed write + read cycle, and why the loop stopped.
    var cycles: [LiveCycle]?
    var stopReason: String?
    var tempStartC: Int?
    var tempMaxC: Int?
    var cancelled = false

    var fillPercent: Double {
        guard volumeTotalBytes > 0 else { return 0 }
        return Double(volumeTotalBytes - volumeFreeBytes) / Double(volumeTotalBytes) * 100
    }
}

enum SpeedError: Error, LocalizedError {
    case io(String, Int32)
    case notEnoughSpace(needed: Int64, free: Int64)
    var errorDescription: String? {
        switch self {
        case .io(let what, let e): "\(what): \(String(cString: strerror(e)))"
        case .notEnoughSpace(let n, let f): "Not enough free space: need \(n / 1_000_000_000) GB plus margin, have \(f / 1_000_000_000) GB"
        }
    }
}
