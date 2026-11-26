import Foundation
import Observation

/// What NVMeter knew about a drive the last time it saw it.
struct DriveVisit: Codable, Equatable, Sendable {
    var name: String
    var lastSeen: Date
    var connection: String
    var smart: SMARTSnapshot?
    /// At the moment the drive vanished: true = its volumes were already unmounted (ejected), false = still mounted,
    /// nil = NVMeter did not see it go (not running, or the drive is still connected).
    var ejectedCleanly: Bool?
}

/// Result of the check run when a drive connects (or is found at launch).
struct ConnectReport: Codable, Identifiable, Equatable, Sendable {
    enum Level: Int, Codable, Comparable, Sendable {
        case ok, info, warning, critical
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }
    struct Line: Codable, Equatable, Sendable, Identifiable {
        var id = UUID()
        var level: Level
        var text: String
    }

    var id = UUID()
    var date: Date
    var driveID: String
    var name: String
    /// Seconds since NVMeter last saw the drive; nil the first time.
    var away: TimeInterval?
    var lines: [Line]
    var level: Level { lines.map(\.level).max() ?? .ok }
    var headline: String {
        if away == nil { return "first seen, baseline saved" }
        return lines.first { $0.level == level && level >= .warning }?.text ?? "OK"
    }
}

/// Runs a check every time a drive appears: SMART against the state from its previous visit
/// (data written elsewhere, power-on time, unsafe shutdowns, errors, wear, connection), a SMART snapshot,
/// an Events entry and, when something needs attention or happened elsewhere, a notification.
@MainActor @Observable
final class ConnectCheck {
    static let shared = ConnectCheck()

    /// Latest report per drive.
    private(set) var reports: [String: ConnectReport] = [:]

    /// Gaps shorter than this are reconnect blips or a quick relaunch: no report.
    nonisolated static let minAway: TimeInterval = 120
    /// A new SMART snapshot is saved on connect unless the newest one is younger than this.
    nonisolated static let snapshotSpacing: TimeInterval = 3600
    /// Waiting for the first SMART read of a new drive.
    nonisolated static let smartWait: TimeInterval = 20

    @ObservationIgnored private var visits: [String: DriveVisit] = [:]
    @ObservationIgnored private var present: Set<String> = []
    @ObservationIgnored private var pending: [String: Date] = [:]
    @ObservationIgnored private var mounted: [String: Bool] = [:]
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private let url: URL?

    private struct Stored: Codable { var visits: [String: DriveVisit]; var reports: [String: ConnectReport] }

    /// `url` nil = in memory only (tests).
    init(url: URL? = ConnectCheck.defaultURL) {
        self.url = url
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let url, let d = try? Data(contentsOf: url), let s = try? dec.decode(Stored.self, from: d) {
            visits = s.visits; reports = s.reports
        }
    }

