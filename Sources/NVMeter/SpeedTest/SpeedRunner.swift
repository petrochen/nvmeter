import Foundation
import Observation

struct ChartPoint: Identifiable, Sendable {
    var id: Int
    var x: Double
    var mbps: Double
    var phase: SpeedPhase
}

/// UI-facing state of one speed test run.
@MainActor @Observable
final class SpeedTestRunner {
    var volumes: [SpeedVolume] = []
    var mountPoint = ""
    var mode: SpeedMode = .quick
    /// Sustained size in GB; 0 = until 10 % free.
    var sustainedGB: Double = 20
    var randomSeconds: Double = 30
    /// Live loop settings: test file size, time limit, write limit.
    var liveSizeGB: Double = 5
    var liveMinutes: Double = 10
    var liveMaxGB: Double = 500

    private(set) var running = false
    private(set) var points: [ChartPoint] = []
    private(set) var phase: SpeedPhase?
    private(set) var liveMBps = 0.0
    private(set) var liveIOPS = 0.0
    private(set) var bytesInPhase: Int64 = 0
    private(set) var totalWritten: Int64 = 0
    private(set) var tempMaxC: Int?
    private(set) var tempStartC: Int?
    private(set) var error: String?
    private(set) var result: SpeedResult?
    /// Live loop state: latest MB/s per direction, averages so far (first sample of each pass skipped),
    /// cycle number, bytes written in the run, start time and the reason the app stopped the loop itself.
    private(set) var liveWrite = 0.0
    private(set) var liveRead = 0.0
    private(set) var cycle = 0
    private(set) var startedAt: Date?
    private(set) var autoStop: String?
    @ObservationIgnored private var sums = (w: 0.0, wn: 0, r: 0.0, rn: 0)
    private(set) var avgWrite: Double?
    private(set) var avgRead: Double?
    /// The run on screen is a live loop (running or finished).
    var showsLive: Bool { running ? mode == .live : result?.mode == .live }
    /// Screenshot mode: show the demo run whatever drive is selected.
    private(set) var isDemo = false
    @ObservationIgnored private var control: SpeedControl?
    @ObservationIgnored private var xOffset = 0.0
    @ObservationIgnored private var lastPhaseX = 0.0

    var volume: SpeedVolume? { volumes.first { $0.mountPoint == mountPoint } }

    func refreshVolumes(mounts: [String]?, scoped: Bool, available: [SpeedVolume] = SpeedVolume.list()) {
        guard !running else { return }
        volumes = available
        if let mounts {
            let paths = Set(mounts)
            let matching = volumes.filter { paths.contains($0.mountPoint) }
            if scoped { volumes = matching }
            if !matching.contains(where: { $0.mountPoint == mountPoint }) {
                mountPoint = matching.count == 1 ? matching[0].mountPoint : ""
            }
        } else if scoped || volume == nil {
            mountPoint = ""
        }
    }

    func request() -> SpeedRequest {
        SpeedRequest(mountPoint: mountPoint, mode: mode,
                     sizeGB: mode == .sustained && sustainedGB > 0 ? sustainedGB : (mode == .live ? liveSizeGB : nil),
                     untilTenPercentFree: mode == .sustained && sustainedGB == 0, randomSeconds: randomSeconds,
                     liveSeconds: liveMinutes * 60, liveMaxBytes: Int64(liveMaxGB * 1e9))
    }

    var plannedBytes: Int64 { volume.map { SpeedJob.plannedBytes(request(), volume: $0) } ?? 0 }

    /// The drive under test, matched by the mount point of one of its volumes.
    func drive(in monitor: Monitor) -> DriveSnapshot? {
        monitor.drives.first { d in d.volumes.contains { $0.mountPoint == mountPoint } }
    }

