import SwiftUI
import Charts

enum GraphWindow: Double, CaseIterable, Identifiable {
    case m5 = 300, m30 = 1800, h2 = 7200
    var id: Double { rawValue }
    var title: String { self == .m5 ? "5 min" : (self == .m30 ? "30 min" : "2 h") }
}

struct GraphsView: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage("graphWindow") private var windowRaw: Double = 300

    private var window: GraphWindow { GraphWindow(rawValue: windowRaw) ?? .m5 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Live graphs").font(.title3.weight(.semibold))
                Spacer()
                Picker("Window", selection: $windowRaw) {
                    ForEach(GraphWindow.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }.padding([.horizontal, .top], 16).padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 12) {
                    totalRow
                    ForEach(monitor.drives) { d in driveCard(d) }
                }.padding(16)
            }
        }
    }

    private var totalRow: some View {
        let cur = monitor.totalHistory.last
        let hottest = monitor.drives.compactMap { $0.smart?.temperatureC }.max()
        return Card {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("All drives").font(.headline)
                    Label(Fmt.rate(cur?.read ?? 0), systemImage: "arrow.down.circle").foregroundStyle(.blue)
                    Label(Fmt.rate(cur?.write ?? 0), systemImage: "arrow.up.circle").foregroundStyle(.orange)
                    Text("hottest \(Fmt.temp(hottest))").font(.caption).foregroundStyle(.secondary)
                }.font(.callout.monospacedDigit()).frame(width: 150, alignment: .leading)
                RateChart(points: monitor.totals(window: window.rawValue), now: monitor.lastTick, window: window.rawValue)
                    .frame(height: 110)
            }
        }
    }

    private func driveCard(_ d: DriveSnapshot) -> some View {
        Card {
            HStack {
                StatusDot(status: d.health)
                Text(d.displayName).font(.headline)
                Text("\(d.model) · \(d.bsdName)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.temp(d.smart?.temperatureC)).font(.callout.monospacedDigit().weight(.semibold))
                Text("R \(Fmt.rate(d.throughput.readMBps))  W \(Fmt.rate(d.throughput.writeMBps))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Temperature").font(.caption).foregroundStyle(.secondary)
                    TempChart(points: monitor.temps(d.id, window: window.rawValue), now: monitor.lastTick, window: window.rawValue,
                              warn: d.identify?.warningTempC, crit: d.identify?.criticalTempC)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Throughput").font(.caption).foregroundStyle(.secondary)
                    RateChart(points: monitor.rates(d.id, window: window.rawValue), now: monitor.lastTick, window: window.rawValue)
                }
            }.frame(height: 150)
        }
    }
}

struct TempChart: View {
    let points: [TempPoint]
    let now: Date
    let window: TimeInterval
    let warn: Int?
    let crit: Int?

    var body: some View {
        let vals = points.map(\.c) + [warn, crit].compactMap { $0 }.map(Double.init)
        let lo = (points.map(\.c).min() ?? 20) - 6
        let hi = (vals.max() ?? 80) + 4
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("Time", p.t), y: .value("°C", p.c)).foregroundStyle(.red).interpolationMethod(.monotone)
            }
            if let warn {
                RuleMark(y: .value("Warning", warn)).foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .annotation(position: .top, alignment: .leading) { Text("warning \(warn) °C").font(.caption2).foregroundStyle(.orange) }
            }
            if let crit {
                RuleMark(y: .value("Critical", crit)).foregroundStyle(.red.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .top, alignment: .leading) { Text("critical \(crit) °C").font(.caption2).foregroundStyle(.red) }
            }
        }
        .chartXScale(domain: now.addingTimeInterval(-window)...now)
        .chartYScale(domain: lo...hi)
        .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine(); AxisValueLabel() } }
    }
}

struct RateChart: View {
    let points: [RatePoint]
    let now: Date
    let window: TimeInterval

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
        }
        .chartForegroundStyleScale(["Read": Color.blue, "Write": Color.orange])
        .chartXScale(domain: now.addingTimeInterval(-window)...now)
        .chartYScale(domain: 0...max(50, (points.map { max($0.read, $0.write) }.max() ?? 0) * 1.1))
        .chartYAxis { AxisMarks(position: .leading) { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))") } } } }
        .chartLegend(position: .bottom, alignment: .trailing, spacing: 2)
    }
}
