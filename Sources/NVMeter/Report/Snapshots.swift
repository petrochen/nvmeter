import Foundation
import CryptoKit

private let currentAppVersion = appVersion

/// Full SMART state of one drive at one moment, stored as a plain JSON file. Independent of any database.
struct SnapshotFile: Codable, Sendable, Identifiable {
    var schemaVersion = 1
    var takenAt: Date
    var appVersion: String
    var driveKey: String
    var vendor: String?
    var model: String
    var firmware: String
    var capacityBytes: UInt64
    /// First 16 hex digits of SHA-256(serial). The raw serial is never stored.
    var serialHash: String
    var health: String
    var smart: SMARTSnapshot?
    var identify: IdentifyInfo?
    var attributes: [AttributeRow]

    var id: String { driveKey + "/" + SnapshotStore.stamp(takenAt) }

    static func make(from d: DriveSnapshot, at date: Date = Date()) -> SnapshotFile {
        var ident = d.identify
        ident?.serial = ""
        return SnapshotFile(takenAt: date, appVersion: currentAppVersion, driveKey: SnapshotStore.driveKey(d), vendor: d.vendor?.name,
                            model: d.model, firmware: d.firmware, capacityBytes: d.capacityBytes,
                            serialHash: SnapshotStore.serialHash(d), health: d.health.rawValue, smart: d.smart,
                            identify: ident, attributes: d.attributes)
    }
}

