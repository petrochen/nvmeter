import Foundation
import Observation
import os

// MARK: - Plan and results

/// What one drive does during an enclosure test.
enum DriveRole: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Reads files already on the volume, uncached. Writes nothing.
    case read
    /// Uses a temporary file: written in the write phases, read back in the read phases.
    case readWrite
    case skip
    var id: String { rawValue }
    var title: String {
        switch self { case .read: "Read only"; case .readWrite: "Read and write"; case .skip: "Skip" }
    }
}

enum EnclosureScenario: String, Codable, CaseIterable, Sendable, Identifiable {
    case readAll, writeAll, both, heat
    var id: String { rawValue }
    var title: String {
        switch self {
        case .readAll: "All drives reading"
        case .writeAll: "All drives writing"
        case .both: "Reading and writing at once"
        case .heat: "Heat soak"
        }
    }
    var question: String {
        switch self {
        case .readAll: "How much does the enclosure deliver through one cable?"
        case .writeAll: "How fast can you offload to all drives at once?"
        case .both: "Does copying from one drive to another slow the others down?"
        case .heat: "Do the drives get hot or slow down under long load?"
        }
    }
}

struct EnclosureTestDrive: Codable, Sendable, Identifiable, Hashable {
    var id: String              // drive key
    var name: String
    var slot: Int?
    var mountPoint: String
    var role: DriveRole
    var linkText: String?
    /// Practical ceiling of the slot's PCIe link in MB/s (0 when unknown).
    var ceilingMBps: Double
}

struct EnclosureTestPlan: Sendable {
    var enclosureName: String
    var linkText: String
    var budgetMBps: Double
    var drives: [EnclosureTestDrive]
    var scenarios: [EnclosureScenario]
    var secondsPerScenario: Double = 20
    var heatSeconds: Double = 300
    /// Size of the temporary file on read-and-write drives.
    var tempFileBytes: Int64 = 4_000_000_000

    var active: [EnclosureTestDrive] { drives.filter { $0.role != .skip } }
    var writers: [EnclosureTestDrive] { drives.filter { $0.role == .readWrite } }

    /// Scenarios that make sense for the chosen roles.
    var runnable: [EnclosureScenario] {
        scenarios.filter { s in
            switch s {
            case .readAll, .heat: !active.isEmpty
            case .writeAll: !writers.isEmpty
            case .both: !writers.isEmpty && active.count >= 2
            }
        }
    }

    /// Roles in a scenario: which drives read and which write. "Both" lets every other writer write while the rest
    /// read, so data goes in both directions through the enclosure at once.
    func roles(in s: EnclosureScenario) -> [String: Direction] {
        var out: [String: Direction] = [:]
        switch s {
        case .readAll:
            for d in active { out[d.id] = .read }
        case .writeAll:
            for d in writers { out[d.id] = .write }
        case .both, .heat:
            if writers.isEmpty { for d in active { out[d.id] = .read }; break }
            var writing = 0
            for d in active {
                if d.role == .readWrite, writing < max(1, active.count / 2) { out[d.id] = .write; writing += 1 }
                else { out[d.id] = .read }
            }
        }
        return out
    }

    /// Upper bound of bytes written, for the warning before the start.
    func plannedWriteBytes(assumingMBps rate: Double = 1600) -> Int64 {
        var seconds = 0.0
        for s in runnable {
            let writers = roles(in: s).values.filter { $0 == .write }.count
            seconds += Double(writers) * (s == .heat ? heatSeconds : secondsPerScenario)
        }
        return Int64(seconds * rate * 1e6) + Int64(writers.count) * tempFileBytes
    }

    enum Direction: String, Codable, Sendable { case read, write }
}

struct EnclosureDriveRate: Codable, Sendable, Equatable {
    var read: Double = 0
    var write: Double = 0
    var total: Double { read + write }
}

struct EnclosureScenarioResult: Codable, Sendable, Identifiable {
    var scenario: EnclosureScenario
    var seconds: Double
    var perDrive: [String: EnclosureDriveRate]
    var totalRead: Double
    var totalWrite: Double
    var findings: [String]
    var id: String { scenario.rawValue }
}

