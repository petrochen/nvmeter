import SwiftUI

/// Volumes of a drive with mount state, Unmount / Mount / read-only controls and "Always mount read-only".
struct VolumesCard: View {
    let drive: DriveSnapshot
    @State private var mounts = MountController.shared

    private var external: Bool { drive.connection.kind != "internal" }
    private var always: Bool { mounts.alwaysReadOnly.contains(drive.id) }

    var body: some View {
        Card("Volumes") {
            if drive.volumes.isEmpty && drive.unmountedVolumes.isEmpty { Text("No volumes").foregroundStyle(.secondary) }
            ForEach(drive.volumes) { v in row(v, mounted: true) }
            ForEach(drive.unmountedVolumes) { v in row(v, mounted: false) }
            if external && !(drive.volumes.isEmpty && drive.unmountedVolumes.isEmpty) {
                Divider()
                Toggle(isOn: Binding(get: { always }, set: { mounts.setAlwaysReadOnly($0, for: drive) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Always mount read-only")
                        Text("NVMeter remounts this drive's volumes read-only whenever they are mounted: nothing (Spotlight, Finder, apps) can write to them. Works while NVMeter runs.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.toggleStyle(.switch)
            }
        }
    }

    @ViewBuilder private func row(_ v: VolumeInfo, mounted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: mounted ? "internaldrive.fill" : "internaldrive").foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    HStack(spacing: 6) {
                        Text(v.name).font(.body.weight(.medium))
                        badge(v, mounted: mounted)
                    }
                    Text(mounted ? "\(v.mountPoint) · \(v.fileSystem ?? "?")" : "\(v.bsdName) · \(v.fileSystem ?? "?") · not mounted")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if mounted {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(Fmt.capacity(v.freeBytes)) free of \(Fmt.capacity(v.sizeBytes))").font(.caption.monospacedDigit())
                        ProgressView(value: v.sizeBytes == 0 ? 0 : Double(v.sizeBytes - min(v.freeBytes, v.sizeBytes)) / Double(v.sizeBytes))
                            .frame(width: 160)
                    }
                } else if v.sizeBytes > 0 {
                    Text(Fmt.capacity(v.sizeBytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if external, MountController.canManage(drive, v) { controls(v, mounted: mounted) }
            if let s = mounts.status[v.bsdName] {
                Label(s.message, systemImage: s.isError ? "exclamationmark.triangle.fill" : "hourglass")
                    .font(.caption).foregroundStyle(s.isError ? .orange : .secondary)
                if !s.holders.isEmpty { HoldersList(holders: s.holders, emptyText: "") }
            }
        }
    }

    @ViewBuilder private func badge(_ v: VolumeInfo, mounted: Bool) -> some View {
        if mounted {
            Text(v.readOnly ? "READ-ONLY" : "READ-WRITE")
                .font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                .foregroundStyle(v.readOnly ? Color.blue : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 4).stroke(v.readOnly ? Color.blue : Color.secondary.opacity(0.5)))
        }
    }

    @ViewBuilder private func controls(_ v: VolumeInfo, mounted: Bool) -> some View {
        let busy = mounts.working.contains(v.bsdName)
        HStack(spacing: 8) {
            if mounted {
                Button("Unmount") { Task { await mounts.unmount(v) } }
                    .help("Unmounts this volume only. The drive stays connected and powered, so SMART and temperature stay visible.")
                if v.readOnly {
                    Button("Remount read-write") { Task { await mounts.remount(v, readOnly: false) } }
                        .disabled(always).help(always ? "Turn off Always mount read-only first." : "Unmounts and mounts the volume writable again.")
                } else {
                    Button("Remount read-only") { Task { await mounts.remount(v, readOnly: true) } }
                        .help("Unmounts and mounts the volume read-only. Fails while an app has files open on it.")
                }
            } else {
                Button("Mount") { Task { await mounts.mount(v, readOnly: always) } }
                if !always { Button("Mount read-only") { Task { await mounts.mount(v, readOnly: true) } } }
            }
            if busy { ProgressView().controlSize(.small) }
        }
        .controlSize(.small).disabled(busy)
    }
}
