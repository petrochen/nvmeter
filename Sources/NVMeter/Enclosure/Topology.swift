import Foundation
import IOKit

extension RegEntry {
    /// Registry name / location in the service plane ("pci-bridge" / "2").
    var registryName: String {
        var buf = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetNameInPlane(handle, kIOServicePlane, &buf)
        return String(cString: buf)
    }
    var registryLocation: String? {
        var buf = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetLocationInPlane(handle, kIOServicePlane, &buf) == KERN_SUCCESS else { return nil }
        return String(cString: buf)
    }
}

/// Groups disks by how they are attached: internal, per enclosure (with slot order) and "other disks".
enum EnclosureTopology {
    static let selectionPrefix = "enc:"

    // MARK: Registry annotation (called from DriveScanner.connection)

    static func annotate(_ info: inout ConnectionInfo, switch s: RegEntry, ancestors: [RegEntry]) {
        info.enclosureID = s.entryID
        info.slotPort = downstreamPort(ancestors: ancestors)
        // The Mac-side receptacle is a "Socket ID" on the host switch port the enclosure hangs off.
        if let sock = s.ancestors().lazy.compactMap({ $0.string("Socket ID") }).first { info.hostPort = "Port \(sock)" }
    }

    static func annotate(_ info: inout ConnectionInfo, usb: RegEntry) {
        info.enclosureID = usb.entryID
        // locationID = 0xBBPPPPPP: bus byte, then one nibble per hub tier (first = root port).
        if let loc = usb.uint64("locationID") {
            let bus = (loc >> 24) & 0xFF, port = (loc >> 20) & 0xF
            info.hostPort = "USB bus \(bus), port \(port)"
        }
    }

    /// The PCIe downstream port a drive sits behind: the first IOPCIDevice above the NVMe function
    /// (the ASMedia-style switch in a multi-bay enclosure exposes one per slot, `pci-bridge@0..3`).
    static func downstreamPort(ancestors: [RegEntry]) -> Int? {
        guard let fn = ancestors.firstIndex(where: { $0.property("IOPCIExpressLinkStatus") != nil }) else { return nil }
        for a in ancestors[(fn + 1)...] where a.conforms("IOPCIDevice") {
            guard let loc = a.registryLocation else { return nil }
            return Int(loc.split(separator: ",").first ?? "", radix: 16)
        }
        return nil
    }

    // MARK: Selection ids

    static func selectionID(for d: DriveSnapshot) -> String { selectionPrefix + String(d.connection.enclosureID ?? 0) }

    static func isValidSelection(_ sel: String?, drives: [DriveSnapshot]) -> Bool {
        guard let sel else { return false }
        if sel.hasPrefix(selectionPrefix) { return drives.contains { $0.connection.enclosureID != nil && selectionID(for: $0) == sel } }
        return drives.contains { $0.id == sel }
    }

    // MARK: Model

    struct Slot: Identifiable {
        var id: String { drive.id }
        let number: Int?            // 1-based, nil when no PCIe port could be derived
        let drive: DriveSnapshot
    }

    struct Enclosure: Identifiable {
        let id: String              // selection id
        let name: String
        let vendor: String?
        let mode: String            // "USB4", "Thunderbolt", "USB"
        let linkGbps: Double?
        let firmware: String?
        let hostPort: String?
        let slots: [Slot]
        var drives: [DriveSnapshot] { slots.map(\.drive) }

        /// "USB4 40 Gb/s"
        var speedText: String {
            guard let g = linkGbps else { return mode }
            let n = g == g.rounded() ? String(Int(g)) : String(format: "%.1f", g)
            return mode == "USB" ? "USB \(n) Gb/s" : "\(mode) \(n) Gb/s"
        }
        /// "OWC Express 4M2 · USB4 40 Gb/s · Port 3"
        var title: String { [name, speedText, hostPort].compactMap { $0 }.joined(separator: " · ") }
        var budgetMBps: Double { EnclosureTopology.budgetMBps(mode: mode, gbps: linkGbps) }
    }

    struct Layout {
        var internalDrives: [DriveSnapshot] = []
        var enclosures: [Enclosure] = []
        var others: [DriveSnapshot] = []
    }

    /// Usable payload per direction in MB/s (decimal). Assumption, not measured: link rate x ~0.95 for USB4 /
    /// Thunderbolt (40 Gb/s -> 3.8 GB/s, 80 Gb/s -> 7.6 GB/s; real PCIe tunnels often top out lower, ~3 GB/s),
    /// USB 10 Gb/s -> ~1 GB/s, USB 20 Gb/s -> ~2 GB/s, USB 5 Gb/s -> ~450 MB/s.
    static func budgetMBps(mode: String?, gbps: Double?) -> Double {
        guard let g = gbps else { return 0 }
        if mode == "USB" { return g >= 20 ? 2000 : (g >= 10 ? 1000 : 450) }
        return g * 95
    }

    static func build(_ drives: [DriveSnapshot], showOthers: Bool) -> Layout {
        var out = Layout()
        var groups: [UInt64: [DriveSnapshot]] = [:]
        for d in drives {
            if d.isUSBOther { if showOthers { out.others.append(d) } }
            else if let e = d.connection.enclosureID { groups[e, default: []].append(d) }
            else { out.internalDrives.append(d) }
        }
        for (eid, ds) in groups {
            let c = ds[0].connection
            let sorted = ds.sorted {
                ($0.connection.slotPort ?? 99, $0.bsdName) < ($1.connection.slotPort ?? 99, $1.bsdName)
            }
            let ports = sorted.compactMap(\.connection.slotPort)
            // Port numbers are used as-is (@0 -> Slot 1); if the switch uses large device numbers, fall back to rank.
            let direct = (ports.max() ?? 0) < 8
            var rank = 0
            let slots: [Slot] = sorted.map { d in
                rank += 1
                let n = d.connection.slotPort.map { direct ? $0 + 1 : rank } 
                return Slot(number: n, drive: d)
            }
            let name = [c.enclosureVendor, c.enclosureModel].compactMap { $0 }.joined(separator: " ")
            out.enclosures.append(Enclosure(
                id: selectionPrefix + String(eid), name: name.isEmpty ? "Disk enclosure" : name, vendor: c.enclosureVendor,
                mode: c.mode ?? "Thunderbolt", linkGbps: c.linkGbps, firmware: c.firmware, hostPort: c.hostPort, slots: slots))
        }
        out.enclosures.sort { $0.title < $1.title }
        return out
    }
}
