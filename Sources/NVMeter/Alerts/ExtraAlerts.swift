import Foundation

/// Alert rules for ATA drives and RAID sets. Kept separate from AlertCenter's NVMe rules; it only calls `post`.
@MainActor
final class ExtraAlerts {
    static let shared = ExtraAlerts()
    private static let baselineKey = "alerts.ataBaselines"

    private var raidLast: [String: RAIDStatus] = [:]
    private var tempState: [String: (warn: Bool, crit: Bool)] = [:]
    private var baselines: [String: [String: UInt64]]
    private var failing: Set<String> = []

    private init() {
        baselines = (UserDefaults.standard.data(forKey: Self.baselineKey)
            .flatMap { try? JSONDecoder().decode([String: [String: UInt64]].self, from: $0) }) ?? [:]
    }

    private func on(_ r: AlertRule) -> Bool { UserDefaults.standard.bool(forKey: r.key) }

    func evaluate(_ snaps: [DriveSnapshot], raidSets: [RAIDSetInfo], center: AlertCenter) {
        guard UserDefaults.standard.bool(forKey: AlertKeys.enabled) else { return }
        evalRAID(raidSets, center)
        var changed = false
        for s in snaps { if let a = s.ata { evalATA(s, a, center, &changed) } }
        if changed, let d = try? JSONEncoder().encode(baselines) { UserDefaults.standard.set(d, forKey: Self.baselineKey) }
    }

    private func evalRAID(_ sets: [RAIDSetInfo], _ c: AlertCenter) {
        for set in sets where set.status != .unknown {
            let prev = raidLast[set.id]
            raidLast[set.id] = set.status
            guard on(.raidDegraded) else { continue }
            if set.status.isProblem, prev != set.status {
                let pct = set.rebuildPercent.map { " (\($0) %)" } ?? ""
                c.post(.raidDegraded, set.status == .rebuilding ? .warning : .critical, drive: set.name, driveID: nil,
                       title: "RAID set \(set.name) is \(set.status.title.lowercased())",
                       body: "\(set.level), \(set.members.count) member(s), status \(set.status.title)\(pct). Check the member drives.")
            } else if set.status == .online, let p = prev, p.isProblem {
                c.post(.raidDegraded, .info, drive: set.name, driveID: nil, title: "RAID set \(set.name) is online again",
                       body: "Status changed from \(p.title.lowercased()) to online.")
            }
        }
    }

    private func evalATA(_ s: DriveSnapshot, _ a: ATASnapshot, _ c: AlertCenter, _ changed: inout Bool) {
        let k = s.serial.isEmpty ? s.id : "\(s.model)|\(s.serial)"
        if let t = a.temperatureC, !a.standby, on(.tempWarning) || on(.tempCritical) {
            let (w, cr) = ATAHealth.thresholds(ssd: a.identity.isSSD)
            var st = tempState[k] ?? (false, false)
            if t >= cr, !st.crit, on(.tempCritical) {
                st.crit = true; st.warn = true
                c.post(.tempCritical, .critical, drive: s.displayName, driveID: s.id, title: "\(s.displayName) is at \(t) °C", body: "Critical level for this drive type is \(cr) °C.")
            } else if t >= w, !st.warn, on(.tempWarning) {
                st.warn = true
                c.post(.tempWarning, .warning, drive: s.displayName, driveID: s.id, title: "\(s.displayName) is at \(t) °C", body: "Warning level for this drive type is \(w) °C.")
            }
            if t < cr - AlertCenter.hysteresis { st.crit = false }
            if t < w - AlertCenter.hysteresis { st.warn = false }
            tempState[k] = st
        }
        if on(.criticalWarning), a.overallPassed == false, !failing.contains(k) {
            failing.insert(k)
            c.post(.criticalWarning, .critical, drive: s.displayName, driveID: s.id, title: "\(s.displayName): SMART status FAILING",
                   body: "The drive reports that an attribute passed its failure threshold. Back up the data now.")
        } else if a.overallPassed == true { failing.remove(k) }
        guard !a.attributes.isEmpty else { return }
        let now = ATAHealth.baseline(a)
        let old = baselines[k]
        baselines[k] = Dictionary(uniqueKeysWithValues: now.map { (String($0.key), $0.value) })
        if baselines[k] != old { changed = true }
        guard on(.mediaErrors), let old else { return }
        for (id, raw) in now.sorted(by: { $0.key < $1.key }) {
            if let before = old[String(id)], raw > before {
                c.post(.mediaErrors, .critical, drive: s.displayName, driveID: s.id,
                       title: "\(s.displayName): \(ATAParser.attributeName(id)) increased",
                       body: "\(id) \(ATAParser.attributeName(id)) went from \(before) to \(raw). The drive is developing bad sectors.")
            }
        }
    }
}
