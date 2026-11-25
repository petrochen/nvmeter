import Foundation

extension DriveSnapshot {
    /// Temperature for graphs and alerts: NVMe composite or the ATA temperature attribute.
    var temperatureC: Int? { smart?.temperatureC ?? ata?.temperatureC }
    var isATA: Bool { ata != nil }
}

/// Everything the ATA / RAID / self-test features need on top of `Sampler`, kept out of Sampler.swift.
/// Not thread safe: called from `Sampler.tick` only.
final class SamplerExtras: @unchecked Sendable {
    private var ata: [UInt64: ATASnapshot] = [:]
    private var ataBaseline: [UInt64: [Int: UInt64]] = [:]
    private var ataLast: [UInt64: TimeInterval] = [:]
    private var selfTests: [UInt64: NVMeSelfTestLog] = [:]
    private var selfTestLast: [UInt64: TimeInterval] = [:]
    private var lastRAID: TimeInterval = -.infinity
    private(set) var raidSets: [RAIDSetInfo] = []

    static let selfTestInterval: TimeInterval = 600
    static let raidInterval: TimeInterval = 5

    func update(devices: [DriveDevice], now: TimeInterval) {
        for d in devices {
            if let r = d.ata, now - (ataLast[d.key] ?? -.infinity) >= ATAPolicy.pollInterval {
                let (cur, max) = d.device.powerStates()
                let rotational = r.identity?.isRotational ?? false
                if ATAPolicy.shouldPoll(rotational: rotational, dontWake: ATAPolicy.dontWake, powerState: cur, maxPowerState: max) {
                    ataLast[d.key] = now
                    if let s = r.read() {
                        ata[d.key] = s
                        if ataBaseline[d.key] == nil { ataBaseline[d.key] = ATAHealth.baseline(s) }
                    }
                } else if ata[d.key] != nil {
                    ata[d.key]!.standby = true
                } else if let id = r.identity {
                    // Asleep before the first read: show identity only, without touching the drive.
                    ata[d.key] = ATASnapshot(identity: id, overallPassed: nil, attributes: [], temperatureC: nil,
                                             powerOnHours: nil, standby: true)
                }
            }
            if let r = d.reader, now - (selfTestLast[d.key] ?? -.infinity) >= Self.selfTestInterval {
                selfTestLast[d.key] = now
                if let log = r.readSelfTestLog() { selfTests[d.key] = log }
            }
        }
        let live = Set(devices.map(\.key))
        for k in ata.keys where !live.contains(k) { ata[k] = nil; ataBaseline[k] = nil; ataLast[k] = nil }
        for k in selfTests.keys where !live.contains(k) { selfTests[k] = nil; selfTestLast[k] = nil }
        if now - lastRAID >= Self.raidInterval { lastRAID = now; raidSets = RAIDScanner.scan() }
    }

    func annotate(_ snaps: [DriveSnapshot], devices: [UInt64: DriveDevice]) -> [DriveSnapshot] {
        let byBSD = Dictionary(uniqueKeysWithValues: devices.values.map { ($0.bsdName, $0) })
        return snaps.map { var s = $0
            guard let d = byBSD[s.bsdName] else { return s }
            if let a = ata[d.key] {
                s.ata = a
                s.smartCapable = true; s.smartError = nil
                s.warnings.removeAll { $0.hasPrefix("SMART unavailable") }
                if a.standby { s.warnings.append("Drive is in standby: SMART values are the last known ones (not polled, to avoid waking it)") }
                let (h, rows) = ATAHealth.evaluate(a, baseline: ataBaseline[d.key])
                s.health = a.attributes.isEmpty ? .unknown : h
                s.attributes = rows
                if s.model.isEmpty || s.model == "Unknown disk" { s.model = a.identity.model }
                if s.firmware.isEmpty { s.firmware = a.identity.firmware }
                if s.capacityBytes == 0 { s.capacityBytes = a.identity.capacityBytes }
            }
            s.selfTest = selfTests[d.key]
            if let set = raidSets.first(where: { $0.memberDrives.contains(s.bsdName) }) { s.raidSetID = set.id }
            return s
        }
    }
}
