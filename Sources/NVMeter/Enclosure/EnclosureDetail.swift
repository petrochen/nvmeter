import SwiftUI

/// Enclosure overview: identity, the shared bandwidth budget with live usage, per-slot table and "why is it slow" hints.
struct EnclosureDetail: View {
    @Environment(Monitor.self) private var monitor
    let enclosureID: String
    private static let palette: [Color] = [.blue, .teal, .purple, .pink, .indigo, .mint]

    var body: some View {
        let layout = EnclosureTopology.build(monitor.drives, showOthers: false)
        if let e = layout.enclosures.first(where: { $0.id == enclosureID }) {
            let hints = EnclosureAnalysis.hints(e, monitor: monitor)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(e)
                    if hints.saturated {
                        banner("Enclosure bandwidth is saturated — drives share one \(e.mode == "USB" ? "USB" : e.mode) link",
                               "Combined throughput has been at 85 % or more of the shared link for 5 s or longer.")
                    }
                    if !hints.limitedNames.isEmpty {
                        let pcie = e.slots.first { hints.limitedSlots.contains($0.number ?? 0) }?.drive.link
                        banner("Slot link limit (PCIe x\(pcie?.currentWidth ?? 1)) reached",
                               "\(hints.limitedNames.joined(separator: ", ")) is running at the limit of its own PCIe link, not of the enclosure.")
                    }
                    budget(e)
                    slotTable(e)
                    Card("Eject") {
                        EjectControls(drives: e.drives, ejectTitle: "Eject all volumes of this enclosure", sheetTitle: e.name)
                    }
                }.padding(20)
            }
        } else {
            ContentUnavailableView("Enclosure disconnected", systemImage: "externaldrive.badge.xmark")
        }
    }

    private func banner(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: "gauge.with.dots.needle.100percent").font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
        .foregroundStyle(.orange).padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    private func header(_ e: EnclosureTopology.Enclosure) -> some View {
        Card("Enclosure") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                row("Name", e.name)
                if let v = e.vendor { row("Vendor", v) }
                row("Firmware", e.firmware ?? "-")
                row("Connection", e.speedText)
                if let p = e.hostPort { row("Mac port", p) }
                row("Drives", "\(e.drives.count)")
                row("Shared budget", e.budgetMBps > 0
                    ? "~\(String(format: "%.1f", e.budgetMBps / 1000)) GB/s per direction" : "unknown")
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow { Text(k).foregroundStyle(.secondary).gridColumnAlignment(.trailing); Text(v).textSelection(.enabled) }
    }

    // MARK: Budget bars

    private func budget(_ e: EnclosureTopology.Enclosure) -> some View {
        let readTotal = e.drives.reduce(0.0) { $0 + $1.throughput.readMBps }
        let writeTotal = e.drives.reduce(0.0) { $0 + $1.throughput.writeMBps }
        return Card("Shared bandwidth") {
            if e.budgetMBps > 0 {
                Text("Currently using \(gb(max(readTotal, writeTotal))) of ~\(gb(e.budgetMBps)) per direction")
                    .font(.callout.monospacedDigit())
                bar("Read", e, value: { $0.throughput.readMBps }, total: readTotal)
                bar("Write", e, value: { $0.throughput.writeMBps }, total: writeTotal)
                HStack(spacing: 12) {
                    ForEach(Array(e.slots.enumerated()), id: \.element.id) { i, s in
                        HStack(spacing: 4) {
                            Circle().fill(Self.palette[i % Self.palette.count]).frame(width: 8, height: 8)
                            Text(label(s)).font(.caption)
                        }
                    }
                }
                Text("Assumed usable payload per direction: USB4 / Thunderbolt 40 Gb/s ≈ 3.8 GB/s, 80 Gb/s ≈ 7.6 GB/s, USB 10 Gb/s ≈ 1 GB/s. Real PCIe tunnels often reach less.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Link speed of the enclosure is unknown, so no budget can be shown.").foregroundStyle(.secondary)
            }
        }
    }

    private func bar(_ title: String, _ e: EnclosureTopology.Enclosure, value: @escaping (DriveSnapshot) -> Double, total: Double) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08))
                    HStack(spacing: 0) {
                        ForEach(Array(e.slots.enumerated()), id: \.element.id) { i, s in
                            Rectangle().fill(Self.palette[i % Self.palette.count])
                                .frame(width: geo.size.width * min(value(s.drive) / e.budgetMBps, 1))
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }.frame(height: 14)
            Text(Fmt.rate(total)).font(.caption.monospacedDigit()).frame(width: 84, alignment: .trailing)
        }
    }

    private func gb(_ mbps: Double) -> String {
        mbps >= 1000 ? String(format: "%.2f GB/s", mbps / 1000) : String(format: "%.0f MB/s", mbps)
    }

    private func label(_ s: EnclosureTopology.Slot) -> String {
        (s.number.map { "Slot \($0)" } ?? "Slot ?") + " · " + (s.drive.vendor?.name ?? s.drive.model)
    }

    // MARK: Per-slot table

    private func slotTable(_ e: EnclosureTopology.Enclosure) -> some View {
        Card("Slots") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Slot"); Text("Drive"); Text("Link"); Text("Temp"); Text("Read"); Text("Write")
                }.font(.caption).foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(e.slots) { s in
                    let warn = LinkCheck.warning(for: s, in: e)
                    GridRow {
                        Text(s.number.map { "\($0)" } ?? "?").font(.body.monospacedDigit().weight(.semibold))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.drive.model).lineLimit(1)
                            Text(Fmt.capacity(s.drive.capacityBytes)).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 4) {
                            if warn != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                            Text(LinkCheck.text(s.drive.link)).foregroundStyle(warn == nil ? Color.primary : .orange)
                        }.help(warn ?? "")
                        Text(Fmt.temp(s.drive.smart?.temperatureC)).monospacedDigit()
                        Text(Fmt.rate(s.drive.throughput.readMBps)).monospacedDigit().foregroundStyle(.blue)
                        Text(Fmt.rate(s.drive.throughput.writeMBps)).monospacedDigit().foregroundStyle(.orange)
                    }
                }
            }
            Text("Slot order is derived from the PCIe port of the enclosure's bridge and may differ from the labels on the case.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
