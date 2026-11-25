import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum ReportFormat: String, CaseIterable, Identifiable {
    case pdf, json, md
    var id: String { rawValue }
    var title: String { switch self { case .pdf: "PDF"; case .json: "JSON"; case .md: "Markdown" } }
    var type: UTType { switch self { case .pdf: .pdf; case .json: .json; case .md: UTType(filenameExtension: "md") ?? .plainText } }
}

extension Notification.Name {
    static let nvmeterExportReport = Notification.Name("nvmeter.exportReport")
}

enum ReportExporter {
    /// Writes the document in the chosen format. Must run on the main thread (PDF rendering).
    @MainActor static func write(_ doc: ReportDocument, format: ReportFormat, to url: URL, paper: ReportPaper) throws {
        switch format {
        case .pdf:
            guard ReportPDF.write(doc, to: url, paper: paper) else {
                throw NSError(domain: "NVMeter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create the PDF"])
            }
        case .json: try doc.jsonData().write(to: url, options: .atomic)
        case .md: try ReportMarkdown.render(doc).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Toolbar + sheets on the Drives tab

private struct ReportToolbar: ViewModifier {
    @Environment(Monitor.self) private var monitor
    @State private var showExport = false
    @State private var showCompare = false
    @State private var message: String?

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItemGroup {
                    Button { showExport = true } label: { Label("Export Report…", systemImage: "square.and.arrow.up") }
                        .help("Export a PDF, JSON or Markdown report of the selected drive")
                        .disabled(monitor.selected == nil)
                    Menu {
                        Button("Save snapshot") { saveSnapshot() }
                        Button("Compare…") { showCompare = true }
                    } label: { Label("Snapshots", systemImage: "camera.on.rectangle") }
                    .disabled(monitor.selected?.smart == nil)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .nvmeterExportReport)) { _ in
                if monitor.selected != nil { showExport = true }
            }
            .sheet(isPresented: $showExport) { ExportSheet().environment(monitor) }
            .sheet(isPresented: $showCompare) { CompareSheet().environment(monitor) }
            .alert("Snapshot", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: { Text(message ?? "") }
    }

    private func saveSnapshot() {
        guard let d = monitor.selected else { return }
        do { let u = try SnapshotStore.save(d); message = "Saved \(u.lastPathComponent) for \(d.model)." }
        catch { message = error.localizedDescription }
    }
}

extension View {
    func reportToolbar() -> some View { modifier(ReportToolbar()) }
}

struct ExportSheet: View {
    @Environment(Monitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hideSerials") private var hideSerialsSetting = false
    @State private var format: ReportFormat = .pdf
    @State private var hideSerials = false
    @State private var hideVolumes = false
    @State private var allDrives = false
    @State private var paper = ReportPaper.localeDefault
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export drive report").font(.title3.weight(.semibold))
            Picker("Format", selection: $format) { ForEach(ReportFormat.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented)
            if format == .pdf {
                Picker("Paper", selection: $paper) { ForEach(ReportPaper.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            }
            Toggle("Hide serial number", isOn: $hideSerials)
            Toggle("Hide volume names and mount points", isOn: $hideVolumes)
            if monitor.drives.count > 1 {
                Toggle("All SMART drives (otherwise the selected drive)", isOn: $allDrives)
            }
            Text("Useful for warranty claims, selling a drive, handing media to a client or posting in a forum.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") { export() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 420)
        .onAppear { hideSerials = hideSerialsSetting }
    }

    private func export() {
        let chosen: [DriveSnapshot] = allDrives ? monitor.drives.filter { $0.smart != nil } : (monitor.selected.map { [$0] } ?? [])
        guard !chosen.isEmpty else { error = "No drive to export"; return }
        var charts: [String: ReportChartData] = [:]
        for d in chosen {
            let w = 1800.0
            charts[d.id] = ReportChartData(
                windowSeconds: w,
                temps: monitor.temps(d.id, window: w).map { ReportTempSample(t: $0.t, c: $0.c) },
                rates: monitor.rates(d.id, window: w).map { ReportRateSample(t: $0.t, readMBps: $0.read, writeMBps: $0.write) })
        }
        let doc = ReportBuilder.make(drives: chosen, charts: charts, options: ReportOptions(hideSerials: hideSerials, hideVolumes: hideVolumes))
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        let base = (chosen.count == 1 ? chosen[0].model : "drives").replacingOccurrences(of: " ", with: "-")
        panel.nameFieldStringValue = "NVMeter-report-\(base).\(format.rawValue)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ReportExporter.write(doc, format: format, to: url, paper: paper); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

struct CompareSheet: View {
    @Environment(Monitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss
    @State private var snaps: [(url: URL, snap: SnapshotFile)] = []
    /// -1 = now, otherwise an index into `snaps`
    @State private var a = 0
    @State private var b = -1

    private func file(_ i: Int) -> SnapshotFile? {
        if i == -1 { return monitor.selected.map { SnapshotFile.make(from: $0) } }
        return snaps.indices.contains(i) ? snaps[i].snap : nil
    }

    private func label(_ i: Int) -> String {
        if i == -1 { return "Now" }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: snaps[i].snap.takenAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compare snapshots").font(.title3.weight(.semibold))
            if snaps.isEmpty {
                Text("No snapshots for this drive yet. Use Snapshots > Save snapshot first.").foregroundStyle(.secondary)
            } else {
                HStack {
                    Picker("Before", selection: $a) { choices }
                    Picker("After", selection: $b) { choices }
                }
                if let fa = file(a), let fb = file(b) {
                    let rows = SnapshotCompare.rows(fa, fb)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                        GridRow {
                            Text("Counter").bold(); Text("Before").bold(); Text("After").bold(); Text("Delta").bold(); Text("Per day").bold()
                        }.foregroundStyle(.secondary)
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(rows) { r in
                            GridRow {
                                Text(r.name)
                                Text(r.before).monospacedDigit()
                                Text(r.after).monospacedDigit()
                                Text(r.delta).monospacedDigit()
                                Text(r.perDay).monospacedDigit()
                            }
                            .foregroundStyle(r.verdict == .worse ? Color.red : (r.verdict == .better ? Color.green : Color.primary))
                            .fontWeight(r.verdict == .worse ? .semibold : .regular)
                        }
                    }
                    Text(String(format: "Interval: %.2f days. Red = got worse.", fb.takenAt.timeIntervalSince(fa.takenAt) / 86400))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20).frame(minWidth: 720)
        .onAppear {
            if let d = monitor.selected { snaps = SnapshotStore.list(for: d) }
            a = snaps.isEmpty ? -1 : snaps.count - 1
            b = -1
        }
    }

    @ViewBuilder private var choices: some View {
        Text("Now").tag(-1)
        ForEach(snaps.indices, id: \.self) { Text(label($0)).tag($0) }
    }
}

/// File menu command, posted to the Drives tab (which owns the sheet).
struct ReportCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Export Report…") { NotificationCenter.default.post(name: .nvmeterExportReport, object: nil) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
    }
}
