import Foundation

/// `NVMeter --speedtest <mountpoint> --mode quick|sustained|random [--size GB] [--seconds N]` prints JSON and exits.
/// `--allow-boot` is required for the startup volume. Progress goes to stderr.
enum SpeedCLI {
    static func arg(_ flag: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static func run() -> Never {
        func fail(_ m: String) -> Never { FileHandle.standardError.write(Data("error: \(m)\n".utf8)); exit(2) }
        guard let mp = arg("--speedtest") else { fail("usage: --speedtest <mountpoint> --mode quick|sustained|random [--size GB] [--seconds N]") }
        guard let mode = SpeedMode(rawValue: arg("--mode") ?? "quick") else { fail("--mode must be quick, sustained or random") }
        guard let vol = SpeedVolume.find(mountPoint: mp) else { fail("not a writable local volume: \(mp)") }
        if vol.isBoot, !CommandLine.arguments.contains("--allow-boot") { fail("refusing the startup volume without --allow-boot") }
        var req = SpeedRequest(mountPoint: vol.mountPoint, mode: mode)
        if let s = arg("--size") { if s == "free10" { req.untilTenPercentFree = true } else if let g = Double(s) { req.sizeGB = g } else { fail("bad --size") } }
        if let s = arg("--seconds"), let d = Double(s) { req.randomSeconds = d }

        let sampler = Sampler()
        func driveInfo() -> (key: String, name: String, temp: Int?) {
            let drives = sampler.tick(full: true)
            guard let d = drives.first(where: { $0.volumes.contains { $0.mountPoint == vol.mountPoint } }) else { return ("vol", "unknown", nil) }
            return (d.id, d.isUSBOther ? d.displayName : d.model, d.temperatureC)
        }
        let before = driveInfo()
        let control = SpeedControl()
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { control.cancel() }
            src.resume()
            signalSources.append(src)
        }
        var tempMax = before.temp
        let tempLock = NSLock()
        let poller = Thread {
            while !Thread.current.isCancelled {
                Thread.sleep(forTimeInterval: 5)
                let t = driveInfo().temp
                tempLock.lock(); if let t { tempMax = max(tempMax ?? t, t) }; tempLock.unlock()
            }
        }
        poller.start()
        do {
            var res = try SpeedJob.run(req, driveKey: before.key, driveName: before.name, control: control) { s in
                if s.id % 4 == 0 {
                    FileHandle.standardError.write(Data(String(format: "%@ %.0fs %.0f MB/s\n", s.phase.rawValue, s.t, s.mbps).utf8))
                }
            }
            poller.cancel()
            let after = driveInfo().temp
            tempLock.lock(); res.tempStartC = before.temp; res.tempMaxC = [tempMax, after].compactMap { $0 }.max(); tempLock.unlock()
            res.driveKey = "drive"   // do not print serial numbers
            if res.series != nil, CommandLine.arguments.contains("--no-series") { res.series = nil }
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
            FileHandle.standardOutput.write(try enc.encode(res)); print()
            exit(0)
        } catch { fail(error.localizedDescription) }
    }

    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []

    /// `--speedtest-selftest`: checks the cliff detector on synthetic series.
    static func selfTest() {
        var a = [Double](repeating: 3000, count: 60) + [Double](repeating: 1000, count: 100)   // 30 s fast, 50 s slow
        var info = CliffDetector.detect(series: a)
        print("cliff series:", info.map { String(format: "%.0f GB at %.0f MB/s then %.0f", $0.fullSpeedGB, $0.fullSpeedMBps, $0.afterMBps) } ?? "none")
        a = (0..<200).map { _ in 2500 + Double.random(in: -150...150) }
        info = CliffDetector.detect(series: a)
        print("flat series:", info == nil ? "no cliff (ok)" : "FALSE POSITIVE")
        a = [Double](repeating: 3000, count: 60) + [Double](repeating: 1000, count: 20) + [Double](repeating: 3000, count: 100)
        info = CliffDetector.detect(series: a)
        print("transient dip:", info == nil ? "no cliff (ok)" : "FALSE POSITIVE")
    }
}