struct EnclosureHeat: Codable, Sendable {
    var startC: Int?
    var maxC: Int?
    /// Minute after which the temperature stayed within 1 °C of its maximum (nil when it kept rising).
    var plateauMinute: Double?
}

struct EnclosureTestResult: Codable, Sendable, Identifiable {
    var id = UUID()
    var date = Date()
    var enclosureName: String
    var linkText: String
    var budgetMBps: Double
    var drives: [EnclosureTestDrive]
    var scenarios: [EnclosureScenarioResult]
    var heat: [String: EnclosureHeat] = [:]
    var bytesWritten: Int64 = 0
    var stopReason: String?

    /// Findings recomputed from the stored speeds with the current rules (older results read correctly too).
    func findings(_ s: EnclosureScenarioResult) -> [String] {
        let plan = EnclosureTestPlan(enclosureName: enclosureName, linkText: linkText, budgetMBps: budgetMBps, drives: drives, scenarios: [])
        return EnclosureEngine.findings(per: s.perDrive, plan: plan)
    }

    /// Best single direction, plus both directions together when that was measured and adds something.
    var headline: String {
        guard let one = scenarios.map({ max($0.totalRead, $0.totalWrite) }).max() else { return "No result" }
        var s = String(format: "%.2f GB/s through one cable", one / 1000)
        if let both = scenarios.filter({ $0.totalRead > 0 && $0.totalWrite > 0 }).map({ $0.totalRead + $0.totalWrite }).max(), both > one * 1.05 {
            s += String(format: ", %.2f GB/s reading and writing at once", both / 1000)
        }
        return s
    }
}

/// Live sample of an enclosure test (10 per second).
struct EnclosureSample: Sendable {
    var scenario: EnclosureScenario
    var t: Double
    var perDrive: [String: EnclosureDriveRate]
    var chart: Bool
    var written: Int64
}

// MARK: - Engine

