import Foundation
import CNVMe

/// NVMe Device Self-test log (log page 06h), read only. Starting a self-test is deliberately not implemented:
/// Apple's public SMART interface has no "Device Self-test" admin command.
struct NVMeSelfTestEntry: Codable, Equatable, Sendable {
    var testName: String        // "Short", "Extended", "Vendor"
    var result: String
    var passed: Bool
    var powerOnHours: UInt64
    var failingLBA: UInt64?
}

struct NVMeSelfTestLog: Codable, Equatable, Sendable {
    var inProgress: String?          // "Short" / "Extended" while running
    var percentComplete: Int?
    var entries: [NVMeSelfTestEntry] // newest first
}

enum NVMeSelfTestParser {
    static let logSize = 564          // 4 + 20 * 28
    static let logDWords: UInt32 = 141

    /// OACS (Identify Controller bytes 256-257) bit 4 = Device Self-test command supported.
    static func supportsSelfTest(oacs: UInt16) -> Bool { oacs & (1 << 4) != 0 }

    static func resultText(_ r: UInt8) -> String {
        switch r {
        case 0: "Completed without error"
        case 1: "Aborted by Device Self-test command"
        case 2: "Aborted by controller reset"
        case 3: "Aborted, namespace removed"
        case 4: "Aborted by Format NVM"
        case 5: "Fatal or unknown test error"
        case 6: "Completed with a failed segment"
        case 7: "Completed, failed segment unknown"
        case 8: "Aborted for an unknown reason"
        case 9: "Aborted by sanitize"
        default: "Unknown result \(r)"
        }
    }

    static func testName(_ code: UInt8) -> String {
        switch code { case 1: "Short"; case 2: "Extended"; case 0xE: "Vendor specific"; default: "Test \(code)" }
    }

    static func parse(_ b: [UInt8]) -> NVMeSelfTestLog? {
        guard b.count >= logSize else { return nil }
        let r = RawBuffer(bytes: b)
        let cur = b[0] & 0x0F
        let inProg: String? = cur == 0 ? nil : testName(cur)
        let pct: Int? = cur == 0 ? nil : Int(b[1] & 0x7F)
        var entries: [NVMeSelfTestEntry] = []
        for i in 0..<20 {
            let o = 4 + 28 * i
            let status = b[o]
            let res = status & 0x0F
            if res == 0xF { continue }                  // entry not used
            let flags = b[o + 2]
            let lbaValid = flags & 0x02 != 0            // bit 1: failing LBA valid
            entries.append(NVMeSelfTestEntry(
                testName: testName(status >> 4), result: resultText(res), passed: res == 0,
                powerOnHours: r.u64(o + 4), failingLBA: lbaValid ? r.u64(o + 16) : nil))
        }
        return NVMeSelfTestLog(inProgress: inProg, percentComplete: pct, entries: entries)
    }
}

extension SMARTReader {
    /// Reads log page 06h when the controller advertises Device Self-test (OACS bit 4). nil otherwise.
    func readSelfTestLog() -> NVMeSelfTestLog? {
        guard let h = rawHandle, NVMeSelfTestParser.supportsSelfTest(oacs: oacs) else { return nil }
        var buf = [UInt8](repeating: 0, count: 4 * Int(NVMeSelfTestParser.logDWords))
        let kr = buf.withUnsafeMutableBufferPointer { nvmeter_read_log_page(h, 0x06, $0.baseAddress, NVMeSelfTestParser.logDWords) }
        guard kr == 0 else { return nil }
        return NVMeSelfTestParser.parse(buf)
    }
}
