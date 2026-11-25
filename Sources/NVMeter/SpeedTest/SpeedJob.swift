import Foundation

struct SpeedVolume: Identifiable, Hashable, Sendable {
    var name: String
    var mountPoint: String
    var fileSystem: String?
    var totalBytes: Int64
    var freeBytes: Int64
    var isBoot: Bool
    var id: String { mountPoint }

    /// Local, writable, user-visible volumes. System sub-volumes (VM, Preboot, ...) are hidden by macOS already.
    static func list() -> [SpeedVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedFormatDescriptionKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var out: [SpeedVolume] = []
        for u in urls {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsLocal == true, v.volumeIsReadOnly != true else { continue }
            let boot = v.volumeIsRootFileSystem == true
            let path = u.path
            if !boot, !path.hasPrefix("/Volumes/") { continue }
            if !boot, access(path, W_OK) != 0 { continue }
            out.append(SpeedVolume(name: v.volumeName ?? path, mountPoint: path, fileSystem: v.volumeLocalizedFormatDescription,
                                   totalBytes: Int64(v.volumeTotalCapacity ?? 0),
                                   freeBytes: v.volumeAvailableCapacityForImportantUsage ?? 0, isBoot: boot))
        }
        return out.sorted { ($0.isBoot ? 1 : 0, $0.name) < ($1.isBoot ? 1 : 0, $1.name) }
    }

    static func find(mountPoint: String) -> SpeedVolume? {
        let p = mountPoint.count > 1 && mountPoint.hasSuffix("/") ? String(mountPoint.dropLast()) : mountPoint
        return list().first { $0.mountPoint == p }
    }
}

struct SpeedRequest: Sendable {
    var mountPoint: String
    var mode: SpeedMode
    /// Quick: test file GB (default 5). Sustained: GB to write. Random: test file GB (default 4). Nil = mode default.
    var sizeGB: Double?
    /// Sustained only: write until the volume has 10 % free.
    var untilTenPercentFree = false
    /// Random 4K: seconds per queue depth.
    var randomSeconds: Double = 30

    static let sustainedChoices: [Double] = [20, 50, 100, 200]
}

enum SpeedJob {
    /// Bytes this request will write (used for the warning shown before starting).
    static func plannedBytes(_ r: SpeedRequest, volume: SpeedVolume) -> Int64 {
        switch r.mode {
        case .quick: return Int64((r.sizeGB ?? 5) * 1e9)
        case .random: return Int64((r.sizeGB ?? 4) * 1e9)
        case .sustained:
            if r.untilTenPercentFree { return max(0, volume.freeBytes - volume.totalBytes / 10) }
            return Int64((r.sizeGB ?? 20) * 1e9)
        }
    }

    /// Runs one test on the calling (background) thread. The test file is always removed.
    static func run(_ r: SpeedRequest, driveKey: String, driveName: String, control: SpeedControl, progress: SpeedProgress?) throws -> SpeedResult {
        guard let vol = SpeedVolume.find(mountPoint: r.mountPoint) else { throw SpeedError.io("Volume not available", ENOENT) }
        let planned = plannedBytes(r, volume: vol)
        guard planned >= 1_000_000_000 else { throw SpeedError.notEnoughSpace(needed: planned, free: vol.freeBytes) }
        try SpeedEngine.checkSpace(mountPoint: vol.mountPoint, needed: planned)
        let dir = try SpeedEngine.makeRunDirectory(mountPoint: vol.mountPoint)
        defer { SpeedEngine.removeRunDirectory(dir) }
        var res = SpeedResult(mode: r.mode, driveKey: driveKey, driveName: driveName, fileSystem: vol.fileSystem,
                              volumeTotalBytes: vol.totalBytes, volumeFreeBytes: vol.freeBytes, testBytes: planned, bytesWritten: 0)
        switch r.mode {
        case .quick:
            let (w, rd) = try SpeedEngine.quick(dir: dir, bytes: planned, control: control, progress: progress)
            res.write = w; res.read = rd; res.bytesWritten = w.bytes
        case .sustained:
            let (stat, series) = try SpeedEngine.sustained(dir: dir, bytes: planned, control: control, progress: progress)
            res.write = stat; res.series = series; res.bytesWritten = stat.bytes
            res.cliff = CliffDetector.detect(series: series)
        case .random:
            let (prep, stats) = try SpeedEngine.random(dir: dir, fileBytes: planned, seconds: r.randomSeconds, control: control, progress: progress)
            res.write = prep; res.random = stats; res.bytesWritten = prep.bytes
        }
        res.cancelled = control.isCancelled
        return res
    }
}
