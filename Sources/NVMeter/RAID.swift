import Foundation

// MARK: - Model

enum RAIDStatus: String, Codable, Sendable {
    case online, degraded, rebuilding, offline, unknown
    var title: String {
        switch self {
        case .online: "Online"; case .degraded: "Degraded"; case .rebuilding: "Rebuilding"
        case .offline: "Offline"; case .unknown: "Unknown"
        }
    }
    var isProblem: Bool { self == .degraded || self == .rebuilding || self == .offline }
}

struct RAIDMember: Codable, Equatable, Sendable, Identifiable {
    var bsdName: String          // member partition, e.g. "disk4s2"
    var driveBSD: String?        // whole physical disk, e.g. "disk4"
    var status: String?          // as reported ("Online", "Failed", ...)
    var id: String { bsdName }
}

struct RAIDSetInfo: Codable, Equatable, Sendable, Identifiable {
    var id: String               // set UUID, falls back to name
    var name: String
    var kind: String             // "AppleRAID" or "SoftRAID"
    var level: String            // "Mirror (RAID 1)", "Stripe (RAID 0)", "Concatenated", "SoftRAID volume"
    var status: RAIDStatus
    var rebuildPercent: Int?
    var sizeBytes: UInt64
    var members: [RAIDMember]
    var bsdName: String?

    var memberDrives: [String] { members.compactMap(\.driveBSD) }
}

// MARK: - Parsers (pure, tested with synthetic dictionaries)

enum RAIDParser {
    /// "disk4s2" -> "disk4"; "disk4" -> "disk4".
    static func wholeDisk(_ bsd: String) -> String {
        guard bsd.hasPrefix("disk") else { return bsd }
        let digits = bsd.dropFirst(4).prefix { $0.isNumber }
        return "disk" + digits
    }

    static func status(_ raw: String?) -> RAIDStatus {
        guard let s = raw?.lowercased(), !s.isEmpty else { return .unknown }
        if s.contains("rebuild") || s.contains("resync") || s.contains("sync") && !s.contains("out") { return .rebuilding }
        if s.contains("degrad") { return .degraded }
        if s.contains("offline") || s.contains("fail") || s.contains("broken") { return .offline }
        if s.contains("online") || s == "ok" || s.contains("optimal") { return .online }
        return .unknown
    }

    static func level(_ raw: Any?) -> String {
        if let s = raw as? String {
            let l = s.lowercased()
            if l.contains("mirror") { return "Mirror (RAID 1)" }
            if l.contains("stripe") || l.contains("raid0") || l == "raid 0" { return "Stripe (RAID 0)" }
            if l.contains("concat") || l.contains("span") { return "Concatenated" }
            return s
        }
        if let n = (raw as? NSNumber)?.intValue {
            // kAppleRAIDStripe = 0, kAppleRAIDMirror = 1, kAppleRAIDConcat = 2 (from AppleRAID.h, unverified here).
            switch n { case 0: return "Stripe (RAID 0)"; case 1: return "Mirror (RAID 1)"; case 2: return "Concatenated"
            default: return "Level \(n)" }
        }
        return "RAID"
    }

    /// Reads an AppleRAIDSet registry property dictionary. Key names vary a little between macOS versions,
    /// so several spellings are accepted.
    static func appleSet(props p: [String: Any], bsdName: String?, sizeBytes: UInt64, members: [RAIDMember]) -> RAIDSetInfo {
        func str(_ keys: String...) -> String? { keys.compactMap { p[$0] as? String }.first }
        let uuid = str("AppleRAID-SetUUID", "AppleRAID-UUID")
        let name = str("AppleRAID-SetName", "AppleRAID-Name", "Name") ?? bsdName ?? "RAID set"
        let st = status(str("AppleRAID-SetStatus", "AppleRAID-Status", "AppleRAID-State"))
        var pct: Int?
        for k in ["AppleRAID-RebuildProgress", "AppleRAID-Rebuild-Progress", "AppleRAID-RebuildPercent"] {
            if let n = (p[k] as? NSNumber)?.intValue { pct = min(100, max(0, n)) }
        }
        return RAIDSetInfo(id: uuid ?? name, name: name, kind: "AppleRAID",
                           level: level(p["AppleRAID-LevelName"] ?? p["AppleRAID-Level"]),
                           status: st, rebuildPercent: pct, sizeBytes: sizeBytes, members: members, bsdName: bsdName)
    }

