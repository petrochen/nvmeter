import SwiftUI
import Charts
import AppKit

enum ReportPaper: String, CaseIterable, Identifiable {
    case a4, letter
    var id: String { rawValue }
    var title: String { self == .a4 ? "A4" : "Letter" }
    var size: CGSize { self == .a4 ? CGSize(width: 595, height: 842) : CGSize(width: 612, height: 792) }
    static var localeDefault: ReportPaper {
        ["US", "CA", "MX"].contains(Locale.current.region?.identifier ?? "") ? .letter : .a4
    }
}

private func statusColor(_ s: String) -> Color {
    switch s {
    case "good": Color(red: 0.13, green: 0.6, blue: 0.3)
    case "caution": Color(red: 0.85, green: 0.5, blue: 0.0)
    case "bad": Color(red: 0.8, green: 0.1, blue: 0.1)
    default: .gray
    }
}

/// One page: A4 / Letter, fixed size, light appearance regardless of the system theme.
struct ReportPageView: View {
    let drive: ReportDrive
    let doc: ReportDocument
    let paper: ReportPaper
    private let ink = Color.black
    private let sub = Color(white: 0.38)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            titleBlock
            HStack(alignment: .top, spacing: 12) {
                card("Drive") { kv(driveRows) }
                card("Connection") { kv(connRows) }
            }
            verdict
            if let c = drive.counters { totals(c) }
            if !drive.smartFields.isEmpty { attributes }
            HStack(alignment: .top, spacing: 12) {
                if !drive.volumes.isEmpty { card("Volumes") { volumes } }
                if let t = drive.temperature { card("Temperature thresholds") { kv(tempRows(t)) }.frame(maxWidth: 190) }
            }
            if let ch = drive.charts { charts(ch) }
            Spacer(minLength: 0)
            footer
        }
        .font(.system(size: 8))
        .foregroundStyle(ink)
        .padding(EdgeInsets(top: 26, leading: 28, bottom: 18, trailing: 28))
        .frame(width: paper.size.width, height: paper.size.height, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    // MARK: pieces

    private var header: some View {
        HStack {
            Text("NVMeter drive report").font(.system(size: 9, weight: .semibold)).foregroundStyle(sub)
            Spacer()
            Text("\(Self.dateText(doc.generatedAt)) · NVMeter \(doc.app.version) · \(doc.machine.model) · macOS \(doc.machine.macOS)")
                .font(.system(size: 7.5)).foregroundStyle(sub)
        }
    }

    private var titleBlock: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(drive.title).font(.system(size: 18, weight: .bold))
                Text([drive.identity.vendor, Fmt.capacity(drive.identity.capacityBytes), drive.identity.nvmeVersion.map { "NVMe \($0)" }]
                    .compactMap { $0 }.joined(separator: " · ")).font(.system(size: 9)).foregroundStyle(sub)
            }
            Spacer()
            Text(drive.health.verdict.uppercased())
                .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(statusColor(drive.health.verdict)))
        }
    }

    private var driveRows: [(String, String)] {
        let i = drive.identity
        var r: [(String, String)] = [("Model", i.model)]
        if let v = i.vendor { r.append(("Vendor", v)) }
        r.append(("Serial", i.serial.isEmpty ? "-" : i.serial))
        r.append(("Firmware", i.firmware.isEmpty ? "-" : i.firmware))
        r.append(("Capacity", Fmt.capacity(i.capacityBytes)))
        r.append(("NVMe version", i.nvmeVersion ?? "-"))
        return r
    }

    private var connRows: [(String, String)] {
        let c = drive.connection
        var r: [(String, String)] = [("Interface", c.interface)]
        if let l = c.link {
            r.append(("Link now", "\(l.current), \(Int(l.currentGTs)) GT/s (~\(Int(l.approxBandwidthMBps)) MB/s)"))
            r.append(("Link max", l.max ?? "-"))
        }
        if let e = c.enclosure {
            let n = [e.vendor, e.model].compactMap { $0 }.joined(separator: " ")
            if !n.isEmpty { r.append(("Enclosure", n)) }
            if let f = e.firmware { r.append(("Encl. firmware", f)) }
        }
        return r
    }

    private func tempRows(_ t: ReportDrive.Temperature) -> [(String, String)] {
        [("Current", "\(t.currentC) °C"), ("Warning", t.warningC.map { "\($0) °C" } ?? "-"),
         ("Critical", t.criticalC.map { "\($0) °C" } ?? "-"),
         ("Time above warning", "\(t.minutesAboveWarning) min"), ("Time above critical", "\(t.minutesAboveCritical) min")]
    }

    private func kv(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                GridRow {
                    Text(r.0).foregroundStyle(sub)
                    Text(r.1).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var verdict: some View {
        card("Health verdict") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(drive.health.reasons.prefix(8).enumerated()), id: \.offset) { _, r in
                    HStack(alignment: .top, spacing: 4) { Text("•"); Text(r).fixedSize(horizontal: false, vertical: true) }
                }
            }
        }
    }

    private func totals(_ c: ReportDrive.Counters) -> some View {
        HStack(spacing: 6) {
            tile("Written", String(format: "%.2f TB", c.terabytesWritten))
            tile("Read", String(format: "%.2f TB", c.terabytesRead))
            tile("Power-on", "\(HealthEvaluator.num(c.powerOnHours)) h")
            tile("Power cycles", HealthEvaluator.num(c.powerCycles))
            tile("Unsafe shutd.", HealthEvaluator.num(c.unsafeShutdowns))
            tile("Media errors", HealthEvaluator.num(c.mediaErrors))
            tile("Error log", HealthEvaluator.num(c.errorLogEntries))
        }
    }

    private func tile(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(t).font(.system(size: 6.5)).foregroundStyle(sub)
            Text(v).font(.system(size: 9.5, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(5).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.95)))
    }

    private var attributes: some View {
        let f = drive.smartFields
        let half = (f.count + 1) / 2
        return card("SMART attributes (NVMe health log)") {
            HStack(alignment: .top, spacing: 14) {
                attrColumn(Array(f[0..<half]))
                attrColumn(Array(f[half...]))
            }
        }
    }

    private func attrColumn(_ rows: [ReportDrive.Field]) -> some View {
        VStack(alignment: .leading, spacing: 2.5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, a in
                HStack(alignment: .top, spacing: 4) {
                    Circle().fill(statusColor(a.status)).frame(width: 6, height: 6).padding(.top, 1.5)
                    Text(a.name).foregroundStyle(sub).frame(width: 100, alignment: .leading)
                    Text(a.value).font(.system(size: 8).monospacedDigit()).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var volumes: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(drive.volumes.prefix(6).enumerated()), id: \.offset) { _, v in
                HStack {
                    Text(v.name).fontWeight(.medium).lineLimit(1)
                    Text(v.fileSystem ?? "").foregroundStyle(sub)
                    Spacer()
                    Text("\(Fmt.capacity(v.freeBytes)) free of \(Fmt.capacity(v.sizeBytes))").monospacedDigit()
                }
            }
            if drive.volumes.count > 6 { Text("+ \(drive.volumes.count - 6) more").foregroundStyle(sub) }
        }
    }

    private func charts(_ ch: ReportDrive.Charts) -> some View {
        HStack(alignment: .top, spacing: 12) {
            card("Temperature, last \(Self.windowText(ch.windowSeconds))") {
                if ch.temperature.count >= 2 {
                    Chart {
                        ForEach(Array(ch.temperature.enumerated()), id: \.offset) { _, p in
                            LineMark(x: .value("Time", p.t), y: .value("°C", p.c)).foregroundStyle(Color.orange)
                        }
                        if let w = drive.temperature?.warningC {
                            RuleMark(y: .value("Warning", w)).foregroundStyle(Color.red.opacity(0.6))
                                .lineStyle(StrokeStyle(lineWidth: 0.7, dash: [3, 2]))
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartYAxis { AxisMarks { _ in AxisGridLine(); AxisValueLabel().font(.system(size: 6)) } }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute().second()).font(.system(size: 6)) } }
                    .frame(height: 78)
                } else {
                    Text("Not enough samples in the window").foregroundStyle(sub).frame(height: 78)
                }
            }
            card("Throughput, last \(Self.windowText(ch.windowSeconds))") {
                if ch.throughput.count >= 2 {
                    Chart {
                        ForEach(Array(ch.throughput.enumerated()), id: \.offset) { _, p in
                            LineMark(x: .value("Time", p.t), y: .value("MB/s", p.readMBps), series: .value("S", "Read"))
                                .foregroundStyle(Color.blue)
                            LineMark(x: .value("Time", p.t), y: .value("MB/s", p.writeMBps), series: .value("S", "Write"))
                                .foregroundStyle(Color.orange)
                        }
                    }
                    .chartYAxis { AxisMarks { _ in AxisGridLine(); AxisValueLabel().font(.system(size: 6)) } }
                    .chartYAxisLabel("MB/s", position: .top)
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute().second()).font(.system(size: 6)) } }
                    .frame(height: 78)
                    HStack(spacing: 8) {
                        Label("read", systemImage: "circle.fill").foregroundStyle(.blue)
                        Label("write", systemImage: "circle.fill").foregroundStyle(.orange)
                    }.font(.system(size: 6.5)).labelStyle(.titleAndIcon)
                } else {
                    Text("Not enough samples in the window").foregroundStyle(sub).frame(height: 78)
                }
            }
        }
    }

    private var footer: some View {
        Text("Purpose: warranty claims, selling a drive, handing media to a client, forum posts. All values are read-only SMART / health-log data "
             + "reported by the drive itself, collected by NVMeter without privileges and without writing to the drive.")
            .font(.system(size: 6.5)).foregroundStyle(sub)
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 8.5, weight: .semibold))
            content()
        }
        .padding(7).frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(white: 0.8), lineWidth: 0.6))
    }

    static func windowText(_ s: Double) -> String { s >= 120 ? "\(Int(s / 60)) min" : "\(Int(s)) s" }
    static func dateText(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f.string(from: d)
    }
}

enum ReportPDF {
    /// Renders one page per drive into a PDF file. Must run on the main thread.
    @MainActor static func write(_ doc: ReportDocument, to url: URL, paper: ReportPaper) -> Bool {
        var box = CGRect(origin: .zero, size: paper.size)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: "NVMeter drive report",
                                                                   kCGPDFContextCreator: "NVMeter \(appVersion)"] as CFDictionary)
        else { return false }
        for d in doc.drives {
            let renderer = ImageRenderer(content: ReportPageView(drive: d, doc: doc, paper: paper))
            renderer.proposedSize = ProposedViewSize(paper.size)
            ctx.beginPDFPage(nil)
            renderer.render { _, draw in draw(ctx) }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return true
    }
}
