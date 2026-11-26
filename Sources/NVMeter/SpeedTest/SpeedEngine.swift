import Foundation
import os

/// Shared cancel flag.
final class SpeedControl: @unchecked Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { flag.withLock { $0 } }
    func cancel() { flag.withLock { $0 = true } }
}

typealias SpeedProgress = @Sendable (SpeedSample) -> Void

/// Raw POSIX I/O engine: F_NOCACHE, several concurrent pwrite/pread streams, 1 MiB blocks.
/// Blocks until done: call it from a background thread.
enum SpeedEngine {
    static let block = 1 << 20
    static let writeStreams = 4
    static let readStreams = 8
    /// Chart points and the series the cliff detector reads: one value per 0.5 s.
    static let sampleInterval = 0.5
    /// Dial updates: every 0.1 s, as a rate over the last `RateMeter.window` seconds so the needles don't jitter.
    static let tickInterval = 0.1

    // MARK: Folder handling

    static let folderName = ".nvmeter-speedtest"

    /// Where test files for a volume go: the volume root, or the home folder for the (read-only root) boot volume.
    static func baseDirectory(forMountPoint mp: String) -> URL {
        mp == "/" ? URL(fileURLWithPath: NSHomeDirectory()) : URL(fileURLWithPath: mp)
    }

