import XCTest
@testable import NVMeter

final class SpeedSelectionTests: XCTestCase {
    @MainActor func testScopedVolumeSelectionAcrossDrives() async {
        let runner = SpeedTestRunner()
        let volumes = ["Media", "Archive", "Scratch"].map {
            SpeedVolume(name: $0, mountPoint: "/Volumes/" + $0, totalBytes: 100, freeBytes: 50, isBoot: false)
        }
        let paths = volumes.map(\.mountPoint)
        runner.refreshVolumes(mounts: [paths[1]], scoped: true, available: volumes)
        XCTAssertEqual(runner.volume, volumes[1])
        runner.refreshVolumes(mounts: [paths[0], paths[2]], scoped: true, available: volumes)
        XCTAssertNil(runner.volume)
        XCTAssertEqual(runner.volumes, [volumes[0], volumes[2]])
        runner.mountPoint = paths[2]
        runner.refreshVolumes(mounts: [paths[0], paths[2]], scoped: true, available: volumes)
        XCTAssertEqual(runner.volume, volumes[2])
        runner.refreshVolumes(mounts: [], scoped: true, available: volumes)
        XCTAssertTrue(runner.volumes.isEmpty)
        XCTAssertNil(runner.volume)
    }
}
