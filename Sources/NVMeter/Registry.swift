import Foundation
import IOKit

/// Thin RAII wrapper around an `io_registry_entry_t` (IOService plane).
final class RegEntry: @unchecked Sendable {
    let handle: io_registry_entry_t

    /// Takes ownership of `handle` (released in deinit).
    init(_ handle: io_registry_entry_t) { self.handle = handle }
    deinit { IOObjectRelease(handle) }

    var entryID: UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(handle, &id)
        return id
    }

    var className: String {
        var buf = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(handle, &buf)
        return String(cString: buf)
    }

    func conforms(_ cls: String) -> Bool { IOObjectConformsTo(handle, cls) != 0 }

    func property(_ key: String) -> Any? {
        guard let v = IORegistryEntryCreateCFProperty(handle, key as CFString, kCFAllocatorDefault, 0) else { return nil }
        return v.takeRetainedValue()
    }

    func string(_ key: String) -> String? { property(key) as? String }
    func int(_ key: String) -> Int? { (property(key) as? NSNumber)?.intValue }
    func uint64(_ key: String) -> UInt64? { (property(key) as? NSNumber)?.uint64Value }
    func bool(_ key: String) -> Bool? { (property(key) as? NSNumber)?.boolValue }
    func dict(_ key: String) -> [String: Any]? { property(key) as? [String: Any] }

    func parent() -> RegEntry? {
        var p: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(handle, kIOServicePlane, &p) == KERN_SUCCESS, p != 0 else { return nil }
        return RegEntry(p)
    }

    func children() -> [RegEntry] {
        var iter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(handle, kIOServicePlane, &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        var out: [RegEntry] = []
        while case let e = IOIteratorNext(iter), e != 0 { out.append(RegEntry(e)) }
        return out
    }

    /// Ancestors from nearest to farthest.
    func ancestors() -> [RegEntry] {
        var out: [RegEntry] = []
        var cur = parent()
        while let c = cur {
            out.append(c)
            cur = c.parent()
        }
        return out
    }

    /// Depth-first descendants (excluding self), bounded depth.
    func descendants(maxDepth: Int = 8) -> [RegEntry] {
        guard maxDepth > 0 else { return [] }
        var out: [RegEntry] = []
        for c in children() {
            out.append(c)
            out.append(contentsOf: c.descendants(maxDepth: maxDepth - 1))
        }
        return out
    }

    static func services(matchingClass cls: String) -> [RegEntry] {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        var out: [RegEntry] = []
        while case let e = IOIteratorNext(iter), e != 0 { out.append(RegEntry(e)) }
        return out
    }

    static func entry(withID id: UInt64) -> RegEntry? {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(id))
        return s == 0 ? nil : RegEntry(s)
    }
}
