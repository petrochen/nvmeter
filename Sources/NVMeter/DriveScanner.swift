import Foundation
import IOKit
import DiskArbitration

/// One physical disk found in the IORegistry. Everything here is read-only.
final class DriveDevice: @unchecked Sendable {
    let key: UInt64                  // registry entry id of the IOBlockStorageDevice
    let device: RegEntry             // IONVMeBlockStorageDevice / IOBlockStorageServices / ...
    let driver: RegEntry             // IOBlockStorageDriver (holds "Statistics")
    let media: RegEntry              // whole-disk IOMedia
    let bsdName: String
    let model: String
    var serial: String
    let firmware: String
    let capacity: UInt64
    let interconnect: String
    let location: String
    let smartCapable: Bool
    var reader: SMARTReader?
    var ata: ATAReader?
    var smartError: String?

    // Refreshed periodically.
    var link: PCIeLink?
    var connection: ConnectionInfo
    var volumes: [VolumeInfo] = []
    var unmounted: [VolumeInfo] = []

    init(key: UInt64, device: RegEntry, driver: RegEntry, media: RegEntry, bsdName: String, model: String, serial: String,
         firmware: String, capacity: UInt64, interconnect: String, location: String, smartCapable: Bool) {
        self.key = key; self.device = device; self.driver = driver; self.media = media
        self.bsdName = bsdName; self.model = model; self.serial = serial; self.firmware = firmware
        self.capacity = capacity; self.interconnect = interconnect; self.location = location
        self.smartCapable = smartCapable
        self.connection = ConnectionInfo(kind: "other", summary: interconnect)
    }

    private lazy var registryPath: String = DriveKey.registryPath(device)

    /// Stable per physical drive: Identify model + serial, or the IORegistry path for drives without SMART / behind a bridge.
    var stableID: String {
        // Uses registry values only (not the SMART plug-in), so a transient SMART failure cannot change the key.
        let real = smartCapable && VendorCatalog.bridgeChip(model: model) == nil
        return DriveKey.make(model: model, serial: serial, registryPath: registryPath, smartCapable: real)
    }

    func counters() -> IOCounters? {
        guard let s = driver.dict("Statistics") else { return nil }
        func n(_ k: String) -> UInt64 { (s[k] as? NSNumber)?.uint64Value ?? 0 }
        return IOCounters(bytesRead: n("Bytes (Read)"), bytesWritten: n("Bytes (Write)"),
                          opsRead: n("Operations (Read)"), opsWritten: n("Operations (Write)"))
    }
}

/// Finds physical disks (never virtual / disk-image devices) and resolves their link, enclosure and volumes.
final class DriveScanner: @unchecked Sendable {
    private(set) var devices: [UInt64: DriveDevice] = [:]
    private let daSession = DASessionCreate(kCFAllocatorDefault)

    /// Light scan: detects appearing / disappearing disks. Returns true when the set changed.
    @discardableResult
    func scan() -> Bool {
        var seen = Set<UInt64>()
        var changed = false
        for driver in RegEntry.services(matchingClass: "IOBlockStorageDriver") {
            guard let dev = driver.parent() else { continue }
            let key = dev.entryID
            seen.insert(key)
            if devices[key] != nil { continue }
            if let d = makeDevice(key: key, device: dev, driver: driver) {
                devices[key] = d
                refresh(d)
                changed = true
            } else {
                seen.remove(key)
            }
        }
        for k in devices.keys where !seen.contains(k) {
            devices.removeValue(forKey: k)
            changed = true
        }
        return changed
    }

