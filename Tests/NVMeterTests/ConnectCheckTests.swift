import XCTest
@testable import NVMeter

@MainActor
final class ConnectCheckTests: XCTestCase {
    private func smart(written: UInt64 = 100_000_000_000, unsafe: UInt64 = 5, poh: UInt64 = 100, cycles: UInt64 = 20,
                       media: UInt64 = 0) -> SMARTSnapshot {
        SMARTSnapshot(criticalWarning: 0, temperatureC: 40, sensorsC: [], availableSparePct: 100, availableSpareThresholdPct: 10,
                      percentageUsed: 1, dataUnitsRead: 0, dataUnitsWritten: 0, bytesRead: 50_000_000_000, bytesWritten: written,
                      hostReadCommands: 0, hostWriteCommands: 0, controllerBusyMinutes: 0, powerCycles: cycles, powerOnHours: poh,
                      unsafeShutdowns: unsafe, mediaErrors: media, errorLogEntries: 0, warningTempMinutes: 0, criticalTempMinutes: 0)
    }

    private func drive(_ s: SMARTSnapshot?, mounted: Bool = true) -> DriveSnapshot {
        DriveSnapshot(id: "k", bsdName: "disk9", model: "Test SSD", serial: "S", firmware: "1", capacityBytes: 1, interconnect: "PCI-Express",
                      location: "External", smartCapable: true, smartError: nil, identify: nil, smart: s, link: nil,
                      connection: ConnectionInfo(kind: "thunderbolt", summary: "PCIe 4.0 x1 via USB4"), interface: "",
                      volumes: [VolumeInfo(name: "Media", bsdName: "disk10s1", mountPoint: mounted ? "/Volumes/Media" : "", sizeBytes: 1, freeBytes: 1)],
                      counters: IOCounters(bytesRead: 0, bytesWritten: 0, opsRead: 0, opsWritten: 0),
                      throughput: Throughput(readMBps: 0, writeMBps: 0, readIOPS: 0, writeIOPS: 0),
                      warnings: [], health: .good, attributes: [])
    }

    private func make() -> (ConnectCheck, () -> [(ConnectReport, Bool)]) {
        let c = ConnectCheck(url: nil)
        var posted: [(ConnectReport, Bool)] = []
        c.post = { posted.append(($0, $1)) }
        c.snapshot = { _ in }
        c.known = { _ in false }
        return (c, { posted })
    }

    func testFirstSightThenReconnectAfterUseElsewhere() {
        let (c, posted) = make()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        c.evaluate([drive(smart())], now: t0)
        XCTAssertEqual(posted().count, 1)
        XCTAssertNil(posted()[0].0.away)
        XCTAssertFalse(posted()[0].1)                                   // first sight: no banner
        c.evaluate([drive(smart(), mounted: false)], now: t0.addingTimeInterval(10))   // ejected
        c.evaluate([], now: t0.addingTimeInterval(11))                  // unplugged
        // back two days later: 300 GB written, 6 h on, one unsafe shutdown (enclosure cut power after a clean eject)
        c.evaluate([drive(smart(written: 400_000_000_000, unsafe: 6, poh: 106, cycles: 23))], now: t0.addingTimeInterval(2 * 86400))
        XCTAssertEqual(posted().count, 2)
        let (r, notify) = posted()[1]
        XCTAssertTrue(notify)                                           // used elsewhere after a long absence
        XCTAssertTrue(r.lines.contains { $0.text.hasPrefix("Used elsewhere: 300 GB written") })
        XCTAssertTrue(r.lines.contains { $0.text.contains("ejected first") && $0.level == .info })
        XCTAssertEqual(r.level, .info)
    }

    func testUnsafeRemovalWhileMountedWarns() {
        let (c, posted) = make()
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        c.evaluate([drive(smart())], now: t0)
        c.evaluate([], now: t0.addingTimeInterval(5))                   // pulled while mounted
        c.evaluate([drive(smart(unsafe: 6))], now: t0.addingTimeInterval(600))
        let r = posted().last!.0
        XCTAssertEqual(r.level, .warning)
        XCTAssertTrue(r.headline.contains("unplugged while its volumes were mounted"))
        XCTAssertTrue(posted().last!.1)
    }

    func testBlipAndNewErrors() {
        let (c, posted) = make()
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        c.evaluate([drive(smart())], now: t0)
        c.evaluate([], now: t0.addingTimeInterval(1))
        c.evaluate([drive(smart())], now: t0.addingTimeInterval(30))    // 30 s blip: no report
        XCTAssertEqual(posted().count, 1)
        c.evaluate([], now: t0.addingTimeInterval(40))
        c.evaluate([drive(smart(media: 2))], now: t0.addingTimeInterval(4000))
        XCTAssertEqual(posted().last!.0.level, .critical)
    }

    func testWaitsForSMARTAndSkipsKnownDrives() {
        let (c, posted) = make()
        let t0 = Date(timeIntervalSince1970: 4_000_000)
        c.evaluate([drive(nil)], now: t0)                               // SMART not read yet
        XCTAssertTrue(posted().isEmpty)
        c.evaluate([drive(smart())], now: t0.addingTimeInterval(1))
        XCTAssertEqual(posted().count, 1)

        let (c2, posted2) = make()
        c2.known = { _ in true }                                         // drive from before this feature
        c2.evaluate([drive(smart())], now: t0)
        XCTAssertTrue(posted2().isEmpty)
        c2.evaluate([], now: t0.addingTimeInterval(1))
        c2.evaluate([drive(smart(written: 200_000_000_000))], now: t0.addingTimeInterval(7200))
        XCTAssertEqual(posted2().count, 1)
        XCTAssertNotNil(posted2()[0].0.away)
    }
}
