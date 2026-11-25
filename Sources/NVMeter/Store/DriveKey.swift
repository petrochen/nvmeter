import Foundation
import IOKit

/// Stable identity of one physical drive. Persisted data is keyed by it, so a drive keeps its
/// history after reconnecting or being renumbered (disk4 -> disk6).
///
/// - Drives with a real NVMe Identify: `"<model>|<serial>"`.
/// - Drives without SMART / behind a USB bridge (model and serial belong to the bridge and are not unique):
///   `"<model>|path:<IORegistry path>"`.
enum DriveKey {
    static func make(model: String, serial: String, registryPath: String, smartCapable: Bool) -> String {
        let m = model.trimmingCharacters(in: .whitespaces)
        let s = serial.trimmingCharacters(in: .whitespaces)
        if smartCapable, !s.isEmpty { return "\(m)|\(s)" }
        return "\(m)|path:\(registryPath)"
    }

    static func registryPath(_ entry: RegEntry) -> String {
        var buf = [CChar](repeating: 0, count: 512)
        guard IORegistryEntryGetPath(entry.handle, kIOServicePlane, &buf) == KERN_SUCCESS else { return "unknown" }
        return String(cString: buf)
    }

    /// Hides the serial part of a key (for `--hide-serials`).
    static func masked(_ key: String) -> String {
        guard let i = key.lastIndex(of: "|") else { return key }
        let tail = key[key.index(after: i)...]
        return tail.hasPrefix("path:") ? key : String(key[..<i]) + "|XXXXXXXX"
    }
}
