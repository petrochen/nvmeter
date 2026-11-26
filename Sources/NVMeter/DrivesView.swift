import SwiftUI

struct DrivesView: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage("showDisksWithoutSMART") private var showNoSMART = true
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var m = monitor
        NavigationSplitView(columnVisibility: $columns) {
            TopologySidebar(selection: $m.selection, showOthers: showNoSMART)
            .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 360)
            .overlay { if monitor.drives.isEmpty { ContentUnavailableView("No disks found", systemImage: "externaldrive.badge.questionmark") } }
        } detail: {
            if let sel = monitor.selection, sel.hasPrefix(EnclosureTopology.selectionPrefix) {
                EnclosureDetail(enclosureID: sel).id(sel)
            } else if let d = monitor.selected {
                DriveDetail(drive: d).id(d.id)
            } else {
                ContentUnavailableView("Select a disk", systemImage: "externaldrive")
            }
        }
        .reportToolbar()
    }
}

struct DriveRow: View {
    let drive: DriveSnapshot
    @Environment(Monitor.self) private var monitor
    @State private var renaming = false
    @State private var nameDraft = ""
    var body: some View {
        HStack(spacing: 10) {
            VendorLogo(vendor: drive.vendor, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(drive.displayName).font(.headline).lineLimit(1)
                Text(drive.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                if let t = drive.temperatureC {
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
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded { nameDraft = drive.customName ?? ""; renaming = true })
        .contextMenu {
            Button("Rename…") { nameDraft = drive.customName ?? ""; renaming = true }
            Button("Reset name") { monitor.rename(drive.id, to: nil) }.disabled(drive.customName == nil)
        }
        .alert("Rename drive", isPresented: $renaming) {
            TextField("Name", text: $nameDraft)
            Button("Rename") { monitor.rename(drive.id, to: nameDraft) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Shown instead of the volume name. An empty name restores the default.") }
    }
}

struct DriveDetail: View {
    let drive: DriveSnapshot
    @Environment(Monitor.self) private var monitor
    @AppStorage("hideSerials") private var hideSerials = false

    private enum SectionTab: String, CaseIterable { case overview = "Overview", history = "History", speed = "Speed Test" }
    @State private var section = SectionTab.overview
    @State private var hover: HoverState?
    private let interval: TimeInterval = 1800
    private var warning: Int { drive.identify?.warningTempC ?? HealthEvaluator.fallbackWarnC }
    private var critical: Int { drive.identify?.criticalTempC ?? HealthEvaluator.fallbackCritC }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding([.horizontal, .top], 20)
            Picker("Drive section", selection: $section) {
                ForEach(SectionTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            if section == .speed {
                SpeedTestView(scopedDrive: drive)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if section == .history {
                                if drive.temperatureC != nil || !monitor.temps(drive.id, window: interval).isEmpty { temperature }
                                events
                            } else {
                                overview
                            }
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: monitor.scrollToUsage) { _, show in
                        if show { section = .overview; proxy.scrollTo("usage", anchor: .top) }
                    }
                }
            }
        }
    }

    private var enclosure: EnclosureTopology.Enclosure? {
        let layout = EnclosureTopology.build(monitor.drives, showOthers: true)
        return layout.enclosures.first { $0.id == EnclosureTopology.selectionID(for: drive) }
    }

    private var location: String {
        if let enclosure,
           let slot = enclosure.slots.first(where: { $0.id == drive.id }) {
            return [enclosure.name, slot.number.map { "Slot \($0)" }].compactMap { $0 }.joined(separator: " / ")
        }
        return drive.isUSBOther ? drive.subtitle : drive.connection.summary
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let enclosure, enclosure.slots.count > 1 {
                HStack(spacing: 3) {
                    ForEach(enclosure.slots) { slot in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(slot.id == drive.id ? Color.orange : Color.secondary.opacity(0.45))
                            .frame(width: 6, height: 23)
                    }
                }.padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
            } else {
                VendorLogo(vendor: drive.vendor, height: 38)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(drive.displayName).font(.largeTitle.weight(.semibold)).textSelection(.enabled)
                Text(location).font(.headline).foregroundStyle(.secondary)
            }
            Spacer()
            if drive.health != .unknown {
                HStack { StatusDot(status: drive.health); Text("SMART · \(drive.health.title)") }
            }
        }
    }

    @ViewBuilder private var overview: some View {
        if let t = drive.temperatureC {
            if t >= warning || t >= critical {
                let threshold = t >= critical ? critical : warning
                HStack {
                    Label("Temperature \(t) °C · \(t >= critical ? "critical" : "warning") threshold \(threshold) °C",
                          systemImage: "exclamationmark.triangle.fill")
                    Spacer()
                    Button("View history") { section = .history }
                }.padding(10).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            temperature
        }
        HStack(spacing: 20) {
            Label("Read  \(Fmt.rate(drive.throughput.readMBps))", systemImage: "arrow.down.circle")
            Label("Write  \(Fmt.rate(drive.throughput.writeMBps))", systemImage: "arrow.up.circle")
        }.font(.callout.monospacedDigit())
        if let report = ConnectCheck.shared.reports[drive.id] { ConnectReportCard(report: report) }
        volumes
        ForEach(drive.warnings, id: \.self) { message in
            if drive.isUSBOther && message.contains("SMART unavailable") {
                Label(message, systemImage: "info.circle").foregroundStyle(.secondary)
            } else {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        EjectControls(drives: [drive], ejectTitle: "Eject", sheetTitle: drive.displayName)
        info
        if drive.smart != nil { totals; UsageSection(drive: drive).id("usage") }
        if !drive.attributes.isEmpty { attributes }
    }

    private var temperature: some View {
        let points = monitor.temps(drive.id, window: interval)
        return Card("Temperature") {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(Fmt.temp(drive.temperatureC)).font(.title.bold().monospacedDigit())
                if let peak = points.map(\.c).max() { Text("30 min peak  \(Int(peak)) °C") }
                Text("Warning at \(warning) °C")
                Spacer()
                if section == .overview { Button("View history") { section = .history }.buttonStyle(.link) }
            }
            TempChart(points: points, now: monitor.lastTick, window: interval, warn: warning,
                      crit: section == .history ? critical : nil, hover: hover, onHover: { hover = $0 },
                      showLabel: true, values: { monitor.hoverValues(at: $0, id: drive.id, window: interval) })
                .frame(height: section == .history ? 190 : 96)
        }
    }

    private var events: some View {
        let recent = monitor.alerts.events.filter { $0.driveID == drive.id }
        return Card("Drive events") {
            if recent.isEmpty { Text("No recorded events for this drive.").foregroundStyle(.secondary) }
            ForEach(recent) { event in
                HStack(alignment: .firstTextBaseline) {
                    Text(event.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    VStack(alignment: .leading) { Text(event.title).bold(); Text(event.body).font(.caption) }
                }
            }
        }
    }

    private var info: some View {
        Card("Drive") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                DriveNameRow(drive: drive)
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
        Card(drive.isATA ? "SMART attributes (ATA)" : "SMART attributes (NVMe health log)") {
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