enum EnclosureEngine {
    final class Counter: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: (read: Int64(0), write: Int64(0), error: Int32(0)))
        func add(read: Int64 = 0, write: Int64 = 0) { lock.withLock { $0.read += read; $0.write += write } }
        var values: (read: Int64, write: Int64) { lock.withLock { ($0.read, $0.write) } }
        func fail(_ e: Int32) { lock.withLock { if $0.error == 0 { $0.error = e } } }
        var error: Int32 { lock.withLock { $0.error } }
    }

    static let block = 1 << 20
    static let streams = 4

    /// Large regular files already on a volume, for read-only drives: biggest first, up to `want` bytes. Skips hidden
    /// folders and the speed test folder; gives up looking after `maxEntries` entries.
    static func readableFiles(mountPoint: String, want: Int64 = 16_000_000_000, minSize: Int64 = 64_000_000,
                              maxEntries: Int = 50_000) -> [(url: URL, size: Int64)] {
        let root = URL(fileURLWithPath: mountPoint)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [(URL, Int64)] = []
        var seen = 0
        for case let u as URL in e {
            seen += 1
            if seen > maxEntries { break }
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let size = v.fileSize, Int64(size) >= minSize else { continue }
            found.append((u, Int64(size)))
        }
        found.sort { $0.1 > $1.1 }
        var out: [(url: URL, size: Int64)] = []
        var total: Int64 = 0
        for f in found where total < want { out.append((f.0, f.1)); total += f.1 }
        return out
    }

    private static func buffer() -> UnsafeMutableRawPointer {
        var p: UnsafeMutableRawPointer?
        posix_memalign(&p, 16384, block)
        let w = p!.bindMemory(to: UInt64.self, capacity: block / 8)
        var x: UInt64 = 0x9E3779B97F4A7C15 ^ UInt64(DispatchTime.now().uptimeNanoseconds)
        for i in 0..<(block / 8) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; w[i] = x }
        return p!
    }

    private static func openUncached(_ path: String, write: Bool) -> Int32 {
        let fd = Darwin.open(path, write ? O_WRONLY : O_RDONLY)
        if fd >= 0 { _ = fcntl(fd, F_NOCACHE, 1); if !write { _ = fcntl(fd, F_RDAHEAD, 0) } }
        return fd
    }

    /// Reads the files block by block, uncached, with `streams` threads, until `stop` is cancelled. Loops over the
    /// files again when it reaches the end.
    static func readLoop(files: [(url: URL, size: Int64)], counter: Counter, stop: SpeedControl) {
        let blocks = files.map { Int(($0.size + Int64(block) - 1) / Int64(block)) }
        let totalBlocks = blocks.reduce(0, +)
        guard totalBlocks > 0 else { return }
        let fds = files.map { openUncached($0.url.path, write: false) }
        defer { for fd in fds where fd >= 0 { close(fd) } }
        let next = OSAllocatedUnfairLock(initialState: 0)
        let group = DispatchGroup()
        for _ in 0..<streams {
            group.enter()
            Thread.detachNewThread {
                let buf = buffer()
                defer { free(buf); group.leave() }
                while !stop.isCancelled, counter.error == 0 {
                    var i = next.withLock { v -> Int in let n = v; v = (v + 1) % totalBlocks; return n }
                    var f = 0
                    while i >= blocks[f] { i -= blocks[f]; f += 1 }
                    guard fds[f] >= 0 else { continue }
                    let n = pread(fds[f], buf, block, off_t(i) * off_t(block))
                    if n < 0 { counter.fail(errno); break }
                    counter.add(read: Int64(n))
                }
            }
        }
        group.wait()
    }

    /// Writes `bytes` of incompressible data into `path` over and over (in place), until `stop` is cancelled.
    static func writeLoop(path: String, bytes: Int64, counter: Counter, stop: SpeedControl) {
        let fd = openUncached(path, write: true)
        guard fd >= 0 else { counter.fail(errno); return }
        defer { close(fd) }
        let totalBlocks = Int(bytes / Int64(block))
        let next = OSAllocatedUnfairLock(initialState: 0)
        let group = DispatchGroup()
        for _ in 0..<streams {
            group.enter()
            Thread.detachNewThread {
                let buf = buffer()
                defer { free(buf); group.leave() }
                while !stop.isCancelled, counter.error == 0 {
                    let i = next.withLock { v -> Int in let n = v; v = (v + 1) % totalBlocks; return n }
                    let n = pwrite(fd, buf, block, off_t(i) * off_t(block))
                    if n < 0 { counter.fail(errno); break }
                    counter.add(write: Int64(n))
                }
            }
        }
        group.wait()
    }

    /// Creates the temporary file of a read-and-write drive (written once, so read phases have data).
    static func prepareTempFile(mountPoint: String, bytes: Int64, control: SpeedControl) throws -> (dir: URL, path: String) {
        try SpeedEngine.checkSpace(mountPoint: mountPoint, needed: bytes)
        let dir = try SpeedEngine.makeRunDirectory(mountPoint: mountPoint)
        let path = dir.appendingPathComponent("enclosure.bin").path
        let fd = Darwin.open(path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
        guard fd >= 0 else { throw SpeedError.io("create test file", errno) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let buf = buffer()
        defer { free(buf); close(fd) }
        var off: Int64 = 0
        while off < bytes, !control.isCancelled {
            let n = pwrite(fd, buf, block, off_t(off))
            if n < 0 { throw SpeedError.io("write test file", errno) }
            off += Int64(n)
        }
        return (dir, path)
    }

    /// Runs the plan on the calling (background) thread. `extraStop` lets the caller end the test early (temperature).
    static func run(_ plan: EnclosureTestPlan, control: SpeedControl, status: @Sendable (String) -> Void,
                    progress: @Sendable (EnclosureSample) -> Void) -> EnclosureTestResult {
        var result = EnclosureTestResult(enclosureName: plan.enclosureName, linkText: plan.linkText,
                                         budgetMBps: plan.budgetMBps, drives: plan.drives, scenarios: [])
        var temp: [String: (dir: URL, path: String)] = [:]
        defer { for t in temp.values { SpeedEngine.removeRunDirectory(t.dir) } }
        var reads: [String: [(url: URL, size: Int64)]] = [:]
        var written: Int64 = 0

        for d in plan.active {
            if control.isCancelled { break }
            if d.role == .readWrite {
                status("Preparing a \(plan.tempFileBytes / 1_000_000_000) GB test file on \(d.name)")
                do {
                    temp[d.id] = try prepareTempFile(mountPoint: d.mountPoint, bytes: plan.tempFileBytes, control: control)
                    written += plan.tempFileBytes
                } catch { result.stopReason = "\(d.name): \(error.localizedDescription)"; return result }
                reads[d.id] = [(URL(fileURLWithPath: temp[d.id]!.path), plan.tempFileBytes)]
            } else {
                status("Looking for files to read on \(d.name)")
                let files = readableFiles(mountPoint: d.mountPoint)
                if files.reduce(Int64(0), { $0 + $1.size }) < 1_000_000_000 {
                    result.stopReason = "\(d.name) has less than 1 GB of large files to read. Use Read and write or skip it."
                    return result
                }
                reads[d.id] = files
            }
        }

        for s in plan.runnable {
            if control.isCancelled { break }
            status(s.title)
            let roles = plan.roles(in: s)
            let phase = SpeedControl()
            var counters: [String: Counter] = [:]
            let group = DispatchGroup()
            for (id, dir) in roles {
                let c = Counter(); counters[id] = c
                group.enter()
                let files = reads[id] ?? [], path = temp[id]?.path, size = plan.tempFileBytes
                Thread.detachNewThread {
                    defer { group.leave() }
                    if dir == .write, let path { writeLoop(path: path, bytes: size, counter: c, stop: phase) }
                    else { readLoop(files: files, counter: c, stop: phase) }
                }
            }
            let duration = s == .heat ? plan.heatSeconds : plan.secondsPerScenario
            let t0 = SpeedEngine.uptime()
            var meters: [String: (r: RateMeter, w: RateMeter)] = [:]
            for id in roles.keys { meters[id] = (RateMeter(t0: t0), RateMeter(t0: t0)) }
            var lastChart = t0
            // Steady-state averages skip the first 2 s (ramp-up).
            var base: [String: (r: Int64, w: Int64, t: Double)] = [:]
            var phaseWritten: Int64 = 0
            while !control.isCancelled {
                Thread.sleep(forTimeInterval: SpeedEngine.tickInterval)
                let t = SpeedEngine.uptime()
                var live: [String: EnclosureDriveRate] = [:]
                phaseWritten = 0
                for (id, c) in counters {
                    let v = c.values
                    phaseWritten += v.write
                    var m = meters[id]!
                    live[id] = EnclosureDriveRate(read: m.r.add(t, Double(v.read)) / 1e6, write: m.w.add(t, Double(v.write)) / 1e6)
                    meters[id] = m
                    if base[id] == nil, t - t0 >= 2 { base[id] = (v.read, v.write, t) }
                }
                let chart = t - lastChart >= SpeedEngine.sampleInterval - 0.02
                if chart { lastChart = t }
                progress(EnclosureSample(scenario: s, t: t - t0, perDrive: live, chart: chart, written: written + phaseWritten))
                if t - t0 >= duration { break }
                if counters.values.contains(where: { $0.error != 0 }) { break }
            }
            phase.cancel()
            group.wait()
            written += counters.values.reduce(Int64(0)) { $0 + $1.values.write }
            let tEnd = SpeedEngine.uptime()
            var per: [String: EnclosureDriveRate] = [:]
            for (id, c) in counters {
                let v = c.values
                let b = base[id] ?? (0, 0, t0)
                let dt = max(0.1, tEnd - b.t)
                per[id] = EnclosureDriveRate(read: Double(v.read - b.r) / dt / 1e6, write: Double(v.write - b.w) / dt / 1e6)
            }
            if let bad = counters.first(where: { $0.value.error != 0 }) {
                let name = plan.drives.first { $0.id == bad.key }?.name ?? "a drive"
                result.stopReason = "\(name): \(String(cString: strerror(bad.value.error)))"
            }
            let sr = EnclosureScenarioResult(scenario: s, seconds: tEnd - t0, perDrive: per,
                                             totalRead: per.values.reduce(0) { $0 + $1.read },
                                             totalWrite: per.values.reduce(0) { $0 + $1.write },
                                             findings: findings(per: per, plan: plan))
            result.scenarios.append(sr)
            if result.stopReason != nil { break }
        }
        result.bytesWritten = written
        if control.isCancelled, result.stopReason == nil { result.stopReason = "Stopped" }
        return result
    }

    /// Plain-language reading of one scenario: what limited the speed. USB4 / Thunderbolt carry each direction
    /// separately, so reading and writing are judged on their own: a direction counts as full at 85 % of the budget,
    /// a drive as "at its slot limit" at 90 % of its PCIe link's practical ceiling.
    static func findings(per: [String: EnclosureDriveRate], plan: EnclosureTestPlan) -> [String] {
        var out: [String] = []
        let busy = plan.drives.filter { per[$0.id] != nil }
        func label(_ d: EnclosureTestDrive) -> String { d.slot.map { "slot \($0) (\(d.name))" } ?? d.name }
        func rate(_ d: EnclosureTestDrive) -> Double { per[d.id].map { max($0.read, $0.write) } ?? 0 }
        func writes(_ d: EnclosureTestDrive) -> Bool { (per[d.id]?.write ?? 0) > (per[d.id]?.read ?? 0) }
        let gb = { (v: Double) in String(format: "%.2f GB/s", v / 1000) }
        let budget = String(format: "%.1f GB/s", plan.budgetMBps / 1000)
        let atSlot = busy.filter { $0.ceilingMBps > 0 && rate($0) >= $0.ceilingMBps * 0.9 }

        for (name, isWrite) in [("Reading", false), ("Writing", true)] {
            let drives = busy.filter { writes($0) == isWrite }
            let total = drives.reduce(0.0) { $0 + rate($1) }
            guard total > 0, plan.budgetMBps > 0 else { continue }
            let slowed = drives.filter { $0.ceilingMBps > 0 && rate($0) < $0.ceilingMBps * 0.9 }
            if total >= plan.budgetMBps * 0.85 {
                if slowed.isEmpty {
                    out.append("\(name) reaches \(gb(total)), close to the link's \(budget), with every drive at its own slot limit.")
                } else {
                    out.append("\(name) fills the enclosure link: \(gb(total)) of about \(budget). Sharing it slows down "
                               + slowed.map(label).joined(separator: ", ") + ".")
                }
            } else {
                out.append("\(name): \(gb(total)) of about \(budget); the link has room left.")
            }
        }
        let read = per.values.reduce(0) { $0 + $1.read }, write = per.values.reduce(0) { $0 + $1.write }
        if read > 0, write > 0, plan.budgetMBps > 0, read + write > plan.budgetMBps * 1.05 {
            out.append("Reading and writing add up to \(gb(read + write)): the link carries both directions at once.")
        }
        if !atSlot.isEmpty {
            out.append("At their slot's PCIe limit: " + atSlot.map { "\(label($0)) \(Fmt.rate(rate($0)))" }.joined(separator: ", ") + ".")
        }
        let writers = busy.filter(writes)
        if write > 0, writers.count == 1, plan.active.count > 1, read == 0 {
            out.append("Only \(label(writers[0])) writes; the other drives are read only.")
        }
        return out
    }

    /// Minute after which temperatures stayed within 1 °C of the maximum.
    static func heatSummary(_ samples: [(t: Double, c: Int)]) -> EnclosureHeat {
        guard let maxC = samples.map(\.c).max() else { return EnclosureHeat() }
        let firstNearMax = samples.first { $0.c >= maxC - 1 }?.t
        let rising = (samples.last?.c ?? maxC) >= maxC && samples.filter { $0.c >= maxC - 1 }.count < 3
        return EnclosureHeat(startC: samples.first?.c, maxC: maxC, plateauMinute: rising ? nil : firstNearMax.map { $0 / 60 })
    }
}

extension SpeedEngine {
    static func uptime() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }
}

