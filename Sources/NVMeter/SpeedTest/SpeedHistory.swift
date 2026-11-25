import Foundation
import Observation

/// Last results per drive, stored as JSON in Application Support.
@MainActor @Observable
final class SpeedHistory {
    static let shared = SpeedHistory()
    private(set) var results: [SpeedResult] = []    // newest first
    static let keepPerDrive = 10

    private var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NVMeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("speedtest-history.json")
    }

    init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: url), let r = try? dec.decode([SpeedResult].self, from: d) { results = r }
    }

    /// Screenshot mode only: shown for every drive, never written to disk.
    var demo: [SpeedResult] = []

    func results(for key: String) -> [SpeedResult] { demo.isEmpty ? results.filter { $0.driveKey == key } : demo }

    func add(_ r: SpeedResult) {
        guard !r.cancelled else { return }
        results.insert(r, at: 0)
        var seen: [String: Int] = [:]
        results = results.filter { seen[$0.driveKey, default: 0] += 1; return seen[$0.driveKey]! <= Self.keepPerDrive }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(results) { try? d.write(to: url, options: .atomic) }
    }
}