    static func makeRunDirectory(mountPoint: String) throws -> URL {
        let parent = baseDirectory(forMountPoint: mountPoint).appendingPathComponent(folderName, isDirectory: true)
        let run = parent.appendingPathComponent("run-\(getpid())-\(UUID().uuidString.prefix(8))", isDirectory: true)
        do { try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true) }
        catch { throw SpeedError.io("Cannot create test folder", EACCES) }
        return run
    }

    /// Removes the run folder, and the parent when it became empty.
    static func removeRunDirectory(_ run: URL) {
        try? FileManager.default.removeItem(at: run)
        let parent = run.deletingLastPathComponent()
        if let c = try? FileManager.default.contentsOfDirectory(atPath: parent.path), c.isEmpty { try? FileManager.default.removeItem(at: parent) }
    }

    /// Deletes run folders left behind by crashed or killed runs (owner pid no longer alive). Returns the count.
    @discardableResult
    static func cleanStale() -> Int {
        var roots = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey], options: [.skipHiddenVolumes]) ?? []
        roots.append(URL(fileURLWithPath: NSHomeDirectory()))
        var removed = 0
        for root in roots {
            let isLocal = (try? root.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? true
            guard isLocal else { continue }
            let parent = root.appendingPathComponent(folderName, isDirectory: true)
            guard let runs = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { continue }
            for r in runs {
                let parts = r.split(separator: "-")
                if parts.count >= 2, parts[0] == "run", let pid = Int32(parts[1]) {
                    if pid == getpid() || kill(pid, 0) == 0 { continue }       // a live run (maybe another NVMeter)
                }
                try? FileManager.default.removeItem(at: parent.appendingPathComponent(r))
                removed += 1
            }
            if let c = try? FileManager.default.contentsOfDirectory(atPath: parent.path), c.isEmpty { try? FileManager.default.removeItem(at: parent) }
        }
        return removed
    }

    // MARK: Primitives

    private static func makeBuffer(_ size: Int) -> UnsafeMutableRawPointer {
        var p: UnsafeMutableRawPointer?
        posix_memalign(&p, 16384, size)
        let buf = p!
        var x: UInt64 = 0x9E3779B97F4A7C15 ^ UInt64(DispatchTime.now().uptimeNanoseconds)
        let w = buf.bindMemory(to: UInt64.self, capacity: size / 8)
        for i in 0..<(size / 8) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; w[i] = x }   // xorshift64: incompressible
        return buf
    }

    private final class Shared: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: (next: 0, bytes: Int64(0), error: Int32(0)))
        func nextIndex() -> Int { lock.withLock { let n = $0.next; $0.next += 1; return n } }
        func add(_ b: Int64) { lock.withLock { $0.bytes += b } }
        var bytes: Int64 { lock.withLock { $0.bytes } }
        func fail(_ e: Int32) { lock.withLock { if $0.error == 0 { $0.error = e } } }
        var error: Int32 { lock.withLock { $0.error } }
    }

    private static func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

    private static func open(_ url: URL, flags: Int32) throws -> Int32 {
        let fd = Darwin.open(url.path, flags, 0o600)
        guard fd >= 0 else { throw SpeedError.io("open", errno) }
        _ = fcntl(fd, F_NOCACHE, 1)
        if flags & O_WRONLY == 0 { _ = fcntl(fd, F_RDAHEAD, 0) }
        return fd
    }

    /// Sequential pass over `totalBytes` with N concurrent streams. Each sample is MB/s over the last interval.
    private static func sequential(fd: Int32, totalBytes: Int64, write: Bool, streams: Int, phase: SpeedPhase,
                                   control: SpeedControl, progress: SpeedProgress?) throws -> (stat: PhaseStat, series: [Double]) {
        let blocks = Int((totalBytes + Int64(block) - 1) / Int64(block))
        let shared = Shared()
        let group = DispatchGroup()
        for _ in 0..<streams {
            group.enter()
            Thread.detachNewThread {
                let buf = makeBuffer(block)
                defer { free(buf); group.leave() }
                while !control.isCancelled, shared.error == 0 {
                    let i = shared.nextIndex()
                    if i >= blocks { break }
                    let off = Int64(i) * Int64(block)
                    let len = Int(min(Int64(block), totalBytes - off))
                    let n = write ? pwrite(fd, buf, len, off) : pread(fd, buf, len, off)
                    if n < 0 { shared.fail(errno); break }
                    if n == 0 { break }
                    shared.add(Int64(n))
                }
            }
        }
        let t0 = now()
        var meter = RateMeter(t0: t0)
        var last = t0, lastBytes: Int64 = 0, n = 0
        var series: [Double] = []
        while group.wait(timeout: .now() + tickInterval) == .timedOut {
            let t = now(), b = shared.bytes
            let mb = meter.add(t, Double(b)) / 1e6
            var chart = false
            if t - last >= sampleInterval - 0.02 {
                series.append(Double(b - lastBytes) / (t - last) / 1e6)
                last = t; lastBytes = b; chart = true
            }
            n += 1
            progress?(SpeedSample(id: n, phase: phase, t: t - t0, mbps: mb, iops: 0, bytes: b, chart: chart))
        }
        if write, shared.error == 0, !control.isCancelled { _ = fcntl(fd, F_FULLFSYNC) }
        let dur = now() - t0
        if shared.error != 0 { throw SpeedError.io(write ? "write" : "read", shared.error) }
        let b = shared.bytes
        let body = series.count > 2 ? Array(series.dropFirst().dropLast()) : series
        let stat = PhaseStat(avgMBps: dur > 0 ? Double(b) / dur / 1e6 : 0, minMBps: body.min() ?? 0, maxMBps: body.max() ?? 0, seconds: dur, bytes: b)
        return (stat, series)
    }

    // MARK: Tests

    /// Free bytes on the volume that holds the test folder.
    static func freeBytes(mountPoint: String) -> Int64 {
        let url = baseDirectory(forMountPoint: mountPoint)
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? Int64(v?.volumeAvailableCapacity ?? 0)
    }

    static func checkSpace(mountPoint: String, needed: Int64) throws {
        let free = freeBytes(mountPoint: mountPoint)
        if free < needed + needed / 20 + 2_000_000_000 { throw SpeedError.notEnoughSpace(needed: needed, free: free) }
    }

    /// Writes the test file, then reads it back uncached. `read` is nil when cancelled during the write.
    static func quick(dir: URL, bytes: Int64, control: SpeedControl, progress: SpeedProgress?) throws -> (write: PhaseStat, read: PhaseStat?) {
        let file = dir.appendingPathComponent("quick.bin")
        defer { try? FileManager.default.removeItem(at: file) }
        let wfd = try open(file, flags: O_CREAT | O_WRONLY | O_TRUNC)
        let w: PhaseStat
        do { w = try sequential(fd: wfd, totalBytes: bytes, write: true, streams: writeStreams, phase: .write, control: control, progress: progress).stat }
        catch { close(wfd); throw error }
        close(wfd)
        if control.isCancelled { return (w, nil) }
        let rfd = try open(file, flags: O_RDONLY)
        defer { close(rfd) }
        let r = try sequential(fd: rfd, totalBytes: bytes, write: false, streams: readStreams, phase: .read, control: control, progress: progress).stat
        return (w, r)
    }

    static func sustained(dir: URL, bytes: Int64, control: SpeedControl, progress: SpeedProgress?) throws -> (stat: PhaseStat, series: [Double]) {
        let file = dir.appendingPathComponent("sustained.bin")
        defer { try? FileManager.default.removeItem(at: file) }
        let fd = try open(file, flags: O_CREAT | O_WRONLY | O_TRUNC)
        defer { close(fd) }
        return try sequential(fd: fd, totalBytes: bytes, write: true, streams: writeStreams, phase: .sustainedWrite, control: control, progress: progress)
    }

    private final class RandCounter: @unchecked Sendable {
        let lock = OSAllocatedUnfairLock(initialState: (ops: Int64(0), latNs: Double(0)))
    }

    /// Prepares a file of `fileBytes`, then random 4K reads at QD1 and QD32 for `seconds` each.
    static func random(dir: URL, fileBytes: Int64, seconds: Double, control: SpeedControl, progress: SpeedProgress?) throws -> (prep: PhaseStat, stats: [RandomStat]) {
        let file = dir.appendingPathComponent("random.bin")
        defer { try? FileManager.default.removeItem(at: file) }
        let wfd = try open(file, flags: O_CREAT | O_WRONLY | O_TRUNC)
        let prep: PhaseStat
        do { prep = try sequential(fd: wfd, totalBytes: fileBytes, write: true, streams: writeStreams, phase: .write, control: control, progress: progress).stat }
        catch { close(wfd); throw error }
        close(wfd)
        var out: [RandomStat] = []
        if control.isCancelled { return (prep, out) }
        let rfd = try open(file, flags: O_RDONLY)
        defer { close(rfd) }
        let slots = fileBytes / 4096
        for (qd, phase) in [(1, SpeedPhase.randomQD1), (32, .randomQD32)] {
            if control.isCancelled { break }
            let counters = (0..<qd).map { _ in RandCounter() }
            let group = DispatchGroup()
            let t0 = now()
            let deadline = t0 + seconds
            for c in counters {
                group.enter()
                Thread.detachNewThread {
                    var raw: UnsafeMutableRawPointer?
                    posix_memalign(&raw, 4096, 4096)
                    defer { free(raw); group.leave() }
                    var gen = SystemRandomNumberGenerator()
                    var ops: Int64 = 0, lat = 0.0
                    while !control.isCancelled {
                        let s = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                        if Double(s) / 1e9 >= deadline { break }
                        let off = Int64.random(in: 0..<slots, using: &gen) * 4096
                        if pread(rfd, raw, 4096, off) != 4096 { break }
                        lat += Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - s)
                        ops += 1
                        if ops & 0x3F == 0 { let o = ops, l = lat; c.lock.withLock { $0.ops = o; $0.latNs = l } }
                    }
                    let o = ops, l = lat
                    c.lock.withLock { $0.ops = o; $0.latNs = l }
                }
            }
            var meter = RateMeter(t0: t0)
            var last = t0, n = 0
            while group.wait(timeout: .now() + tickInterval) == .timedOut {
                let t = now()
                let ops = counters.reduce(Int64(0)) { $0 + $1.lock.withLock { $0.ops } }
                n += 1
                let iops = meter.add(t, Double(ops))
                let chart = t - last >= sampleInterval - 0.02
                if chart { last = t }
                progress?(SpeedSample(id: n, phase: phase, t: t - t0, mbps: iops * 4096 / 1e6, iops: iops, bytes: ops * 4096, chart: chart))
            }
            let dur = now() - t0
            var ops: Int64 = 0, lat = 0.0
            for c in counters { let v = c.lock.withLock { $0 }; ops += v.ops; lat += v.latNs }
            guard ops > 0 else { continue }
            out.append(RandomStat(queueDepth: qd, iops: Double(ops) / dur, mbps: Double(ops) * 4096 / dur / 1e6,
                                  meanLatencyUs: lat / Double(ops) / 1000, seconds: dur))
        }
        return (prep, out)
    }

    // MARK: Live loop

    /// Writes the test file, reads it back uncached, and repeats until cancelled, `seconds` elapsed or `maxBytes`
    /// written (checked between passes, so the last pass always completes). Samples carry the cycle number and the
    /// bytes written in the whole run.
    static func live(dir: URL, bytes: Int64, seconds: Double, maxBytes: Int64, control: SpeedControl,
                     progress: SpeedProgress?) throws -> (cycles: [LiveCycle], write: PhaseStat?, read: PhaseStat?, written: Int64, stop: String) {
        let file = dir.appendingPathComponent("live.bin")
        defer { try? FileManager.default.removeItem(at: file) }
        let t0 = now()
        var written: Int64 = 0
        var cycles: [LiveCycle] = []
        var writes: [PhaseStat] = [], reads: [PhaseStat] = []
        var stop = "Stopped"
        var n = 0
        while true {
            if control.isCancelled { stop = "Stopped"; break }
            if now() - t0 >= seconds { stop = "Time limit reached"; break }
            if written + bytes > maxBytes { stop = "Write limit reached"; break }
            n += 1
            let cycle = n, base = written
            let wrap: SpeedProgress = { s in
                var s = s
                s.cycle = cycle
                s.totalWritten = base + (s.phase == .write ? s.bytes : bytes)
                progress?(s)
            }
            let wfd = try open(file, flags: O_CREAT | O_WRONLY)
            let w: PhaseStat
            do { w = try sequential(fd: wfd, totalBytes: bytes, write: true, streams: writeStreams, phase: .write, control: control, progress: wrap).stat }
            catch { close(wfd); throw error }
            close(wfd)
            written += w.bytes
            if control.isCancelled { stop = "Stopped"; break }
            let rfd = try open(file, flags: O_RDONLY)
            let r: PhaseStat
            do { r = try sequential(fd: rfd, totalBytes: bytes, write: false, streams: readStreams, phase: .read, control: control, progress: wrap).stat }
            catch { close(rfd); throw error }
            close(rfd)
            if control.isCancelled { stop = "Stopped"; break }
            writes.append(w); reads.append(r)
            cycles.append(LiveCycle(writeMBps: w.avgMBps, readMBps: r.avgMBps))
        }
        return (cycles, aggregate(writes), aggregate(reads), written, stop)
    }

    /// Average over several passes (total bytes / total time); min and max are the slowest and fastest pass.
    private static func aggregate(_ stats: [PhaseStat]) -> PhaseStat? {
        guard !stats.isEmpty else { return nil }
        let b = stats.reduce(Int64(0)) { $0 + $1.bytes }, t = stats.reduce(0.0) { $0 + $1.seconds }
        return PhaseStat(avgMBps: t > 0 ? Double(b) / t / 1e6 : 0, minMBps: stats.map(\.avgMBps).min() ?? 0,
                         maxMBps: stats.map(\.avgMBps).max() ?? 0, seconds: t, bytes: b)
    }
}

/// Rate over a sliding window: smooth enough for a needle, fresh enough for 10 updates a second.
struct RateMeter: Sendable {
    static let window = 0.5
    private var points: [(t: Double, v: Double)]
    init(t0: Double, start: Double = 0) { points = [(t0, start)] }

    /// Adds a cumulative value at time `t`; returns the rate per second over roughly the last `window` seconds.
    mutating func add(_ t: Double, _ v: Double) -> Double {
        points.append((t, v))
        while points.count > 2, t - points[1].t >= Self.window { points.removeFirst() }
        let f = points[0]
        return t > f.t ? (v - f.v) / (t - f.t) : 0
    }
}
