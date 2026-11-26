import SwiftUI
import Charts

extension Monitor {
    /// Hottest composite temperature and its status over all drives with SMART.
    var hottest: (temp: Int, status: HealthStatus)? {
        let items = drives.compactMap { d -> (Int, HealthStatus)? in
            guard let t = d.temperatureC else { return nil }
            return (t, HealthEvaluator.tempStatus(t, warn: d.identify?.warningTempC, crit: d.identify?.criticalTempC))
        }
        guard let top = items.max(by: { $0.0 < $1.0 }) else { return nil }
        return (top.0, items.map(\.1).max() ?? .good)
    }

    var totalMBps: Double { drives.reduce(0) { $0 + $1.throughput.readMBps + $1.throughput.writeMBps } }

    var menuBarText: String {
        var s = hottest.map { "\($0.temp)°" } ?? "–"
        if UserDefaults.standard.bool(forKey: AlertKeys.menuBarTotal) {
            let t = totalMBps
            s += t >= 1000 ? String(format: " %.1fG", t / 1000) : String(format: " %.0fM", t)
        }
        return s
    }
}

/// Link text such as "Gen4 x1 · USB4".
func linkSummary(_ d: DriveSnapshot) -> String {
    var parts: [String] = []
    if let l = d.link { parts.append(AlertCenter.linkText(l.currentGTs, l.currentWidth)) }
    switch d.connection.kind {
    case "thunderbolt": parts.append(d.connection.mode ?? "Thunderbolt")
    case "usb": parts.append(d.usbSpeedText)
    case "internal": parts.append("internal")
    default: break
    }
    return parts.isEmpty ? "-" : parts.joined(separator: " · ")
}

/// Label shown in the menu bar. Also owns the openWindow action used by the popover and notification clicks.
struct MenuBarLabel: View {
    @Environment(Monitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarIcon.image(text: monitor.menuBarIcon.text, status: monitor.menuBarIcon.status))
            .task { monitor.start() }
            .onReceive(NotificationCenter.default.publisher(for: .nvmeterShowMain)) { n in
                if let id = n.userInfo?["driveID"] as? String { monitor.selection = id; monitor.tab = .drives }
                openWindow(id: "main")
                AppLifecycle.shared.bringToFront()
            }
    }
}

struct MenuPopover: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage("hideSerials") private var hideSerials = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("NVMeter").font(.headline)
                Spacer()
                if let h = monitor.hottest { Text("hottest \(h.temp) °C").font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if monitor.drives.isEmpty {
                Text("No disks found").foregroundStyle(.secondary).padding(14)
            } else {
                ForEach(monitor.drives) { d in
                    PopoverRow(drive: d)
                    Divider().opacity(0.4)
                }
            }
            recentEvents
            HStack {
                Button("Open NVMeter") { AppRouter.showMain(driveID: nil) }
                SettingsLink { Image(systemName: "gearshape") }.help("Settings")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }.padding(10)
        }
        .frame(width: 360)
    }

    @ViewBuilder private var recentEvents: some View {
        let ev = DemoNames.enabled ? [] : Array(monitor.alerts.events.prefix(3))
        if !ev.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Recent events").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("All") { monitor.tab = .events; AppRouter.showMain(driveID: nil) }.buttonStyle(.link).font(.caption)
                }
                ForEach(ev) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(e.severity.color).frame(width: 7, height: 7)
                        Text(e.title).font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(e.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }.padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
        }
    }
}

struct PopoverRow: View {
    @Environment(Monitor.self) private var monitor
    let drive: DriveSnapshot

    var body: some View {
        Button {
            monitor.selection = drive.id; monitor.tab = .drives
            AppRouter.showMain(driveID: drive.id)
        } label: {
            HStack(spacing: 10) {
                VendorLogo(vendor: drive.vendor, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        StatusDot(status: drive.health)
                        Text(drive.displayName).font(.callout.weight(.semibold)).lineLimit(1)
                    }
                    Text(linkSummary(drive)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 8) {
                        Label(Fmt.rate(drive.throughput.readMBps), systemImage: "arrow.down").foregroundStyle(.blue)
                        Label(Fmt.rate(drive.throughput.writeMBps), systemImage: "arrow.up").foregroundStyle(.orange)
                    }.font(.caption2.monospacedDigit()).labelStyle(CompactLabel())
                }
                Spacer(minLength: 4)
                if let t = drive.temperatureC {
                    Sparkline(points: monitor.temps(drive.id, window: 300)).frame(width: 56, height: 22)
                    Text("\(t)°").font(.system(.title3, design: .rounded).monospacedDigit().weight(.semibold))
                        .foregroundStyle(HealthEvaluator.tempStatus(t, warn: drive.identify?.warningTempC, crit: drive.identify?.criticalTempC).color)
                        .frame(minWidth: 40, alignment: .trailing)
                } else {
                    Text("n/a").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) { configuration.icon.imageScale(.small); configuration.title }
    }
}

struct Sparkline: View {
    let points: [TempPoint]
    var body: some View {
        if points.count > 1 {
            Chart(points) { LineMark(x: .value("t", $0.t), y: .value("°C", $0.c)).interpolationMethod(.monotone) }
                .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .foregroundStyle(.secondary)
        } else {
            Color.clear
        }
    }
}

extension AlertSeverity {
    var color: Color { switch self { case .info: .blue; case .warning: .orange; case .critical: .red } }
}
