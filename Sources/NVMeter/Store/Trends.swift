import Foundation

/// Usage trends derived from hourly SMART snapshots (pure functions, no I/O).
struct UsageTrends: Sendable {
    struct Rate: Sendable { var perDay: Double?; var spanDays: Double }

    enum Projection: Sendable, Equatable {
        case notEnoughData(String)
        case noWrites
        case reached
        case years(Double, method: String)
    }

    var writtenPerDay7: Rate, writtenPerDay30: Rate
    var readPerDay7: Rate, readPerDay30: Rate
    var powerOnPerDay7: Rate, powerOnPerDay30: Rate
    var projection: Projection
    var firstSeen: Date
    var historyDays: Double
    var snapshotCount: Int
    // Since first seen by NVMeter
    var writtenSinceBytes: Double
    var readSinceBytes: Double
    var mediaErrorsAdded: Int
    var errorLogAdded: Int
    var unsafeShutdownsAdded: Int
    var criticalWarningNow: Int
    var criticalWarningChanged: Bool

    static let minAverageSpan: Double = 0.25      // days (6 h) before a per-day average is shown
    static let minProjectionSpan: Double = 2      // days

    /// `rows` must be sorted by time. Returns nil without at least one snapshot.
    static func compute(rows: [SmartRow], now: Date = Date()) -> UsageTrends? {
        guard let first = rows.first, let last = rows.last else { return nil }
        let nowTS = max(now.timeIntervalSince1970, last.ts)

        func rate(_ days: Double, _ value: (SmartRow) -> Double) -> Rate {
            let start = nowTS - days * 86400
            let base = rows.last(where: { $0.ts <= start }) ?? first
            let span = (last.ts - base.ts) / 86400
            guard span >= minAverageSpan else { return Rate(perDay: nil, spanDays: span) }
            let d = value(last) - value(base)
            return d < 0 ? Rate(perDay: nil, spanDays: span) : Rate(perDay: d / span, spanDays: span)
        }
        let w7 = rate(7, { $0.bytesWritten }), w30 = rate(30, { $0.bytesWritten })
        let r7 = rate(7, { $0.bytesRead }), r30 = rate(30, { $0.bytesRead })
        let p7 = rate(7, { Double($0.powerOnHours) }), p30 = rate(30, { Double($0.powerOnHours) })

        let histDays = (last.ts - first.ts) / 86400
        return UsageTrends(
            writtenPerDay7: w7, writtenPerDay30: w30, readPerDay7: r7, readPerDay30: r30,
            powerOnPerDay7: p7, powerOnPerDay30: p30,
            projection: projection(first: first, last: last, writeRate: w30.perDay ?? w7.perDay, historyDays: histDays),
            firstSeen: Date(timeIntervalSince1970: first.ts), historyDays: histDays, snapshotCount: rows.count,
            writtenSinceBytes: max(0, last.bytesWritten - first.bytesWritten),
            readSinceBytes: max(0, last.bytesRead - first.bytesRead),
            mediaErrorsAdded: Int(clamping: Int64(last.mediaErrors) - Int64(first.mediaErrors)),
            errorLogAdded: Int(clamping: Int64(last.errorLogEntries) - Int64(first.errorLogEntries)),
            unsafeShutdownsAdded: Int(clamping: Int64(last.unsafeShutdowns) - Int64(first.unsafeShutdowns)),
            criticalWarningNow: last.criticalWarning,
            criticalWarningChanged: rows.contains { $0.criticalWarning != 0 })
    }

    static func projection(first: SmartRow, last: SmartRow, writeRate: Double?, historyDays: Double) -> Projection {
        guard historyDays >= minProjectionSpan, let rate = writeRate else {
            return .notEnoughData("not enough data yet (needs ≥ 2 days)")
        }
        if last.percentageUsed >= 100 { return .reached }
        if rate < 1e6 { return .noWrites }
        let dPct = last.percentageUsed - first.percentageUsed
        let dBytes = last.bytesWritten - first.bytesWritten
        let bytesPerPct: Double
        let method: String
        if dPct >= 1, dBytes > 0 {
            bytesPerPct = dBytes / Double(dPct)
            method = "from \(dPct) % wear over \(String(format: "%.0f", historyDays)) days of history"
        } else if last.percentageUsed >= 1 {
            bytesPerPct = last.bytesWritten / Double(last.percentageUsed)
            method = "from lifetime wear \(last.percentageUsed) % for \(String(format: "%.0f", last.bytesWritten / 1e12)) TB written"
        } else {
            return .notEnoughData("percentage used is still 0 %, wear has not moved yet")
        }
        let remainingBytes = Double(100 - last.percentageUsed) * bytesPerPct
        return .years(remainingBytes / rate / 365.25, method: method)
    }

    // MARK: Formatting

    static func bytesPerDay(_ r: Rate) -> String {
        guard let v = r.perDay else { return "n/a" }
        return v >= 1e12 ? String(format: "%.2f TB/day", v / 1e12) : (v >= 1e9 ? String(format: "%.1f GB/day", v / 1e9) : String(format: "%.0f MB/day", v / 1e6))
    }

    static func hoursPerDay(_ r: Rate) -> String {
        guard let v = r.perDay else { return "n/a" }
        return String(format: "%.1f h/day", min(v, 24))
    }

    /// "7-day avg", or "avg over 1.5 d" while there is less history than the window.
    static func avgLabel(_ r: Rate, window: Double) -> String {
        r.spanDays + 0.05 >= window ? "\(Int(window))-day avg" : String(format: "avg over %.1f d", r.spanDays)
    }

    var projectionText: String {
        switch projection {
        case .notEnoughData(let why): return "Lifetime projection: " + why
        case .noWrites: return "No measurable writes lately: wear is not advancing"
        case .reached: return "Rated endurance reached (percentage used ≥ 100 %)"
        case .years(let y, let method):
            let t = y > 100 ? "more than 100 years" : (y >= 10 ? String(format: "~%.0f years", y) : (y >= 1 ? String(format: "~%.1f years", y) : String(format: "~%.0f months", max(y * 12, 1))))
            return "At the current write rate, rated endurance (percentage used → 100 %) is reached in \(t) (\(method))"
        }
    }
}
