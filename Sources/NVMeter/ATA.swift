import Foundation

// MARK: - Model (pure data, Codable)

struct ATAAttribute: Codable, Equatable, Sendable, Identifiable {
    var id: Int
    var name: String
    var flags: UInt16
    var value: Int
    var worst: Int
    /// 0 when the drive does not report thresholds.
    var threshold: Int
    var raw: UInt64
    var rawText: String
    /// Value at or below a non-zero threshold: the drive considers this attribute failed.
    var failingNow: Bool { threshold > 0 && value <= threshold }
}

struct ATAIdentity: Codable, Equatable, Sendable {
    var model: String
    var serial: String
    var firmware: String
    var capacityBytes: UInt64
    /// nil = not reported, 1 = non-rotating (SSD), otherwise RPM.
    var rotationRPM: Int?
    var isSSD: Bool { rotationRPM == 1 }
    var isRotational: Bool { (rotationRPM ?? 0) > 1 }
    var kind: String { isSSD ? "SSD" : (isRotational ? "HDD \(rotationRPM!) rpm" : "ATA drive") }
}

struct ATASnapshot: Codable, Equatable, Sendable {
    var identity: ATAIdentity
    /// SMART RETURN STATUS: false = threshold exceeded ("SMART FAILING"), nil = status could not be read.
    var overallPassed: Bool?
    var attributes: [ATAAttribute]
    var temperatureC: Int?
    var powerOnHours: UInt64?
    /// True when this snapshot was not read now because the drive is spun down (values are the last known ones).
    var standby: Bool = false

    func attribute(_ id: Int) -> ATAAttribute? { attributes.first { $0.id == id } }
}

// MARK: - Parsers

