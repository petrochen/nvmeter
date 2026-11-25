import SwiftUI

extension RAIDStatus {
    var color: Color {
        switch self { case .online: .green; case .rebuilding: .orange; case .degraded: .orange; case .offline: .red; case .unknown: .secondary }
    }
}

/// Sidebar groups: one section per RAID set with its member drives.
struct RAIDSidebarSections: View {
    let sets: [RAIDSetInfo]
    let drives: [DriveSnapshot]

    var body: some View {
        ForEach(sets) { set in
            Section {
                if set.kind == "SoftRAID" && set.members.isEmpty {
                    Label("SoftRAID volume", systemImage: "externaldrive.connected.to.line.below").foregroundStyle(.secondary)
                }
                ForEach(set.members) { m in
                    if let d = drives.first(where: { $0.bsdName == m.driveBSD }) {
                        DriveRow(drive: d).tag(d.id)
                    } else {
                        Label("\(m.bsdName): drive missing", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).font(.caption)
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up.fill")
                    Text(set.name)
                    Text(set.level).foregroundStyle(.secondary)
                    Spacer()
                    if set.status != .unknown {
                        Text(set.status.title + (set.rebuildPercent.map { " \($0) %" } ?? ""))
                            .font(.caption.weight(.semibold)).foregroundStyle(set.status.color)
                    }
                }
            }
        }
    }
}

struct SelfTestCard: View {
    let log: NVMeSelfTestLog
    var body: some View {
        Card("Device self-test log") {
            if let p = log.inProgress {
                Label("\(p) self-test running" + (log.percentComplete.map { ", \($0) % done" } ?? ""), systemImage: "hourglass")
                    .foregroundStyle(.blue)
            }
            if log.entries.isEmpty && log.inProgress == nil {
                Text("No self-tests recorded").foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                ForEach(Array(log.entries.prefix(10).enumerated()), id: \.offset) { _, e in
                    GridRow {
                        Image(systemName: e.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(e.passed ? Color.green : Color.red)
                        Text(e.testName)
                        Text(e.result)
                        Text("at \(HealthEvaluator.num(e.powerOnHours)) h").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }
}

struct DriveSettingsSection: View {
    @AppStorage(ATAPolicy.dontWakeKey) private var dontWake = true
    var body: some View {
        Section("SATA / hard drives") {
            Toggle("Don't wake sleeping hard drives", isOn: $dontWake)
            Text("ATA SMART is read at most once a minute. A spun-down hard drive is not polled; its last known values stay on screen.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
