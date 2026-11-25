import SwiftUI

struct DrivesView: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage("showDisksWithoutSMART") private var showNoSMART = true
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var m = monitor
        let withSMART = monitor.drives.filter { !$0.isUSBOther }
        let others = showNoSMART ? monitor.drives.filter(\.isUSBOther) : []
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $m.selection) {
                ForEach(withSMART) { d in DriveRow(drive: d).tag(d.id) }
                if !others.isEmpty {
                    Section("Other disks (no SMART)") {
                        ForEach(others) { d in DriveRow(drive: d).tag(d.id) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 360)
            .overlay { if monitor.drives.isEmpty { ContentUnavailableView("No disks found", systemImage: "externaldrive.badge.questionmark") } }
        } detail: {
            if let d = monitor.selected {
                DriveDetail(drive: d).id(d.id)
            } else {
                ContentUnavailableView("Select a disk", systemImage: "externaldrive")
            }
        }
    }
}

struct DriveRow: View {
    let drive: DriveSnapshot
    var body: some View {
        HStack(spacing: 10) {
            VendorLogo(vendor: drive.vendor, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(drive.displayName).font(.headline).lineLimit(1)
                Text(drive.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                if let t = drive.smart?.temperatureC {
                    Text("\(t) °C").font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(HealthEvaluator.tempStatus(t, warn: drive.identify?.warningTempC, crit: drive.identify?.criticalTempC).color)
                } else {
                    Text("n/a").font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    StatusDot(status: drive.health)
                    Text(drive.health.title).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct DriveDetail: View {
    let drive: DriveSnapshot
    @AppStorage("hideSerials") private var hideSerials = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                ForEach(drive.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                }
                info
                if drive.smart != nil { totals }
                volumes
                if !drive.attributes.isEmpty { attributes }
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            HealthTile(title: "Health Status", value: drive.health.title,
                       subtitle: drive.smart.map { "Wear \($0.percentageUsed) %" } ?? "SMART unavailable",
                       color: drive.health.color)
            let t = drive.smart?.temperatureC
            let ts = t.map { HealthEvaluator.tempStatus($0, warn: drive.identify?.warningTempC, crit: drive.identify?.criticalTempC) } ?? .unknown
            HealthTile(title: "Temperature", value: Fmt.temp(t),
                       subtitle: drive.identify?.warningTempC.map { "warn \($0) °C · crit \(drive.identify?.criticalTempC ?? 0) °C" },
                       color: ts.color)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    VendorLogo(vendor: drive.vendor, height: 34)
                    Text(drive.displayName).font(.title2.weight(.semibold))
                }
                Text(drive.isUSBOther ? drive.subtitle : drive.model).foregroundStyle(.secondary)
                Text("/dev/\(drive.bsdName) · \(Fmt.capacity(drive.capacityBytes))").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Label(Fmt.rate(drive.throughput.readMBps), systemImage: "arrow.down.circle").foregroundStyle(.blue)
                    Label(Fmt.rate(drive.throughput.writeMBps), systemImage: "arrow.up.circle").foregroundStyle(.orange)
                }.font(.callout.monospacedDigit()).padding(.top, 6)
            }
            Spacer()
        }
    }

    private var info: some View {
        Card("Drive") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                if drive.bridgeChip != nil {
                    row("Model", "drive model unknown (bridge does not pass NVMe identify)")
                    row("USB bridge", drive.bridgeChip ?? "-")
                } else {
                    row("Model", drive.model)
                    if let v = drive.vendor { row("Vendor", v.name) }
                }
                row(drive.bridgeChip != nil ? "Bridge serial" : "Serial", Fmt.serial(drive.serial, hide: hideSerials))
                row("Firmware", drive.firmware.isEmpty ? "-" : drive.firmware)
                row("Capacity", Fmt.capacity(drive.capacityBytes))
                row("Interface", drive.interface)
                if let l = drive.link {
                    row("Link", "PCIe \(l.currentGen).0 x\(l.currentWidth) (\(String(format: "%.0f", l.currentGTs)) GT/s), up to ~\(Int(l.bandwidthMBps)) MB/s"
                        + " · drive supports PCIe \(l.maxGen).0 x\(l.maxWidth)")
                }
                if let fw = drive.connection.firmware { row("Enclosure firmware", fw) }
                if let v = drive.identify?.nvmeVersion { row("NVMe version", v) }
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(v).textSelection(.enabled)
        }
    }

    private var totals: some View {
        let s = drive.smart!
        return HStack(spacing: 12) {
            stat("Total written", String(format: "%.2f TB", s.terabytesWritten))
            stat("Total read", String(format: "%.2f TB", s.terabytesRead))
            stat("Power-on", "\(HealthEvaluator.hours(s.powerOnHours))")
            stat("Power cycles", HealthEvaluator.num(s.powerCycles))
        }
    }

    private func stat(_ t: String, _ v: String) -> some View {
        Card { VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.title3.monospacedDigit().weight(.semibold)).lineLimit(2).minimumScaleFactor(0.7)
        } }
    }

    private var volumes: some View {
        Card("Volumes") {
            if drive.volumes.isEmpty { Text("No mounted volumes").foregroundStyle(.secondary) }
            ForEach(drive.volumes) { v in
                HStack {
                    Image(systemName: "internaldrive.fill").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(v.name).font(.body.weight(.medium))
                        Text("\(v.mountPoint) · \(v.fileSystem ?? "?")").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(Fmt.capacity(v.freeBytes)) free of \(Fmt.capacity(v.sizeBytes))").font(.caption.monospacedDigit())
                        ProgressView(value: v.sizeBytes == 0 ? 0 : Double(v.sizeBytes - min(v.freeBytes, v.sizeBytes)) / Double(v.sizeBytes))
                            .frame(width: 160)
                    }
                }
            }
        }
    }

    private var attributes: some View {
        Card("SMART attributes (NVMe health log)") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(drive.attributes) { a in
                    GridRow {
                        StatusDot(status: a.status)
                        Text(a.name)
                        Text(a.value).font(.body.monospacedDigit()).foregroundStyle(a.status == .good ? Color.primary : a.status.color)
                            .gridColumnAlignment(.leading).textSelection(.enabled)
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
            }
        }
    }
}
