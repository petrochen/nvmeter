import SwiftUI
import Charts

/// Speed Test, organised around what people want to know: how fast (dials and one Start button), whether it keeps up
/// with their footage (live grid), long takes, small files, heat, and the whole enclosure. Technical settings stay
/// in a popover and under "Details".
struct SpeedTestView: View {
    @Environment(Monitor.self) private var monitor
    var scopedDrive: DriveSnapshot? = nil
    private var runner: SpeedTestRunner { monitor.speedRunner }
    private var targetDrive: DriveSnapshot? { scopedDrive ?? monitor.selected }
    private var runMatchesScope: Bool {
        scopedDrive == nil || runner.drive(in: monitor)?.id == scopedDrive?.id
    }
    @State private var history = SpeedHistory.shared
    @State private var confirmBoot = false
    @State private var pendingStart: (() -> Void)?
    @State private var showSettings = false
    @State private var heatChoice: Double = 10

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if runner.running && !runMatchesScope {
                    Card {
                        Text("A test is running on \(runner.volume?.name ?? runner.mountPoint).")
                        Button("Show running test") { monitor.tab = .speed }
                    }
                } else if scopedDrive == nil, let enc = monitor.speedEnclosure {
                    targetPicker
                    EnclosureTestPanel(enclosureID: enc)
                } else {
                    if scopedDrive == nil { targetPicker }
                    SpeedHero(runner: runner, canStart: canStart, idleText: idleText) { guarded { runner.mode = .live; start() } }
                    notices
                    if let e = runner.error { Card { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) } }
                    footageCard
                    moreTests
                    if let r = runner.result, !runner.running, r.mode != .live || runner.isDemo, r.driveKey == driveKey || runner.isDemo {
                        ResultCard(result: r)
                    }
                    historyCard
                }
            }.padding(16)
        }
        .onAppear { refreshVolumes() }
        .onChange(of: targetDrive?.volumes.map(\.mountPoint)) { _, _ in refreshVolumes() }
        .onChange(of: runner.running) { _, running in if !running { refreshVolumes() } }
        .confirmationDialog("This is the startup volume", isPresented: $confirmBoot) {
            Button("Test anyway") { pendingStart?(); pendingStart = nil }
        } message: {
            Text("The test writes to your startup disk (in your home folder) and may slow the Mac down while it runs.")
        }
    }

    // MARK: Target

    private var enclosures: [EnclosureTopology.Enclosure] { EnclosureTopology.build(monitor.drives, showOthers: false).enclosures }

    /// Cards for every writable volume, plus "whole enclosure" cards.
    private var targetPicker: some View {
        @Bindable var r = runner
        @Bindable var m = monitor
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(enclosures) { e in
                    TargetCard(icon: AnyView(Image(systemName: "externaldrive.connected.to.line.below").font(.title2).foregroundStyle(.secondary)),
                               title: "Whole enclosure", subtitle: "\(e.name) · \(e.drives.count) drives", selected: m.speedEnclosure == e.id) {
                        m.speedEnclosure = e.id
                    }
                }
                ForEach(runner.volumes) { v in
                    let d = monitor.drives.first { $0.volumes.contains { $0.mountPoint == DemoNames.mountPoint(v.mountPoint) } }
                    TargetCard(icon: AnyView(VendorLogo(vendor: d?.vendor, height: 22)), title: DemoNames.name(v.name),
                               subtitle: "\(Fmt.capacity(UInt64(max(0, v.freeBytes)))) free" + (v.isBoot ? " · startup" : ""),
                               selected: m.speedEnclosure == nil && r.mountPoint == v.mountPoint) {
                        m.speedEnclosure = nil; r.mountPoint = v.mountPoint
                    }
                }
            }.padding(.vertical, 2)
        }.disabled(runner.running || EnclosureTestRunner.shared.running)
    }

    private func refreshVolumes() {
        guard monitor.tab == (scopedDrive == nil ? .speed : .drives) else { return }
        // The tab offers every volume and starts on the first external one; a drive's own section only its volumes.
        runner.refreshVolumes(mounts: scopedDrive?.volumes.map(\.mountPoint), scoped: scopedDrive != nil)
        if scopedDrive == nil, runner.mountPoint.isEmpty, monitor.speedEnclosure == nil {
            runner.mountPoint = runner.volumes.first { !$0.isBoot }?.mountPoint ?? runner.volumes.first?.mountPoint ?? ""
        }
    }

    private var canStart: Bool {
        guard let v = runner.volume else { return false }
        return v.freeBytes > runner.plannedBytes + runner.plannedBytes / 20 + 2_000_000_000
    }

    /// Runs `action` now, or after the startup-volume confirmation.
    private func guarded(_ action: @escaping () -> Void) {
        if runner.volume?.isBoot == true { pendingStart = action; confirmBoot = true } else { action() }
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

    private func gb(_ b: Double) -> String { String(format: "%.0f GB", b) }

    private var idleText: String {
        guard let v = runner.volume else { return "Choose a drive above." }
        return "Start writes a \(Int(runner.liveSizeGB)) GB test file to \(DemoNames.name(v.name)) and reads it back, again and again, "
            + "until you press Stop (at most \(Int(runner.liveMinutes)) min or \(Int(runner.liveMaxGB)) GB). The file is deleted afterwards."
    }

    // MARK: Notices (one line each, only when they apply)

    @ViewBuilder private var notices: some View {
        if let v = runner.volume, !runner.running {
            let needed = runner.plannedBytes + runner.plannedBytes / 20 + 2_000_000_000
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Writing wears flash a little; keep runs short.", systemImage: "info.circle")
                    Spacer()
                    Button { showSettings = true } label: { Label("Test settings", systemImage: "slider.horizontal.3") }
                        .buttonStyle(.link)
                        .popover(isPresented: $showSettings, arrowEdge: .bottom) { settings.padding(16).frame(width: 340) }
                }
                if v.freeBytes < needed {
                    Label("Not enough free space: about \(gb(Double(needed) / 1e9)) needed, \(gb(Double(v.freeBytes) / 1e9)) free.", systemImage: "externaldrive.badge.xmark").foregroundStyle(.red)
                }
                if v.isBoot { Label("Startup volume: the test competes with macOS and may slow the Mac down.", systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                if v.totalBytes > 0, Double(v.totalBytes - v.freeBytes) / Double(v.totalBytes) > 0.75 {
                    Label("More than 75 % full: drives with QLC flash get much slower as they fill.", systemImage: "info.circle")
                }
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
    }

    private var settings: some View {
        @Bindable var r = runner
        return Form {
            Picker("Test file", selection: $r.liveSizeGB) {
                ForEach(SpeedRequest.liveSizeChoices, id: \.self) { Text("\(Int($0)) GB").tag($0) }
            }
            Picker("Stop after", selection: $r.liveMinutes) {
                ForEach(SpeedRequest.liveMinuteChoices, id: \.self) { Text("\(Int($0)) min").tag($0) }
            }
            Picker("or after writing", selection: $r.liveMaxGB) {
                ForEach(SpeedRequest.liveMaxGBChoices, id: \.self) { Text("\(Int($0)) GB").tag($0) }
            }
            Text("A bigger file measures past the drive's fast cache. Tests always stop when the drive reaches its warning temperature.")
                .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }

    // MARK: Footage

    private var driveKey: String { runner.drive(in: monitor)?.id ?? "vol:\(runner.mountPoint)" }

    /// Live numbers while the loop runs, otherwise the latest results for this drive.
    private var footageInput: (write: Double?, read: Double?, source: String)? {
        if runner.running, runner.mode == .live {
            let w = runner.avgWrite ?? (runner.liveWrite > 0 ? runner.liveWrite : nil)
            let r = runner.avgRead ?? (runner.liveRead > 0 ? runner.liveRead : nil)
            return w == nil && r == nil ? nil : (w, r, "live, averages so far")
        }
        guard let input = Verdict.input(from: history.results(for: driveKey)) else { return nil }
        return (input.writeMBps, input.readMBps, "the latest \(input.writeSource)")
    }

    private var footageCard: some View {
        Card("Can it handle your footage?") {
            if let f = footageInput {
                FormatGridView(writeMBps: f.write, readMBps: f.read)
                Text("Based on \(f.source).").font(.caption2).foregroundStyle(.secondary)
                    .accessibilityLabel("Based on \(f.source)")
                if let input = Verdict.input(from: history.results(for: driveKey)) {
                    DisclosureGroup("Every format with stream counts") { VerdictTable(input: input) }.font(.callout)
                }
            } else {
                Text("Press Start: the grid fills in while the test runs.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: More tests

    private var moreTests: some View {
        @Bindable var r = runner
        let enc = runner.drive(in: monitor).flatMap { d in enclosures.first { $0.drives.contains { $0.id == d.id } } }
        return Card("More tests") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12, alignment: .top)], spacing: 12) {
                TestTile(icon: "film", title: "Long recording",
                         text: "Writes without a break to see whether the speed holds for long takes or drops once the drive's fast cache is full.",
                         cost: runner.sustainedGB == 0 ? "until 10 % free" : "writes \(Int(runner.sustainedGB)) GB",
                         running: runner.running && runner.mode == .sustained, enabled: !runner.running && runner.volume != nil,
                         options: AnyView(Picker("Write", selection: $r.sustainedGB) {
                             ForEach(SpeedRequest.sustainedChoices, id: \.self) { Text("\(Int($0)) GB").tag($0) }
                             Text("until 10 % free").tag(0.0)
                         }.labelsHidden().frame(width: 150))) {
                    guarded { runner.mode = .sustained; start() }
                }
                TestTile(icon: "photo.on.rectangle.angled", title: "Photos and small files",
                         text: "Reads small blocks at random, the way a photo library, a catalog or an app does.",
                         cost: "about 1 min · writes 4 GB", running: runner.running && runner.mode == .random,
                         enabled: !runner.running && runner.volume != nil, options: nil) {
                    guarded { runner.mode = .random; start() }
                }
                TestTile(icon: "thermometer.high", title: "Heat soak",
                         text: "Keeps writing and reading with a temperature chart. Stops early if the drive reaches its warning temperature.",
                         cost: "\(Int(heatChoice)) min · writes a lot", running: runner.running && runner.heatMinutes != nil,
                         enabled: !runner.running && runner.volume != nil,
                         options: AnyView(Picker("Minutes", selection: $heatChoice) {
                             ForEach([5.0, 10, 20, 30], id: \.self) { Text("\(Int($0)) min").tag($0) }
                         }.labelsHidden().frame(width: 110))) {
                    guarded { runner.mode = .live; runner.heatMinutes = heatChoice; start() }
                }
                if let enc {
                    TestTile(icon: "externaldrive.connected.to.line.below", title: "Whole enclosure",
                             text: "All drives in the \(enc.name) at once: what the shared \(enc.speedText) link really delivers.",
                             cost: "about 1 to 2 min · read only by default", running: false, enabled: !runner.running, options: nil) {
                        monitor.speedEnclosure = enc.id; monitor.tab = .speed
                    }
                }
            }
        }
    }

    // MARK: History

    private var historyCard: some View {
        let hist = history.results(for: driveKey)
        return Card {
            DisclosureGroup("Earlier results on this drive (\(hist.count))") {
                if hist.isEmpty { Text("No results yet.").font(.callout).foregroundStyle(.secondary) }
                ForEach(hist.prefix(10)) { r in
                    HStack(alignment: .firstTextBaseline) {
                        Text(r.date, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                        Text(ResultCard.plain(r)).lineLimit(2)
                        Spacer()
                        if let t = r.tempMaxC { Text("\(t) °C").foregroundStyle(.secondary) }
                    }.font(.caption.monospacedDigit())
                }
            }
        }
    }
}

/// A selectable card in the target row.
struct TargetCard: View {
    let icon: AnyView
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon.frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(minWidth: 170, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// One of the "More tests": what it finds out, what it costs, and a Run button.
struct TestTile: View {
    let icon: String
    let title: String
    let text: String
    let cost: String
    let running: Bool
    let enabled: Bool
    let options: AnyView?
    let run: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let options { options }
            HStack {
                Text(cost).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if running { ProgressView().controlSize(.small) }
                else { Button("Run", action: run).disabled(!enabled) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
    }
}

struct ResultCard: View {
    let result: SpeedResult

    /// The result in one or two plain sentences.
    static func plain(_ r: SpeedResult) -> String {
        let w = Fmt.rate(r.write?.avgMBps ?? 0), rd = Fmt.rate(r.read?.avgMBps ?? 0)
        switch r.mode {
        case .quick:
            return "Writes at \(w) and reads at \(rd)."
        case .live:
            let n = r.cycles?.count ?? 0
            var s = "Writes at \(w) and reads at \(rd) on average over \(n) pass\(n == 1 ? "" : "es")."
            if let wr = r.write, wr.maxMBps > 0, wr.minMBps < wr.maxMBps * 0.85 {
                s += " Write speed varied between \(Fmt.rate(wr.minMBps)) and \(Fmt.rate(wr.maxMBps))."
            }
            if let t = r.tempMaxC { s += " Peak temperature \(t) °C." }
            return s
        case .sustained:
            if let c = r.cliff {
                return String(format: "Full speed (%@) for the first %.0f GB, then %@: takes longer than that are recorded at the lower speed.",
                              Fmt.rate(c.fullSpeedMBps), c.fullSpeedGB, Fmt.rate(c.afterMBps))
            }
            return String(format: "Held %@ for all %.0f GB without slowing down.", w, Double(r.write?.bytes ?? 0) / 1e9)
        case .random:
            let one = r.random?.first { $0.queueDepth == 1 }, many = r.random?.first { $0.queueDepth > 1 }
            var s = ""
            if let one { s += String(format: "Small files one at a time: %.0f per second (%.0f µs each).", one.iops, one.meanLatencyUs) }
            if let many { s += String(format: " Many at once: %.0f per second.", many.iops) }
            return s.trimmingCharacters(in: .whitespaces)
        }
    }

    var body: some View {
        Card(result.mode == .sustained ? "Long recording" : result.mode == .random ? "Photos and small files" : "Result") {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.plain(result)).font(.title3.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                Spacer()
                ShareButton(title: "NVMeter speed test", content: AnyView(SpeedShareCard(result: result)))
            }
            if result.cancelled { Label("Stopped before the end: numbers cover the part that ran.", systemImage: "stop.circle").font(.caption).foregroundStyle(.orange) }
            DisclosureGroup("Details") { details }.font(.callout)
        }
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch result.mode {
            case .quick, .live:
                HStack(spacing: 24) { stat("Write", result.write); stat("Read", result.read) }
            case .sustained:
                stat("Average write", result.write)
            case .random:
                ForEach(result.random ?? [], id: \.queueDepth) { s in
                    Text(String(format: "Queue depth %d: %.0f IOPS, %@, mean latency %.0f µs", s.queueDepth, s.iops, Fmt.rate(s.mbps), s.meanLatencyUs))
                        .font(.callout.monospacedDigit())
                }
            }
            Text("1 MiB blocks, 4 write and 8 read streams, uncached (F_NOCACHE); random test: 4 KB reads, queue depth 1 and 32.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Text("Written: \(String(format: "%.1f GB", Double(result.bytesWritten) / 1e9))")
                Text(String(format: "Volume %.0f %% full", result.fillPercent))
                if let t = result.tempStartC, let m = result.tempMaxC { Text("Temperature \(t) → \(m) °C") }
                if let s = result.stopReason { Text(s) }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.top, 4)
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
