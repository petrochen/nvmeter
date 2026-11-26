import SwiftUI
import Charts

/// The main speed test, Blackmagic style: write and read dials around one Start / Stop button, a plain status line,
/// and while it runs the elapsed time, data written, temperature and the speed and temperature traces.
struct SpeedHero: View {
    @Environment(Monitor.self) private var monitor
    let runner: SpeedTestRunner
    let canStart: Bool
    let idleText: String
    let start: () -> Void

    private var isLive: Bool { runner.running ? runner.mode == .live : runner.result?.mode == .live }
    private var result: SpeedResult? { runner.running ? nil : runner.result }

    private var writeValue: Double {
        if runner.running {
            if runner.mode == .live { return runner.liveWrite }
            return runner.phase == .write || runner.phase == .sustainedWrite ? runner.liveMBps : 0
        }
        return result?.write?.avgMBps ?? 0
    }
    private var readValue: Double {
        if runner.running {
            if runner.mode == .live { return runner.liveRead }
            return runner.phase == .read || runner.phase == .randomQD1 || runner.phase == .randomQD32 ? runner.liveMBps : 0
        }
        return result?.mode == .random ? (result?.random?.last?.mbps ?? 0) : (result?.read?.avgMBps ?? 0)
    }

    private var scale: Double {
        let peak = max(runner.points.map(\.mbps).max() ?? 0, writeValue, readValue, 1)
        return [2000.0, 3000, 4000, 6000, 8000, 10000, 15000].first { $0 >= peak * 1.1 } ?? 20000
    }

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: 34) {
                Spacer(minLength: 0)
                SpeedDial(title: "Write", value: writeValue, average: isLive ? runner.avgWrite : nil, scale: scale, tint: .orange,
                          active: runner.running && (runner.phase == .write || runner.phase == .sustainedWrite))
                    .scaleEffect(1.2).frame(width: 216, height: 204)
                StartStopButton(running: runner.running, enabled: runner.running || canStart) {
                    if runner.running { runner.cancel() } else { start() }
                }
                SpeedDial(title: "Read", value: readValue, average: isLive ? runner.avgRead : nil, scale: scale, tint: .blue,
                          active: runner.running && !(runner.phase == .write || runner.phase == .sustainedWrite) && runner.phase != nil)
                    .scaleEffect(1.2).frame(width: 216, height: 204)
                Spacer(minLength: 0)
            }
            Text(runner.running ? runner.statusLine : (result.map(ResultCard.plain) ?? idleText))
                .font(.callout).multilineTextAlignment(.center).foregroundStyle(runner.running ? .primary : .secondary)
                .frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
            if runner.running || !runner.points.isEmpty { stats }
            if !runner.points.isEmpty {
                HStack(alignment: .top, spacing: 16) {
                    trace.frame(height: 120)
                    if runner.tempPoints.count > 1 { tempTrace.frame(width: 260, height: 120) }
                }
            }
        }
    }

    private var stats: some View {
        let elapsed = (runner.running ? Date() : runner.result?.date ?? Date()).timeIntervalSince(runner.startedAt ?? Date())
        return HStack(spacing: 22) {
            Spacer(minLength: 0)
            if runner.running { stat("clock", mmss(elapsed)) }
            stat("square.and.arrow.down", String(format: "%.1f GB written", Double(runner.running ? runner.totalWritten : runner.result?.bytesWritten ?? 0) / 1e9))
            stat("thermometer.medium", temperature)
            if isLive, runner.cycle > 0 || (runner.result?.cycles?.count ?? 0) > 0 {
                let n = runner.running ? runner.cycle : runner.result?.cycles?.count ?? 0
                stat("arrow.triangle.2.circlepath", "\(n) pass\(n == 1 ? "" : "es")")
            }
            Spacer(minLength: 0)
        }.font(.callout.monospacedDigit()).foregroundStyle(.secondary)
    }

    private var temperature: String {
        let now = runner.drive(in: monitor)?.temperatureC
        var s = Fmt.temp(runner.running ? now : runner.result?.tempMaxC)
        if let a = runner.tempStartC, let m = runner.tempMaxC, m > a { s += " (from \(a), max \(m))" }
        return s
    }

    private func stat(_ icon: String, _ text: String) -> some View { Label(text, systemImage: icon) }
    private func mmss(_ t: TimeInterval) -> String { String(format: "%d:%02d", Int(max(0, t)) / 60, Int(max(0, t)) % 60) }

    private var trace: some View {
        var pass = 0, last: SpeedPhase?
        let tagged = runner.points.map { p -> (ChartPoint, Int) in
            if p.phase != last { pass += 1; last = p.phase }
            return (p, pass)
        }
        return Chart(tagged, id: \.0.id) { p, pass in
            LineMark(x: .value("s", p.x), y: .value("MB/s", p.mbps), series: .value("pass", pass))
                .foregroundStyle(by: .value("direction", p.phase == .write || p.phase == .sustainedWrite ? "Write" : "Read"))
                .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale(["Write": Color.orange, "Read": Color.blue])
        .chartYScale(domain: 0...scale)
        .chartXAxisLabel("seconds")
        .chartYAxisLabel("MB/s")
    }

    private var tempTrace: some View {
        let pts = runner.tempPoints
        let lo = Double((pts.map(\.c).min() ?? 30) - 3), hi = Double((pts.map(\.c).max() ?? 50) + 3)
        return Chart(Array(pts.enumerated()), id: \.offset) { _, p in
            LineMark(x: .value("s", p.x), y: .value("°C", p.c)).foregroundStyle(.red).interpolationMethod(.monotone)
        }
        .chartYScale(domain: lo...hi)
        .chartXAxisLabel("seconds")
        .chartYAxisLabel("°C")
    }
}

/// The big round Start / Stop button between the dials.
struct StartStopButton: View {
    let running: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(running ? Color.red.gradient : Color.accentColor.gradient)
                    .shadow(color: .black.opacity(hover ? 0.25 : 0.12), radius: hover ? 8 : 4, y: 2)
                VStack(spacing: 2) {
                    Image(systemName: running ? "stop.fill" : "play.fill").font(.system(size: 22, weight: .bold))
                    Text(running ? "STOP" : "START").font(.system(size: 13, weight: .heavy, design: .rounded))
                }.foregroundStyle(.white)
            }
            .frame(width: 104, height: 104)
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .keyboardShortcut(.space, modifiers: [])
        .accessibilityLabel(running ? "Stop the test" : "Start the speed test")
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
