import Foundation

struct SamplePoint: Sendable {
    var key: String
    var ts: Int64
    var temp: Double?
    var read: Double
    var write: Double
}

/// One bucket of a (possibly down-sampled) series.
struct SeriesPoint: Sendable {
    var ts: Double
    var temp: Double?      // max temperature in the bucket
    var read: Double
    var write: Double
}

/// One hourly SMART snapshot (key counters only).
struct SmartRow: Sendable, Equatable {
    var key: String
    var ts: Double
    var unitsRead: UInt64
    var unitsWritten: UInt64
    var powerOnHours: UInt64
    var powerCycles: UInt64
    var unsafeShutdowns: UInt64
    var mediaErrors: UInt64
    var errorLogEntries: UInt64
    var percentageUsed: Int
    var availableSpare: Int
    var warnTempMinutes: UInt32
    var critTempMinutes: UInt32
    var criticalWarning: Int
    var tempC: Int

    /// One NVMe data unit = 1000 x 512 bytes.
    var bytesRead: Double { Double(unitsRead) * 512_000 }
    var bytesWritten: Double { Double(unitsWritten) * 512_000 }
}

struct HistoryDriveStats: Codable, Sendable {
    var key: String
    var name: String?
    var model: String
    var firstSeen: Date?
    var lastSeen: Date?
    var samples1s: Int
    var samples1m: Int
    var samples1h: Int
    var snapshots: Int
    var lastSnapshot: Date?
    var lastSnapshotTBWritten: Double?
    var lastSnapshotMediaErrors: Int?
}

struct HistoryStats: Codable, Sendable {
    var path: String
    var fileBytes: Int
    var walBytes: Int
    var keepDays: Int
    var drives: [HistoryDriveStats]
}

/// Persistent history in `~/Library/Application Support/NVMeter/history.sqlite` (WAL).
/// All database access happens on one private serial queue; callers never block the main thread
/// except `flush()` / `deleteAll()` which are meant for quit and the settings button.
final class HistoryStore: @unchecked Sendable {
    static var overridePath: String?
    static let shared: HistoryStore = {
        let path = overridePath ?? defaultPath
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        return HistoryStore(path: path)
    }()

