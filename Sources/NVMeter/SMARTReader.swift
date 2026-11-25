import Foundation
import CNVMe

/// Little-endian field access on a raw byte buffer.
struct RawBuffer {
    let bytes: [UInt8]
    func u8(_ o: Int) -> UInt8 { bytes[o] }
    func u16(_ o: Int) -> UInt16 { UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8 }
    func u32(_ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[o + $1]) << (8 * UInt32($1)) } }
    func u64(_ o: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(bytes[o + $1]) << (8 * UInt64($1)) } }
    /// Low 64 bits of a 128-bit NVMe counter (saturates if the high half is non-zero).
    func counter(_ o: Int) -> UInt64 { u64(o + 8) != 0 ? UInt64.max : u64(o) }
    func string(_ o: Int, _ n: Int) -> String {
        let s = String(decoding: bytes[o..<o + n].prefix { $0 != 0 }, as: UTF8.self)
        return s.trimmingCharacters(in: .whitespaces)
    }
}

/// Reads SMART / Identify of one NVMe device.
///
/// The IOCFPlugIn SMART user client is opened for each read and closed right after: macOS allows
/// only one open client per device, so holding it would lock out smartctl, DriveDx and any second
/// NVMeter instance (they get kIOReturnNoResources, 0xe00002be).
final class SMARTReader: @unchecked Sendable {
    private let service: RegEntry
    private(set) var identify: IdentifyInfo?
    /// IOReturn of the last failed `readSMART` (0 when it succeeded).
    private(set) var lastError: Int32 = 0

    /// Returns nil with an error string when the device does not expose the SMART plug-in.
    static func open(service: RegEntry) -> (SMARTReader?, String?) {
        var err: Int32 = 0
        guard let h = nvmeter_open(service.handle, &err) else {
            return (nil, String(format: "SMART plug-in unavailable (0x%08x)", UInt32(bitPattern: err)))
        }
        nvmeter_close(h)
        let r = SMARTReader(service: service)
        r.identify = r.readIdentify()
        return (r, nil)
    }

    private init(service: RegEntry) { self.service = service }

    /// Opens the user client, runs `body`, closes it. Returns the IOReturn of the open on failure.
    private func withHandle<T>(_ body: (OpaquePointer) -> T) -> (T?, Int32) {
        var err: Int32 = 0
        guard let h = nvmeter_open(service.handle, &err) else { return (nil, err) }
        defer { nvmeter_close(h) }
        return (body(h), 0)
    }

    private func readIdentify() -> IdentifyInfo? {
        var buf = [UInt8](repeating: 0, count: 4096)
        let (res, _) = withHandle { h in buf.withUnsafeMutableBufferPointer { nvmeter_read_identify(h, $0.baseAddress) } }
        guard let kr = res, kr == 0 else { return nil }
        let r = RawBuffer(bytes: buf)
        // Identify Controller: WCTEMP @266, CCTEMP @268 (Kelvin), VER @80, NN @516.
        func celsius(_ k: UInt16) -> Int? { k == 0 ? nil : Int(k) - 273 }
        let ver = r.u32(80)
        let verStr = ver == 0 ? nil : "\(ver >> 16).\((ver >> 8) & 0xFF)" + ((ver & 0xFF) != 0 ? ".\(ver & 0xFF)" : "")
        return IdentifyInfo(
            model: r.string(24, 40), serial: r.string(4, 20), firmware: r.string(64, 8),
            warningTempC: celsius(r.u16(266)), criticalTempC: celsius(r.u16(268)),
            nvmeVersion: verStr, pciVendorID: r.u16(0), subsystemVendorID: r.u16(2), namespaces: r.u32(516))
    }

    /// Reads the SMART / Health log page. Read-only.
    func readSMART() -> SMARTSnapshot? {
        var buf = [UInt8](repeating: 0, count: 512)
        let (res, openErr) = withHandle { h in buf.withUnsafeMutableBufferPointer { nvmeter_read_smart(h, $0.baseAddress) } }
        let kr = res ?? openErr
        lastError = kr
        guard kr == 0 else { return nil }
        let r = RawBuffer(bytes: buf)
        // NVMe base spec, Figure "SMART / Health Information Log".
        let composite = r.u16(1)
        var sensors: [Int] = []
        for i in 0..<8 {
            let k = r.u16(200 + 2 * i)
            if k != 0 { sensors.append(Int(k) - 273) }
        }
        return SMARTSnapshot(
            criticalWarning: r.u8(0),
            temperatureC: Int(composite) - 273,
            sensorsC: sensors,
            availableSparePct: Int(r.u8(3)),
            availableSpareThresholdPct: Int(r.u8(4)),
            percentageUsed: Int(r.u8(5)),
            dataUnitsRead: r.counter(32),
            dataUnitsWritten: r.counter(48),
            bytesRead: r.counter(32) &* 512_000,
            bytesWritten: r.counter(48) &* 512_000,
            hostReadCommands: r.counter(64),
            hostWriteCommands: r.counter(80),
            controllerBusyMinutes: r.counter(96),
            powerCycles: r.counter(112),
            powerOnHours: r.counter(128),
            unsafeShutdowns: r.counter(144),
            mediaErrors: r.counter(160),
            errorLogEntries: r.counter(176),
            warningTempMinutes: r.u32(192),
            criticalTempMinutes: r.u32(196))
    }
}
