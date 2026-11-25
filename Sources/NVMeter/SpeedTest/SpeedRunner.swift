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
    @ObservationIgnored private var control: SpeedControl?
    @ObservationIgnored private var xOffset = 0.0
    @ObservationIgnored private var lastPhaseX = 0.0

    var volume: SpeedVolume? { volumes.first { $0.mountPoint == mountPoint } }

    func refreshVolumes() {
        volumes = SpeedVolume.list()
        if volume == nil { mountPoint = volumes.first { !$0.isBoot }?.mountPoint ?? volumes.first?.mountPoint ?? "" }
    }

    func request() -> SpeedRequest {
        SpeedRequest(mountPoint: mountPoint, mode: mode, sizeGB: mode == .sustained && sustainedGB > 0 ? sustainedGB : nil,
                     untilTenPercentFree: mode == .sustained && sustainedGB == 0, randomSeconds: randomSeconds)
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
        tempStartC = d?.smart?.temperatureC; tempMaxC = tempStartC
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
        if s.phase == .write || s.phase == .sustainedWrite { totalWritten = s.bytes }
        if let t = drive(in: monitor)?.smart?.temperatureC { tempMaxC = max(tempMaxC ?? t, t) }
    }

    private func finish(_ outcome: Result<SpeedResult, Error>, monitor: Monitor, key: String) {
        running = false; control = nil
        switch outcome {
        case .success(var r):
            r.tempStartC = tempStartC; r.tempMaxC = tempMaxC
            result = r
            SpeedHistory.shared.add(r)
        case .failure(let e):
            error = e.localizedDescription
        }
    }
}