    func start(monitor: Monitor) {
        guard !running, let vol = volume else { return }
        let d = drive(in: monitor)
        let key = d?.id ?? "vol:\(vol.mountPoint)"
        let name = d.map { $0.isUSBOther ? $0.displayName : $0.model } ?? vol.name
        let req = request()
        let ctl = SpeedControl()
        control = ctl
        running = true; error = nil; result = nil; points = []; phase = nil; xOffset = 0; lastPhaseX = 0
        liveMBps = 0; liveIOPS = 0; totalWritten = 0; bytesInPhase = 0
        liveWrite = 0; liveRead = 0; cycle = 0; startedAt = Date(); autoStop = nil
        sums = (0, 0, 0, 0); avgWrite = nil; avgRead = nil
        tempStartC = d?.temperatureC; tempMaxC = tempStartC
        Task { [weak self] in
            let outcome: Result<SpeedResult, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try SpeedJob.run(req, driveKey: key, driveName: name, control: ctl) { s in
                        Task { @MainActor in self?.apply(s, monitor: monitor) }
                    })
                } catch { return .failure(error) }
            }.value
            self?.finish(outcome, monitor: monitor, key: key)
        }
    }

    func cancel() { control?.cancel() }

    private func apply(_ s: SpeedSample, monitor: Monitor) {
        guard running else { return }
        if phase != s.phase { if phase != nil { xOffset = lastPhaseX }; phase = s.phase }
        let x = xOffset + s.t
        lastPhaseX = x
        points.append(ChartPoint(id: points.count, x: x, mbps: s.mbps, phase: s.phase))
        liveMBps = s.mbps; liveIOPS = s.iops; bytesInPhase = s.bytes
        if s.cycle > 0 {
            cycle = s.cycle; totalWritten = s.totalWritten
            if s.phase == .write { liveWrite = s.mbps } else { liveRead = s.mbps }
            if s.id > 1 {   // the first 0.5 s of a pass includes the ramp-up
                if s.phase == .write { sums.w += s.mbps; sums.wn += 1; avgWrite = sums.w / Double(sums.wn) }
                else { sums.r += s.mbps; sums.rn += 1; avgRead = sums.r / Double(sums.rn) }
            }
        } else if s.phase == .write || s.phase == .sustainedWrite { totalWritten = s.bytes }
        if let d = drive(in: monitor), let t = d.temperatureC {
            tempMaxC = max(tempMaxC ?? t, t)
            // Live loop safety net: stop when the drive reaches its own warning temperature.
            let warn = d.identify?.warningTempC ?? HealthEvaluator.fallbackWarnC
            if s.cycle > 0, autoStop == nil, t >= warn {
                autoStop = "Stopped at \(t) °C: the drive reached its warning temperature (\(warn) °C)"
                control?.cancel()
            }
        }
    }

    private func finish(_ outcome: Result<SpeedResult, Error>, monitor: Monitor, key: String) {
        running = false; control = nil
        switch outcome {
        case .success(var r):
            r.tempStartC = tempStartC; r.tempMaxC = tempMaxC
            if let autoStop { r.stopReason = autoStop }
            result = r
            SpeedHistory.shared.add(r)
        case .failure(let e):
            error = e.localizedDescription
        }
    }

    /// Screenshot mode only: a made-up live loop in progress (nothing is written).
    func loadLiveDemo() {
        isDemo = true
        mode = .live; running = false; error = nil; points = []; startedAt = Date().addingTimeInterval(-252)
        var x = 0.0, n = 0
        for c in 1...6 {
            for (phase, base, secs) in [(SpeedPhase.write, 1360.0, 3.7), (.read, 1690.0, 3.0)] {
                for i in stride(from: 0.5, through: secs, by: 0.5) {
                    let v = base * (i == 0.5 ? 0.82 : 1) - Double(c) * (phase == .write ? 9 : 3) + Double((n * 37) % 23) - 11
                    points.append(ChartPoint(id: n, x: x + i, mbps: v, phase: phase)); n += 1
                }
                x += secs
            }
        }
        liveWrite = 1318; liveRead = 1676; avgWrite = 1331; avgRead = 1679; cycle = 7
        totalWritten = 33_000_000_000; tempStartC = 41; tempMaxC = 49
        let stat = { (a: Double, lo: Double, hi: Double) in PhaseStat(avgMBps: a, minMBps: lo, maxMBps: hi, seconds: 22, bytes: 30_000_000_000) }
        var r = SpeedResult(mode: .live, driveKey: "demo", driveName: "Demo SSD", fileSystem: "APFS", volumeTotalBytes: 1_000_000_000_000,
                            volumeFreeBytes: 550_000_000_000, testBytes: 5_000_000_000, bytesWritten: 30_000_000_000)
        r.write = stat(1331, 1305, 1352); r.read = stat(1679, 1668, 1688)
        r.cycles = (1...6).map { LiveCycle(writeMBps: 1352 - Double($0) * 9, readMBps: 1688 - Double($0) * 3) }
        r.stopReason = "Time limit reached"; r.tempStartC = 41; r.tempMaxC = 49
        result = r
    }
}
