import SwiftUI
import Charts

/// Live loop: two dials (write, read), run counters, the MB/s trace and the "will it work?" grid.
struct LiveLoopCard: View {
    @Environment(Monitor.self) private var monitor
    let runner: SpeedTestRunner

    private var shownWrite: Double { runner.running ? runner.liveWrite : (runner.result?.write?.avgMBps ?? runner.avgWrite ?? 0) }
    private var shownRead: Double { runner.running ? runner.liveRead : (runner.result?.read?.avgMBps ?? runner.avgRead ?? 0) }
    private var gridWrite: Double? { runner.running ? (runner.avgWrite ?? nonZero(runner.liveWrite)) : runner.result?.write?.avgMBps ?? runner.avgWrite }
    private var gridRead: Double? { runner.running ? (runner.avgRead ?? nonZero(runner.liveRead)) : runner.result?.read?.avgMBps ?? runner.avgRead }
    private func nonZero(_ v: Double) -> Double? { v > 0 ? v : nil }

    /// Shared dial scale: a round number above everything seen so far.
    private var scale: Double {
        let peak = max(runner.points.map(\.mbps).max() ?? 0, shownWrite, shownRead, 1)
        return [500.0, 1000, 1500, 2000, 3000, 4000, 5000, 6000, 8000, 10000, 15000].first { $0 >= peak * 1.1 } ?? 20000
    }

    var body: some View {
        Card(runner.running ? "Live loop · cycle \(max(runner.cycle, 1))" : "Live loop") {
            HStack(alignment: .center, spacing: 28) {
                SpeedDial(title: "Write", value: shownWrite, average: runner.avgWrite, scale: scale, tint: .orange,
                          active: runner.running && runner.phase == .write)
                SpeedDial(title: "Read", value: shownRead, average: runner.avgRead, scale: scale, tint: .blue,
                          active: runner.running && runner.phase == .read)
                stats
                Spacer(minLength: 0)
            }
            trace.frame(height: 130)
        }
        Card("Will it work? (\(runner.running ? "averages so far" : "this run"))") {
            FormatGridView(writeMBps: gridWrite, readMBps: gridRead)
        }
    }

    private var stats: some View {
        let elapsed = (runner.running ? Date() : runner.result?.date ?? Date()).timeIntervalSince(runner.startedAt ?? Date())
        let limit = runner.liveMinutes * 60
        return VStack(alignment: .leading, spacing: 6) {
            row("clock", runner.running ? "\(mmss(elapsed)) of \(mmss(limit))" : runner.result.map { "\(($0.cycles ?? []).count) cycles" } ?? "-")
            row("square.and.arrow.down", String(format: "%.1f of %.0f GB written", Double(runner.totalWritten) / 1e9, runner.liveMaxGB))
            row("thermometer.medium", tempText)
            if let r = runner.result, !runner.running, let why = r.stopReason {
                Label(why, systemImage: why.hasPrefix("Stopped at") ? "thermometer.high" : "stop.circle")
                    .foregroundStyle(why.hasPrefix("Stopped at") ? .orange : .secondary).font(.caption)
            }
            if let r = runner.result, !runner.running, let w = r.write, let rd = r.read, (r.cycles?.count ?? 0) > 1 {
                Text("Cycle to cycle: write \(Fmt.rate(w.minMBps))–\(Fmt.rate(w.maxMBps)), read \(Fmt.rate(rd.minMBps))–\(Fmt.rate(rd.maxMBps))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.font(.callout.monospacedDigit()).frame(minWidth: 220, alignment: .leading)
    }

    private var tempText: String {
        let now = runner.drive(in: monitor)?.temperatureC
        var s = Fmt.temp(runner.running ? now : runner.result?.tempMaxC)
        if let a = runner.tempStartC, let m = runner.tempMaxC { s += "  (\(a) → max \(m) °C)" }
        return s
    }

    private func row(_ icon: String, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: icon).frame(width: 18) }
    }

    private func mmss(_ t: TimeInterval) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }

    private var trace: some View {
        // Number the passes so a write line never joins the following read line.
        var pass = 0, last: SpeedPhase?
        let tagged = runner.points.map { p -> (ChartPoint, Int) in
            if p.phase != last { pass += 1; last = p.phase }
            return (p, pass)
        }
        return Chart(tagged, id: \.0.id) { p, pass in
            LineMark(x: .value("s", p.x), y: .value("MB/s", p.mbps), series: .value("pass", pass))
                .foregroundStyle(by: .value("direction", p.phase == .write ? "Write" : "Read"))
                .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale(["Write": Color.orange, "Read": Color.blue])
        .chartYScale(domain: 0...scale)
        .chartXAxisLabel("seconds")
        .chartYAxisLabel("MB/s")
    }
}

/// A 240-degree dial with the current value in the middle and a tick for the running average.
struct SpeedDial: View {
    let title: String
    let value: Double
    let average: Double?
    let scale: Double
    let tint: Color
    let active: Bool