// MARK: - Runner

@MainActor @Observable
final class EnclosureTestRunner {
    static let shared = EnclosureTestRunner()

    private(set) var running = false
    private(set) var status = ""
    private(set) var scenario: EnclosureScenario?
    private(set) var elapsed = 0.0
    private(set) var live: [String: EnclosureDriveRate] = [:]
    private(set) var written: Int64 = 0
    /// Total read / write per chart sample, per scenario run.
    private(set) var points: [EnclosurePoint] = []
    private(set) var temps: [String: [(t: Double, c: Int)]] = [:]
    private(set) var result: EnclosureTestResult?
    private(set) var plan: EnclosureTestPlan?
    @ObservationIgnored private var control: SpeedControl?
    @ObservationIgnored private var autoStop: String?
    @ObservationIgnored private var started = Date()
    @ObservationIgnored private var xOffset = 0.0
    @ObservationIgnored private var lastX = 0.0

    struct EnclosurePoint: Identifiable, Sendable {
        var id: Int
        var x: Double
        var read: Double
        var write: Double
        var scenario: EnclosureScenario
    }

    var totalRead: Double { live.values.reduce(0) { $0 + $1.read } }
    var totalWrite: Double { live.values.reduce(0) { $0 + $1.write } }

    func start(_ plan: EnclosureTestPlan, monitor: Monitor) {
        guard !running, !plan.runnable.isEmpty else { return }
        self.plan = plan
        let ctl = SpeedControl()
        control = ctl
        running = true; result = nil; points = []; temps = [:]; live = [:]; written = 0; scenario = nil
        autoStop = nil; started = Date(); xOffset = 0; lastX = 0; status = "Starting"
        Task { [weak self] in
            let res = await Task.detached(priority: .userInitiated) {
                EnclosureEngine.run(plan, control: ctl, status: { s in Task { @MainActor in self?.status = s } },
                                    progress: { s in Task { @MainActor in self?.apply(s, monitor: monitor) } })
            }.value
            self?.finish(res)
        }
    }

