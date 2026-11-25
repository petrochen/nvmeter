import SwiftUI
import Charts

enum GraphWindow: Double, CaseIterable, Identifiable {
    case m5 = 300, m30 = 1800, h2 = 7200
    var id: Double { rawValue }
    var title: String { self == .m5 ? "5 min" : (self == .m30 ? "30 min" : "2 h") }
}

/// Which chart the cursor is in; only that chart shows the value label, the rule is drawn on both.
enum HoverSource { case temp, rate }
struct HoverState: Equatable { var time: Date; var source: HoverSource }

struct GraphsView: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage("graphWindow") private var windowRaw: Double = 300
    @AppStorage("showDisksWithoutSMART") private var showNoSMART = true
    /// Hover per card (key = drive id, "" = all drives).
    @State private var hovers: [String: HoverState] = [:]

    private var window: GraphWindow { GraphWindow(rawValue: windowRaw) ?? .m5 }

    private func hover(_ key: String, source: HoverSource) -> HoverState? {
        if let h = hovers[key] { return h }
        if let age = monitor.simulatedHoverAge { return HoverState(time: monitor.lastTick.addingTimeInterval(-age), source: source) }
        return nil
    }

    private func binding(_ key: String) -> (HoverState?) -> Void {
        { hovers[key] = $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Live graphs").font(.title3.weight(.semibold))
                Spacer()
                Picker("Window", selection: $windowRaw) {
                    ForEach(GraphWindow.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }.padding([.horizontal, .top], 16).padding(.bottom, 8)
            ScrollViewReader { sp in
            ScrollView {
                VStack(spacing: 12) {
                    totalRow.id("top")
                    ForEach(monitor.drives.filter { showNoSMART || !$0.isUSBOther }) { d in driveCard(d) }
                }.padding(16)
            }
            .onChange(of: monitor.simulatedHoverAge) { sp.scrollTo("top", anchor: .top) }
            }
        }
    }

    private var totalRow: some View {
        let cur = monitor.totalHistory.last
        let hottest = monitor.drives.compactMap { $0.temperatureC }.max()
        let w = window.rawValue
        return Card {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("All drives").font(.headline)
                    Label(Fmt.rate(cur?.read ?? 0), systemImage: "arrow.down.circle").foregroundStyle(.blue)
                    Label(Fmt.rate(cur?.write ?? 0), systemImage: "arrow.up.circle").foregroundStyle(.orange)
                    Text("hottest \(Fmt.temp(hottest))").font(.caption).foregroundStyle(.secondary)
                }.font(.callout.monospacedDigit()).frame(width: 150, alignment: .leading)
                RateChart(points: monitor.totals(window: w), now: monitor.lastTick, window: w,
                          hover: hover("", source: .rate), onHover: binding(""), showLabel: true,
                          values: { monitor.hoverValues(at: $0, id: nil, window: w) })
                    .frame(height: 110)
            }
        }
    }

    private func driveCard(_ d: DriveSnapshot) -> some View {
        let w = window.rawValue
        let h = hover(d.id, source: .rate)
        let values: (Date) -> HoverValues = { monitor.hoverValues(at: $0, id: d.id, window: w) }
        return Card {
            HStack(spacing: 8) {
                StatusDot(status: d.health)
                VendorLogo(vendor: d.vendor, height: 18)
                Text(d.displayName).font(.headline)
                Text(d.subtitle).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.temp(d.temperatureC)).font(.callout.monospacedDigit().weight(.semibold))
                Text("R \(Fmt.rate(d.throughput.readMBps))  W \(Fmt.rate(d.throughput.writeMBps))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Temperature").font(.caption).foregroundStyle(.secondary)
                    TempChart(points: monitor.temps(d.id, window: w), now: monitor.lastTick, window: w,
                              warn: d.identify?.warningTempC, crit: d.identify?.criticalTempC,
                              hover: h, onHover: binding(d.id), showLabel: h?.source == .temp, values: values)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Throughput").font(.caption).foregroundStyle(.secondary)
                    RateChart(points: monitor.rates(d.id, window: w), now: monitor.lastTick, window: w,
                              hover: h, onHover: binding(d.id), showLabel: h?.source != .temp, values: values)
                }
            }.frame(height: 150)
        }
    }
}

// MARK: - Hover plumbing

private extension View {
    /// Tracks the cursor over a chart and reports the hovered time (nil when it leaves).
    func hoverTracking(source: HoverSource, onHover: @escaping (HoverState?) -> Void) -> some View {
        chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            guard let frame = proxy.plotFrame else { return }
                            let x = loc.x - geo[frame].origin.x
                            if let t: Date = proxy.value(atX: x) { onHover(HoverState(time: t, source: source)) }
                        case .ended:
                            onHover(nil)
                        }
                    }
            }
        }
    }
}

