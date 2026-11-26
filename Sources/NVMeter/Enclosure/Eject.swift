import Foundation
import DiskArbitration
import Observation

/// Unmounts all volumes of whole disks and ejects them through DiskArbitration (what Finder's Eject does).
/// Never called without a confirmation sheet (see EjectViews).
@MainActor @Observable
final class EjectController {
    enum Phase: Equatable {
        case idle
        case working(String)
        case done(String)
        case busy(String, [VolumeHolder])      // unmount refused: processes holding files
        case failed(String)
    }
    private(set) var phase: Phase = .idle
    var holders: [VolumeHolder] = []
    private(set) var lookingUp = false

    @ObservationIgnored private let session: DASession? = {
        guard let s = DASessionCreate(kCFAllocatorDefault) else { return nil }
        DASessionSetDispatchQueue(s, DispatchQueue.main)
        return s
    }()

    func reset() { phase = .idle; holders = [] }

    /// Read-only: lists processes with files open on any volume of these drives.
    func showHolders(of drives: [DriveSnapshot]) async {
        lookingUp = true
        defer { lookingUp = false }
        var all: [VolumeHolder] = []
        for v in drives.flatMap(\.volumes) { all += await VolumeHolders.find(mountPoint: v.mountPoint) }
        holders = all
    }

    /// Unmount (whole disk) then eject, drive by drive; stops at the first failure.
    func eject(_ drives: [DriveSnapshot]) async {
        guard let session else { phase = .failed("DiskArbitration session unavailable"); return }
        holders = []
        for d in drives {
            phase = .working("Unmounting \(d.displayName)…")
            guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, d.bsdName) else {
                phase = .failed("Disk \(d.bsdName) not found"); return
            }
            if !d.volumes.isEmpty {
                let r = await Self.unmountWhole(disk)
                if let r {
                    if r.busy {
                        var all: [VolumeHolder] = []
                        for v in d.volumes { all += await VolumeHolders.find(mountPoint: v.mountPoint) }
                        holders = all
                        phase = .busy("\(d.displayName) is in use and was not unmounted.", all)
                    } else {
                        phase = .failed("Could not unmount \(d.displayName): \(r.message)")
                    }
                    return
                }
            }
            phase = .working("Ejecting \(d.displayName)…")
            if let r = await Self.ejectDisk(disk) {
                // Disks inside a PCIe-tunnelled enclosure are often not "ejectable": the unmount alone makes them safe.
                if !d.volumes.isEmpty || r.notEjectable { continue }
                phase = .failed("Could not eject \(d.displayName): \(r.message)"); return
            }
        }
        phase = .done("Done. Volumes are unmounted; the drives can be unplugged.")
    }

    // MARK: DiskArbitration wrappers (callbacks hop back through a continuation)

    struct Failure: Sendable {
        var code: Int32
        var message: String
        /// DiskArbitration's own "busy", or the file system's EBUSY wrapped as unix_err(EBUSY) = 0xc010.
        var busy: Bool { code == Int32(truncatingIfNeeded: kDAReturnBusy) || code == 0xC000 | EBUSY }
        var notEjectable: Bool { code == Int32(truncatingIfNeeded: kDAReturnNotPermitted) || code == Int32(truncatingIfNeeded: kDAReturnUnsupported) } // not permitted / unsupported
    }

    private final class Box { let cont: CheckedContinuation<Failure?, Never>; init(_ c: CheckedContinuation<Failure?, Never>) { cont = c } }

    private static func failure(_ dissenter: DADissenter?) -> Failure? {
        guard let dissenter else { return nil }
        let code = DADissenterGetStatus(dissenter)
        let text = DADissenterGetStatusString(dissenter) as String?
        return Failure(code: Int32(bitPattern: UInt32(truncatingIfNeeded: code)), message: text ?? String(format: "error 0x%08x", UInt32(truncatingIfNeeded: code)))
    }

    private static func unmountWhole(_ disk: DADisk) async -> Failure? {
        await withCheckedContinuation { cont in
            let box = Unmanaged.passRetained(Box(cont)).toOpaque()
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionWhole), { _, dissenter, ctx in
                let b = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                b.cont.resume(returning: EjectController.failure(dissenter))
            }, box)
        }
    }

    private static func ejectDisk(_ disk: DADisk) async -> Failure? {
        await withCheckedContinuation { cont in
            let box = Unmanaged.passRetained(Box(cont)).toOpaque()
            DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), { _, dissenter, ctx in
                let b = Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue()
                b.cont.resume(returning: EjectController.failure(dissenter))
            }, box)
        }
    }
}
