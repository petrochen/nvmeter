import Foundation

/// `--seed-demo` (screenshot mode only, requires `--db <file>`): fills a throwaway database with SYNTHETIC
/// history for the drives that are connected right now, so screenshots can show the 24 h / 7 d graphs and the
/// "Usage & lifetime" trends without waiting weeks. Never touches the real history database.
enum DemoSeed {
    static func run(drives: [DriveSnapshot], store: HistoryStore) {
        guard HistoryStore.overridePath != nil else { return }
        let now = Int64(Date().timeIntervalSince1970)
        var rng = SystemRandomNumberGenerator()
        store.withDB { db in
            try? db.transaction {
                for (idx, d) in drives.enumerated() {
                    guard let s = d.smart else { continue }
                    let key = d.id
                    let ratePerDay = Double([40, 120, 25, 300, 70][idx % 5]) * 1e9
                    try db.run("INSERT OR IGNORE INTO drives(key, model, first_seen, last_seen) VALUES(?,?,?,?)",
                               [.text(key), .text(d.model), .int(now - 30 * 86400), .int(now)])
                    // Hourly SMART snapshots over 30 days, walking backwards from the live values.
                    let bytesPerPct = max(Double(s.bytesWritten) / Double(max(s.percentageUsed, 1)), 5e12)
                    for h in 0..<(30 * 24) {
                        let ageD = Double(h) / 24
                        let ts = now - Int64(h) * 3600
                        let w = max(0, Double(s.bytesWritten) - ratePerDay * ageD)
                        let r = max(0, Double(s.bytesRead) - ratePerDay * 0.8 * ageD)
                        let pct = max(0, Int((Double(s.percentageUsed) - ratePerDay * ageD / bytesPerPct).rounded()))
                        let poh = max(0, Int64(s.powerOnHours) - Int64(Double(h) * 0.9))
                        try db.run("INSERT OR REPLACE INTO smart_snapshots VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
                            .text(key), .int(ts), .int(Int64(r / 512_000)), .int(Int64(w / 512_000)), .int(poh),
                            .int(Int64(s.powerCycles)), .int(Int64(s.unsafeShutdowns)), .int(Int64(s.mediaErrors)),
                            .int(Int64(s.errorLogEntries)), .int(Int64(pct)), .int(Int64(s.availableSparePct)),
                            .int(Int64(s.warningTempMinutes)), .int(Int64(s.criticalTempMinutes)), .int(Int64(s.criticalWarning)),
                            .int(Int64(s.temperatureC))])
                    }
                    // One drive gets a few media errors 4 days ago (also on live rows) so the red highlight is visible.
                    if drives.count > 1 && key == drives.max(by: { ($0.smart?.percentageUsed ?? 0) < ($1.smart?.percentageUsed ?? 0) })?.id {
                        try db.run("UPDATE smart_snapshots SET media_errors=media_errors+3, error_log_entries=error_log_entries+3 WHERE key=? AND ts>=?",
                                   [.text(key), .int(now - 4 * 86400)])
                    }
                    // Samples: 1 min rows for 7 days, 1 h rows for 30 days (plausible daily rhythm).
                    func shape(_ t: Int64) -> Double {
                        let hour = Double((t / 3600) % 24)
                        return max(0, sin((hour - 6) / 24 * 2 * .pi)) + 0.15
                    }
                    let base = Double(s.temperatureC)
                    for m in stride(from: 2 * 60, to: 7 * 1440, by: 1) {
                        let ts = (now - Int64(m) * 60) / 60 * 60
                        let act = shape(ts) * (Double.random(in: 0...1, using: &rng) < 0.25 ? 1 : 0.1)
                        let wr = ratePerDay / 86400 / 1e6 * 6 * act, rd = wr * 0.8
                        let t = base - 6 + shape(ts) * 9 + Double.random(in: -1...1, using: &rng)
                        try db.run("INSERT OR REPLACE INTO samples_1m VALUES(?,?,?,?,?,?,?,?)",
                                   [.text(key), .int(ts), .double(t), .double(t + 1), .int(60), .double(rd), .double(wr), .int(60)])
                    }
                    for h in stride(from: 7 * 24, to: 30 * 24, by: 1) {
                        let ts = (now - Int64(h) * 3600) / 3600 * 3600
                        let wr = ratePerDay / 86400 / 1e6 * 4 * shape(ts), rd = wr * 0.8
                        let t = base - 6 + shape(ts) * 9
                        try db.run("INSERT OR REPLACE INTO samples_1h VALUES(?,?,?,?,?,?,?,?)",
                                   [.text(key), .int(ts), .double(t), .double(t + 1), .int(3600), .double(rd), .double(wr), .int(3600)])
                    }
                }
            }
        }
    }
}