struct HoverLabel: View {
    let v: HoverValues
    private static let f: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Self.f.string(from: v.time)).fontWeight(.semibold)
            if let t = v.tempC { Text("\(v.hottest ? "Hottest" : "Temp") \(Int(t)) °C").foregroundStyle(.red) }
            if let r = v.read { Text("Read \(Fmt.rate(r))").foregroundStyle(.blue) }
            if let w = v.write { Text("Write \(Fmt.rate(w))").foregroundStyle(.orange) }
        }
        .font(.caption2.monospacedDigit())
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
    }
}

private let fitChart = AnnotationOverflowResolution(x: .fit(to: .chart), y: .fit(to: .chart))

struct TempChart: View {
    let points: [TempPoint]
    let now: Date
    let window: TimeInterval
    let warn: Int?
    let crit: Int?
    let hover: HoverState?
    let onHover: (HoverState?) -> Void
    let showLabel: Bool
    let values: (Date) -> HoverValues

    var body: some View {
        let vals = points.map(\.c) + [warn, crit].compactMap { $0 }.map(Double.init)
        let lo = (points.map(\.c).min() ?? 20) - 6
        let hi = (vals.max() ?? 80) + 9          // room for the threshold labels above the top line
        let from = now.addingTimeInterval(-window)
        let close = warn != nil && crit != nil && Double(crit! - warn!) < (hi - lo) * 0.14   // keep the two labels apart
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("Time", p.t), y: .value("°C", p.c)).foregroundStyle(.red).interpolationMethod(.monotone)
            }
            if let warn {
                RuleMark(xStart: .value("From", from), xEnd: .value("To", now), y: .value("Warning", warn))
                    .foregroundStyle(.orange).lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .annotation(position: close ? .bottom : .top, alignment: .trailing, spacing: 1, overflowResolution: fitChart) {
                        Text(warn == crit ? "warning = critical \(warn) °C" : "warning \(warn) °C").font(.caption2).foregroundStyle(.orange)
                    }
            }
            if let crit, crit != warn {
                RuleMark(xStart: .value("From", from), xEnd: .value("To", now), y: .value("Critical", crit))
                    .foregroundStyle(.red.opacity(0.8)).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .top, alignment: .trailing, spacing: 1, overflowResolution: fitChart) {
                        Text("critical \(crit) °C").font(.caption2).foregroundStyle(.red)
                    }
            }
            if let hover {
                let v = values(hover.time)
                RuleMark(x: .value("Hover", v.time)).foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 0, overflowResolution: fitChart) {
                        if showLabel { HoverLabel(v: v) }
                    }
            }
        }
        .chartXScale(domain: from...now)
        .chartYScale(domain: lo...hi)
        .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine(); AxisValueLabel() } }
        .hoverTracking(source: .temp, onHover: onHover)
    }
}

struct RateChart: View {
    let points: [RatePoint]
    let now: Date
    let window: TimeInterval
    let hover: HoverState?
    let onHover: (HoverState?) -> Void
    let showLabel: Bool
    let values: (Date) -> HoverValues

    var body: some View {
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Time", p.t), y: .value("MB/s", p.read), series: .value("Dir", "Read"), stacking: .unstacked)
                    .foregroundStyle(by: .value("Direction", "Read")).opacity(0.18)
                LineMark(x: .value("Time", p.t), y: .value("MB/s", p.read), series: .value("Dir", "Read"))
                    .foregroundStyle(by: .value("Direction", "Read"))
                AreaMark(x: .value("Time", p.t), y: .value("MB/s", p.write), series: .value("Dir", "Write"), stacking: .unstacked)
                    .foregroundStyle(by: .value("Direction", "Write")).opacity(0.18)
                LineMark(x: .value("Time", p.t), y: .value("MB/s", p.write), series: .value("Dir", "Write"))
                    .foregroundStyle(by: .value("Direction", "Write"))
            }
            if let hover {
                let v = values(hover.time)
                RuleMark(x: .value("Hover", v.time)).foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 0, overflowResolution: fitChart) {
                        if showLabel { HoverLabel(v: v) }
                    }
            }
        }
        .chartForegroundStyleScale(["Read": Color.blue, "Write": Color.orange])
        .chartXScale(domain: now.addingTimeInterval(-window)...now)
        .chartYScale(domain: 0...max(50, (points.map { max($0.read, $0.write) }.max() ?? 0) * 1.1))
        .chartYAxis { AxisMarks(position: .leading) { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))") } } } }
        .chartLegend(position: .bottom, alignment: .trailing, spacing: 2)
        .hoverTracking(source: .rate, onHover: onHover)
    }
}