enum ATAParser {
    /// ATA strings are stored two characters per 16-bit word, first character in the high byte.
    /// `bytes` is the native-endian (little endian on every Mac) IDENTIFY buffer.
    static func ataString(_ bytes: [UInt8], word: Int, words: Int) -> String {
        var out: [UInt8] = []
        for w in word..<word + words {
            let lo = bytes[2 * w], hi = bytes[2 * w + 1]
            out.append(hi); out.append(lo)
        }
        let s = String(decoding: out.map { $0 == 0 ? 0x20 : $0 }, as: UTF8.self)
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func word(_ b: [UInt8], _ w: Int) -> UInt16 { UInt16(b[2 * w]) | UInt16(b[2 * w + 1]) << 8 }

    /// IDENTIFY DEVICE (ATA8-ACS): serial words 10-19, firmware 23-26, model 27-46, LBA28 count 60-61,
    /// LBA48 count 100-103, logical sector size 117-118 (valid when word 106 bit 14 set, bit 15 clear, bit 12 set),
    /// nominal media rotation rate word 217.
    static func identity(_ b: [UInt8]) -> ATAIdentity? {
        guard b.count >= 512 else { return nil }
        let w106 = word(b, 106)
        var sector: UInt64 = 512
        if w106 & 0xC000 == 0x4000, w106 & 0x1000 != 0 {
            let words = UInt64(word(b, 117)) | UInt64(word(b, 118)) << 16
            if words >= 256 { sector = words * 2 }
        }
        let lba48 = (0..<4).reduce(UInt64(0)) { $0 | UInt64(word(b, 100 + $1)) << (16 * UInt64($1)) }
        let lba28 = UInt64(word(b, 60)) | UInt64(word(b, 61)) << 16
        let sectors = lba48 != 0 ? lba48 : lba28
        let rpmWord = Int(word(b, 217))
        // 0 / 0xFFFF = not reported, 1 = non-rotating, 0x0401...0xFFFE = RPM.
        let rpm: Int? = (rpmWord == 0 || rpmWord == 0xFFFF) ? nil : (rpmWord == 1 || rpmWord >= 0x0401 ? rpmWord : nil)
        return ATAIdentity(model: ataString(b, word: 27, words: 20), serial: ataString(b, word: 10, words: 10),
                           firmware: ataString(b, word: 23, words: 4), capacityBytes: sectors * sector, rotationRPM: rpm)
    }

    /// SMART data / thresholds: 30 entries of 12 bytes starting at offset 2.
    static func attributes(data: [UInt8], thresholds: [UInt8]?) -> [ATAAttribute] {
        guard data.count >= 512 else { return [] }
        var thr: [Int: Int] = [:]
        if let t = thresholds, t.count >= 512 {
            for i in 0..<30 {
                let o = 2 + 12 * i
                if t[o] != 0 { thr[Int(t[o])] = Int(t[o + 1]) }
            }
        }
        var out: [ATAAttribute] = []
        for i in 0..<30 {
            let o = 2 + 12 * i
            let id = Int(data[o])
            if id == 0 { continue }
            let flags = UInt16(data[o + 1]) | UInt16(data[o + 2]) << 8
            let raw = (0..<6).reduce(UInt64(0)) { $0 | UInt64(data[o + 5 + $1]) << (8 * UInt64($1)) }
            out.append(ATAAttribute(id: id, name: attributeName(id), flags: flags, value: Int(data[o + 3]),
                                    worst: Int(data[o + 4]), threshold: thr[id] ?? 0, raw: raw, rawText: rawText(id, raw)))
        }
        return out
    }

    static func rawText(_ id: Int, _ raw: UInt64) -> String {
        switch id {
        case 190, 194: return "\(raw & 0xFF) °C"        // upper bytes are often min / max
        case 9: return "\(raw & 0xFFFF_FFFF) h"
        default: return String(raw)
        }
    }

    static func temperature(_ attrs: [ATAAttribute]) -> Int? {
        guard let a = attrs.first(where: { $0.id == 194 }) ?? attrs.first(where: { $0.id == 190 }) else { return nil }
        let t = Int(a.raw & 0xFF)
        return (1...120).contains(t) ? t : nil
    }

    static func powerOnHours(_ attrs: [ATAAttribute]) -> UInt64? {
        attrs.first(where: { $0.id == 9 }).map { $0.raw & 0xFFFF_FFFF }
    }

    static func attributeName(_ id: Int) -> String { names[id] ?? "Attribute \(id)" }

    static let names: [Int: String] = [
        1: "Raw Read Error Rate", 2: "Throughput Performance", 3: "Spin-Up Time", 4: "Start/Stop Count",
        5: "Reallocated Sector Count", 7: "Seek Error Rate", 8: "Seek Time Performance", 9: "Power-On Hours",
        10: "Spin Retry Count", 11: "Calibration Retry Count", 12: "Power Cycle Count",
        170: "Available Reserved Space", 171: "Program Fail Count", 172: "Erase Fail Count",
        173: "Wear Leveling Count", 174: "Unexpected Power Loss Count", 175: "Power Loss Protection Failure",
        177: "Wear Leveling Count", 178: "Used Reserved Block Count (chip)", 179: "Used Reserved Block Count (total)",
        180: "Unused Reserved Block Count", 181: "Program Fail Count (total)", 182: "Erase Fail Count",
        183: "SATA Downshift Error Count", 184: "End-to-End Error", 187: "Reported Uncorrectable Errors",
        188: "Command Timeout", 189: "High Fly Writes", 190: "Airflow Temperature", 191: "G-Sense Error Rate",
        192: "Power-Off Retract Count", 193: "Load/Unload Cycle Count", 194: "Temperature",
        195: "Hardware ECC Recovered", 196: "Reallocation Event Count", 197: "Current Pending Sector Count",
        198: "Offline Uncorrectable Sector Count", 199: "UDMA CRC Error Count", 200: "Multi-Zone Error Rate",
        201: "Soft Read Error Rate", 202: "Percent Lifetime Remaining", 206: "Flying Height",
        211: "Vibration During Write", 220: "Disk Shift", 222: "Loaded Hours", 223: "Load/Unload Retry Count",
        224: "Load Friction", 225: "Load/Unload Cycle Count", 226: "Load-In Time", 227: "Torque Amplification Count",
        228: "Power-Off Retract Count", 230: "Drive Life Protection Status", 231: "SSD Life Left",
        232: "Endurance Remaining", 233: "Media Wearout Indicator", 234: "Average Erase Count",
        235: "Good Block Count", 240: "Head Flying Hours", 241: "Total LBAs Written", 242: "Total LBAs Read",
        243: "Total LBAs Written (expanded)", 244: "Total LBAs Read (expanded)", 245: "Flash Writes (NAND)",
        246: "Total Host Sector Writes", 247: "Host Program Page Count", 248: "Background Program Page Count",
        249: "NAND Writes (1 GiB)", 250: "Read Error Retry Rate", 251: "Minimum Spares Remaining",
        252: "Newly Added Bad Flash Block", 254: "Free Fall Protection",
    ]
}

// MARK: - Health rules

enum ATAHealth {
    /// Raw counters where any non-zero value is a problem.
    static let badSectorIDs: Set<Int> = [5, 196, 197, 198, 187]
    /// Normalised "life left" style attributes (100 = new).
    static let lifeIDs: Set<Int> = [177, 202, 231, 232, 233]

