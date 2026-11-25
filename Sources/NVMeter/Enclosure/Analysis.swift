import Foundation

/// Remembers the best PCIe link each drive has ever shown, so a degraded link can be flagged ("previously seen Gen4 x1").
/// Stored in UserDefaults on this Mac only.
@MainActor
final class LinkMemory {
    static let shared = LinkMemory()
    private let key = "linkMemoryMBps"
    private var best: [String: Double]

    private init() { best = (UserDefaults.standard.dictionary(forKey: "linkMemoryMBps") as? [String: Double]) ?? [:] }

    func observe(_ drives: [DriveSnapshot]) {
        var changed = false
        for d in drives {
            guard d.connection.enclosureID != nil, let l = d.link, l.bandwidthMBps > (best[d.id] ?? 0) else { continue }
            best[d.id] = l.bandwidthMBps; changed = true
        }
        if changed { UserDefaults.standard.set(best, forKey: key) }
    }

    func bestSeen(_ id: String) -> Double? { best[id] }
}

enum LinkCheck {
    /// Why this slot's link deserves attention, or nil. A link below the drive's own maximum is normal for a
    /// shared-switch enclosure (x1 per slot), so only siblings and history count.
    @MainActor
    static func warning(for slot: EnclosureTopology.Slot, in enclosure: EnclosureTopology.Enclosure) -> String? {
        guard let l = slot.drive.link else { return nil }
        // Siblings only count where this drive could do better: a Gen3 drive next to Gen4 drives is not degraded.
        let siblings = enclosure.slots.filter { $0.id != slot.id }.compactMap { $0.drive.link }
        if let w = siblings.map(\.currentWidth).max(), l.currentWidth < w { return "Link is narrower than the other slots" }
        if let g = siblings.map(\.currentGen).max(), l.currentGen < min(g, l.maxGen) { return "Link is slower than the other slots" }
        if let seen = LinkMemory.shared.bestSeen(slot.drive.id), l.bandwidthMBps < seen * 0.99 {
            return "Link is lower than previously seen"
        }
        return nil
    }

    static func text(_ l: PCIeLink?) -> String {
        guard let l else { return "-" }
        return "Gen\(l.currentGen) x\(l.currentWidth)" + ((l.maxGen != l.currentGen || l.maxWidth != l.currentWidth)
            ? " of Gen\(l.maxGen) x\(l.maxWidth)" : "")
    }
}

struct EnclosureHints {
    var saturated = false
    var limitedSlots: [Int] = []          // slot numbers (or 0 when unknown) at their own link limit
    var limitedNames: [String] = []
}

enum EnclosureAnalysis {
    static let saturationFraction = 0.85
    static let saturationSeconds = 5
    static let slotFraction = 0.90
    /// PCIe payload efficiency: usable throughput is about 90 % of the raw lane rate (Gen4 x1 ~1.6-1.8 GB/s).
    static let pcieEfficiency = 0.90

    /// Practical per-drive ceiling in MB/s from its current PCIe link.
    static func slotCeiling(_ l: PCIeLink) -> Double { l.bandwidthMBps * pcieEfficiency }

    @MainActor
    static func hints(_ e: EnclosureTopology.Enclosure, monitor: Monitor) -> EnclosureHints {
        var h = EnclosureHints()
        // Saturation: summed read or write over the last N one-second samples all at >= 85 % of the shared budget.
        if e.budgetMBps > 0 {
            var read: [Date: Double] = [:], write: [Date: Double] = [:]
            for d in e.drives {
                for p in (monitor.rateHistory[d.id] ?? []).suffix(saturationSeconds + 2) {
                    read[p.t, default: 0] += p.read; write[p.t, default: 0] += p.write
                }
            }
            let times = read.keys.sorted().suffix(saturationSeconds)
            if times.count == saturationSeconds {
                let limit = e.budgetMBps * saturationFraction
                h.saturated = times.allSatisfy { max(read[$0] ?? 0, write[$0] ?? 0) >= limit }
            }
        }
        // Slot limit: one drive at >= 90 % of what its own link can carry for the last 3 samples.
        for s in e.slots {
            guard let l = s.drive.link else { continue }
            let limit = slotCeiling(l) * slotFraction
            let pts = (monitor.rateHistory[s.drive.id] ?? []).suffix(3)
            if pts.count == 3, pts.allSatisfy({ max($0.read, $0.write) >= limit }) {
                h.limitedSlots.append(s.number ?? 0)
                h.limitedNames.append(s.number.map { "Slot \($0)" } ?? s.drive.displayName)
            }
        }
        return h
    }
}