    nonisolated static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NVMeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("connect-check.json")
    }

    /// Called on every tick with all drives. `post` sends an event (nil in tests).
    /// Side effects, replaceable in tests: post an event, save a SMART snapshot, "drive known from before this feature".
    @ObservationIgnored var post: (ConnectReport, _ notify: Bool) -> Void = { r, n in ConnectCheck.postEvent(r, notify: n) }
    @ObservationIgnored var snapshot: (DriveSnapshot) -> Void = { ConnectCheck.saveSnapshot($0) }
    @ObservationIgnored var known: (DriveSnapshot) -> Bool = { !SnapshotStore.files(forKey: SnapshotStore.driveKey($0)).isEmpty }

    func evaluate(_ snaps: [DriveSnapshot], now: Date = Date()) {
        let current = Set(snaps.map(\.id))
        for k in present.subtracting(current) {           // gone: remember how it left
            pending[k] = nil
            if var v = visits[k] { v.ejectedCleanly = !(mounted[k] ?? false); visits[k] = v; dirty = true }
            mounted[k] = nil
        }
        for k in current.subtracting(present) { pending[k] = now }
        present = current

        for s in snaps {
            if let since = pending[s.id] {
                let smartPossible = !s.isUSBOther && s.smartError == nil
                guard s.smart != nil || !smartPossible || now.timeIntervalSince(since) >= Self.smartWait else { continue }
                pending[s.id] = nil
                // Drives from before this feature (they already have SMART snapshots): start tracking silently.
                if visits[s.id] == nil, known(s) {
                    // fall through to the visit update below
                } else if let r = Self.check(s, previous: visits[s.id], now: now) {
                    reports[s.id] = r
                    post(r, Self.shouldNotify(r))
                    if s.smart != nil, r.away != nil { snapshot(s) }
                }
            }
            mounted[s.id] = s.volumes.contains { !$0.mountPoint.isEmpty }
            let v = DriveVisit(name: s.displayName, lastSeen: now, connection: s.connection.summary,
                               smart: s.smart ?? visits[s.id]?.smart, ejectedCleanly: nil)
            if visits[s.id]?.smart != v.smart || visits[s.id]?.connection != v.connection || visits[s.id]?.name != v.name { dirty = true }
            visits[s.id] = v
        }
        if now.timeIntervalSince(lastSave) >= 60 || (dirty && now.timeIntervalSince(lastSave) >= 5) { save(now) }
    }

    func save(_ now: Date = Date()) {
        lastSave = now; dirty = false
        guard let url else { return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(Stored(visits: visits, reports: reports)) { try? d.write(to: url, options: .atomic) }
    }

    // MARK: The check

    nonisolated static func check(_ s: DriveSnapshot, previous p: DriveVisit?, now: Date) -> ConnectReport? {
        typealias L = ConnectReport.Line
        var lines: [L] = []
        guard let p else {
            if s.smart != nil {
                lines.append(L(level: .info, text: "First time NVMeter sees this drive: its SMART state is the baseline for later checks"))
                lines.append(health(s))
            } else {
                lines.append(L(level: .info, text: "First time NVMeter sees this drive. SMART is not available over this connection (\(s.connection.summary)), so only the connection will be checked"))
            }
            return ConnectReport(date: now, driveID: s.id, name: s.displayName, away: nil, lines: lines)
        }
        let away = now.timeIntervalSince(p.lastSeen)
        guard away >= minAway else { return nil }
        lines.append(L(level: .info, text: "Not seen for \(duration(away)) (since \(p.lastSeen.formatted(date: .abbreviated, time: .shortened)))"))

        if let a = p.smart, let b = s.smart {
            let w = sub(b.bytesWritten, a.bytesWritten), r = sub(b.bytesRead, a.bytesRead)
            if w >= 1_000_000_000 || r >= 1_000_000_000 {
                lines.append(L(level: .info, text: "Used elsewhere: \(bytes(w)) written, \(bytes(r)) read"))
            } else {
                lines.append(L(level: .ok, text: "No data written or read elsewhere"))
            }
            let poh = sub(b.powerOnHours, a.powerOnHours), cyc = sub(b.powerCycles, a.powerCycles)
            if poh > 0 || cyc > 1 {
                lines.append(L(level: .info, text: "Powered on elsewhere: \(poh) h, \(cyc) power cycles"))
            }
            let unsafe = sub(b.unsafeShutdowns, a.unsafeShutdowns)
            if unsafe > 0 {
                let n = unsafe == 1 ? "1 unsafe shutdown" : "\(unsafe) unsafe shutdowns"
                switch p.ejectedCleanly {
                case true?:
                    lines.append(L(level: .info, text: "\(n), although the drive was ejected first: the enclosure cuts power without telling the drive. Usually harmless"))
                case false?:
                    lines.append(L(level: .warning, text: "\(n): the drive was unplugged while its volumes were mounted. Eject before unplugging"))
                case nil:
                    lines.append(L(level: .warning, text: "\(n) since last seen: unplugged without eject, a power loss, or an enclosure that cuts power"))
                }
            }
            let me = sub(b.mediaErrors, a.mediaErrors)
            if me > 0 { lines.append(L(level: .critical, text: "Media and data integrity errors grew by \(me) (now \(b.mediaErrors))")) }
            let el = sub(b.errorLogEntries, a.errorLogEntries)
            if el > 0 { lines.append(L(level: .info, text: "Error log grew by \(el) entries (often harmless commands the drive rejected)")) }
            if b.criticalWarning != 0, b.criticalWarning != a.criticalWarning {
                lines.append(L(level: .critical, text: "SMART critical warning: \(HealthEvaluator.criticalWarningText(b.criticalWarning))"))
            }
            if b.percentageUsed > a.percentageUsed { lines.append(L(level: .info, text: "Wear \(a.percentageUsed) % → \(b.percentageUsed) %")) }
            if b.availableSparePct < a.availableSparePct {
                lines.append(L(level: b.availableSparePct <= b.availableSpareThresholdPct ? .critical : .warning,
                               text: "Available spare dropped \(a.availableSparePct) % → \(b.availableSparePct) %"))
            }
            if b.warningTempMinutes > a.warningTempMinutes {
                lines.append(L(level: .warning, text: "Ran above its warning temperature for \(b.warningTempMinutes - a.warningTempMinutes) min elsewhere"))
            }
        } else if s.smart == nil {
            lines.append(L(level: .info, text: "SMART is not available over this connection: only the connection was checked"))
        }

        let conn = s.connection.summary
        if s.isUSBOther, !AlertCenter.enclosureName(s.connection).isEmpty {
            lines.append(L(level: .warning, text: "Connected over USB (\(conn)): no SMART, limited speed. Check the cable or port"))
        } else if conn != p.connection {
            lines.append(L(level: .info, text: "Connection changed: was \(p.connection), now \(conn)"))
        }
        if s.smart != nil || s.health != .unknown { lines.append(health(s)) }
        return ConnectReport(date: now, driveID: s.id, name: s.displayName, away: away, lines: lines)
    }

    /// Notify when something needs attention, or when the drive was away a while and used elsewhere.
    nonisolated static func shouldNotify(_ r: ConnectReport) -> Bool {
        if r.level >= .warning { return true }
        guard let away = r.away, away >= 3600 else { return false }
        return r.lines.contains { $0.text.hasPrefix("Used elsewhere") || $0.text.hasPrefix("Powered on elsewhere") }
    }

    private nonisolated static func health(_ s: DriveSnapshot) -> ConnectReport.Line {
        let lvl: ConnectReport.Level = switch s.health { case .good: .ok; case .caution: .warning; case .bad: .critical; default: .info }
        return .init(level: lvl, text: "Health now: \(s.health.title)" + (s.temperatureC.map { ", \($0) °C" } ?? ""))
    }

    private nonisolated static func sub(_ a: UInt64, _ b: UInt64) -> UInt64 { a > b ? a - b : 0 }

    nonisolated static func bytes(_ b: UInt64) -> String {
        let v = Double(b)
        return v >= 1e12 ? String(format: "%.2f TB", v / 1e12) : v >= 1e9 ? String(format: "%.0f GB", v / 1e9) : String(format: "%.0f MB", v / 1e6)
    }

    nonisolated static func duration(_ t: TimeInterval) -> String {
        let m = Int(t / 60), h = m / 60, d = h / 24
        if d > 0 { return "\(d) d \(h % 24) h" }
        if h > 0 { return "\(h) h \(m % 60) min" }
        return "\(m) min"
    }

    // MARK: Side effects

    static func postEvent(_ r: ConnectReport, notify: Bool) {
        guard UserDefaults.standard.bool(forKey: AlertKeys.enabled) else { return }
        let sev: AlertSeverity = r.level == .critical ? .critical : r.level == .warning ? .warning : .info
        let body = r.lines.filter { $0.level != .ok || r.level == .ok }.prefix(4).map(\.text).joined(separator: ". ")
        AlertCenter.shared.post(.driveConnected, sev, drive: r.name, driveID: r.driveID,
                                title: "\(r.name) connected: \(r.headline)", body: body,
                                notify: notify && UserDefaults.standard.bool(forKey: AlertRule.driveConnected.key))
    }

    static func saveSnapshot(_ d: DriveSnapshot) {
        let files = SnapshotStore.files(forKey: SnapshotStore.driveKey(d))
        if let last = files.last, let date = (try? last.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(date) < snapshotSpacing { return }
        _ = try? SnapshotStore.save(d)
    }
}

import SwiftUI

/// "Connect check" card on the drive's Overview.
struct ConnectReportCard: View {
    let report: ConnectReport

    var body: some View {
        Card("Connect check") {
            Text("Checked \(report.date.formatted(date: .abbreviated, time: .shortened)), when the drive "
                 + (report.away == nil ? "was first seen." : "connected or NVMeter started."))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(report.lines) { line in
                Label { Text(line.text).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: Self.icon(line.level)).foregroundStyle(Self.color(line.level))
                }.font(.callout)
            }
        }
    }

    static func icon(_ l: ConnectReport.Level) -> String {
        switch l {
        case .ok: "checkmark.circle.fill"
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }

    static func color(_ l: ConnectReport.Level) -> Color {
        switch l { case .ok: .green; case .info: .secondary; case .warning: .orange; case .critical: .red }
    }
}
