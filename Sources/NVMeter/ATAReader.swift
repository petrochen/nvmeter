import Foundation
import CNVMe

/// Reads the IOATASMARTInterface of one SATA / PATA drive. Read-only (no SMART enable, no self-test).
/// The plug-in is exclusive per client, so every read opens it, reads and closes it again.
final class ATAReader: @unchecked Sendable {
    private let service: RegEntry
    private(set) var identity: ATAIdentity?
    private var thresholds: [UInt8]?
    private(set) var lastError: Int32 = 0

    init(service: RegEntry) { self.service = service }

    static func open(service: RegEntry) -> (ATAReader?, String?) {
        var err: Int32 = 0
        guard let h = nvmeter_ata_open(service.handle, &err) else {
            return (nil, String(format: "ATA SMART plug-in unavailable (0x%08x)", UInt32(bitPattern: err)))
        }
        defer { nvmeter_ata_close(h) }
        let r = ATAReader(service: service)
        var buf = [UInt8](repeating: 0, count: 512)
        if buf.withUnsafeMutableBufferPointer({ nvmeter_ata_identify(h, $0.baseAddress) }) == 0 {
            r.identity = ATAParser.identity(buf)
        }
        return (r, nil)
    }

    func read() -> ATASnapshot? {
        guard let id = identity else { return nil }
        var err: Int32 = 0
        guard let h = nvmeter_ata_open(service.handle, &err) else { lastError = err; return nil }
        defer { nvmeter_ata_close(h) }
        var data = [UInt8](repeating: 0, count: 512)
        let kr = data.withUnsafeMutableBufferPointer { nvmeter_ata_read_data(h, $0.baseAddress) }
        lastError = kr
        guard kr == 0 else { return nil }
        if thresholds == nil {
            var t = [UInt8](repeating: 0, count: 512)
            if t.withUnsafeMutableBufferPointer({ nvmeter_ata_read_thresholds(h, $0.baseAddress) }) == 0 { thresholds = t }
        }
        var exceeded: Int32 = 0
        let sk = nvmeter_ata_return_status(h, &exceeded)
        let attrs = ATAParser.attributes(data: data, thresholds: thresholds)
        return ATASnapshot(identity: id, overallPassed: sk == 0 ? exceeded == 0 : nil, attributes: attrs,
                           temperatureC: ATAParser.temperature(attrs), powerOnHours: ATAParser.powerOnHours(attrs))
    }
}

extension RegEntry {
    /// (CurrentPowerState, MaxPowerState) from the nearest IOPowerManagement dictionary at or above this entry.
    func powerStates(maxLevels: Int = 3) -> (current: Int?, max: Int?) {
        var cur: RegEntry? = self
        var n = 0
        while let e = cur, n < maxLevels {
            if let pm = e.dict("IOPowerManagement"), let c = (pm["CurrentPowerState"] as? NSNumber)?.intValue {
                return (c, (pm["MaxPowerState"] as? NSNumber)?.intValue)
            }
            cur = e.parent(); n += 1
        }
        return (nil, nil)
    }
}
