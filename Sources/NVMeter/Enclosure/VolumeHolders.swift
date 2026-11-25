import AppKit
import Foundation

/// A process that has files open on a volume.
struct VolumeHolder: Identifiable, Equatable, Sendable {
    var pid: Int32
    var command: String
    var files: [String]
    var id: Int32 { pid }
    var volume: String
}

/// Finds which processes hold files open on a volume. Read-only: runs the system `lsof` (the only shell-out in the app).
enum VolumeHolders {
    /// `lsof -F pcn +f -- <mountpoint>`; gives up after `timeout` seconds. Not root, so other users' processes may be missing.
    static func find(mountPoint: String, timeout: TimeInterval = 20) async -> [VolumeHolder] {
        await Task.detached(priority: .userInitiated) { run(mountPoint: mountPoint, timeout: timeout) }.value
    }

    static func run(mountPoint: String, timeout: TimeInterval) -> [VolumeHolder] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-F", "pcn", "+f", "--", mountPoint]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return parse(String(decoding: data, as: UTF8.self), volume: mountPoint)
    }

    /// Parses lsof `-F` output: `p<pid>`, `c<command>`, then `n<path>` lines per open file.
    static func parse(_ text: String, volume: String) -> [VolumeHolder] {
        var out: [VolumeHolder] = []
        for line in text.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let rest = String(line.dropFirst())
            switch tag {
            case "p": if let pid = Int32(rest) { out.append(VolumeHolder(pid: pid, command: "", files: [], volume: volume)) }
            case "c": if !out.isEmpty { out[out.count - 1].command = rest }
            case "n": if !out.isEmpty, rest.hasPrefix(volume) { out[out.count - 1].files.append(rest) }
            default: break
            }
        }
        return out.filter { !$0.files.isEmpty && $0.pid != getpid() }.sorted { $0.pid < $1.pid }
    }

    /// App name for a pid when it is a regular app, else the (truncated) lsof command name.
    static func displayName(_ h: VolumeHolder) -> String {
        NSRunningApplication(processIdentifier: h.pid)?.localizedName ?? h.command
    }
}