    static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("NVMeter/history.sqlite").path
    }

    static let rawSeconds: Int64 = 2 * 3600
    static let minuteSeconds: Int64 = 30 * 86400
    static let keepOptions: [(days: Int, title: String)] = [(30, "30 days"), (90, "90 days"), (730, "2 years")]
    static var keepDays: Int {
        let d = UserDefaults.standard.integer(forKey: "historyKeepDays")
        return d > 0 ? d : 730
    }

    let path: String
    private let queue = DispatchQueue(label: "nvmeter.history", qos: .utility)
    private var db: SQLiteDB?
    private var sampleBuf: [SamplePoint] = []
    private var snapBuf: [SmartRow] = []
    private var drivesBuf: [String: (model: String, ts: Int64)] = [:]
    private var flushTimer: DispatchSourceTimer?
    private var compactTimer: DispatchSourceTimer?
    private(set) var openError: String?

    init(path: String, background: Bool = true) {
        self.path = path
        queue.sync {
            do {
                let d = try SQLiteDB(path: path)
                try d.exec("PRAGMA journal_mode=WAL")
                try d.exec("PRAGMA synchronous=NORMAL")
                try Self.migrate(d)
                self.db = d
            } catch { self.openError = "\(error)" }
        }
        guard background, db != nil else { return }
        let f = DispatchSource.makeTimerSource(queue: queue)
        f.schedule(deadline: .now() + 10, repeating: 10)
        f.setEventHandler { [weak self] in self?.flushLocked() }
        f.resume(); flushTimer = f
        let c = DispatchSource.makeTimerSource(queue: queue)
        c.schedule(deadline: .now() + 20, repeating: 300)
        c.setEventHandler { [weak self] in self?.compactLocked(now: Int64(Date().timeIntervalSince1970)) }
        c.resume(); compactTimer = c
    }

    private static func migrate(_ d: SQLiteDB) throws {
        try d.exec("""
        CREATE TABLE IF NOT EXISTS drives(
          key TEXT PRIMARY KEY, model TEXT NOT NULL DEFAULT '', first_seen INTEGER, last_seen INTEGER, custom_name TEXT);
        CREATE TABLE IF NOT EXISTS samples_1s(
          key TEXT NOT NULL, ts INTEGER NOT NULL, temp REAL, rd REAL NOT NULL, wr REAL NOT NULL,
          PRIMARY KEY(key, ts)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS samples_1m(
          key TEXT NOT NULL, ts INTEGER NOT NULL, temp_avg REAL, temp_max REAL, nt INTEGER NOT NULL,
          rd REAL NOT NULL, wr REAL NOT NULL, n INTEGER NOT NULL, PRIMARY KEY(key, ts)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS samples_1h(
          key TEXT NOT NULL, ts INTEGER NOT NULL, temp_avg REAL, temp_max REAL, nt INTEGER NOT NULL,
          rd REAL NOT NULL, wr REAL NOT NULL, n INTEGER NOT NULL, PRIMARY KEY(key, ts)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS smart_snapshots(
          key TEXT NOT NULL, ts INTEGER NOT NULL,
          data_units_read INTEGER, data_units_written INTEGER, power_on_hours INTEGER, power_cycles INTEGER,
          unsafe_shutdowns INTEGER, media_errors INTEGER, error_log_entries INTEGER, percentage_used INTEGER,
          available_spare INTEGER, warn_temp_minutes INTEGER, crit_temp_minutes INTEGER, critical_warning INTEGER,
          temp_c INTEGER, PRIMARY KEY(key, ts)) WITHOUT ROWID;
        PRAGMA user_version=1;
        """)
    }

    // MARK: Writing (async, batched)

    func noteDrive(key: String, model: String, at ts: Int64) {
        queue.async { [self] in
            if drivesBuf[key] == nil { drivesBuf[key] = (model, ts) }
        }
    }

    func record(_ pts: [SamplePoint]) { queue.async { [self] in sampleBuf.append(contentsOf: pts) } }
    func record(snapshot: SmartRow) { queue.async { [self] in snapBuf.append(snapshot) } }

    /// Writes everything buffered. Blocks until done (use on quit / in CLI modes).
    func flush() { queue.sync { flushLocked() } }

    private func flushLocked() {
        guard let db, !(sampleBuf.isEmpty && snapBuf.isEmpty && drivesBuf.isEmpty) else { return }
        let samples = sampleBuf, snaps = snapBuf, metas = drivesBuf
        sampleBuf = []; snapBuf = []; drivesBuf = [:]
        do {
            try db.transaction {
                for (k, m) in metas {
                    try db.run("INSERT OR IGNORE INTO drives(key, model, first_seen, last_seen) VALUES(?,?,?,?)",
                               [.text(k), .text(m.model), .int(m.ts), .int(m.ts)])
                    try db.run("UPDATE drives SET last_seen=max(IFNULL(last_seen,0),?), model=? WHERE key=?",
                               [.int(m.ts), .text(m.model), .text(k)])
                }
                for s in samples {
                    try db.run("INSERT OR REPLACE INTO samples_1s(key, ts, temp, rd, wr) VALUES(?,?,?,?,?)",
                               [.text(s.key), .int(s.ts), .opt(s.temp), .double(s.read), .double(s.write)])
                }
                if let last = samples.last {
                    for k in Set(samples.map(\.key)) {
                        try db.run("UPDATE drives SET last_seen=max(IFNULL(last_seen,0),?) WHERE key=?", [.int(last.ts), .text(k)])
                    }
                }
                for r in snaps {
                    func i(_ v: UInt64) -> SQLBind { .int(Int64(min(v, UInt64(Int64.max)))) }
                    try db.run("""
                        INSERT OR REPLACE INTO smart_snapshots VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                        """, [.text(r.key), .int(Int64(r.ts)), i(r.unitsRead), i(r.unitsWritten), i(r.powerOnHours), i(r.powerCycles),
                              i(r.unsafeShutdowns), i(r.mediaErrors), i(r.errorLogEntries), .int(Int64(r.percentageUsed)),
                              .int(Int64(r.availableSpare)), .int(Int64(r.warnTempMinutes)), .int(Int64(r.critTempMinutes)),
                              .int(Int64(r.criticalWarning)), .int(Int64(r.tempC))])
                }
            }
        } catch {
            // Keep the data for the next attempt unless the buffer is already large.
            if sampleBuf.count < 20_000 { sampleBuf = samples + sampleBuf }
            FileHandle.standardError.write(Data("NVMeter history flush failed: \(error)\n".utf8))
        }
    }

    // MARK: Compaction

    /// Rolls 1 s rows older than 2 h into 1 min rows, 1 min rows older than 30 d into 1 h rows, prunes by retention.
    func compact(now: Int64 = Int64(Date().timeIntervalSince1970)) { queue.sync { flushLocked(); compactLocked(now: now) } }

    private func compactLocked(now: Int64) {
        guard let db else { return }
        let keep = Int64(Self.keepDays) * 86400
        do {
            try db.transaction {
                let prune = now - keep
                for t in ["samples_1s", "samples_1m", "samples_1h", "smart_snapshots"] {
                    try db.run("DELETE FROM \(t) WHERE ts < ?", [.int(prune)])
                }
                let cut1m = (now - Self.rawSeconds) / 60 * 60
                try db.run("""
                    INSERT OR REPLACE INTO samples_1m(key, ts, temp_avg, temp_max, nt, rd, wr, n)
                    SELECT key, ts/60*60, AVG(temp), MAX(temp), COUNT(temp), AVG(rd), AVG(wr), COUNT(*)
                    FROM samples_1s WHERE ts < ? GROUP BY key, ts/60*60
                    """, [.int(cut1m)])
                try db.run("DELETE FROM samples_1s WHERE ts < ?", [.int(cut1m)])
                let cut1h = (now - Self.minuteSeconds) / 3600 * 3600
                try db.run("""
                    INSERT OR REPLACE INTO samples_1h(key, ts, temp_avg, temp_max, nt, rd, wr, n)
                    SELECT key, ts/3600*3600, SUM(IFNULL(temp_avg,0)*nt)/NULLIF(SUM(nt),0), MAX(temp_max), SUM(nt),
                           SUM(rd*n)/SUM(n), SUM(wr*n)/SUM(n), SUM(n)
                    FROM samples_1m WHERE ts < ? GROUP BY key, ts/3600*3600
                    """, [.int(cut1h)])
                try db.run("DELETE FROM samples_1m WHERE ts < ?", [.int(cut1h)])
            }
        } catch { FileHandle.standardError.write(Data("NVMeter history compaction failed: \(error)\n".utf8)) }
    }

    /// Removes all samples and snapshots (custom names are kept).
    func deleteAll() {
        queue.sync {
            sampleBuf = []; snapBuf = []
            guard let db else { return }
            try? db.transaction {
                for t in ["samples_1s", "samples_1m", "samples_1h", "smart_snapshots"] { try db.run("DELETE FROM \(t)") }
            }
            try? db.exec("PRAGMA wal_checkpoint(TRUNCATE); VACUUM")
        }
    }

    /// Direct database access on the store queue (demo seeding, tests).
    func withDB(_ body: (SQLiteDB) throws -> Void) rethrows {
        try queue.sync { flushLocked(); if let db { try body(db) } }
    }

    // MARK: Names

    func names() -> [String: String] {
        queue.sync {
            var out: [String: String] = [:]
            try? db?.query("SELECT key, custom_name FROM drives WHERE custom_name IS NOT NULL AND custom_name <> ''") {
                out[$0.text(0)] = $0.text(1)
            }
            return out
        }
    }

    /// nil or empty resets to the default name.
    func setName(key: String, name: String?) {
        queue.async { [self] in
            guard let db else { return }
            let n = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let now = Int64(Date().timeIntervalSince1970)
            try? db.run("INSERT OR IGNORE INTO drives(key, first_seen, last_seen) VALUES(?,?,?)", [.text(key), .int(now), .int(now)])
            try? db.run("UPDATE drives SET custom_name=? WHERE key=?", [(n?.isEmpty == false) ? .text(n!) : .null, .text(key)])
        }
    }

    // MARK: Reading

    private func read<T: Sendable>(_ body: @escaping @Sendable (SQLiteDB) -> T) async -> T? {
        await withCheckedContinuation { cont in
            queue.async { [self] in cont.resume(returning: db.map(body)) }
        }
    }

    /// Raw 1 s rows since `from` (used to refill the live graphs after a restart).
    func recentRaw(since from: Date) async -> [SamplePoint] {
        await read { db in
            var out: [SamplePoint] = []
            try? db.query("SELECT key, ts, temp, rd, wr FROM samples_1s WHERE ts >= ? ORDER BY ts",
                          [.int(Int64(from.timeIntervalSince1970))]) {
                out.append(SamplePoint(key: $0.text(0), ts: $0.int(1), temp: $0.optDouble(2), read: $0.double(3), write: $0.double(4)))
            }
            return out
        } ?? []
    }

    /// All tiers merged into `bucket`-second buckets (temperature = max, rates = weighted average), per drive.
    func series(from: Date, to: Date, bucket: Int) async -> [String: [SeriesPoint]] {
        let f = Int64(from.timeIntervalSince1970), t = Int64(to.timeIntervalSince1970), b = Int64(bucket)
        return await read { db in
            var out: [String: [SeriesPoint]] = [:]
            try? db.query("""
                SELECT key, ts/?1*?1 AS bt, SUM(tsum)/NULLIF(SUM(nt),0), MAX(tmax), SUM(rds)/SUM(n), SUM(wrs)/SUM(n) FROM (
                  SELECT key, ts, IFNULL(temp,0) AS tsum, temp AS tmax, temp IS NOT NULL AS nt, rd AS rds, wr AS wrs, 1 AS n
                    FROM samples_1s WHERE ts >= ?2 AND ts < ?3
                  UNION ALL
                  SELECT key, ts, IFNULL(temp_avg,0)*nt, temp_max, nt, rd*n, wr*n, n FROM samples_1m WHERE ts >= ?2 AND ts < ?3
                  UNION ALL
                  SELECT key, ts, IFNULL(temp_avg,0)*nt, temp_max, nt, rd*n, wr*n, n FROM samples_1h WHERE ts >= ?2 AND ts < ?3
                ) GROUP BY key, bt ORDER BY key, bt
                """, [.int(b), .int(f), .int(t)]) {
                out[$0.text(0), default: []].append(SeriesPoint(ts: Double($0.int(1)) + Double(b) / 2, temp: $0.optDouble(3),
                                                                 read: $0.double(4), write: $0.double(5)))
            }
            return out
        } ?? [:]
    }

    func snapshots(key: String, since: Date? = nil) async -> [SmartRow] {
        let s = Int64((since ?? .distantPast).timeIntervalSince1970.clamped(to: 0...4e9))
        return await read { db in
            var out: [SmartRow] = []
            try? db.query("""
                SELECT key, ts, data_units_read, data_units_written, power_on_hours, power_cycles, unsafe_shutdowns, media_errors,
                       error_log_entries, percentage_used, available_spare, warn_temp_minutes, crit_temp_minutes, critical_warning, temp_c
                FROM smart_snapshots WHERE key=? AND ts>=? ORDER BY ts
                """, [.text(key), .int(s)]) { r in
                out.append(SmartRow(key: r.text(0), ts: Double(r.int(1)), unitsRead: UInt64(max(0, r.int(2))),
                                    unitsWritten: UInt64(max(0, r.int(3))), powerOnHours: UInt64(max(0, r.int(4))),
                                    powerCycles: UInt64(max(0, r.int(5))), unsafeShutdowns: UInt64(max(0, r.int(6))),
                                    mediaErrors: UInt64(max(0, r.int(7))), errorLogEntries: UInt64(max(0, r.int(8))),
                                    percentageUsed: Int(r.int(9)), availableSpare: Int(r.int(10)),
                                    warnTempMinutes: UInt32(clamping: r.int(11)), critTempMinutes: UInt32(clamping: r.int(12)),
                                    criticalWarning: Int(r.int(13)), tempC: Int(r.int(14))))
            }
            return out
        } ?? []
    }

    func stats() -> HistoryStats {
        queue.sync {
            flushLocked()
            var drives: [HistoryDriveStats] = []
            if let db {
                try? db.query("SELECT key, custom_name, model, first_seen, last_seen FROM drives ORDER BY first_seen") { r in
                    drives.append(HistoryDriveStats(key: r.text(0), name: r.optText(1), model: r.text(2),
                        firstSeen: r.isNull(3) ? nil : Date(timeIntervalSince1970: Double(r.int(3))),
                        lastSeen: r.isNull(4) ? nil : Date(timeIntervalSince1970: Double(r.int(4))),
                        samples1s: 0, samples1m: 0, samples1h: 0, snapshots: 0))
                }
                for i in drives.indices {
                    let k = [SQLBind.text(drives[i].key)]
                    drives[i].samples1s = Int(db.scalarInt("SELECT COUNT(*) FROM samples_1s WHERE key=?", k))
                    drives[i].samples1m = Int(db.scalarInt("SELECT COUNT(*) FROM samples_1m WHERE key=?", k))
                    drives[i].samples1h = Int(db.scalarInt("SELECT COUNT(*) FROM samples_1h WHERE key=?", k))
                    drives[i].snapshots = Int(db.scalarInt("SELECT COUNT(*) FROM smart_snapshots WHERE key=?", k))
                    try? db.query("SELECT ts, data_units_written, media_errors FROM smart_snapshots WHERE key=? ORDER BY ts DESC LIMIT 1", k) {
                        drives[i].lastSnapshot = Date(timeIntervalSince1970: Double($0.int(0)))
                        drives[i].lastSnapshotTBWritten = Double($0.int(1)) * 512_000 / 1e12
                        drives[i].lastSnapshotMediaErrors = Int($0.int(2))
                    }
                }
            }
            func size(_ p: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? Int) ?? 0 }
            return HistoryStats(path: path, fileBytes: size(path), walBytes: size(path + "-wal"), keepDays: Self.keepDays, drives: drives)
        }
    }
}

extension Double {
    func clamped(to r: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, r.lowerBound), r.upperBound) }
}
