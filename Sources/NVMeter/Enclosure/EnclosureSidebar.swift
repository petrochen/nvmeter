import SwiftUI

/// Sidebar grouped by connection: Internal, one section per enclosure (drives in slot order), Other disks.
struct TopologySidebar: View {
    @Environment(Monitor.self) private var monitor
    @Binding var selection: String?
    let showOthers: Bool
    @State private var collapsed: Set<String> = []

    var body: some View {
        let raidDrives = Set(monitor.raidSets.flatMap(\.memberDrives))
        let layout = EnclosureTopology.build(monitor.drives.filter { !raidDrives.contains($0.bsdName) }, showOthers: showOthers)
        List(selection: $selection) {
            RAIDSidebarSections(sets: monitor.raidSets, drives: monitor.drives)
            if !layout.internalDrives.isEmpty {
                section("Internal", key: "internal") {
                    ForEach(layout.internalDrives) { d in DriveRow(drive: d).tag(d.id) }
                }
            }
            ForEach(layout.enclosures) { e in
                section(e.title, key: e.id) {
                    EnclosureRow(enclosure: e).tag(e.id)
                    ForEach(e.slots) { s in SlotRow(slot: s, enclosure: e).tag(s.drive.id) }
                    Text("Slot order from the PCIe port; it may differ from the labels on the case.")
                        .font(.caption2).foregroundStyle(.tertiary).selectionDisabled()
                }
            }
            if !layout.others.isEmpty {
                section("Other disks (no SMART)", key: "other") {
                    ForEach(layout.others) { d in DriveRow(drive: d).tag(d.id) }
                }
            }
        }
    }

    private func section<C: View>(_ title: String, key: String, @ViewBuilder content: () -> C) -> some View {
        Section(isExpanded: Binding(get: { !collapsed.contains(key) },
                                    set: { if $0 { collapsed.remove(key) } else { collapsed.insert(key) } })) {
            content()
        } header: { Text(title) }
    }
}

struct EnclosureRow: View {
    let enclosure: EnclosureTopology.Enclosure
    var body: some View {
        let total = enclosure.drives.reduce(0.0) { $0 + $1.throughput.readMBps + $1.throughput.writeMBps }
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.connected.to.line.below").font(.title3).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("Enclosure").font(.headline)
                Text("\(enclosure.drives.count) drive\(enclosure.drives.count == 1 ? "" : "s") · \(enclosure.speedText)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(Fmt.rate(total)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }.padding(.vertical, 3)
    }
}

struct SlotRow: View {
    let slot: EnclosureTopology.Slot
    let enclosure: EnclosureTopology.Enclosure
    var body: some View {
        HStack(spacing: 6) {
            Text(slot.number.map { "\($0)" } ?? "?")
                .font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.5)))
                .help(slot.number.map { "Slot \($0) (from the PCIe port)" } ?? "Slot unknown")
            DriveRow(drive: slot.drive)
            if let w = LinkCheck.warning(for: slot, in: enclosure) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(w)
            }
        }
    }
}
