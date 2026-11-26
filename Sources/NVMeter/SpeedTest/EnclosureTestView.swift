import SwiftUI
import Charts

/// Whole-enclosure test: choose what each drive does, which questions to answer, then watch every slot and the shared
/// link live (10 updates a second) and get a plain answer on what limits the speed.
struct EnclosureTestPanel: View {
    @Environment(Monitor.self) private var monitor
    let enclosureID: String
    @State private var runner = EnclosureTestRunner.shared
    @State private var roles: [String: DriveRole] = [:]
    @State private var scenarios: Set<EnclosureScenario> = [.readAll, .writeAll, .both]
    @State private var heatMinutes: Double = 5
    @State private var seconds: Double = 20
    @State private var editing = false

    private var enclosure: EnclosureTopology.Enclosure? {
        EnclosureTopology.build(monitor.drives, showOthers: false).enclosures.first { $0.id == enclosureID }
    }

    var body: some View {
        if let e = enclosure {
            let plan = makePlan(e)
            let hasResult = runner.result != nil && runner.plan?.enclosureName == e.name
            VStack(spacing: 14) {
                if (runner.running || hasResult) && !editing { compact(e, plan: plan) } else { setup(e, plan: plan) }
                if runner.running || (runner.result != nil && runner.plan?.enclosureName == e.name) { live(e) }
                if let r = runner.result, !runner.running, r.enclosureName == e.name { ResultView(result: r) }
            }
        } else {
            Card { Text("This enclosure is not connected.").foregroundStyle(.secondary) }
        }
    }

    // MARK: Plan

    private func volume(_ d: DriveSnapshot) -> VolumeInfo? {
        d.volumes.first { !$0.mountPoint.isEmpty && !$0.readOnly } ?? d.volumes.first { !$0.mountPoint.isEmpty }
    }

    private func role(_ d: DriveSnapshot) -> DriveRole { volume(d) == nil ? .skip : roles[d.id] ?? .read }

    private func makePlan(_ e: EnclosureTopology.Enclosure) -> EnclosureTestPlan {
        let ds = e.slots.compactMap { s -> EnclosureTestDrive? in
            guard let v = volume(s.drive) else { return nil }
            return EnclosureTestDrive(id: s.drive.id, name: s.drive.displayName, slot: s.number, mountPoint: v.mountPoint,
                                      role: role(s.drive), linkText: s.drive.link.map { LinkCheck.text($0) },
                                      ceilingMBps: s.drive.link.map { EnclosureAnalysis.slotCeiling($0) } ?? 0)
        }
        var p = EnclosureTestPlan(enclosureName: e.name, linkText: e.speedText, budgetMBps: e.budgetMBps, drives: ds,
                                  scenarios: EnclosureScenario.allCases.filter { scenarios.contains($0) })
        p.secondsPerScenario = seconds
        p.heatSeconds = heatMinutes * 60
        return p
    }

    private func estimate(_ p: EnclosureTestPlan) -> String {
        let t = p.runnable.reduce(0.0) { $0 + ($1 == .heat ? p.heatSeconds : p.secondsPerScenario) } + 15
        let minutes = max(1, Int((t / 60).rounded()))
        let w = p.plannedWriteBytes()
        let writes = w == 0 ? "writes nothing" : "writes up to \(Int(Double(w) / 1e9)) GB to " + p.writers.map(\.name).joined(separator: ", ")
        return "About \(minutes) min · \(writes)"
    }

    // MARK: Setup

