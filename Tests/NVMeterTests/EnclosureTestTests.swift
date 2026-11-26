import XCTest
@testable import NVMeter

final class EnclosureTestTests: XCTestCase {
    // Numbers measured on a 4-bay USB4 enclosure (3.8 GB/s budget, two Gen4 x1 and two Gen3 x1 slots).
    private let plan = EnclosureTestPlan(enclosureName: "Enclosure", linkText: "USB4 40 Gb/s", budgetMBps: 3800, drives: [
        EnclosureTestDrive(id: "a", name: "A", slot: 1, mountPoint: "/Volumes/A", role: .readWrite, linkText: "Gen4 x1", ceilingMBps: 1772),
        EnclosureTestDrive(id: "b", name: "B", slot: 2, mountPoint: "/Volumes/B", role: .read, linkText: "Gen3 x1", ceilingMBps: 886),
        EnclosureTestDrive(id: "c", name: "C", slot: 3, mountPoint: "/Volumes/C", role: .read, linkText: "Gen3 x1", ceilingMBps: 886),
        EnclosureTestDrive(id: "d", name: "D", slot: 4, mountPoint: "/Volumes/D", role: .read, linkText: "Gen4 x1", ceilingMBps: 1772),
    ], scenarios: EnclosureScenario.allCases)

    func testAllReadingFillsTheLink() {
        let f = EnclosureEngine.findings(per: ["a": .init(read: 1288), "b": .init(read: 844), "c": .init(read: 467), "d": .init(read: 1250)], plan: plan)
        XCTAssertTrue(f[0].hasPrefix("Reading fills the enclosure link: 3.85 GB/s"), f[0])
        XCTAssertTrue(f[0].contains("slot 1 (A)") && f[0].contains("slot 3 (C)") && !f[0].contains("slot 2 (B)"), f[0])
        XCTAssertTrue(f.contains { $0.hasPrefix("At their slot's PCIe limit: slot 2 (B)") })
    }

    func testBothDirectionsEveryDriveAtSlotLimit() {
        // Measured: three drives reading at their slot limits, one writing at its own speed in the other direction.
        let f = EnclosureEngine.findings(per: ["a": .init(write: 1494), "b": .init(read: 844), "c": .init(read: 822), "d": .init(read: 1658)], plan: plan)
        XCTAssertTrue(f[0].hasPrefix("Reading reaches 3.32 GB/s") && f[0].contains("every drive at its own slot limit"), f[0])
        XCTAssertTrue(f[1].hasPrefix("Writing: 1.49 GB/s"), f[1])
        XCTAssertTrue(f.contains { $0.contains("both directions at once") })
        XCTAssertFalse(f.contains { $0.contains("slows down") }, "a writer must not be blamed on the full read direction")
    }

    func testRolesAndPlannedWrites() {
        XCTAssertEqual(plan.roles(in: .both)["a"], .write)
        XCTAssertEqual(plan.roles(in: .both)["b"], .read)
        XCTAssertEqual(plan.roles(in: .writeAll).count, 1)
        var readOnly = plan
        readOnly.drives = readOnly.drives.map { var d = $0; d.role = .read; return d }
        XCTAssertEqual(readOnly.runnable, [.readAll, .heat])
        XCTAssertEqual(readOnly.plannedWriteBytes(), 0)
    }

    func testRateMeterSmoothsOverHalfASecond() {
        var m = RateMeter(t0: 0)
        var last = 0.0
        for i in 1...20 { last = m.add(Double(i) * 0.1, Double(i) * 100) }   // 1000 units/s
        XCTAssertEqual(last, 1000, accuracy: 1)
    }

    func testHeatPlateau() {
        let s = (0..<40).map { (t: Double($0) * 15, c: min(40 + $0, 52)) }   // rises to 52 at 3 min, then flat
        let h = EnclosureEngine.heatSummary(s)
        XCTAssertEqual(h.maxC, 52)
        XCTAssertEqual(h.plateauMinute ?? 0, 2.75, accuracy: 0.01)
    }
}