    func cancel() { control?.cancel() }

    private func apply(_ s: EnclosureSample, monitor: Monitor) {
        guard running else { return }
        if scenario != s.scenario { if scenario != nil { xOffset = lastX }; scenario = s.scenario }
        lastX = xOffset + s.t
        elapsed = Date().timeIntervalSince(started)
        live = s.perDrive
        written = s.written
        guard s.chart, let plan else { return }
        points.append(EnclosurePoint(id: points.count, x: lastX, read: totalRead, write: totalWrite, scenario: s.scenario))
        for d in plan.active {
            guard let snap = monitor.drives.first(where: { $0.id == d.id }), let c = snap.temperatureC else { continue }
            if temps[d.id]?.last?.c != c || Int(elapsed) % 5 == 0 { temps[d.id, default: []].append((elapsed, c)) }
            let warn = snap.identify?.warningTempC ?? HealthEvaluator.fallbackWarnC
            if c >= warn, autoStop == nil {
                autoStop = "Stopped at \(c) °C: \(d.name) reached its warning temperature (\(warn) °C)"
                control?.cancel()
            }
        }
    }

    private func finish(_ r: EnclosureTestResult) {
        var r = r
        if let autoStop { r.stopReason = autoStop }
        for (id, series) in temps { r.heat[id] = EnclosureEngine.heatSummary(series) }
        result = r
        running = false; control = nil; status = ""
        if !r.scenarios.isEmpty { EnclosureTestHistory.add(r) }
    }
}