    private func setup(_ e: EnclosureTopology.Enclosure, plan: EnclosureTestPlan) -> some View {
        Card("\(e.name) · whole enclosure") {
            Text("Puts load on all drives at once to see what the shared \(e.speedText) link delivers (about \(String(format: "%.1f", e.budgetMBps / 1000)) GB/s per direction) and which drive or slot holds things back.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(e.slots) { s in
                    GridRow {
                        Text(s.number.map { "\($0)" } ?? "?").font(.caption.weight(.bold)).frame(width: 18, height: 18)
                            .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.5)))
                        VendorLogo(vendor: s.drive.vendor, height: 18).frame(width: 60)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.drive.displayName).font(.body.weight(.medium))
                            Text([s.drive.link.map { LinkCheck.text($0) }, volume(s.drive).map { "\(Fmt.capacity($0.freeBytes)) free" }]
                                .compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                        Picker("", selection: Binding(get: { role(s.drive) }, set: { roles[s.drive.id] = $0 })) {
                            ForEach(DriveRole.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 300).disabled(volume(s.drive) == nil || runner.running)
                    }
                }
            }
            Text("Read only reads files already on the drive and writes nothing (it needs at least 1 GB of large files). Read and write uses a temporary \(plan.tempFileBytes / 1_000_000_000) GB file that is deleted afterwards.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(EnclosureScenario.allCases) { s in
                    let possible = { () -> Bool in var p = plan; p.scenarios = [s]; return !p.runnable.isEmpty }()
                    Toggle(isOn: Binding(get: { scenarios.contains(s) }, set: { if $0 { scenarios.insert(s) } else { scenarios.remove(s) } })) {
                        HStack(spacing: 6) {
                            Text(s.title).font(.body.weight(.medium))
                            Text(s.question).foregroundStyle(.secondary)
                            if s == .heat {
                                Picker("", selection: $heatMinutes) {
                                    ForEach([2.0, 5, 10, 20], id: \.self) { Text("\(Int($0)) min").tag($0) }
                                }.labelsHidden().frame(width: 90)
                            }
                            if !possible { Text(s == .both ? "(needs a Read and write drive and one more)" : "(needs a Read and write drive)").font(.caption).foregroundStyle(.orange) }
                        }
                    }.disabled(runner.running)
                }
            }
            HStack {
                Text(estimate(plan)).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if runner.running {
                    Button(role: .cancel) { runner.cancel() } label: { Label("Stop", systemImage: "stop.fill") }.controlSize(.large)
                } else {
                    Button { editing = false; runner.start(plan, monitor: monitor) } label: { Label("Start", systemImage: "play.fill") }
                        .controlSize(.large).buttonStyle(.borderedProminent).disabled(plan.runnable.isEmpty || monitor.speedRunner.running)
                }
            }
        }
    }

    /// One line instead of the setup while a test runs or its result is shown.
    private func compact(_ e: EnclosureTopology.Enclosure, plan: EnclosureTestPlan) -> some View {
        let p = runner.plan ?? plan
        let rw = p.writers.map(\.name), ro = p.drives.filter { $0.role == .read }.count
        let summary = (rw.isEmpty ? "" : rw.joined(separator: ", ") + " read and write") + (rw.isEmpty || ro == 0 ? "" : ", ")
            + (ro == 0 ? "" : "\(ro) drive\(ro == 1 ? "" : "s") read only")
        return Card {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(e.name) · whole enclosure").font(.headline)
                    Text(summary + " · " + p.runnable.map(\.title).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if runner.running {
                    Button(role: .cancel) { runner.cancel() } label: { Label("Stop", systemImage: "stop.fill") }.controlSize(.large)
                } else {
                    Button("Change settings") { editing = true }
                    Button { runner.start(plan, monitor: monitor) } label: { Label("Run again", systemImage: "arrow.clockwise") }
                        .buttonStyle(.borderedProminent).disabled(plan.runnable.isEmpty || monitor.speedRunner.running)
                }
            }
        }
    }

    // MARK: Live

    private func live(_ e: EnclosureTopology.Enclosure) -> some View {
        let budget = max(e.budgetMBps, 1000)
        let scale = [2000.0, 4000, 6000, 8000, 10000].first { $0 >= budget * 1.05 } ?? 16000
        return Card(runner.running ? (runner.scenario?.title ?? runner.status) : "Last run") {
            if runner.running {
                Text(runner.scenario?.question ?? runner.status).font(.callout).foregroundStyle(.secondary)
            }
            HStack(alignment: .center, spacing: 30) {
                Spacer(minLength: 0)
                SpeedDial(title: "Read, all drives", value: runner.totalRead, average: nil, scale: scale, tint: .blue, active: runner.totalRead > 0)
                    .scaleEffect(1.15).frame(width: 207, height: 196)
                SpeedDial(title: "Write, all drives", value: runner.totalWrite, average: nil, scale: scale, tint: .orange, active: runner.totalWrite > 0)
                    .scaleEffect(1.15).frame(width: 207, height: 196)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shared link").font(.caption).foregroundStyle(.secondary)
                    ShareBar(value: max(runner.totalRead, runner.totalWrite), scale: budget, tint: .accentColor).frame(width: 200)
                    Text(String(format: "%.2f of %.1f GB/s per direction", max(runner.totalRead, runner.totalWrite) / 1000, budget / 1000))
                        .font(.callout.monospacedDigit())
                    Text(String(format: "%.1f GB written · %@", Double(runner.written) / 1e9, mmss(runner.elapsed)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(e.slots) { s in
                    let r = runner.live[s.drive.id] ?? EnclosureDriveRate()
                    let ceiling = s.drive.link.map { EnclosureAnalysis.slotCeiling($0) } ?? 2000
                    GridRow {
                        Text(s.number.map { "Slot \($0)" } ?? "Drive").font(.callout.weight(.semibold))
                        Text(s.drive.displayName).lineLimit(1).frame(width: 130, alignment: .leading)
                        ShareBar(value: r.total, scale: max(ceiling, r.total, 1), tint: r.write > r.read ? .orange : .blue).frame(minWidth: 160)
                        Text(r.total > 0 ? (r.write > r.read ? "W " : "R ") + Fmt.rate(r.total) : "idle").font(.callout.monospacedDigit()).frame(width: 110, alignment: .trailing)
                        Text(Fmt.temp(s.drive.temperatureC)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if runner.points.count > 1 {
                Chart(runner.points) { p in
                    LineMark(x: .value("s", p.x), y: .value("MB/s", p.read), series: .value("dir", "Read")).foregroundStyle(.blue)
                    LineMark(x: .value("s", p.x), y: .value("MB/s", p.write), series: .value("dir", "Write")).foregroundStyle(.orange)
                    RuleMark(y: .value("budget", budget)).foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                .chartYScale(domain: 0...scale).chartXAxisLabel("seconds").chartYAxisLabel("MB/s, all drives")
                .frame(height: 140)
            }
        }
    }

    private func mmss(_ t: TimeInterval) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
}

/// Plain result of an enclosure test, one block per scenario.
private struct ResultView: View {
    let result: EnclosureTestResult

    var body: some View {
        Card("Result") {
            HStack(alignment: .firstTextBaseline) {
                Text(result.headline).font(.title2.weight(.semibold))
                Spacer()
                ShareButton(title: "NVMeter enclosure test", content: AnyView(EnclosureShareCard(result: result)))
            }
            if let s = result.stopReason { Label(s, systemImage: "stop.circle").foregroundStyle(.orange).font(.callout) }
            ForEach(result.scenarios) { s in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(s.scenario.title).font(.headline)
                        Spacer()
                        Text(totals(s)).font(.callout.monospacedDigit())
                    }
                    ForEach(result.findings(s), id: \.self) { f in Label(f, systemImage: "arrow.right.circle").font(.callout) }
                    DisclosureGroup("Per drive") {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                            ForEach(result.drives.filter { s.perDrive[$0.id] != nil }) { d in
                                let r = s.perDrive[d.id]!
                                GridRow {
                                    Text(d.slot.map { "Slot \($0)" } ?? "")
                                    Text(d.name)
                                    Text(d.linkText ?? "").foregroundStyle(.secondary)
                                    Text(r.read > 0 ? "read \(Fmt.rate(r.read))" : "")
                                    Text(r.write > 0 ? "write \(Fmt.rate(r.write))" : "")
                                }.font(.caption.monospacedDigit())
                            }
                        }
                    }.font(.caption)
                }.padding(.vertical, 4)
            }
            let heat = result.drives.compactMap { d in result.heat[d.id].map { (d, $0) } }
            if !heat.isEmpty {
                Divider()
                Text("Temperatures").font(.headline)
                ForEach(heat, id: \.0.id) { d, h in
                    Text("\(d.name): \(h.startC.map { "\($0)" } ?? "?") → \(h.maxC.map { "\($0)" } ?? "?") °C"
                         + (h.plateauMinute.map { String(format: ", levelled off after %.0f min", max(1, $0)) } ?? ", still rising at the end"))
                        .font(.callout.monospacedDigit())
                }
            }
            Text(String(format: "Written during the test: %.1f GB.", Double(result.bytesWritten) / 1e9)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func totals(_ s: EnclosureScenarioResult) -> String {
        var parts: [String] = []
        if s.totalRead > 0 { parts.append("read \(String(format: "%.2f GB/s", s.totalRead / 1000))") }
        if s.totalWrite > 0 { parts.append("write \(String(format: "%.2f GB/s", s.totalWrite / 1000))") }
        return parts.joined(separator: " + ")
    }
}
