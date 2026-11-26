import Foundation
import DiskArbitration
import Observation

/// Unmount, mount and read-only / read-write remount of single volumes through DiskArbitration (what Finder and
/// `diskutil mount readOnly` use; no root needed for external volumes). macOS cannot switch a mounted volume
/// between read-only and read-write without root, so a remount is an unmount followed by a mount.
/// Also applies the per-drive "Always mount read-only" setting.
@MainActor @Observable
final class MountController {
    static let shared = MountController()

    struct Status: Equatable {
        var message: String
        var isError: Bool
        var holders: [VolumeHolder] = []
    }

    /// Volume BSD names with an operation in progress.
    private(set) var working: Set<String> = []
    /// Last outcome per volume BSD name.
    private(set) var status: [String: Status] = [:]
    /// Drive ids whose volumes are kept read-only.
    private(set) var alwaysReadOnly: Set<String>

    static let alwaysKey = "mount.alwaysReadOnly"
    /// Attempts to remount an always-read-only volume before giving up (Spotlight often holds a fresh volume briefly).
    static let maxAttempts = 3

    @ObservationIgnored private var attempts: [String: (count: Int, last: Date)] = [:]
    @ObservationIgnored private let session: DASession? = {
        guard let s = DASessionCreate(kCFAllocatorDefault) else { return nil }
        DASessionSetDispatchQueue(s, DispatchQueue.main)
        return s
    }()
    @ObservationIgnored weak var monitor: Monitor?

    private init() {
        alwaysReadOnly = Set(UserDefaults.standard.stringArray(forKey: Self.alwaysKey) ?? [])
    }

    /// Mount controls are offered for external drives only, never for system locations.
    static func canManage(_ d: DriveSnapshot, _ v: VolumeInfo) -> Bool {
        d.connection.kind != "internal" && v.mountPoint != "/" && !v.mountPoint.hasPrefix("/System/")
    }

    func setAlwaysReadOnly(_ on: Bool, for d: DriveSnapshot) {
        if on { alwaysReadOnly.insert(d.id) } else { alwaysReadOnly.remove(d.id) }
        UserDefaults.standard.set(Array(alwaysReadOnly).sorted(), forKey: Self.alwaysKey)
        for v in d.volumes { attempts[v.bsdName] = nil }
        if on { enforce([d]) }
    }

    // MARK: Actions

    func unmount(_ v: VolumeInfo) async {
        await run(v, "Unmounting") {
            if let f = await Self.unmount(v.bsdName, session: $0) { return f }
            return nil
        }
    }

    func mount(_ v: VolumeInfo, readOnly: Bool) async {
        await run(v, readOnly ? "Mounting read-only" : "Mounting") { await Self.mount(v.bsdName, readOnly: readOnly, session: $0) }
    }

    /// Unmount, then mount in the other mode. When the mount fails the volume is mounted again as it was.
    func remount(_ v: VolumeInfo, readOnly: Bool) async {
        await run(v, readOnly ? "Remounting read-only" : "Remounting read-write") { session in
            if let f = await Self.unmount(v.bsdName, session: session) { return f }
            if let f = await Self.mount(v.bsdName, readOnly: readOnly, session: session) {
                _ = await Self.mount(v.bsdName, readOnly: v.readOnly, session: session)
                return f
            }
            return nil
        }
    }

    private func run(_ v: VolumeInfo, _ what: String, _ op: (DASession) async -> Failure?) async {
        guard let session else { status[v.bsdName] = Status(message: "DiskArbitration session unavailable", isError: true); return }
        guard !working.contains(v.bsdName) else { return }
        working.insert(v.bsdName)
        status[v.bsdName] = Status(message: "\(what)…", isError: false)
        let failure = await op(session)
        working.remove(v.bsdName)
        if let failure {
            var s = Status(message: failure.busy ? "\(v.name) is in use" : "\(what) failed: \(failure.message)", isError: true)
            if failure.busy, !v.mountPoint.isEmpty { s.holders = await VolumeHolders.find(mountPoint: v.mountPoint) }
            status[v.bsdName] = s
        } else {
            status[v.bsdName] = nil
        }
        monitor?.forceRefresh = true
    }

    // MARK: Always read-only

    /// Called on every tick: remounts writable volumes of always-read-only drives, a few attempts per volume.
    func enforce(_ snaps: [DriveSnapshot], now: Date = Date()) {
        let present = Set(snaps.flatMap { $0.volumes.map(\.bsdName) })
        for k in attempts.keys where !present.contains(k) { attempts[k] = nil }
        for d in snaps where alwaysReadOnly.contains(d.id) {
            for v in d.volumes where !v.readOnly && Self.canManage(d, v) && !working.contains(v.bsdName) {
                let a = attempts[v.bsdName] ?? (0, .distantPast)
                guard a.count < Self.maxAttempts, now.timeIntervalSince(a.last) >= 5 else { continue }
                attempts[v.bsdName] = (a.count + 1, now)
                let last = a.count + 1 == Self.maxAttempts
                Task {
                    await remount(v, readOnly: true)
                    if last, let s = status[v.bsdName], s.isError {
                        let who = s.holders.prefix(3).map(\.command).joined(separator: ", ")
                        AlertCenter.shared.post(.readOnlyMount, .warning, drive: d.displayName, driveID: d.id,
                                                title: "\(v.name) stays writable",
                                                body: "\(d.displayName) is set to always mount read-only, but \(v.name) could not be remounted: \(s.message)"
                                                    + (who.isEmpty ? "." : " (\(who)).") + " Close those apps and use Remount read-only.")
                    }
                }
            }
        }
    }