    private func makeDevice(key: UInt64, device: RegEntry, driver: RegEntry) -> DriveDevice? {
        let proto = device.dict("Protocol Characteristics") ?? [:]
        let interconnect = (proto["Physical Interconnect"] as? String) ?? "Unknown"
        let location = (proto["Physical Interconnect Location"] as? String) ?? ""
        if interconnect == "Virtual Interface" || location == "File" { return nil }          // disk images
        let chars = device.dict("Device Characteristics") ?? [:]
        // Whole-disk media below the driver.
        guard let media = driver.children().first(where: { $0.conforms("IOMedia") && $0.bool("Whole") == true }),
              let bsd = media.string("BSD Name") else { return nil }
        if media.bool("Removable") == true && (media.uint64("Size") ?? 0) == 0 { return nil }
        let smartCapable = device.bool("NVMe SMART Capable") == true
        var serial = ((chars["Serial Number"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        if serial.isEmpty, let usb = device.ancestors().first(where: { $0.conforms("IOUSBHostDevice") }) {
            serial = usb.string("USB Serial Number") ?? ""
        }
        let d = DriveDevice(
            key: key, device: device, driver: driver, media: media, bsdName: bsd,
            model: ((chars["Product Name"] as? String) ?? "Unknown disk").trimmingCharacters(in: .whitespaces),
            serial: serial,
            firmware: ((chars["Product Revision Level"] as? String) ?? "").trimmingCharacters(in: .whitespaces),
            capacity: media.uint64("Size") ?? 0, interconnect: interconnect, location: location,
            smartCapable: smartCapable)
        if smartCapable {
            let (r, err) = SMARTReader.open(service: device)
            d.reader = r
            d.smartError = err
            if let id = r?.identify {
                if d.serial.isEmpty { d.serial = id.serial }
            }
        } else if device.bool("SMART Capable") == true {
            let (a, err) = ATAReader.open(service: device)
            d.ata = a
            d.smartError = err
            if let id = a?.identity, d.serial.isEmpty { d.serial = id.serial }
        } else {
            d.smartError = "No NVMe SMART interface exposed by macOS for this device"
        }
        return d
    }

    /// Re-reads link, enclosure and volume information (cheap, a few registry reads + DiskArbitration).
    func refresh(_ d: DriveDevice) {
        let ancestors = d.device.ancestors()
        d.link = Self.pcieLink(ancestors: ancestors)
        d.connection = Self.connection(for: d, ancestors: ancestors)
        (d.volumes, d.unmounted) = volumes(for: d)
    }

    // MARK: PCIe link

    static func pcieLink(ancestors: [RegEntry]) -> PCIeLink? {
        guard let pci = ancestors.first(where: { $0.property("IOPCIExpressLinkStatus") != nil }),
              let status = pci.int("IOPCIExpressLinkStatus") else { return nil }
        let cap = pci.int("IOPCIExpressLinkCapabilities") ?? 0
        let gts: [Int: Double] = [1: 2.5, 2: 5, 3: 8, 4: 16, 5: 32, 6: 64]
        let perLane: [Int: Double] = [1: 250, 2: 500, 3: 984.6, 4: 1969.2, 5: 3938.5, 6: 7563]
        let gen = status & 0xF, width = (status >> 4) & 0x3F
        let maxGen = cap & 0xF, maxWidth = (cap >> 4) & 0x3F
        guard gen > 0, width > 0 else { return nil }
        return PCIeLink(
            currentGen: gen, currentGTs: gts[gen] ?? 0, currentWidth: width,
            maxGen: maxGen, maxGTs: gts[maxGen] ?? 0, maxWidth: maxWidth,
            tunnelled: pci.bool("IOPCITunnelled") ?? false,
            bandwidthMBps: (perLane[gen] ?? 0) * Double(width))
    }

    // MARK: Enclosure / connection

    static func connection(for d: DriveDevice, ancestors: [RegEntry]) -> ConnectionInfo {
        if d.interconnect == "Apple Fabric" {
            return ConnectionInfo(kind: "internal", summary: "internal Apple SSD controller")
        }
        // Thunderbolt / USB4: a bridge above the NVMe device carries the "Thunderbolt Entry ID" of the PCIe adapter port.
        if let tbID = ancestors.compactMap({ $0.uint64("Thunderbolt Entry ID") }).first,
           let port = RegEntry.entry(withID: tbID) {
            var sw: RegEntry? = port
            var hops = 0
            while let s = sw, !s.className.hasPrefix("IOThunderboltSwitch"), hops < 6 { sw = s.parent(); hops += 1 }
            if let s = sw, s.className.hasPrefix("IOThunderboltSwitch") {
                var info = thunderbolt(switch: s)
                EnclosureTopology.annotate(&info, switch: s, ancestors: ancestors)
                return info
            }
            return ConnectionInfo(kind: "thunderbolt", summary: "Thunderbolt / USB4")
        }
        if d.interconnect == "USB", let usb = ancestors.first(where: { $0.conforms("IOUSBHostDevice") }) {
            let bps = (usb.property("UsbLinkSpeed") as? NSNumber)?.doubleValue ?? 0
            let gbps = bps / 1e9
            let name = usb.string("USB Product Name") ?? usb.string("kUSBProductString")
            let vendor = usb.string("USB Vendor Name") ?? usb.string("kUSBVendorString")
            let speed = gbps > 0 ? " \(fmtGbps(gbps)) Gb/s" : ""
            let enc = [vendor, name].compactMap { $0 }.joined(separator: " ")
            var info = ConnectionInfo(kind: "usb", summary: "USB\(speed)" + (enc.isEmpty ? "" : ", \(enc)"),
                                      enclosureVendor: vendor, enclosureModel: name, mode: "USB", linkGbps: gbps > 0 ? gbps : nil)
            EnclosureTopology.annotate(&info, usb: usb)
            return info
        }
        if d.interconnect == "PCI-Express" {
            return ConnectionInfo(kind: "pcie", summary: "PCIe (\(d.location.lowercased()))")
        }
        return ConnectionInfo(kind: "other", summary: d.interconnect)
    }

    private static func thunderbolt(switch s: RegEntry) -> ConnectionInfo {
        let vendor = s.string("Device Vendor Name")
        let model = s.string("Device Model Name")
        let mode = s.className.contains("USB4") ? "USB4" : "Thunderbolt"
        // Link speed: lane adapter of the enclosure's upstream port. Codes follow the USB4 spec:
        // 0x2 = 40 Gb/s per lane (Gen 4), 0x4 = 20 (Gen 3), 0x8 = 10 (Gen 2).
        var gbps: Double?
        for p in s.children() {
            guard let code = p.int("Current Link Speed"), let width = p.int("Current Link Width"), width > 0 else { continue }
            let perLane: Double? = [2: 40, 4: 20, 8: 10][code]
            if let l = perLane { gbps = max(gbps ?? 0, l * Double(min(width, 2))) }
        }
        var fw: String?
        if let rom = s.int("ROM Version"), let ee = s.int("EEPROM Revision") { fw = String(format: "%x.%x", rom, ee) }
        let enc = [vendor, model].compactMap { $0 }.joined(separator: " ")
        let speed = gbps.map { " \(fmtGbps($0)) Gb/s" } ?? ""
        return ConnectionInfo(kind: "thunderbolt", summary: "\(mode)\(speed)" + (enc.isEmpty ? "" : ", \(enc)"),
                              enclosureVendor: vendor, enclosureModel: model, mode: mode, linkGbps: gbps, firmware: fw)
    }

    private static func fmtGbps(_ g: Double) -> String { g == g.rounded() ? String(Int(g)) : String(format: "%.1f", g) }

    // MARK: Volumes

    private static let hiddenMounts = ["/System/Volumes/VM", "/System/Volumes/Preboot", "/System/Volumes/Update",
                                       "/System/Volumes/xarts", "/System/Volumes/iSCPreboot", "/System/Volumes/Hardware"]

    /// Volumes live below the whole-disk media. For APFS the container disk is a descendant of the physical store
    /// ("APFS Physical Store" diskNs2 -> AppleAPFSContainerScheme -> synthesized diskM), so one traversal covers both.
    /// Mounted volumes, and (external drives only) volumes with a file system that are not mounted.
    func volumes(for d: DriveDevice) -> (mounted: [VolumeInfo], unmounted: [VolumeInfo]) {
        guard let session = daSession else { return ([], []) }
        var out: [VolumeInfo] = [], idle: [VolumeInfo] = []
        var seen = Set<String>()
        for m in d.media.descendants(maxDepth: 8) where m.conforms("IOMedia") {
            guard let bsd = m.string("BSD Name"), !seen.contains(bsd),
                  let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd),
                  let desc = DADiskCopyDescription(disk) as? [String: Any] else { continue }
            guard let url = desc[kDADiskDescriptionVolumePathKey as String] as? URL else {
                let name = (desc[kDADiskDescriptionVolumeNameKey as String] as? String) ?? ""
                if d.connection.kind != "internal", desc[kDADiskDescriptionVolumeMountableKey as String] as? Bool == true,
                   let kind = desc[kDADiskDescriptionVolumeKindKey as String] as? String,
                   !Self.systemVolumeNames.contains(name) {
                    seen.insert(bsd)
                    idle.append(VolumeInfo(name: name.isEmpty ? bsd : name, bsdName: bsd, mountPoint: "", fileSystem: kind,
                                           sizeBytes: (desc[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.uint64Value ?? 0, freeBytes: 0))
                }
                continue
            }
            seen.insert(bsd)
            let path = url.path
            if Self.hiddenMounts.contains(path) { continue }
            let rv = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                                      .volumeAvailableCapacityKey, .volumeIsReadOnlyKey])
            let total = UInt64(rv?.volumeTotalCapacity ?? 0)
            let free = UInt64(max(0, rv?.volumeAvailableCapacityForImportantUsage ?? Int64(rv?.volumeAvailableCapacity ?? 0)))
            out.append(VolumeInfo(
                name: (desc[kDADiskDescriptionVolumeNameKey as String] as? String) ?? url.lastPathComponent,
                bsdName: bsd, mountPoint: path,
                fileSystem: desc[kDADiskDescriptionVolumeKindKey as String] as? String,
                sizeBytes: total, freeBytes: free, readOnly: rv?.volumeIsReadOnly ?? false))
        }
        // The sealed system volume "/" and its Data volume share one container: show only "/" (e.g. Macintosh HD).
        if out.contains(where: { $0.mountPoint == "/" }) { out.removeAll { $0.mountPoint == "/System/Volumes/Data" } }
        let order = { (a: VolumeInfo, b: VolumeInfo) in a.bsdName.localizedStandardCompare(b.bsdName) == .orderedAscending }
        return (out.sorted(by: order), idle.sorted(by: order))
    }

    /// APFS helper volumes and the EFI partition: mountable, but never something to offer.
    private static let systemVolumeNames: Set<String> = ["EFI", "Recovery", "Preboot", "VM", "Update", "Hardware", "xART", "iSCPreboot"]
}
