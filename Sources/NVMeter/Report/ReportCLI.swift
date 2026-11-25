import Foundation
import AppKit

/// CLI entry points: --report, --snapshot, --compare. Returns an exit code, or nil when no such flag is present.
enum ReportCLI {
    static func handle(_ args: [String]) -> Int32? {
        if let i = args.firstIndex(of: "--report") { return report(args, at: i) }
        if let i = args.firstIndex(of: "--snapshot") { return snapshot(args, at: i) }
        if let i = args.firstIndex(of: "--compare") { return compare(args, at: i) }
        return nil
    }

    private static func value(_ args: [String], _ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    private static func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    private static func select(_ sel: String, from drives: [DriveSnapshot]) -> [DriveSnapshot] {
        sel == "all" ? drives.filter { $0.smart != nil } : drives.filter { $0.bsdName == sel }
    }

    private static func report(_ args: [String], at i: Int) -> Int32 {
        guard args.indices.contains(i + 1), let fmtS = value(args, "--format"), let fmt = ReportFormat(rawValue: fmtS),
              let out = value(args, "--out") else {
            err("usage: --report <diskN|all> --format pdf|json|md --out <path> [--hide-serials] [--hide-volumes] [--paper a4|letter]")
            return 2
        }
        let sampler = Sampler()
        var drives = sampler.tick(full: true)
        var temps: [String: [ReportTempSample]] = [:], rates: [String: [ReportRateSample]] = [:]
        func addTemps() { for d in drives { if let t = d.smart?.temperatureC { temps[d.id, default: []].append(ReportTempSample(t: Date(), c: Double(t))) } } }
        addTemps()
        let seconds = 6
        for _ in 0..<seconds {
            Thread.sleep(forTimeInterval: 1)
            drives = sampler.tick(full: false)
            for d in drives { rates[d.id, default: []].append(ReportRateSample(t: Date(), readMBps: d.throughput.readMBps, writeMBps: d.throughput.writeMBps)) }
        }
        drives = sampler.tick(full: true)
        addTemps()
        let chosen = select(args[i + 1], from: drives)
        guard !chosen.isEmpty else { err("no matching disk with SMART: \(args[i + 1])"); return 1 }
        var charts: [String: ReportChartData] = [:]
        for d in chosen { charts[d.id] = ReportChartData(windowSeconds: Double(seconds), temps: temps[d.id] ?? [], rates: rates[d.id] ?? []) }
        let opts = ReportOptions(hideSerials: args.contains("--hide-serials"), hideVolumes: args.contains("--hide-volumes"))
        let doc = ReportBuilder.make(drives: chosen, charts: charts, options: opts)
        let paper = value(args, "--paper").flatMap(ReportPaper.init(rawValue:)) ?? ReportPaper.localeDefault
        let url = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try MainActor.assumeIsolated { try ReportExporter.write(doc, format: fmt, to: url, paper: paper) }
            print("wrote \(out)")
            return 0
        } catch { err("failed: \(error.localizedDescription)"); return 1 }
    }

    private static func snapshot(_ args: [String], at i: Int) -> Int32 {
        guard args.indices.contains(i + 1) else { err("usage: --snapshot <diskN|all>"); return 2 }
        let drives = Sampler().tick(full: true)
        let chosen = select(args[i + 1], from: drives)
        guard !chosen.isEmpty else { err("no matching disk with SMART: \(args[i + 1])"); return 1 }
        for d in chosen {
            do { let u = try SnapshotStore.save(d); print("\(d.bsdName): saved \(SnapshotStore.driveKey(d))/\(u.lastPathComponent)") }
            catch { err("\(d.bsdName): \(error.localizedDescription)"); return 1 }
        }
        return 0
    }

    /// `--compare diskN` (latest snapshot vs now), `--compare diskN A` (A vs now), `--compare diskN A B`.
    /// A and B are snapshot file names (with or without .json), a unique prefix of one, or "now".
    private static func compare(_ args: [String], at i: Int) -> Int32 {
        guard args.indices.contains(i + 1) else { err("usage: --compare <diskN> [<snapshotA> [<snapshotB>]]"); return 2 }
        let drives = Sampler().tick(full: true)
        guard let d = drives.first(where: { $0.bsdName == args[i + 1] && $0.smart != nil }) else {
            err("no matching disk with SMART: \(args[i + 1])"); return 1
        }
        let snaps = SnapshotStore.list(for: d)
        let extra = args[(i + 2)...].filter { !$0.hasPrefix("--") }
        func resolve(_ name: String) -> (SnapshotFile, String)? {
            if name == "now" { return (SnapshotFile.make(from: d), "now") }
            let n = name.hasSuffix(".json") ? String(name.dropLast(5)) : name
            if FileManager.default.fileExists(atPath: name), let s = SnapshotStore.load(URL(fileURLWithPath: name)) { return (s, name) }
            let hits = snaps.filter { $0.url.deletingPathExtension().lastPathComponent.hasPrefix(n) }
            return hits.count == 1 ? (hits[0].snap, hits[0].url.lastPathComponent) : nil
        }
        let a: (SnapshotFile, String)?, b: (SnapshotFile, String)?
        switch extra.count {
        case 0:
            guard let last = snaps.last else { err("no snapshots for \(d.bsdName) yet; run --snapshot \(d.bsdName)"); return 1 }
            a = (last.snap, last.url.lastPathComponent); b = resolve("now")
        case 1: a = resolve(extra[0]); b = resolve("now")
        default: a = resolve(extra[0]); b = resolve(extra[1])
        }
        guard let a, let b else { err("snapshot not found or ambiguous; available:\n" + snaps.map { "  " + $0.url.lastPathComponent }.joined(separator: "\n")); return 1 }
        print(SnapshotCompare.text(a.0, b.0, labelA: a.1, labelB: b.1))
        return 0
    }
}