    private let sweep = 240.0
    private func fraction(_ v: Double) -> Double { min(max(v / scale, 0), 1) }

    var body: some View {
        ZStack {
            arc(1).stroke(.quaternary, style: StrokeStyle(lineWidth: 14, lineCap: .round))
            arc(fraction(value)).stroke(tint.gradient, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .animation(.easeOut(duration: 0.4), value: value)
            ForEach(0...4, id: \.self) { i in tick(Double(i) / 4, long: true) }
            if let average, average > 0 { marker(fraction(average)) }
            VStack(spacing: 0) {
                Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(active ? tint : .secondary)
                Text(value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value))
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text("MB/s").font(.caption).foregroundStyle(.secondary)
                if let average, average > 0 { Text("avg \(Fmt.rate(average))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
            }.offset(y: 6)
            Text(scaleLabel(scale)).font(.caption2).foregroundStyle(.secondary).offset(x: 62, y: 72)
            Text("0").font(.caption2).foregroundStyle(.secondary).offset(x: -62, y: 72)
        }
        .frame(width: 180, height: 170)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(Fmt.rate(value))")
    }

    private func scaleLabel(_ v: Double) -> String { v >= 1000 ? String(format: "%g GB/s", v / 1000) : "\(Int(v))" }

    /// Angle in degrees (SwiftUI: 0 = right, clockwise) for a fraction of the sweep, starting bottom-left.
    private func angle(_ f: Double) -> Double { 90 + (360 - sweep) / 2 + sweep * f }

    private func arc(_ f: Double) -> Path {
        Path { p in
            p.addArc(center: CGPoint(x: 90, y: 90), radius: 72, startAngle: .degrees(angle(0)), endAngle: .degrees(angle(f)), clockwise: false)
        }
    }

    private func point(_ f: Double, r: Double) -> CGPoint {
        let a = angle(f) * .pi / 180
        return CGPoint(x: 90 + r * cos(a), y: 90 + r * sin(a))
    }

    private func tick(_ f: Double, long: Bool) -> some View {
        Path { p in p.move(to: point(f, r: 82)); p.addLine(to: point(f, r: long ? 88 : 85)) }
            .stroke(.secondary.opacity(0.6), lineWidth: 1.5)
    }

    private func marker(_ f: Double) -> some View {
        Path { p in p.move(to: point(f, r: 62)); p.addLine(to: point(f, r: 82)) }
            .stroke(.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
    }
}

/// Resolution x frame rate grid for one codec: W = recording (write) keeps up, R = playback (read) keeps up.
struct FormatGridView: View {
    let writeMBps: Double?
    let readMBps: Double?
    @AppStorage("formatGridCodec") private var codecName = "ProRes 422 HQ"

    private var codec: FormatGrid.Codec { FormatGrid.codecs.first { $0.name == codecName } ?? FormatGrid.codecs[2] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Codec", selection: $codecName) {
                ForEach(FormatGrid.codecs) { Text($0.name).tag($0.name) }
            }.frame(maxWidth: 320)
            Grid(alignment: .center, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    ForEach(FormatGrid.frameRates, id: \.self) { Text("\(Int($0)) fps").font(.caption.bold()) }
                }
                ForEach(FormatGrid.resolutions) { res in
                    GridRow {
                        Text(res.name).font(.callout.bold()).gridColumnAlignment(.leading)
                        ForEach(FormatGrid.frameRates, id: \.self) { fps in cell(codec.mBps(res, fps: fps)) }
                    }
                }
            }
            Text("W = recording keeps up (write), R = playback keeps up (read), one stream; hover a cell for the data rate. "
                 + "Rates are approximate (Apple ProRes white paper, Blackmagic published rates) and vary with content.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cell(_ need: Double) -> some View {
        HStack(spacing: 3) {
            badge("W", writeMBps.map { $0 >= need })
            badge("R", readMBps.map { $0 >= need })
        }
        .help(String(format: "%@ needs about %@", codec.name, Fmt.rate(need)))
    }

    private func badge(_ letter: String, _ ok: Bool?) -> some View {
        let color: Color = ok == nil ? .secondary : (ok! ? .green : .red)
        return Text(letter).font(.caption.weight(.bold).monospaced())
            .frame(width: 22, height: 20)
            .foregroundStyle(ok == nil ? Color.secondary : color)
            .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(ok == nil ? 0.08 : 0.18)))
            .overlay { if ok == false { Rectangle().fill(color).frame(height: 1.5).rotationEffect(.degrees(-35)).padding(4) } }
    }
}