/// Last enclosure test results, as JSON in Application Support (newest first, 20 kept).
enum EnclosureTestHistory {
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NVMeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("enclosure-tests.json")
    }
    static func load() -> [EnclosureTestResult] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? dec.decode([EnclosureTestResult].self, from: $0) } ?? []
    }
    static func add(_ r: EnclosureTestResult) {
        var all = load(); all.insert(r, at: 0); all = Array(all.prefix(20))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(all) { try? d.write(to: url, options: .atomic) }
    }
}

// MARK: - CLI

/// `NVMeter --enclosure-test [--rw <mountpoint>]... [--skip <mountpoint>]... [--scenarios readAll,writeAll,both,heat]
/// [--seconds N] [--heat-seconds N]`: tests the first USB4 / Thunderbolt enclosure. Every drive reads its existing
/// files unless listed with --rw (temporary file, written and read) or --skip. Prints JSON; progress on stderr.
enum EnclosureTestCLI {
    static func values(_ flag: String) -> [String] {
        let a = CommandLine.arguments
        return a.indices.filter { a[$0] == flag && $0 + 1 < a.count }.map { a[$0 + 1] }
    }

    static func makePlan(drives: [DriveSnapshot], rw: Set<String>, skip: Set<String>) -> EnclosureTestPlan? {
        guard let e = EnclosureTopology.build(drives, showOthers: false).enclosures.first else { return nil }
        let ds = e.slots.compactMap { s -> EnclosureTestDrive? in
            guard let v = s.drive.volumes.first(where: { !$0.mountPoint.isEmpty && !$0.readOnly }) ?? s.drive.volumes.first else { return nil }
            let role: DriveRole = skip.contains(v.mountPoint) ? .skip : rw.contains(v.mountPoint) ? .readWrite : .read
            return EnclosureTestDrive(id: s.drive.id, name: s.drive.displayName, slot: s.number, mountPoint: v.mountPoint, role: role,
                                      linkText: s.drive.link.map { LinkCheck.text($0) },
                                      ceilingMBps: s.drive.link.map { EnclosureAnalysis.slotCeiling($0) } ?? 0)
        }
        return EnclosureTestPlan(enclosureName: e.name, linkText: e.speedText, budgetMBps: e.budgetMBps, drives: ds,
                                 scenarios: EnclosureScenario.allCases.filter { $0 != .heat })
    }

