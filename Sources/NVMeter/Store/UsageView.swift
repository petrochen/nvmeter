import SwiftUI

/// "Usage & lifetime" card on the Drives tab: per-day trends and endurance projection from hourly SMART snapshots.
struct UsageSection: View {
    let drive: DriveSnapshot
    @Environment(Monitor.self) private var monitor
    @State private var trends: UsageTrends?
    @State private var loaded = false

    var body: some View {
        Card("Usage & lifetime") {
            if let t = trends {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    row("Written per day", "\(UsageTrends.bytesPerDay(t.writtenPerDay7)) (\(UsageTrends.avgLabel(t.writtenPerDay7, window: 7)))  ·  \(UsageTrends.bytesPerDay(t.writtenPerDay30)) (\(UsageTrends.avgLabel(t.writtenPerDay30, window: 30)))")
                    row("Read per day", "\(UsageTrends.bytesPerDay(t.readPerDay7)) (\(UsageTrends.avgLabel(t.readPerDay7, window: 7)))  ·  \(UsageTrends.bytesPerDay(t.readPerDay30)) (\(UsageTrends.avgLabel(t.readPerDay30, window: 30)))")
                    row("Power-on per day", "\(UsageTrends.hoursPerDay(t.powerOnPerDay7)) (\(UsageTrends.avgLabel(t.powerOnPerDay7, window: 7)))  ·  \(UsageTrends.hoursPerDay(t.powerOnPerDay30)) (\(UsageTrends.avgLabel(t.powerOnPerDay30, window: 30)))")
                }
                projection(t)
                Divider()
                since(t)
            } else if loaded {
                Text("No SMART history yet: the first hourly snapshot is taken as soon as SMART is readable.").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: drive.id) {
            while !Task.isCancelled {
                let rows = await monitor.store.snapshots(key: drive.id)
                trends = UsageTrends.compute(rows: rows)
                loaded = true
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(v).font(.body.monospacedDigit()).textSelection(.enabled)
        }
    }

    private func projection(_ t: UsageTrends) -> some View {
        let warn: Bool = { if case .reached = t.projection { return true }; return false }()
        return Label(t.projectionText, systemImage: "hourglass")
            .foregroundStyle(warn ? Color.red : Color.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func since(_ t: UsageTrends) -> some View {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        let days = t.historyDays
        let age = days >= 1 ? String(format: "%.1f days", days) : String(format: "%.0f min", days * 1440)
        let crit = t.criticalWarningNow != 0 || t.criticalWarningChanged
        return VStack(alignment: .leading, spacing: 5) {
            Text("Since first seen by NVMeter (\(f.string(from: t.firstSeen)), \(age), \(t.snapshotCount) snapshots)").font(.subheadline.weight(.semibold))
            HStack(spacing: 22) {
                stat("Written", String(format: "%.2f TB", t.writtenSinceBytes / 1e12), red: false)
                stat("Read", String(format: "%.2f TB", t.readSinceBytes / 1e12), red: false)
                stat("Media errors added", "\(t.mediaErrorsAdded)", red: t.mediaErrorsAdded > 0)
                stat("Error log entries added", "\(t.errorLogAdded)", red: t.errorLogAdded > 0)
                stat("Unsafe shutdowns added", "\(t.unsafeShutdownsAdded)", red: false)
                stat("Critical warning", crit ? HealthEvaluator.criticalWarningText(UInt8(clamping: t.criticalWarningNow)) : "none", red: crit)
            }
        }
    }

    private func stat(_ title: String, _ value: String, red: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(red ? .bold : .regular)).foregroundStyle(red ? Color.red : Color.primary)
        }
    }
}

/// Name field for the drive detail card.
struct DriveNameRow: View {
    let drive: DriveSnapshot
    @Environment(Monitor.self) private var monitor
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        GridRow {
            Text("Name").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            HStack {
                TextField("Default name", text: $draft, prompt: Text(defaultName))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 280).focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, f in if !f { commit() } }
                Button("Reset name") { draft = ""; monitor.rename(drive.id, to: nil) }
                    .disabled(drive.customName == nil)
            }
            .onAppear { draft = drive.customName ?? "" }
        }
    }

    private var defaultName: String {
        var d = drive; d.customName = nil
        return d.displayName
    }

    private func commit() {
        let n = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { if drive.customName != nil { monitor.rename(drive.id, to: nil) } }
        else if n != drive.customName { monitor.rename(drive.id, to: n) }
    }
}

/// Settings: retention and deletion.
struct HistorySettingsSection: View {
    @AppStorage("historyKeepDays") private var keepDays: Int = 730
    @State private var confirm = false
    @State private var info = ""

    var body: some View {
        Section("History") {
            Picker("Keep history for", selection: $keepDays) {
                ForEach(HistoryStore.keepOptions, id: \.days) { Text($0.title).tag($0.days) }
            }
            HStack {
                Button("Delete history…", role: .destructive) { confirm = true }
                Text(info).font(.caption).foregroundStyle(.secondary)
            }
            Text("Graphs and trends are stored in Application Support/NVMeter/history.sqlite. Custom drive names are kept.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Delete all stored history?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Delete history", role: .destructive) {
                HistoryStore.shared.deleteAll()
                NotificationCenter.default.post(name: .nvmeterHistoryDeleted, object: nil)
                info = "History deleted."
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Samples and SMART snapshots of all drives are removed. This cannot be undone.")
        }
    }
}