    /// `baseline` = raw values of the bad-sector attributes seen when this drive first appeared:
    /// a counter that grew since then is `bad`, a non-zero counter that is stable is `caution`.
    static func evaluate(_ s: ATASnapshot, baseline: [Int: UInt64]?) -> (HealthStatus, [AttributeRow]) {
        var rows: [AttributeRow] = []
        func add(_ n: String, _ v: String, _ st: HealthStatus, overall: Bool = true) {
            rows.append(AttributeRow(name: n, value: v, status: st, affectsOverall: overall))
        }
        if let p = s.overallPassed { add("SMART overall status", p ? "PASSED" : "FAILING", p ? .good : .bad) }
        if let t = s.temperatureC {
            add("Temperature", "\(t) °C", tempStatus(t, ssd: s.identity.isSSD))
        }
        for a in s.attributes {
            var st: HealthStatus = .good
            let raw = a.raw & 0xFFFF_FFFF   // upper bytes are vendor packed on some drives
            if badSectorIDs.contains(a.id), raw > 0 {
                if let b = baseline?[a.id], raw > b { st = .bad } else { st = .caution }
            }
            if a.failingNow { st = .bad }
            if lifeIDs.contains(a.id), a.value > 0, a.value <= 100 {
                if a.value <= 10 { st = max(st, .bad) } else if a.value < 20 { st = max(st, .caution) }
            }
            let affects = st != .good || badSectorIDs.contains(a.id) || lifeIDs.contains(a.id)
            let text = "\(a.rawText)   [value \(a.value), worst \(a.worst)" + (a.threshold > 0 ? ", threshold \(a.threshold)]" : "]")
            add("\(a.id) \(a.name)", text, st, overall: affects)
        }
        let overall = rows.filter(\.affectsOverall).map(\.status).max() ?? .good
        return (rows.isEmpty ? .unknown : overall, rows)
    }

    static func tempStatus(_ t: Int, ssd: Bool) -> HealthStatus {
        let (w, c) = thresholds(ssd: ssd)
        return t >= c ? .bad : (t >= w ? .caution : .good)
    }

    /// ATA drives report no thresholds: 55 / 60 °C for HDDs (typical max operating 60), 70 / 80 °C for SSDs.
    static func thresholds(ssd: Bool) -> (warn: Int, crit: Int) { ssd ? (70, 80) : (55, 60) }

    static func baseline(_ s: ATASnapshot) -> [Int: UInt64] {
        Dictionary(uniqueKeysWithValues: s.attributes.filter { badSectorIDs.contains($0.id) }.map { ($0.id, $0.raw) })
    }
}

// MARK: - Standby policy

enum ATAPolicy {
    /// Pure decision used by the sampler. `powerState` = CurrentPowerState, `maxPowerState` from IOPowerManagement.
    /// A rotating drive in its lowest state (and a higher one exists) is asleep: polling would spin it up.
    static func isAsleep(powerState: Int?, maxPowerState: Int?) -> Bool {
        guard let p = powerState, let m = maxPowerState, m >= 1 else { return false }
        return p == 0
    }

    static func shouldPoll(rotational: Bool, dontWake: Bool, powerState: Int?, maxPowerState: Int?) -> Bool {
        !(rotational && dontWake && isAsleep(powerState: powerState, maxPowerState: maxPowerState))
    }

    static let dontWakeKey = "ata.dontWakeSleepingDrives"
    static var dontWake: Bool { UserDefaults.standard.object(forKey: dontWakeKey) as? Bool ?? true }
    /// Seconds between ATA SMART reads (attributes change slowly; every read can wake / disturb a disk).
    static let pollInterval: TimeInterval = 60
}