    // MARK: DiskArbitration wrappers

    typealias Failure = EjectController.Failure

    private final class Box { let cont: CheckedContinuation<Failure?, Never>; init(_ c: CheckedContinuation<Failure?, Never>) { cont = c } }

    private static func failure(_ dissenter: DADissenter?) -> Failure? {
        guard let dissenter else { return nil }
        let code = DADissenterGetStatus(dissenter)
        let text = DADissenterGetStatusString(dissenter) as String?
        return Failure(code: Int32(bitPattern: UInt32(truncatingIfNeeded: code)),
                       message: text ?? String(format: "error 0x%08x", UInt32(truncatingIfNeeded: code)))
    }

    private static func disk(_ bsd: String, _ session: DASession) -> DADisk? { DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd) }

    static func unmount(_ bsd: String, session: DASession) async -> Failure? {
        guard let disk = disk(bsd, session) else { return Failure(code: -1, message: "\(bsd) not found") }
        return await withCheckedContinuation { cont in
            let box = Unmanaged.passRetained(Box(cont)).toOpaque()
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), { _, dissenter, ctx in
                Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue().cont.resume(returning: MountController.failure(dissenter))
            }, box)
        }
    }

    /// Mounts at the default location; `readOnly` passes the "rdonly" mount option.
    static func mount(_ bsd: String, readOnly: Bool, session: DASession) async -> Failure? {
        guard let disk = disk(bsd, session) else { return Failure(code: -1, message: "\(bsd) not found") }
        return await withCheckedContinuation { (cont: CheckedContinuation<Failure?, Never>) in
            let box = Unmanaged.passRetained(Box(cont)).toOpaque()
            let callback: DADiskMountCallback = { _, dissenter, ctx in
                Unmanaged<Box>.fromOpaque(ctx!).takeRetainedValue().cont.resume(returning: MountController.failure(dissenter))
            }
            if readOnly {
                let opt = Unmanaged.passRetained("rdonly" as CFString)
                var args: [Unmanaged<CFString>?] = [opt, nil]
                args.withUnsafeMutableBufferPointer { (buf: inout UnsafeMutableBufferPointer<Unmanaged<CFString>?>) -> Void in
                    DADiskMountWithArguments(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), callback, box, buf.baseAddress!)
                }
                opt.release()
            } else {
                DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), callback, box)
            }
        }
    }
}

/// `NVMeter --volume <diskNsM> unmount|mount|mount-ro|remount-ro|remount-rw`: the same DiskArbitration calls as the
/// Volumes card, for scripting and testing. Prints the result and the volume's mount state afterwards.
enum MountCLI {
    static func run() -> Never {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--volume"), i + 2 < a.count else {
            FileHandle.standardError.write(Data("usage: --volume <diskNsM> unmount|mount|mount-ro|remount-ro|remount-rw\n".utf8)); exit(2)
        }
        let bsd = a[i + 1].replacingOccurrences(of: "/dev/", with: ""), op = a[i + 2]
        guard let session = DASessionCreate(kCFAllocatorDefault) else { exit(1) }
        DASessionSetDispatchQueue(session, .main)
        Task { @MainActor in
            var f: EjectController.Failure?
            switch op {
            case "unmount": f = await MountController.unmount(bsd, session: session)
            case "mount": f = await MountController.mount(bsd, readOnly: false, session: session)
            case "mount-ro": f = await MountController.mount(bsd, readOnly: true, session: session)
            case "remount-ro", "remount-rw":
                f = await MountController.unmount(bsd, session: session)
                if f == nil { f = await MountController.mount(bsd, readOnly: op == "remount-ro", session: session) }
            default: FileHandle.standardError.write(Data("unknown operation \(op)\n".utf8)); exit(2)
            }
            var state = "not mounted"
            if let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd),
               let desc = DADiskCopyDescription(disk) as? [String: Any], let url = desc[kDADiskDescriptionVolumePathKey as String] as? URL {
                let ro = (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
                state = "mounted at \(url.path) \(ro ? "read-only" : "read-write")"
            }
            print(f.map { "\(op) failed: \($0.message) (0x\(String(UInt32(bitPattern: $0.code), radix: 16)))" } ?? "\(op) ok", "|", state)
            exit(f == nil ? 0 : 1)
        }
        dispatchMain()
    }
}
