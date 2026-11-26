import SwiftUI
import Charts

struct SpeedTestView: View {
    @Environment(Monitor.self) private var monitor
    var scopedDrive: DriveSnapshot? = nil
    private var runner: SpeedTestRunner { monitor.speedRunner }
    private var targetDrive: DriveSnapshot? { scopedDrive ?? monitor.selected }
    private var runMatchesScope: Bool {
        scopedDrive == nil || runner.drive(in: monitor)?.id == scopedDrive?.id
    }
    @State private var formatName = "ProRes 422 HQ 4K60"
    @State private var history = SpeedHistory.shared
    @State private var confirmBoot = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if runner.running && !runMatchesScope {
                    Text("A test is running on \(runner.volume?.name ?? runner.mountPoint).")
                    Button("Show running test") { monitor.tab = .speed }
                } else {
                    controls
                    if runner.running || runner.isDemo || (runner.result?.driveKey == driveKey && !runner.points.isEmpty) {
                        if runner.showsLive { LiveLoopCard(runner: runner) } else { liveCard }
                    }
                    if let e = runner.error { Card { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) } }
                    if let r = runner.result, r.driveKey == driveKey || runner.isDemo { ResultCard(result: r) }
                    verdictCard
                    historyCard
                }
            }.padding(16)
        }
        .onAppear { refreshVolumes() }
        .onChange(of: targetDrive?.volumes.map(\.mountPoint)) { _, _ in refreshVolumes() }
        .onChange(of: runner.running) { _, running in if !running { refreshVolumes() } }
        .confirmationDialog("This is the startup volume", isPresented: $confirmBoot) {
            Button("Test anyway") { start() }
        } message: {
            Text("The test writes \(runner.mode == .live ? "up to \(Int(runner.liveMaxGB))" : gb(runner.plannedBytes)) GB to your startup disk and may slow the Mac down while it runs.")
        }
    }

    private func refreshVolumes() {
        guard monitor.tab == (scopedDrive == nil ? .speed : .drives) else { return }
        runner.refreshVolumes(mounts: targetDrive?.volumes.map(\.mountPoint), scoped: scopedDrive != nil)
    }

    private func start() {
        let path = runner.mountPoint
        guard SpeedVolume.find(mountPoint: path) != nil,
              scopedDrive == nil || monitor.drives.contains(where: { d in
                  d.id == scopedDrive?.id && d.volumes.contains { $0.mountPoint == path }
              }) else {
            refreshVolumes()
            return
        }
        runner.start(monitor: monitor)
    }

    private func gb(_ b: Int64) -> String { String(format: "%.0f", Double(b) / 1e9) }

    // MARK: Controls

    private var controls: some View {
        Card("Speed Test") {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    @Bindable var r = runner
                    Picker("Volume", selection: $r.mountPoint) {
                        Text("Choose a writable volume").tag("")
                        ForEach(runner.volumes) { v in
                            Text("\(v.name)\(v.isBoot ? " (startup)" : "") - \(Fmt.capacity(UInt64(max(0, v.freeBytes)))) free").tag(v.mountPoint)
                        }
                    }.frame(maxWidth: 420).disabled(runner.running)
                    Picker("Test", selection: $r.mode) {
                        ForEach(SpeedMode.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).frame(maxWidth: 420).disabled(runner.running)
                    modeOptions
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    if runner.running {
                        Button(role: .cancel) { runner.cancel() } label: {
                            runner.mode == .live ? Label("Stop", systemImage: "stop.fill") : Label("Cancel", systemImage: "xmark.circle")
                        }.controlSize(.large)
                    } else {
                        Button {
                            if runner.volume?.isBoot == true { confirmBoot = true } else { start() }
                        } label: { Label(runner.volume.map { "Start on \($0.name)" } ?? "Start", systemImage: "play.fill") }
                            .controlSize(.large).buttonStyle(.borderedProminent).disabled(runner.volume == nil)
                    }
                    if let d = runner.drive(in: monitor) {
                        Text("\(d.isUSBOther ? d.displayName : d.model)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            warnings
        }
    }

    @ViewBuilder private var modeOptions: some View {
        @Bindable var r = runner
        switch runner.mode {
        case .quick:
            Text("5 GB sequential write, then read back uncached (1 MiB blocks, 4 write / 8 read streams).").font(.caption).foregroundStyle(.secondary)
        case .sustained:
            HStack {
                Picker("Write", selection: $r.sustainedGB) {
                    ForEach(SpeedRequest.sustainedChoices, id: \.self) { Text("\(Int($0)) GB").tag($0) }
                    Text("until 10 % free").tag(0.0)
                }.frame(maxWidth: 260).disabled(runner.running)
                Text("Plots MB/s every 0.5 s and looks for the SLC cache cliff.").font(.caption).foregroundStyle(.secondary)
            }
        case .random:
            Text("4 KB random reads on a 4 GB file, QD1 and QD32, \(Int(runner.randomSeconds)) s each.").font(.caption).foregroundStyle(.secondary)
        case .live:
            HStack(spacing: 12) {
                Picker("File", selection: $r.liveSizeGB) {
                    ForEach(SpeedRequest.liveSizeChoices, id: \.self) { Text("\(Int($0)) GB").tag($0) }
                }.frame(width: 120)
                Picker("Stop after", selection: $r.liveMinutes) {
                    ForEach(SpeedRequest.liveMinuteChoices, id: \.self) { Text("\(Int($0)) min").tag($0) }
                }.frame(width: 170)
                Picker("or", selection: $r.liveMaxGB) {
                    ForEach(SpeedRequest.liveMaxGBChoices, id: \.self) { Text("\(Int($0)) GB written").tag($0) }
                }.frame(width: 190)
            }.disabled(runner.running)
            Text("Writes the file and reads it back uncached, again and again, until you press Stop or a limit is reached. Also stops when the drive reaches its warning temperature.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var warnings: some View {
        let planned = runner.plannedBytes
        VStack(alignment: .leading, spacing: 4) {
            if runner.mode == .live {
                Label("The loop writes up to \(Int(runner.liveMaxGB)) GB in \(Int(runner.liveMinutes)) min (about 80 GB a minute on a fast SSD). Writing wears flash: keep runs short.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Label("This test writes about \(gb(planned)) GB to the SSD. Writing wears flash: use it sparingly.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let v = runner.volume {
                let needed = planned + planned / 20 + 2_000_000_000
                if v.freeBytes < needed {
                    Label("Not enough free space: about \(gb(needed)) GB needed, \(gb(v.freeBytes)) GB free.", systemImage: "externaldrive.badge.xmark").foregroundStyle(.red)
                }
                if v.isBoot { Label("Startup volume: the test file goes to your home folder and competes with macOS.", systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                if v.totalBytes > 0, Double(v.totalBytes - v.freeBytes) / Double(v.totalBytes) > 0.75 {
                    Label("The volume is more than 75 % full: results on QLC drives drop a lot as the drive fills.", systemImage: "info.circle").foregroundStyle(.secondary)
                }
            }
            Text("Results on QLC drives depend on how full the drive is. The test file is deleted afterwards, also after a cancel or crash.")
                .foregroundStyle(.secondary)
        }.font(.caption)
    }

    // MARK: Live

    private var liveCard: some View {
        Card(runner.phase?.title ?? "Speed Test") {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Fmt.rate(runner.liveMBps)).font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                    if runner.phase == .randomQD1 || runner.phase == .randomQD32 {
                        Text(String(format: "%.0f IOPS", runner.liveIOPS)).font(.callout.monospacedDigit())
                    } else {
                        Text(String(format: "%.1f GB in this phase", Double(runner.bytesInPhase) / 1e9)).font(.callout.monospacedDigit())
                    }
                    Label(Fmt.temp(runner.drive(in: monitor)?.temperatureC), systemImage: "thermometer.medium")
                        .font(.callout.monospacedDigit())
                    if let m = runner.tempMaxC { Text("max \(m) °C").font(.caption).foregroundStyle(.secondary) }
                    if runner.running { ProgressView().controlSize(.small) }
                }.frame(width: 170, alignment: .leading)
                Chart {
                    ForEach(runner.points) { p in
                        LineMark(x: .value("s", p.x), y: .value("MB/s", p.mbps), series: .value("phase", p.phase.rawValue))
                            .foregroundStyle(by: .value("phase", p.phase.title))
                            .interpolationMethod(.monotone)
                    }
                    if let c = runner.result?.cliff, let x = cliffX(c) {
                        RuleMark(x: .value("cliff", x)).foregroundStyle(.red).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .annotation(position: .top, alignment: .leading) { Text("cache full").font(.caption2).foregroundStyle(.red) }
                    }
                }
                .chartYAxisLabel("MB/s")
                .chartXAxisLabel("seconds")
                .chartYScale(domain: .automatic(includesZero: true))
                .frame(height: 220)
            }
        }
    }

    private func cliffX(_ c: CliffInfo) -> Double? {
        guard let s = runner.result?.series else { return nil }
        var cum = 0.0
        for (i, v) in s.enumerated() {
            cum += v * SpeedEngine.sampleInterval / 1000
            if cum >= c.fullSpeedGB { return Double(i + 1) * SpeedEngine.sampleInterval }
        }
        return nil
    }

    // MARK: Verdict + history

    private var driveKey: String { runner.drive(in: monitor)?.id ?? "vol:\(runner.mountPoint)" }

    private var verdictCard: some View {
        let hist = history.results(for: driveKey)
        return Card("Verdict for video (approximate)") {
            if let input = Verdict.input(from: hist) {
                Picker("Video format", selection: $formatName) {
                    ForEach(VideoFormats.all) { Text($0.name).tag($0.name) }
                }
                if let format = VideoFormats.all.first(where: { $0.name == formatName }),
                   let count = Verdict.streams(input.writeMBps, format) {
                    Text("Estimated simultaneous write streams: \(count)")
                }
                DisclosureGroup("Resolution and frame rate grid") { FormatGridView(writeMBps: input.writeMBps, readMBps: input.readMBps) }
                DisclosureGroup("Compare all formats") { VerdictTable(input: input) }
            }
            else { Text("Run a Quick, Live loop or Sustained write test to see which video formats this drive can record and play.").font(.callout).foregroundStyle(.secondary) }
        }
    }

    private var historyCard: some View {
        let hist = history.results(for: driveKey)
        return Card("Previous results for this drive") {
            if hist.isEmpty { Text("No results yet.").font(.callout).foregroundStyle(.secondary) }
            ForEach(hist.prefix(8)) { r in
                HStack {
                    Text(r.date, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                    Text(r.mode.title).frame(width: 120, alignment: .leading)
                    Text(ResultCard.summary(r)).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.0f %% full", r.fillPercent)).foregroundStyle(.secondary)
                    if let t = r.tempMaxC { Text("\(t) °C").foregroundStyle(.secondary) }
                }.font(.caption.monospacedDigit())
            }
        }
    }
}

struct ResultCard: View {
    let result: SpeedResult

    static func summary(_ r: SpeedResult) -> String {
        switch r.mode {
        case .quick: return "W \(Fmt.rate(r.write?.avgMBps ?? 0))  R \(Fmt.rate(r.read?.avgMBps ?? 0))"
        case .sustained:
            if let c = r.cliff { return String(format: "%.0f GB at %@, then %@", c.fullSpeedGB, Fmt.rate(c.fullSpeedMBps), Fmt.rate(c.afterMBps)) }
            return "avg \(Fmt.rate(r.write?.avgMBps ?? 0)), no cliff"
        case .random:
            return (r.random ?? []).map { "QD\($0.queueDepth) \(Int($0.iops)) IOPS" }.joined(separator: "  ")
        case .live:
            return "W \(Fmt.rate(r.write?.avgMBps ?? 0))  R \(Fmt.rate(r.read?.avgMBps ?? 0))  \(r.cycles?.count ?? 0) cycles"
        }
    }

    var body: some View {
        Card("Result") {
            switch result.mode {
            case .quick:
                HStack(spacing: 24) {
                    stat("Write", result.write)
                    if let r = result.read { stat("Read", r) }
                }
            case .sustained:
                stat("Average write", result.write)
                if let c = result.cliff {
                    Label(String(format: "Full speed for %.0f GB (%@), then %@", c.fullSpeedGB, Fmt.rate(c.fullSpeedMBps), Fmt.rate(c.afterMBps)), systemImage: "arrow.down.right.circle.fill")
                        .foregroundStyle(.orange).font(.headline)
                } else if !result.cancelled {
                    Label("No SLC cache cliff in \(Int(Double(result.write?.bytes ?? 0) / 1e9)) GB: write speed stayed steady. A bigger test may still find one.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            case .live:
                HStack(spacing: 24) {
                    stat("Write, all cycles", result.write)
                    stat("Read, all cycles", result.read)
                }
                Text("\(result.cycles?.count ?? 0) full cycles of \(String(format: "%.0f GB", Double(result.testBytes) / 1e9)). \(result.stopReason ?? "")")
                    .font(.callout)
            case .random:
                ForEach(result.random ?? [], id: \.queueDepth) { s in
                    Text(String(format: "QD%d: %.0f IOPS, %@, mean latency %.0f µs", s.queueDepth, s.iops, Fmt.rate(s.mbps), s.meanLatencyUs)).font(.callout.monospacedDigit())
                }
            }
            HStack(spacing: 14) {
                Text("Written to the SSD: \(String(format: "%.1f GB", Double(result.bytesWritten) / 1e9))")
                Text(String(format: "Volume %.0f %% full", result.fillPercent))
                if let t = result.tempStartC, let m = result.tempMaxC { Text("Temperature \(t) → \(m) °C") }
                if result.cancelled { Text("Cancelled").foregroundStyle(.orange) }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }

    private func stat(_ title: String, _ s: PhaseStat?) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(Fmt.rate(s?.avgMBps ?? 0)).font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
            if let s { Text("min \(Fmt.rate(s.minMBps)), max \(Fmt.rate(s.maxMBps))").font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

struct VerdictTable: View {
    let input: VerdictInput

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Write measured: \(input.writeMBps.map(Fmt.rate) ?? "-") (\(input.writeSource)). Read measured: \(input.readMBps.map(Fmt.rate) ?? "-") (\(input.readSource)). ✓ = the drive keeps up with one stream; the number is how many streams (multicam) fit.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    Text("Format").bold(); Text("Rate").bold(); Text("Write").bold(); Text("Read").bold()
                }.font(.caption)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(VideoFormats.all) { f in
                    GridRow {
                        Text(f.name)
                        Text(String(format: f.mBps >= 100 ? "%.0f MB/s" : "%.1f MB/s", f.mBps)).foregroundStyle(.secondary)
                        cell(Verdict.streams(input.writeMBps, f))
                        cell(Verdict.streams(input.readMBps, f))
                    }.font(.caption.monospacedDigit())
                }
            }
            Text("Data rates are approximate (Apple ProRes white paper, Blackmagic published rates, camera typicals); real rates vary with content.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func cell(_ n: Int?) -> some View {
        if let n {
            if n >= 1 { Text("✓ x\(n)").foregroundStyle(.green) } else { Text("✗").foregroundStyle(.red) }
        } else { Text("-").foregroundStyle(.secondary) }
    }
}