    static func appleMember(props p: [String: Any], bsdName: String) -> (setUUID: String?, member: RAIDMember) {
        let st = (p["AppleRAID-MemberStatus"] as? String) ?? (p["AppleRAID-Status"] as? String)
        return (p["AppleRAID-SetUUID"] as? String,
                RAIDMember(bsdName: bsdName, driveBSD: wholeDisk(bsdName), status: st))
    }

    /// Combines sets with their members: members are matched by set UUID.
    static func assemble(sets: [(props: [String: Any], bsd: String?, size: UInt64)],
                         members: [(setUUID: String?, member: RAIDMember)]) -> [RAIDSetInfo] {
        sets.map { s in
            let uuid = s.props["AppleRAID-SetUUID"] as? String
            let ms = members.filter { $0.setUUID != nil && $0.setUUID == uuid }.map(\.member)
                .sorted { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }
            var info = appleSet(props: s.props, bsdName: s.bsd, sizeBytes: s.size, members: ms)
            // A mirror that lists fewer healthy members than expected is degraded even if the status key is missing.
            if info.status == .unknown, ms.contains(where: { RAIDParser.status($0.status) == .offline }) { info.status = .degraded }
            return info
        }.sorted { $0.name < $1.name }
    }
}

// MARK: - Registry scan (IOKit; untested without hardware)

enum RAIDScanner {
    static func scan() -> [RAIDSetInfo] {
        var sets: [(props: [String: Any], bsd: String?, size: UInt64)] = []
        for e in RegEntry.services(matchingClass: "AppleRAIDSet") {
            var props: [String: Any] = [:]
            var cf: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(e.handle, &cf, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let d = cf?.takeRetainedValue() as? [String: Any] { props = d }
            sets.append((props, e.string("BSD Name"), e.uint64("Size") ?? 0))
        }
        var members: [(setUUID: String?, member: RAIDMember)] = []
        for e in RegEntry.services(matchingClass: "AppleRAIDMember") {
            var props: [String: Any] = [:]
            var cf: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(e.handle, &cf, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let d = cf?.takeRetainedValue() as? [String: Any] { props = d }
            let bsd = e.string("BSD Name") ?? e.ancestors().compactMap { $0.string("BSD Name") }.first
            guard let bsd else { continue }
            var m = RAIDParser.appleMember(props: props, bsdName: bsd)
            if let whole = e.ancestors().first(where: { $0.conforms("IOMedia") && $0.bool("Whole") == true })?.string("BSD Name") {
                m.member.driveBSD = whole
            }
            members.append(m)
        }
        var out = RAIDParser.assemble(sets: sets, members: members)
        out.append(contentsOf: softRAID())
        return out
    }

    /// SoftRAID (OWC): detected only by its driver objects in the registry; class names are from memory of the kext
    /// (`SoftRAIDDriver` / `SoftRAIDVolume`) and have never been verified on hardware.
    static func softRAID() -> [RAIDSetInfo] {
        let vols = RegEntry.services(matchingClass: "SoftRAIDVolume")
        if !vols.isEmpty {
            return vols.map { v in
                let bsd = v.string("BSD Name")
                let name = v.string("Name") ?? v.string("SoftRAID Volume Name") ?? bsd ?? "SoftRAID volume"
                return RAIDSetInfo(id: "softraid-\(bsd ?? name)", name: name, kind: "SoftRAID", level: "SoftRAID volume",
                                   status: .unknown, rebuildPercent: nil, sizeBytes: v.uint64("Size") ?? 0, members: [], bsdName: bsd)
            }
        }
        if !RegEntry.services(matchingClass: "SoftRAIDDriver").isEmpty {
            return [RAIDSetInfo(id: "softraid-driver", name: "SoftRAID volume", kind: "SoftRAID", level: "SoftRAID volume",
                                status: .unknown, rebuildPercent: nil, sizeBytes: 0, members: [], bsdName: nil)]
        }
        return []
    }
}
