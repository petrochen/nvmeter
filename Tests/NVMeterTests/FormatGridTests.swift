import XCTest
@testable import NVMeter

final class FormatGridTests: XCTestCase {
    func testRatesMatchPublishedFigures() {
        let uhd = FormatGrid.resolutions[1], hd = FormatGrid.resolutions[0]
        let hq = FormatGrid.codecs.first { $0.name == "ProRes 422 HQ" }!
        // Apple: ProRes 422 HQ UHD 29.97 = 707 Mb/s = 88 MB/s; HD is a quarter of that.
        XCTAssertEqual(hq.mBps(uhd, fps: 29.97), 707.0 / 8, accuracy: 0.1)
        XCTAssertEqual(hq.mBps(hd, fps: 29.97), 707.0 / 32, accuracy: 0.1)
        // Uncompressed 10-bit 4:2:2 UHD 30p: 3840 x 2160 x 20 bit x 30 = 622 MB/s.
        let raw = FormatGrid.codecs.last!
        XCTAssertEqual(raw.mBps(uhd, fps: 30), 3840 * 2160 * 20 * 30 / 8 / 1e6, accuracy: 0.1)
        // BRAW 3:1 at 6K 24p = 2130 Mb/s.
        let braw = FormatGrid.codecs.first { $0.name == "BRAW 3:1" }!
        XCTAssertEqual(braw.mBps(FormatGrid.resolutions[2], fps: 24), 2130.0 / 8, accuracy: 0.1)
    }

    func testVerdictUsesLiveLoop() {
        var r = SpeedResult(mode: .live, driveKey: "k", driveName: "d", volumeTotalBytes: 1, volumeFreeBytes: 1, testBytes: 1, bytesWritten: 1)
        r.write = PhaseStat(avgMBps: 1300, minMBps: 1, maxMBps: 1, seconds: 1, bytes: 1)
        r.read = PhaseStat(avgMBps: 1700, minMBps: 1, maxMBps: 1, seconds: 1, bytes: 1)
        let v = Verdict.input(from: [r])
        XCTAssertEqual(v?.writeMBps, 1300)
        XCTAssertEqual(v?.readMBps, 1700)
        XCTAssertEqual(v?.readSource, "live loop read")
    }
}