    static func run() -> Never {
        let drives = Sampler().tick(full: true)
        guard var plan = makePlan(drives: drives, rw: Set(values("--rw")), skip: Set(values("--skip"))) else {
            FileHandle.standardError.write(Data("error: no USB4 / Thunderbolt enclosure with mounted volumes\n".utf8)); exit(2)
        }
        if let s = values("--scenarios").first { plan.scenarios = s.split(separator: ",").compactMap { EnclosureScenario(rawValue: String($0)) } }
        if let s = values("--seconds").first, let d = Double(s) { plan.secondsPerScenario = d }
        if let s = values("--heat-seconds").first, let d = Double(s) { plan.heatSeconds = d }
        let control = SpeedControl()
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        src.setEventHandler { control.cancel() }
        src.resume()
        let err = FileHandle.standardError
        let res = EnclosureEngine.run(plan, control: control, status: { err.write(Data("== \($0)\n".utf8)) }) { s in
            guard s.chart, Int((s.t * 2).rounded()) % 4 == 0 else { return }
            let r = s.perDrive.values.reduce(0) { $0 + $1.read }, w = s.perDrive.values.reduce(0) { $0 + $1.write }
            err.write(Data(String(format: "%@ %3.0fs read %6.0f write %6.0f MB/s\n", s.scenario.rawValue, s.t, r, w).utf8))
        }
        _ = src
        var out = res
        out.drives = out.drives.map { var d = $0; d.id = "slot-\($0.slot ?? 0)"; return d }   // no serials in the output
        var idMap: [String: String] = [:]
        for (a, b) in zip(res.drives, out.drives) { idMap[a.id] = b.id }
        out.scenarios = out.scenarios.map { s in var s = s; s.perDrive = Dictionary(uniqueKeysWithValues: s.perDrive.map { (idMap[$0.key] ?? $0.key, $0.value) }); return s }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        FileHandle.standardOutput.write((try? enc.encode(out)) ?? Data()); print()
        exit(out.scenarios.isEmpty ? 1 : 0)
    }
}
