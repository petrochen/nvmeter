import XCTest
@testable import NVMeter

final class ATARAIDTests: XCTestCase {
    // MARK: fixtures (synthetic)

    /// Writes an ATA string into IDENTIFY words (two chars per word, first char in the high byte).
    private func put(_ b: inout [UInt8], word: Int, _ s: String, words: Int) {
        let padded = Array(s.utf8) + Array(repeating: UInt8(ascii: " "), count: words * 2 - s.utf8.count)
        for i in 0..<words { b[2 * (word + i)] = padded[2 * i + 1]; b[2 * (word + i) + 1] = padded[2 * i] }
    }

    private func identify(rpm: UInt16, lba48: UInt64 = 1_953_525_168) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 512)
        put(&b, word: 10, "SN12345", words: 10)
        put(&b, word: 23, "FW1.0", words: 4)
        put(&b, word: 27, "Test Drive 1TB", words: 20)
        for i in 0..<4 { b[2 * (100 + i)] = UInt8((lba48 >> (16 * UInt64(i))) & 0xFF); b[2 * (100 + i) + 1] = UInt8((lba48 >> (16 * UInt64(i) + 8)) & 0xFF) }
        b[2 * 217] = UInt8(rpm & 0xFF); b[2 * 217 + 1] = UInt8(rpm >> 8)
        return b
    }

    private func smartData(_ attrs: [(id: UInt8, value: UInt8, worst: UInt8, raw: UInt64)]) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 512)
        for (i, a) in attrs.enumerated() {
            let o = 2 + 12 * i
            b[o] = a.id; b[o + 3] = a.value; b[o + 4] = a.worst
            for k in 0..<6 { b[o + 5 + k] = UInt8((a.raw >> (8 * UInt64(k))) & 0xFF) }
        }
        return b
    }

    private func thresholds(_ t: [(UInt8, UInt8)]) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 512)
        for (i, e) in t.enumerated() { b[2 + 12 * i] = e.0; b[3 + 12 * i] = e.1 }
        return b
    }

    // MARK: ATA

    func testIdentify() throws {
        let id = try XCTUnwrap(ATAParser.identity(identify(rpm: 7200)))
        XCTAssertEqual(id.model, "Test Drive 1TB")
        XCTAssertEqual(id.serial, "SN12345")
        XCTAssertEqual(id.firmware, "FW1.0")
        XCTAssertEqual(id.capacityBytes, 1_953_525_168 * 512)
        XCTAssertEqual(id.rotationRPM, 7200)
        XCTAssertTrue(id.isRotational)
        XCTAssertEqual(ATAParser.identity(identify(rpm: 1))?.isSSD, true)
        XCTAssertNil(ATAParser.identity(identify(rpm: 0))?.rotationRPM)
    }

    func testAttributesAndNames() {
        let data = smartData([(5, 100, 100, 0), (9, 90, 90, 12345), (194, 70, 50, 0x0032_0000_0025), (197, 100, 100, 3)])
        let thr = thresholds([(5, 36), (9, 0), (194, 0), (197, 0)])
        let a = ATAParser.attributes(data: data, thresholds: thr)
        XCTAssertEqual(a.map(\.id), [5, 9, 194, 197])
        XCTAssertEqual(a[0].name, "Reallocated Sector Count")
        XCTAssertEqual(a[0].threshold, 36)
        XCTAssertEqual(a[3].raw, 3)
        XCTAssertEqual(ATAParser.temperature(a), 0x25)
        XCTAssertEqual(ATAParser.powerOnHours(a), 12345)
        XCTAssertEqual(ATAParser.attributeName(241), "Total LBAs Written")
        XCTAssertEqual(ATAParser.attributeName(999), "Attribute 999")
    }

    private func snapshot(_ attrs: [ATAAttribute], passed: Bool? = true, rpm: Int = 7200) -> ATASnapshot {
        ATASnapshot(identity: ATAIdentity(model: "M", serial: "S", firmware: "F", capacityBytes: 1, rotationRPM: rpm),
                    overallPassed: passed, attributes: attrs, temperatureC: ATAParser.temperature(attrs), powerOnHours: nil)
    }

    func testHealthRules() {
        func attrs(_ pending: UInt64) -> [ATAAttribute] {
            ATAParser.attributes(data: smartData([(5, 100, 100, 0), (197, 100, 100, pending), (194, 100, 100, 35)]), thresholds: nil)
        }
        XCTAssertEqual(ATAHealth.evaluate(snapshot(attrs(0)), baseline: nil).0, .good)
        // non-zero but stable: caution
        let s3 = snapshot(attrs(3))
        XCTAssertEqual(ATAHealth.evaluate(s3, baseline: ATAHealth.baseline(s3)).0, .caution)
        XCTAssertEqual(ATAHealth.evaluate(s3, baseline: nil).0, .caution)
        // rising since baseline: bad
        XCTAssertEqual(ATAHealth.evaluate(snapshot(attrs(5)), baseline: ATAHealth.baseline(s3)).0, .bad)
        // failing overall
        XCTAssertEqual(ATAHealth.evaluate(snapshot(attrs(0), passed: false), baseline: nil).0, .bad)
        // value below threshold
        let thr = ATAParser.attributes(data: smartData([(1, 10, 10, 0)]), thresholds: thresholds([(1, 20)]))
        XCTAssertEqual(ATAHealth.evaluate(snapshot(thr), baseline: nil).0, .bad)
        // hot HDD
        let hot = ATAParser.attributes(data: smartData([(194, 100, 100, 61)]), thresholds: nil)
        XCTAssertEqual(ATAHealth.evaluate(snapshot(hot), baseline: nil).0, .bad)
        XCTAssertEqual(ATAHealth.evaluate(snapshot(hot, rpm: 1), baseline: nil).0, .good)
    }

    func testStandbyPolicy() {
        XCTAssertFalse(ATAPolicy.shouldPoll(rotational: true, dontWake: true, powerState: 0, maxPowerState: 1))
        XCTAssertTrue(ATAPolicy.shouldPoll(rotational: true, dontWake: true, powerState: 1, maxPowerState: 1))
        XCTAssertTrue(ATAPolicy.shouldPoll(rotational: true, dontWake: false, powerState: 0, maxPowerState: 1))
        XCTAssertTrue(ATAPolicy.shouldPoll(rotational: false, dontWake: true, powerState: 0, maxPowerState: 1))
        XCTAssertTrue(ATAPolicy.shouldPoll(rotational: true, dontWake: true, powerState: nil, maxPowerState: nil))
    }

    // MARK: RAID

    func testRAIDStatusAndLevel() {
        XCTAssertEqual(RAIDParser.status("Online"), .online)
        XCTAssertEqual(RAIDParser.status("Degraded"), .degraded)
        XCTAssertEqual(RAIDParser.status("Rebuilding"), .rebuilding)
        XCTAssertEqual(RAIDParser.status("Offline"), .offline)
        XCTAssertEqual(RAIDParser.status(nil), .unknown)
        XCTAssertEqual(RAIDParser.level("Mirror"), "Mirror (RAID 1)")
        XCTAssertEqual(RAIDParser.level("Stripe"), "Stripe (RAID 0)")
        XCTAssertEqual(RAIDParser.level("Concat"), "Concatenated")
        XCTAssertEqual(RAIDParser.wholeDisk("disk12s2"), "disk12")
    }

    func testRAIDAssemble() {
        let set: [String: Any] = ["AppleRAID-SetUUID": "U1", "AppleRAID-SetName": "Backup",
                                  "AppleRAID-LevelName": "Mirror", "AppleRAID-Status": "Degraded"]
        let other: [String: Any] = ["AppleRAID-SetUUID": "U2", "AppleRAID-SetName": "Scratch", "AppleRAID-Status": "Online"]
        let m1 = RAIDParser.appleMember(props: ["AppleRAID-SetUUID": "U1", "AppleRAID-MemberStatus": "Online"], bsdName: "disk4s2")
        let m2 = RAIDParser.appleMember(props: ["AppleRAID-SetUUID": "U2"], bsdName: "disk6s2")
        let sets = RAIDParser.assemble(sets: [(set, "disk9", 1000), (other, nil, 5)], members: [m1, m2])
        XCTAssertEqual(sets.count, 2)
        let b = sets.first { $0.name == "Backup" }!
        XCTAssertEqual(b.status, .degraded)
        XCTAssertEqual(b.level, "Mirror (RAID 1)")
        XCTAssertEqual(b.memberDrives, ["disk4"])
        XCTAssertTrue(b.status.isProblem)
        XCTAssertEqual(sets.first { $0.name == "Scratch" }!.memberDrives, ["disk6"])
    }

    // MARK: NVMe self-test log

    func testSelfTestLog() throws {
        var b = [UInt8](repeating: 0, count: 564)
        for i in 0..<20 { b[4 + 28 * i] = 0x0F }                 // unused
        b[0] = 0x01; b[1] = 0x80 | 40                            // short test running, 40 %
        b[4] = 0x10                                              // short, completed OK
        b[8] = 0x39                                              // power-on hours 57 (LE) at +4
        b[4 + 28] = 0x26                                         // extended, failed segment
        b[4 + 28 + 2] = 0x02                                     // LBA valid
        b[4 + 28 + 16] = 0x2A                                    // failing LBA 42
        let log = try XCTUnwrap(NVMeSelfTestParser.parse(b))
        XCTAssertEqual(log.inProgress, "Short")
        XCTAssertEqual(log.percentComplete, 40)
        XCTAssertEqual(log.entries.count, 2)
        XCTAssertEqual(log.entries[0].testName, "Short")
        XCTAssertTrue(log.entries[0].passed)
        XCTAssertEqual(log.entries[0].powerOnHours, 57)
        XCTAssertEqual(log.entries[1].testName, "Extended")
        XCTAssertFalse(log.entries[1].passed)
        XCTAssertEqual(log.entries[1].failingLBA, 42)
        XCTAssertTrue(NVMeSelfTestParser.supportsSelfTest(oacs: 0x16))
        XCTAssertFalse(NVMeSelfTestParser.supportsSelfTest(oacs: 0x06))
        XCTAssertNil(NVMeSelfTestParser.parse([UInt8](repeating: 0, count: 100)))
    }
}
