import SwiftUI
import AppKit

/// "Eject" and "Show processes using this volume" for a drive or a whole enclosure.
struct EjectControls: View {
    let drives: [DriveSnapshot]
    let ejectTitle: String
    let sheetTitle: String
    @State private var controller = EjectController()
    @State private var confirming = false
    @State private var showingHolders = false

    private var hasVolumes: Bool { drives.contains { !$0.volumes.isEmpty } }

    var body: some View {
        HStack(spacing: 10) {
            Button { controller.reset(); confirming = true } label: { Label(ejectTitle, systemImage: "eject.fill") }
            Button {
                controller.reset(); showingHolders = true
                Task { await controller.showHolders(of: drives) }
            } label: { Label("Show processes using this volume", systemImage: "list.bullet.rectangle") }
                .disabled(!hasVolumes)
        }
        .sheet(isPresented: $confirming) { EjectSheet(drives: drives, title: sheetTitle, controller: controller, isPresented: $confirming) }
        .sheet(isPresented: $showingHolders) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Processes using \(sheetTitle)").font(.headline)
                if controller.lookingUp { HStack { ProgressView().controlSize(.small); Text("Looking up open files…") } }
                else { HoldersList(holders: controller.holders, emptyText: "No process has files open on these volumes.") }
                HStack { Spacer(); Button("Close") { showingHolders = false }.keyboardShortcut(.cancelAction) }
            }.padding(20).frame(width: 520)
        }
    }
}

struct EjectSheet: View {
    let drives: [DriveSnapshot]
    let title: String
    let controller: EjectController
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Eject \(title)?").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(drives) { d in
                    let vols = d.volumes.map(\.name).filter { !$0.isEmpty }
                    Label(vols.isEmpty ? "\(d.model) (no mounted volumes)" : vols.joined(separator: ", "), systemImage: "externaldrive")
                }
            }
            Text("All volumes on \(drives.count == 1 ? "this disk" : "these \(drives.count) disks") are unmounted, then the disks are ejected. "
                 + "Make sure no copy or backup is running.").font(.callout).foregroundStyle(.secondary)
            switch controller.phase {
            case .idle: EmptyView()
            case .working(let t): HStack { ProgressView().controlSize(.small); Text(t) }
            case .done(let t): Label(t, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let t): Label(t, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            case .busy(let t, let hs):
                Label(t, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                HoldersList(holders: hs, emptyText: "macOS reports the volume busy but no process was found (system services or other users' processes may hold it).")
            }
            HStack {
                Spacer()
                Button(isDone ? "Close" : "Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                if !isDone {
                    Button("Eject") { Task { await controller.eject(drives) } }
                        .keyboardShortcut(.defaultAction).disabled(isWorking)
                }
            }
        }
        .padding(20).frame(width: 520)
    }

    private var isDone: Bool { if case .done = controller.phase { true } else { false } }
    private var isWorking: Bool { if case .working = controller.phase { true } else { false } }
}

struct HoldersList: View {
    let holders: [VolumeHolder]
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if holders.isEmpty {
                Text(emptyText).font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(holders) { h in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(VolumeHolders.displayName(h)).font(.body.weight(.medium))
                            Text("PID \(h.pid)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(h.files.count) open file\(h.files.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                        }
                        if let f = h.files.first { Text(f).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                    }
                }
                HStack {
                    Text("Quit these apps, or find the PID in Activity Monitor (View > All Processes).").font(.caption).foregroundStyle(.secondary)
                    Button("Reveal in Activity Monitor") {
                        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                                                           configuration: NSWorkspace.OpenConfiguration())
                    }.controlSize(.small)
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}