enum SnapshotStore {
    /// `NVMETER_SNAPSHOT_DIR` overrides the location (used for testing).
    static var root: URL {
        if let o = ProcessInfo.processInfo.environment["NVMETER_SNAPSHOT_DIR"], !o.isEmpty { return URL(fileURLWithPath: o, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NVMeter/snapshots", isDirectory: true)
    }

    static func serialHash(_ d: DriveSnapshot) -> String {
        let src = d.serial.isEmpty ? d.id : d.serial
        return SHA256.hash(data: Data(src.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// vendor/model + serial hash, safe as a directory name.
    static func driveKey(_ d: DriveSnapshot) -> String {
        let base = ((d.vendor?.short ?? "") + " " + d.model).lowercased()
        let slug = base.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return (slug.isEmpty ? "drive" : String(slug.prefix(48))) + "-" + String(serialHash(d).prefix(10))
    }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: d)
    }

    static func dir(_ key: String) -> URL { root.appendingPathComponent(key, isDirectory: true) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    /// Writes a snapshot of a drive; returns its URL.
    @discardableResult
    static func save(_ d: DriveSnapshot, at date: Date = Date()) throws -> URL {
        guard d.smart != nil else { throw NSError(domain: "NVMeter", code: 1, userInfo: [NSLocalizedDescriptionKey: "No SMART data for \(d.bsdName)"]) }
        let snap = SnapshotFile.make(from: d, at: date)
        let dir = dir(snap.driveKey)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appendingPathComponent(stamp(date) + ".json")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) { url = dir.appendingPathComponent("\(stamp(date))-\(n).json"); n += 1 }
        try encoder.encode(snap).write(to: url, options: .atomic)
        return url
    }

    static func load(_ url: URL) -> SnapshotFile? { (try? Data(contentsOf: url)).flatMap { try? decoder.decode(SnapshotFile.self, from: $0) } }

    /// Snapshot files of a drive, oldest first.
    static func files(forKey key: String) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir(key), includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func list(for d: DriveSnapshot) -> [(url: URL, snap: SnapshotFile)] {
        files(forKey: driveKey(d)).compactMap { u in load(u).map { (u, $0) } }
    }

    // MARK: automatic snapshot on first sight

    nonisolated(unsafe) private static var seen = Set<String>()
    private static let lock = NSLock()

    /// Saves a snapshot the first time a drive with SMART data is seen and no snapshot exists yet.
    @discardableResult
    static func autoSnapshot(_ drives: [DriveSnapshot]) -> [URL] {
        var written: [URL] = []
        for d in drives where d.smart != nil {
            let key = driveKey(d)
            lock.lock(); let isNew = seen.insert(key).inserted; lock.unlock()
            guard isNew, files(forKey: key).isEmpty else { continue }
            if let u = try? save(d) { written.append(u) }
        }
        return written
    }
}

// MARK: - Compare

struct CompareRow: Identifiable, Sendable {
    enum Verdict { case worse, better, same, info }
    var id: String { name }
    var name: String
    var before: String
    var after: String
    var delta: String
    var perDay: String
    var verdict: Verdict
}

enum SnapshotCompare {
    private enum Dir { case higherWorse, lowerWorse, neutral }
    private struct Metric {
        var name: String
        var value: (SMARTSnapshot) -> Double
        var format: (Double) -> String
        var dir: Dir
        var perDay = true
        var isTemp = false
    }

    private static func int(_ v: Double) -> String { HealthEvaluator.num(UInt64(max(v, 0))) }
    private static func tb(_ v: Double) -> String { String(format: "%.3f TB", v / 1e12) }

    private static let metrics: [Metric] = [
        Metric(name: "Critical Warning", value: { Double($0.criticalWarning) }, format: { String(format: "0x%02X", Int($0)) }, dir: .higherWorse, perDay: false),
        Metric(name: "Composite Temperature", value: { Double($0.temperatureC) }, format: { "\(Int($0)) °C" }, dir: .neutral, perDay: false, isTemp: true),
        Metric(name: "Available Spare", value: { Double($0.availableSparePct) }, format: { "\(Int($0)) %" }, dir: .lowerWorse),
        Metric(name: "Percentage Used (wear)", value: { Double($0.percentageUsed) }, format: { "\(Int($0)) %" }, dir: .higherWorse),
        Metric(name: "Data Written", value: { Double($0.bytesWritten) }, format: tb, dir: .neutral),
        Metric(name: "Data Read", value: { Double($0.bytesRead) }, format: tb, dir: .neutral),
        Metric(name: "Host Write Commands", value: { Double($0.hostWriteCommands) }, format: int, dir: .neutral),
        Metric(name: "Host Read Commands", value: { Double($0.hostReadCommands) }, format: int, dir: .neutral),
        Metric(name: "Controller Busy Time (min)", value: { Double($0.controllerBusyMinutes) }, format: int, dir: .neutral),
        Metric(name: "Power Cycles", value: { Double($0.powerCycles) }, format: int, dir: .neutral),
        Metric(name: "Power On Hours", value: { Double($0.powerOnHours) }, format: int, dir: .neutral),
        Metric(name: "Unsafe Shutdowns", value: { Double($0.unsafeShutdowns) }, format: int, dir: .higherWorse),
        Metric(name: "Media and Data Integrity Errors", value: { Double($0.mediaErrors) }, format: int, dir: .higherWorse),
        Metric(name: "Error Information Log Entries", value: { Double($0.errorLogEntries) }, format: int, dir: .higherWorse),
        Metric(name: "Time above Warning Temp (min)", value: { Double($0.warningTempMinutes) }, format: int, dir: .higherWorse),
        Metric(name: "Time above Critical Temp (min)", value: { Double($0.criticalTempMinutes) }, format: int, dir: .higherWorse),
    ]

    static func rows(_ a: SnapshotFile, _ b: SnapshotFile) -> [CompareRow] {
        guard let sa = a.smart, let sb = b.smart else { return [] }
        let days = b.takenAt.timeIntervalSince(a.takenAt) / 86400
        return metrics.map { m in
            let va = m.value(sa), vb = m.value(sb), d = vb - va
            var deltaText = "0"
            if d != 0 {
                let abs = m.format(Swift.abs(d))
                deltaText = (d > 0 ? "+" : "-") + (m.isTemp ? abs : abs)
            }
            var perDay = "-"
            if m.perDay, days >= 1.0 / 24, d != 0 {
                let p = d / days
                perDay = (p > 0 ? "+" : "-") + m.format(Swift.abs(p)) + "/day"
            }
            let verdict: CompareRow.Verdict
            if d == 0 { verdict = .same }
            else {
                switch m.dir {
                case .higherWorse: verdict = d > 0 ? .worse : .better
                case .lowerWorse: verdict = d < 0 ? .worse : .better
                case .neutral: verdict = .info
                }
            }
            return CompareRow(name: m.name, before: m.format(va), after: m.format(vb), delta: deltaText, perDay: perDay, verdict: verdict)
        }
    }

    /// Plain-text table for the CLI.
    static func text(_ a: SnapshotFile, _ b: SnapshotFile, labelA: String, labelB: String) -> String {
        let rows = rows(a, b)
        let df = ISO8601DateFormatter()
        var o = "Compare \(a.model) (\(a.firmware))\n  A: \(labelA)  \(df.string(from: a.takenAt))\n  B: \(labelB)  \(df.string(from: b.takenAt))\n"
        o += String(format: "  interval: %.2f days\n\n", b.takenAt.timeIntervalSince(a.takenAt) / 86400)
        func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
        o += pad("Counter", 34) + pad("Before", 18) + pad("After", 18) + pad("Delta", 16) + "Per day\n"
        for r in rows {
            let mark = r.verdict == .worse ? "  <-- worse" : ""
            o += pad(r.name, 34) + pad(r.before, 18) + pad(r.after, 18) + pad(r.delta, 16) + r.perDay + mark + "\n"
        }
        return o
    }
}
