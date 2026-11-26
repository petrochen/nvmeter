import Foundation
import DiskArbitration

/// Tools of the NVMeter MCP server. Read-only unless the name says otherwise; the two state-changing tools
/// (speed_test, volume) need `confirm: true`.
@MainActor
enum MCPTools {
    // MARK: Definitions

    private static func schema(_ props: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": props, "required": required, "additionalProperties": false]
    }
    private static let driveArg: [String: Any] = ["type": "string", "description": "Volume name, BSD name (disk10), custom name or part of the model"]
    private static let serialsArg: [String: Any] = ["type": "boolean", "description": "Include serial numbers (default false)"]
    private static func readOnly(_ title: String) -> [String: Any] { ["title": title, "readOnlyHint": true, "openWorldHint": false] }

    static let definitions: [[String: Any]] = [
        ["name": "list_drives",
         "description": "All drives with a one-line status each: health, temperature vs the drive's own limits, wear, written TB, errors, unsafe shutdowns, where it sits (internal, enclosure and slot, USB), PCIe link and connection, volumes with read-only state, current MB/s (1 s sample), warnings and the latest connect check. Start here.",
         "inputSchema": schema(["include_serials": serialsArg]), "annotations": readOnly("List drives")],
        ["name": "drive_details",
         "description": "Everything about one drive: identity, every SMART field with status, NVMe identify limits, link, connection, volumes, usage trends from history (written per day, lifetime projection, errors added since first seen), latest connect check, recent speed test results.",
         "inputSchema": schema(["drive": driveArg, "include_serials": serialsArg], required: ["drive"]), "annotations": readOnly("Drive details")],
        ["name": "history",
         "description": "Temperature (max per bucket) and read / write MB/s over a window from NVMeter's history database, with min / max / average. Only covers time when the NVMeter app was running.",
         "inputSchema": schema([
            "drive": driveArg,
            "window": ["type": "string", "enum": ["1h", "6h", "24h", "7d", "30d"], "description": "Default 24h"],
            "points": ["type": "integer", "minimum": 6, "maximum": 240, "description": "Buckets per drive (default 48)"],
         ]), "annotations": readOnly("History")],
        ["name": "events",
         "description": "Recent NVMeter events: temperature alerts, SMART counters getting worse, link downgrades, USB fallback, removals, connect checks.",
         "inputSchema": schema(["drive": driveArg, "limit": ["type": "integer", "minimum": 1, "maximum": 200, "description": "Default 20"]]),
         "annotations": readOnly("Events")],
        ["name": "enclosures",
         "description": "External enclosures: mode and link speed, Mac port, shared bandwidth budget, each slot's drive, PCIe link and practical ceiling, and current read / write per slot and in total (1 s sample).",
         "inputSchema": schema(), "annotations": readOnly("Enclosures")],
        ["name": "compare_snapshots",
         "description": "SMART snapshot comparison for a drive: before, after, delta and delta per day. Default: newest snapshot vs now. With list: true, lists the snapshots.",
         "inputSchema": schema(["drive": driveArg, "a": ["type": "string", "description": "Snapshot name prefix (timestamp) or 'now'"],
                                "b": ["type": "string", "description": "Snapshot name prefix or 'now' (default now)"],
                                "list": ["type": "boolean"]], required: ["drive"]),
         "annotations": readOnly("Compare SMART snapshots")],
        ["name": "drive_report",
         "description": "A shareable drive report (warranty claim, resale, forum post) as Markdown or JSON, serials and volume names hidden by default.",
         "inputSchema": schema(["drive": driveArg, "format": ["type": "string", "enum": ["md", "json"]], "include_serials": serialsArg,
                                "hide_volumes": ["type": "boolean"]], required: ["drive"]),
         "annotations": readOnly("Drive report")],
        ["name": "speed_test",
         "description": "WRITES a temporary file to a volume and measures it (wears flash). quick: 5 GB write + uncached read; random: 4K QD1/QD32 reads; live: write/read loop for 'seconds'; sustained: long write with SLC cache cliff detection. Without confirm: true it only returns what it would do; set confirm only after the user agreed.",
         "inputSchema": schema([
            "volume": ["type": "string", "description": "Mount point or volume name"],
            "mode": ["type": "string", "enum": ["quick", "random", "live", "sustained"]],
            "size_gb": ["type": "number", "description": "Test file size (quick / live / random) or amount to write (sustained, max 100)"],
            "seconds": ["type": "number", "description": "live: time limit (max 300); random: seconds per queue depth (max 60)"],
            "confirm": ["type": "boolean"], "allow_startup": ["type": "boolean", "description": "Allow the startup volume"],
         ], required: ["volume", "mode"]),
         "annotations": ["title": "Speed test (writes)", "readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false]],
        ["name": "enclosure_test",
         "description": "Puts load on all drives of the (first) USB4 / Thunderbolt enclosure at once: all reading, all writing, both directions, optional heat soak. Answers what the shared link delivers and which slot or drive is the limit. Drives read their existing files (no writes) unless listed in read_write (temporary file, wears flash). Without confirm: true it only returns the plan; set confirm only after the user agreed.",
         "inputSchema": schema([
            "read_write": ["type": "array", "items": ["type": "string"], "description": "Volume names or mount points that may be written (temporary file)"],
            "skip": ["type": "array", "items": ["type": "string"], "description": "Volume names or mount points to leave out"],
            "scenarios": ["type": "array", "items": ["type": "string", "enum": ["readAll", "writeAll", "both", "heat"]], "description": "Default readAll, writeAll, both"],
            "seconds": ["type": "number", "description": "Seconds per scenario (default 20, max 60)"],
            "heat_minutes": ["type": "number", "description": "Heat soak length (default 5, max 20)"],
            "confirm": ["type": "boolean"],
         ]),
         "annotations": ["title": "Enclosure test", "readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false]],
        ["name": "volume",
         "description": "Unmount, mount, mount read-only, or remount read-only / read-write one volume of an external drive (an unmount plus a mount through DiskArbitration; fails without changes while apps hold files and says which). Without confirm: true it only returns what it would do.",
         "inputSchema": schema([
            "volume": ["type": "string", "description": "Volume name, mount point or BSD name (disk10s1)"],
            "action": ["type": "string", "enum": ["unmount", "mount", "mount_ro", "remount_ro", "remount_rw"]],
            "confirm": ["type": "boolean"],
         ], required: ["volume", "action"]),
         "annotations": ["title": "Mount / unmount volume", "readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false]],
    ]

    // MARK: Dispatch

    struct ToolError: Error { let message: String }

    static func call(_ name: String, _ a: [String: Any]) async -> (String, Bool) {
        do {
            let out: Any
            switch name {
            case "list_drives": out = try await listDrives(a)
            case "drive_details": out = try await driveDetails(a)
            case "history": out = try await history(a)
            case "events": out = try await events(a)
            case "enclosures": out = try await enclosures()
            case "compare_snapshots": out = try await compare(a)
            case "drive_report": out = try await report(a)
            case "speed_test": out = try await speedTest(a)
            case "volume": out = try await volume(a)
            case "enclosure_test": out = try await enclosureTest(a)
            default: throw ToolError(message: "Unknown tool \(name)")
            }
            if let s = out as? String { return (s, false) }
            let d = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .withoutEscapingSlashes])
            return (String(decoding: d, as: UTF8.self), false)
        } catch let e as ToolError {
            return (e.message, true)
        } catch {
            return ("\(error.localizedDescription)", true)
        }
    }

    // MARK: Shared helpers

    private static let store = HistoryStore(path: HistoryStore.defaultPath, background: false)

    /// Sampler / scanner instances are not safe to run concurrently in one process (the app only ever runs one):
    /// all sampling goes through this serial queue, and a result younger than 1.5 s is shared by parallel calls.
    nonisolated private static let sampleQueue = DispatchQueue(label: "nvmeter.mcp.sample")
    nonisolated(unsafe) private static var cached: (at: TimeInterval, drives: [DriveSnapshot])?

    /// Two full ticks one second apart: SMART, volumes and a 1 s throughput sample.
    static func sample() async -> [DriveSnapshot] {
        var drives = await withCheckedContinuation { (c: CheckedContinuation<[DriveSnapshot], Never>) in
            sampleQueue.async {
                if let hit = cached, ProcessInfo.processInfo.systemUptime - hit.at < 1.5 { c.resume(returning: hit.drives); return }
                let s = Sampler()
                _ = s.tick(full: true)
                usleep(1_000_000)
                let d = s.tick(full: true)
                cached = (ProcessInfo.processInfo.systemUptime, d)
                c.resume(returning: d)
            }
        }
        let names = store.names()
        for i in drives.indices { drives[i].customName = names[drives[i].id] }
        return drives
    }

    static func find(_ q: String?, in drives: [DriveSnapshot]) throws -> DriveSnapshot {
        guard let q, !q.isEmpty else { throw ToolError(message: "drive is required") }
        let l = q.lowercased().replacingOccurrences(of: "/dev/", with: "")
        let all = { (d: DriveSnapshot) in d.volumes + d.unmountedVolumes }
        if let d = drives.first(where: { $0.bsdName == l || $0.id == q })
            ?? drives.first(where: { $0.displayName.lowercased() == l || ($0.customName?.lowercased() == l) })
            ?? drives.first(where: { all($0).contains { $0.name.lowercased() == l || $0.mountPoint.lowercased() == l || $0.bsdName == l } })
            ?? drives.first(where: { $0.model.lowercased().contains(l) }) { return d }
        throw ToolError(message: "No drive matches '\(q)'. Drives: " + drives.map { "\($0.displayName) (\($0.bsdName), \($0.model))" }.joined(separator: "; "))
    }

    /// One decimal, encoded without binary noise (41.7, not 41.700000000000003).
    private static func r1(_ v: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.1f", v)) }

    private static func location(_ d: DriveSnapshot, _ layout: EnclosureTopology.Layout) -> String {
        for e in layout.enclosures {
            if let s = e.slots.first(where: { $0.drive.id == d.id }) {
                return [e.title, s.number.map { "slot \($0)" }].compactMap { $0 }.joined(separator: ", ")
            }
        }
        return d.isUSBOther ? d.subtitle : d.connection.summary
    }

    private static func volumeJSON(_ v: VolumeInfo, mounted: Bool) -> [String: Any] {
        var o: [String: Any] = ["name": v.name, "bsd": v.bsdName, "fs": v.fileSystem ?? "?", "mounted": mounted]
        if mounted {
            o["mountPoint"] = v.mountPoint; o["readOnly"] = v.readOnly
            o["freeGB"] = r1(Double(v.freeBytes) / 1e9); o["sizeGB"] = r1(Double(v.sizeBytes) / 1e9)
        }
        return o
    }

    // MARK: Read-only tools

    static func listDrives(_ a: [String: Any]) async throws -> Any {
        let drives = await sample()
        let layout = EnclosureTopology.build(drives, showOthers: true)
        let reports = ConnectCheck(url: ConnectCheck.defaultURL).reports
        let serials = a["include_serials"] as? Bool ?? false
        return ["drives": drives.map { d -> [String: Any] in
            var o: [String: Any] = [
                "name": d.displayName, "bsd": d.bsdName, "model": d.model, "location": location(d, layout),
                "interface": d.interface, "health": d.health.title,
                "volumes": d.volumes.map { volumeJSON($0, mounted: true) } + d.unmountedVolumes.map { volumeJSON($0, mounted: false) },
                "readMBps": r1(d.throughput.readMBps), "writeMBps": r1(d.throughput.writeMBps),
            ]
            if let v = d.vendor?.name { o["vendor"] = v }
            if serials { o["serial"] = d.serial }
            if let t = d.temperatureC { o["temperatureC"] = t }
            if let w = d.identify?.warningTempC { o["warningTempC"] = w }
            if let c = d.identify?.criticalTempC { o["criticalTempC"] = c }
            if let s = d.smart {
                o["wearPercent"] = s.percentageUsed; o["spare"] = "\(s.availableSparePct) % (threshold \(s.availableSpareThresholdPct) %)"
                o["writtenTB"] = NSDecimalNumber(string: String(format: "%.2f", s.terabytesWritten)); o["powerOnHours"] = s.powerOnHours
                o["mediaErrors"] = s.mediaErrors; o["unsafeShutdowns"] = s.unsafeShutdowns; o["powerCycles"] = s.powerCycles
            } else if let ata = d.ata {
                o["ata"] = ata.identity.kind
            } else {
                o["smart"] = d.smartError ?? "not available"
            }
            if !d.warnings.isEmpty { o["warnings"] = d.warnings }
            if let r = reports[d.id] { o["connectCheck"] = "\(r.date.ISO8601Format()): \(r.headline)" }
            return o
        }]
    }

    static func driveDetails(_ a: [String: Any]) async throws -> Any {
        let drives = await sample()
        var d = try find(a["drive"] as? String, in: drives)
        let layout = EnclosureTopology.build(drives, showOthers: true)
        if !(a["include_serials"] as? Bool ?? false) {
            d.serial = d.serial.isEmpty ? "" : "hidden"; d.identify?.serial = "hidden"; d.id = DriveKey.masked(d.id)
        }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        var o = (try JSONSerialization.jsonObject(with: enc.encode(d)) as? [String: Any]) ?? [:]
        for k in ["counters", "throughput"] { o[k] = nil }
        o["location"] = location(d, layout)
        o["displayName"] = d.displayName
        let real = try find(a["drive"] as? String, in: drives)
        let rows = await store.snapshots(key: real.id)
        if let t = UsageTrends.compute(rows: rows) {
            var u: [String: Any] = ["firstSeen": t.firstSeen.ISO8601Format(), "historyDays": r1(t.historyDays),
                                    "writtenSinceFirstSeenGB": r1(t.writtenSinceBytes / 1e9), "readSinceFirstSeenGB": r1(t.readSinceBytes / 1e9),
                                    "mediaErrorsAdded": t.mediaErrorsAdded, "errorLogAdded": t.errorLogAdded,
                                    "unsafeShutdownsAdded": t.unsafeShutdownsAdded]
            if let w = t.writtenPerDay7.perDay { u["writtenPerDay7dGB"] = r1(w / 1e9) }
            if let w = t.writtenPerDay30.perDay { u["writtenPerDay30dGB"] = r1(w / 1e9) }
            switch t.projection {
            case .notEnoughData(let why): u["lifetimeProjection"] = "not enough data: \(why)"
            case .noWrites: u["lifetimeProjection"] = "no writes recorded"
            case .reached: u["lifetimeProjection"] = "rated endurance reached"
            case .years(let y, let m): u["lifetimeProjection"] = String(format: "%.1f years (%@)", y, m)
            }
            o["usage"] = u
        }
        if let r = ConnectCheck(url: ConnectCheck.defaultURL).reports[real.id] {
            o["connectCheck"] = ["date": r.date.ISO8601Format(), "lines": r.lines.map { "\($0.level): \($0.text)" }]
        }
        let speed = SpeedHistory.shared.results(for: real.id).prefix(3)
        if !speed.isEmpty { o["speedTests"] = speed.map { "\($0.date.ISO8601Format()) \($0.mode.title): \(ResultCard.plain($0))" } }
        return o
    }

    static func history(_ a: [String: Any]) async throws -> Any {
        let windows: [String: Double] = ["1h": 3600, "6h": 21600, "24h": 86400, "7d": 604800, "30d": 2_592_000]
        let wName = a["window"] as? String ?? "24h"
        guard let w = windows[wName] else { throw ToolError(message: "window must be one of \(windows.keys.sorted())") }
        let points = min(240, max(6, a["points"] as? Int ?? 48))
        let drives = await sample()
        let chosen = try (a["drive"] as? String).map { [try find($0, in: drives)] } ?? drives
        let now = Date()
        let bucket = max(1, Int(w) / points)
        let series = await store.series(from: now.addingTimeInterval(-w), to: now, bucket: bucket)
        var out: [[String: Any]] = []
        for d in chosen {
            let pts = series[d.id] ?? []
            var o: [String: Any] = ["name": d.displayName, "bucketSeconds": bucket, "points": pts.count]
            let temps = pts.compactMap(\.temp)
            if !temps.isEmpty { o["tempC"] = ["min": r1(temps.min()!), "max": r1(temps.max()!), "avg": r1(temps.reduce(0, +) / Double(temps.count))] }
            if !pts.isEmpty {
                o["readMBps"] = ["max": r1(pts.map(\.read).max()!), "avg": r1(pts.map(\.read).reduce(0, +) / Double(pts.count))]
                o["writeMBps"] = ["max": r1(pts.map(\.write).max()!), "avg": r1(pts.map(\.write).reduce(0, +) / Double(pts.count))]
                o["columns"] = ["time", "tempMaxC", "readMBps", "writeMBps"]
                o["rows"] = pts.map { p -> [Any] in
                    [Date(timeIntervalSince1970: p.ts).ISO8601Format(), p.temp.map(r1) as Any? ?? NSNull(), r1(p.read), r1(p.write)]
                }
            } else {
                o["note"] = "No history in this window (NVMeter was not running or the drive was not connected)"
            }
            out.append(o)
        }
        return ["window": wName, "drives": out]
    }

    static func events(_ a: [String: Any]) async throws -> Any {
        let limit = min(200, max(1, a["limit"] as? Int ?? 20))
        var list = (UserDefaults.standard.data(forKey: AlertKeys.events).flatMap { try? JSONDecoder().decode([AlertEvent].self, from: $0) }) ?? []
        if let q = a["drive"] as? String {
            let d = try find(q, in: await sample())
            list = list.filter { $0.driveID == d.id || $0.drive == d.displayName }
        }
        return ["events": list.prefix(limit).map { e in
            ["date": e.date.ISO8601Format(), "severity": e.severity.rawValue, "rule": e.rule.rawValue, "drive": e.drive,
             "title": e.title, "body": e.body] as [String: Any]
        }]
    }

    static func enclosures() async throws -> Any {
        let drives = await sample()
        let layout = EnclosureTopology.build(drives, showOthers: false)
        if layout.enclosures.isEmpty { return "No USB4 / Thunderbolt / USB enclosures with NVMe drives are connected." }
        return ["enclosures": layout.enclosures.map { e -> [String: Any] in
            let rd = e.drives.reduce(0) { $0 + $1.throughput.readMBps }, wr = e.drives.reduce(0) { $0 + $1.throughput.writeMBps }
            var o: [String: Any] = ["name": e.name, "link": e.speedText, "sharedBudgetMBps": Int(e.budgetMBps),
                                    "readMBps": r1(rd), "writeMBps": r1(wr)]
            if let p = e.hostPort { o["macPort"] = p }
            if let f = e.firmware { o["firmware"] = f }
            o["slots"] = e.slots.map { s -> [String: Any] in
                var so: [String: Any] = ["slot": s.number as Any? ?? NSNull(), "drive": s.drive.displayName, "model": s.drive.model,
                                         "readMBps": r1(s.drive.throughput.readMBps), "writeMBps": r1(s.drive.throughput.writeMBps)]
                if let l = s.drive.link {
                    so["pcieLink"] = LinkCheck.text(l); so["slotCeilingMBps"] = Int(EnclosureAnalysis.slotCeiling(l))
                }
                if let t = s.drive.temperatureC { so["temperatureC"] = t }
                return so
            }
            return o
        }]
    }

    static func compare(_ a: [String: Any]) async throws -> Any {
        let drives = await sample()
        let d = try find(a["drive"] as? String, in: drives)
        guard d.smart != nil else { throw ToolError(message: "\(d.displayName) has no NVMe SMART data over this connection") }
        let snaps = SnapshotStore.list(for: d)
        if a["list"] as? Bool == true {
            return ["snapshots": snaps.map { $0.url.deletingPathExtension().lastPathComponent }]
        }
        func resolve(_ name: String?) throws -> (SnapshotFile, String) {
            guard let name, name != "now" else { return (SnapshotFile.make(from: d), "now") }
            let hits = snaps.filter { $0.url.deletingPathExtension().lastPathComponent.hasPrefix(name) }
            guard hits.count == 1 else {
                throw ToolError(message: "Snapshot '\(name)' \(hits.isEmpty ? "not found" : "is ambiguous"). Available: "
                                + snaps.map { $0.url.deletingPathExtension().lastPathComponent }.joined(separator: ", "))
            }
            return (hits[0].snap, hits[0].url.deletingPathExtension().lastPathComponent)
        }
        let first: (SnapshotFile, String)
        if let an = a["a"] as? String { first = try resolve(an) } else {
            guard let last = snaps.last else { throw ToolError(message: "No snapshots for \(d.displayName) yet") }
            first = (last.snap, last.url.deletingPathExtension().lastPathComponent)
        }
        let second = try resolve(a["b"] as? String)
        return SnapshotCompare.text(first.0, second.0, labelA: first.1, labelB: second.1)
    }

    static func report(_ a: [String: Any]) async throws -> Any {
        let drives = await sample()
        let d = try find(a["drive"] as? String, in: drives)
        let now = Date()
        let pts = await store.series(from: now.addingTimeInterval(-1800), to: now, bucket: 30)[d.id] ?? []
        let chart = ReportChartData(windowSeconds: 1800,
                                    temps: pts.compactMap { p in p.temp.map { ReportTempSample(t: Date(timeIntervalSince1970: p.ts), c: $0) } },
                                    rates: pts.map { ReportRateSample(t: Date(timeIntervalSince1970: $0.ts), readMBps: $0.read, writeMBps: $0.write) })
        let opts = ReportOptions(hideSerials: !(a["include_serials"] as? Bool ?? false), hideVolumes: a["hide_volumes"] as? Bool ?? false)
        let doc = ReportBuilder.make(drives: [d], charts: [d.id: chart], options: opts)
        if (a["format"] as? String) == "json" { return String(decoding: try doc.jsonData(), as: UTF8.self) }
        return ReportMarkdown.render(doc)
    }

    // MARK: State-changing tools

    static func speedTest(_ a: [String: Any]) async throws -> Any {
        guard let q = a["volume"] as? String, let modeS = a["mode"] as? String, let mode = SpeedMode(rawValue: modeS) else {
            throw ToolError(message: "volume and mode (quick, random, live, sustained) are required")
        }
        let vols = SpeedVolume.list()
        guard let vol = vols.first(where: { $0.mountPoint == q || $0.name.lowercased() == q.lowercased() }) else {
            throw ToolError(message: "No writable local volume '\(q)'. Volumes: " + vols.map(\.name).joined(separator: ", "))
        }
        if vol.isBoot, a["allow_startup"] as? Bool != true { throw ToolError(message: "\(vol.name) is the startup volume; pass allow_startup: true if the user wants that") }
        var req = SpeedRequest(mountPoint: vol.mountPoint, mode: mode)
        if let g = a["size_gb"] as? Double { req.sizeGB = mode == .sustained ? min(g, 100) : min(max(g, 1), 20) }
        else if mode == .sustained { req.sizeGB = 20 }
        let secs = a["seconds"] as? Double
        req.randomSeconds = min(secs ?? 10, 60)
        req.liveSeconds = min(secs ?? 60, 300)
        req.liveMaxBytes = 200_000_000_000
        let planned = SpeedJob.plannedBytes(req, volume: vol)
        let writes = mode == .live ? "up to \(Int(Double(req.liveMaxBytes) / 1e9)) GB over \(Int(req.liveSeconds)) s (a \(Int(Double(planned) / 1e9)) GB file rewritten in a loop)"
                                   : "about \(Int(Double(planned) / 1e9)) GB"
        guard a["confirm"] as? Bool == true else {
            return "Not started. A \(mode.title) test on \(vol.name) (\(vol.mountPoint)) writes \(writes) to the SSD (flash wear) "
                + "into a temporary folder that is deleted afterwards. Ask the user, then call again with confirm: true."
        }
        let drives = await sample()
        let d = drives.first { $0.volumes.contains { $0.mountPoint == vol.mountPoint } }
        let key = d?.id ?? "vol:\(vol.mountPoint)", name = d?.model ?? vol.name
        let control = SpeedControl()
        var res = try await Task.detached(priority: .userInitiated) {
            try SpeedJob.run(req, driveKey: key, driveName: name, control: control, progress: nil)
        }.value
        res.tempStartC = d?.temperatureC
        res.driveKey = "drive"; res.series = nil
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]; enc.dateEncodingStrategy = .iso8601
        var o = (try JSONSerialization.jsonObject(with: enc.encode(res)) as? [String: Any]) ?? [:]
        o["summary"] = ResultCard.plain(res)
        if let input = Verdict.input(from: [res]) {
            o["videoFormatsThatFit"] = VideoFormats.all.filter { (Verdict.streams(input.writeMBps, $0) ?? 0) >= 1 }.map(\.name)
        }
        o["note"] = "Not added to the app's speed test history."
        return o
    }

    static func volume(_ a: [String: Any]) async throws -> Any {
        guard let q = a["volume"] as? String, let action = a["action"] as? String else { throw ToolError(message: "volume and action are required") }
        let drives = await sample()
        let l = q.lowercased().replacingOccurrences(of: "/dev/", with: "")
        var hit: (DriveSnapshot, VolumeInfo, Bool)?
        for d in drives {
            if let v = d.volumes.first(where: { $0.bsdName == l || $0.name.lowercased() == l || $0.mountPoint.lowercased() == l }) { hit = (d, v, true); break }
            if let v = d.unmountedVolumes.first(where: { $0.bsdName == l || $0.name.lowercased() == l }) { hit = (d, v, false); break }
        }
        guard let (d, v, mounted) = hit else { throw ToolError(message: "No volume '\(q)'") }
        guard MountController.canManage(d, v) else { throw ToolError(message: "\(v.name) is on the internal drive or a system location: not managed") }
        let needsMounted = action.hasPrefix("remount") || action == "unmount"
        if needsMounted != mounted { throw ToolError(message: "\(v.name) is \(mounted ? "mounted" : "not mounted"); \(action) does not apply") }
        let what: String = switch action {
        case "unmount": "unmount \(v.name) (the drive stays connected)"
        case "mount": "mount \(v.name) read-write"
        case "mount_ro": "mount \(v.name) read-only"
        case "remount_ro": "unmount \(v.name) and mount it read-only"
        case "remount_rw": "unmount \(v.name) and mount it read-write"
        default: ""
        }
        if what.isEmpty { throw ToolError(message: "action must be unmount, mount, mount_ro, remount_ro or remount_rw") }
        guard a["confirm"] as? Bool == true else {
            return "Not done. This would \(what) (drive \(d.model)). Apps with open files make it fail without changes. Ask the user, then call again with confirm: true."
        }
        guard let session = DASessionCreate(kCFAllocatorDefault) else { throw ToolError(message: "DiskArbitration unavailable") }
        DASessionSetDispatchQueue(session, .main)
        var f: EjectController.Failure?
        switch action {
        case "unmount": f = await MountController.unmount(v.bsdName, session: session)
        case "mount", "mount_ro": f = await MountController.mount(v.bsdName, readOnly: action == "mount_ro", session: session)
        default:
            f = await MountController.unmount(v.bsdName, session: session)
            if f == nil, let g = await MountController.mount(v.bsdName, readOnly: action == "remount_ro", session: session) {
                _ = await MountController.mount(v.bsdName, readOnly: v.readOnly, session: session)
                f = g
            }
        }
        if let f {
            var msg = f.busy ? "\(v.name) is in use; nothing changed." : "Failed: \(f.message)"
            if f.busy, !v.mountPoint.isEmpty {
                let h = await VolumeHolders.find(mountPoint: v.mountPoint)
                if !h.isEmpty { msg += " Open files held by: " + h.map { "\($0.command) (pid \($0.pid))" }.joined(separator: ", ") }
            }
            throw ToolError(message: msg)
        }
        return "Done: \(what)."
    }

    static func enclosureTest(_ a: [String: Any]) async throws -> Any {
        let drives = await sample()
        func mounts(_ key: String) -> Set<String> {
            Set((a[key] as? [String] ?? []).compactMap { q in
                drives.flatMap(\.volumes).first { $0.name.lowercased() == q.lowercased() || $0.mountPoint == q }?.mountPoint
            })
        }
        guard var plan = EnclosureTestCLI.makePlan(drives: drives, rw: mounts("read_write"), skip: mounts("skip")) else {
            throw ToolError(message: "No USB4 / Thunderbolt enclosure with mounted volumes is connected.")
        }
        if let s = a["scenarios"] as? [String] { plan.scenarios = s.compactMap(EnclosureScenario.init(rawValue:)) }
        plan.secondsPerScenario = min(60, max(5, a["seconds"] as? Double ?? 20))
        plan.heatSeconds = min(20, max(1, a["heat_minutes"] as? Double ?? 5)) * 60
        guard !plan.runnable.isEmpty else { throw ToolError(message: "Nothing to run: writing scenarios need at least one read_write drive.") }
        let roles = plan.drives.map { "\($0.slot.map { "slot \($0)" } ?? "?") \($0.name): \($0.role.title.lowercased())" }.joined(separator: ", ")
        let w = plan.plannedWriteBytes()
        guard a["confirm"] as? Bool == true else {
            return "Not started. Enclosure \(plan.enclosureName): \(roles). Scenarios: \(plan.runnable.map(\.title).joined(separator: ", ")). "
                + (w == 0 ? "Writes nothing." : "Writes up to \(Int(Double(w) / 1e9)) GB (temporary files, deleted afterwards).")
                + " Ask the user, then call again with confirm: true."
        }
        let control = SpeedControl()
        let res = await Task.detached(priority: .userInitiated) { EnclosureEngine.run(plan, control: control, status: { _ in }, progress: { _ in }) }.value
        return [
            "enclosure": "\(res.enclosureName) · \(res.linkText)", "budgetMBps": Int(res.budgetMBps),
            "writtenGB": NSDecimalNumber(string: String(format: "%.1f", Double(res.bytesWritten) / 1e9)),
            "stopReason": res.stopReason as Any? ?? NSNull(),
            "scenarios": res.scenarios.map { s -> [String: Any] in
                ["scenario": s.scenario.title, "readMBps": Int(s.totalRead), "writeMBps": Int(s.totalWrite), "findings": s.findings,
                 "perDrive": res.drives.compactMap { d -> [String: Any]? in
                     guard let r = s.perDrive[d.id] else { return nil }
                     return ["slot": d.slot as Any? ?? NSNull(), "drive": d.name, "readMBps": Int(r.read), "writeMBps": Int(r.write)]
                 }]
            },
        ] as [String: Any]
    }
}
