import Foundation
import Observation
import UserNotifications

struct DriveBaseline: Codable, Equatable {
    var mediaErrors: UInt64
    var errorLog: UInt64
    var critWarn: UInt8
    var spare: Int
    var spareThr: Int
    var used: Int
    var linkGTs: Double?
    var linkWidth: Int?
}

struct TBSeen: Codable, Equatable {
    var enclosure: String
    var notified: Bool
}

/// Evaluates alert rules against every snapshot, keeps the in-app event list and posts macOS notifications.
/// Edge-triggered: rules fire when something changes, not on every tick.
@MainActor @Observable
final class AlertCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AlertCenter()

    private(set) var events: [AlertEvent] = []
    private(set) var authorization: String = "unknown"

    static let cooldown: TimeInterval = 30 * 60
    static let hysteresis = 3
    static let maxEvents = 200
    static let debounce: TimeInterval = 10

    private struct TempState { var warnActive = false, critActive = false; var lastWarn: Date?, lastCrit: Date? }
    @ObservationIgnored private var temp: [String: TempState] = [:]
    @ObservationIgnored private var baselines: [String: DriveBaseline]
    @ObservationIgnored private var tbSeen: [String: TBSeen]
    @ObservationIgnored private var linkLowSince: [String: Date] = [:]
    @ObservationIgnored private var usbSince: [String: Date] = [:]
    @ObservationIgnored private var lastSeen: [String: (name: String, mounted: Bool)] = [:]
    @ObservationIgnored private var missingSince: [String: Date] = [:]
    @ObservationIgnored private var authRequested = false

    private override init() {
        let d = UserDefaults.standard
        baselines = (d.data(forKey: AlertKeys.baselines).flatMap { try? JSONDecoder().decode([String: DriveBaseline].self, from: $0) }) ?? [:]
        tbSeen = (d.data(forKey: AlertKeys.tbSeen).flatMap { try? JSONDecoder().decode([String: TBSeen].self, from: $0) }) ?? [:]
        super.init()
        if let data = d.data(forKey: AlertKeys.events), let e = try? JSONDecoder().decode([AlertEvent].self, from: data) { events = e }
    }

    // MARK: Settings

    private func on(_ r: AlertRule) -> Bool { UserDefaults.standard.bool(forKey: r.key) }
    private var masterOn: Bool { UserDefaults.standard.bool(forKey: AlertKeys.enabled) }
    private var tempOffset: Int { UserDefaults.standard.integer(forKey: AlertKeys.tempOffset) }

    // MARK: Notification plumbing

    nonisolated static var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    func setUp() {
        guard Self.canNotify else { authorization = "unavailable (not running from an .app bundle)"; return }
        UNUserNotificationCenter.current().delegate = self
        Task { await refreshAuthorization(); if masterOn { await requestIfNeeded() } }
    }

    func refreshAuthorization() async {
        guard Self.canNotify else { return }
        let s = await UNUserNotificationCenter.current().notificationSettings()
        authorization = switch s.authorizationStatus {
        case .authorized: "allowed"
        case .denied: "denied in System Settings"
        case .notDetermined: "not asked yet"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        @unknown default: "unknown"
        }
    }

    /// Asks macOS for permission the first time notifications are enabled.
    func requestIfNeeded() async {
        guard Self.canNotify else { return }
        let c = UNUserNotificationCenter.current()
        if await c.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await c.requestAuthorization(options: [.alert, .sound])
        }
        await refreshAuthorization()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.content.userInfo["driveID"] as? String
        await MainActor.run { AppRouter.showMain(driveID: id) }
    }

    // MARK: Posting

    func clearEvents() { events = []; saveEvents() }

    private func saveEvents() {
        if let d = try? JSONEncoder().encode(events) { UserDefaults.standard.set(d, forKey: AlertKeys.events) }
    }

    @discardableResult
    func post(_ rule: AlertRule, _ sev: AlertSeverity, drive: String, driveID: String?, title: String, body: String, persist: Bool = true) -> AlertEvent {
        let ev = AlertEvent(date: Date(), rule: rule, severity: sev, drive: drive, title: title, body: body, driveID: driveID)
        if persist {
            events.insert(ev, at: 0)
            if events.count > Self.maxEvents { events.removeLast(events.count - Self.maxEvents) }
            saveEvents()
        }
        if UserDefaults.standard.bool(forKey: AlertKeys.system), Self.canNotify {
            let c = UNMutableNotificationContent()
            c.title = title; c.body = body
            c.sound = sev == .critical ? .defaultCritical : .default
            c.threadIdentifier = drive
            if let driveID { c.userInfo = ["driveID": driveID] }
            let req = UNNotificationRequest(identifier: ev.id.uuidString, content: c, trigger: nil)
            Task { await requestIfNeeded(); try? await UNUserNotificationCenter.current().add(req) }
        }
        return ev
    }

    // MARK: Evaluation

    private func key(_ s: DriveSnapshot) -> String { s.serial.isEmpty ? s.id : "\(s.model)|\(s.serial)" }

    func evaluate(_ snaps: [DriveSnapshot], now: Date = Date()) {
        guard masterOn else { return }
        var baselinesChanged = false, tbChanged = false
        let presentKeys = Set(snaps.map(key))

        for s in snaps {
            let k = key(s), name = s.displayName
            lastSeen[k] = (name, s.volumes.contains { !$0.mountPoint.isEmpty })
            missingSince[k] = nil
            if s.connection.kind == "thunderbolt" {
                let enc = Self.enclosureName(s.connection)
                if tbSeen[k] == nil || tbSeen[k]?.enclosure != enc || tbSeen[k]?.notified == true {
                    tbSeen[k] = TBSeen(enclosure: enc, notified: false); tbChanged = true
                }
            }
            if let sm = s.smart {
                evalTemperature(s, sm, k, name, now)
                evalSMART(s, sm, k, name, &baselinesChanged)
                evalLink(s, k, name, now, &baselinesChanged)
            }
            if s.isUSBOther { evalUSBFallback(s, k, name, presentKeys, now, &tbChanged) }
        }
        evalRemoval(presentKeys, now)

        if baselinesChanged, let d = try? JSONEncoder().encode(baselines) { UserDefaults.standard.set(d, forKey: AlertKeys.baselines) }
        if tbChanged, let d = try? JSONEncoder().encode(tbSeen) { UserDefaults.standard.set(d, forKey: AlertKeys.tbSeen) }
    }

    private func evalTemperature(_ s: DriveSnapshot, _ sm: SMARTSnapshot, _ k: String, _ name: String, _ now: Date) {
        let t = sm.temperatureC
        let warn = s.identify?.warningTempC ?? HealthEvaluator.fallbackWarnC
        let crit = s.identify?.criticalTempC ?? HealthEvaluator.fallbackCritC
        let trigger = warn - max(0, tempOffset)
        var st = temp[k] ?? TempState()
        defer { temp[k] = st }

        if t >= crit {
            if !st.critActive {
                st.critActive = true; st.warnActive = true
                if on(.tempCritical), st.lastCrit.map({ now.timeIntervalSince($0) >= Self.cooldown }) ?? true {
                    st.lastCrit = now
                    post(.tempCritical, .critical, drive: name, driveID: s.id, title: "\(name): critical temperature \(t) °C",
                         body: "The drive reached its critical threshold of \(crit) °C. Reduce load and check cooling.")
                }
            }
        } else if st.critActive && t <= crit - Self.hysteresis { st.critActive = false }

        if t >= trigger && !st.warnActive {
            st.warnActive = true
            if on(.tempWarning), st.lastWarn.map({ now.timeIntervalSince($0) >= Self.cooldown }) ?? true {
                st.lastWarn = now
                post(.tempWarning, .warning, drive: name, driveID: s.id, title: "\(name): \(t) °C",
                     body: "Within \(max(0, tempOffset)) °C of the drive's warning threshold (\(warn) °C).")
            }
        } else if st.warnActive && !st.critActive && t <= trigger - Self.hysteresis { st.warnActive = false }
    }

    private func evalSMART(_ s: DriveSnapshot, _ sm: SMARTSnapshot, _ k: String, _ name: String, _ changed: inout Bool) {
        let cur = DriveBaseline(mediaErrors: sm.mediaErrors, errorLog: sm.errorLogEntries, critWarn: sm.criticalWarning,
                                spare: sm.availableSparePct, spareThr: sm.availableSpareThresholdPct, used: sm.percentageUsed,
                                linkGTs: baselines[k]?.linkGTs, linkWidth: baselines[k]?.linkWidth)
        guard let b = baselines[k] else { baselines[k] = cur; changed = true; return }

        if cur.mediaErrors > b.mediaErrors, on(.mediaErrors) {
            post(.mediaErrors, .critical, drive: name, driveID: s.id, title: "\(name): media errors increased",
                 body: "Media and data integrity errors: \(b.mediaErrors) -> \(cur.mediaErrors).")
        }
        if cur.errorLog > b.errorLog, on(.errorLog) {
            post(.errorLog, .warning, drive: name, driveID: s.id, title: "\(name): new error log entries",
                 body: "Error information log entries: \(b.errorLog) -> \(cur.errorLog).")
        }
        let newFlags = cur.critWarn & ~b.critWarn
        if newFlags != 0, on(.criticalWarning) {
            post(.criticalWarning, .critical, drive: name, driveID: s.id, title: "\(name): SMART critical warning",
                 body: HealthEvaluator.criticalWarningText(newFlags))
        }
        if cur.spare <= cur.spareThr, !(b.spare <= b.spareThr), on(.spareLow) {
            post(.spareLow, .critical, drive: name, driveID: s.id, title: "\(name): available spare \(cur.spare) %",
                 body: "Spare capacity dropped to the drive's threshold of \(cur.spareThr) %.")
        }
        if let crossed = [100, 90, 80].first(where: { b.used < $0 && cur.used >= $0 }), on(.wear) {
            post(.wear, crossed >= 100 ? .critical : .warning, drive: name, driveID: s.id,
                 title: "\(name): \(cur.used) % of rated endurance used", body: "Wear crossed \(crossed) %.")
        }
        var next = cur
        // Counters only ratchet upward so a one-off bad read cannot re-arm a rule.
        next.mediaErrors = max(cur.mediaErrors, b.mediaErrors); next.errorLog = max(cur.errorLog, b.errorLog)
        next.critWarn = cur.critWarn
        next.used = max(cur.used, b.used)
        next.linkGTs = b.linkGTs; next.linkWidth = b.linkWidth
        if next != b { baselines[k] = next; changed = true }
    }

    private func evalLink(_ s: DriveSnapshot, _ k: String, _ name: String, _ now: Date, _ changed: inout Bool) {
        guard let l = s.link, var b = baselines[k] else { return }
        guard let pg = b.linkGTs, let pw = b.linkWidth else {
            b.linkGTs = l.currentGTs; b.linkWidth = l.currentWidth; baselines[k] = b; changed = true; return
        }
        let lower = l.currentGTs < pg - 0.1 || l.currentWidth < pw
        if lower {
            let since = linkLowSince[k] ?? now
            linkLowSince[k] = since
            if now.timeIntervalSince(since) >= Self.debounce {
                linkLowSince[k] = nil
                b.linkGTs = l.currentGTs; b.linkWidth = l.currentWidth; baselines[k] = b; changed = true
                if on(.linkDowngrade) {
                    post(.linkDowngrade, .warning, drive: name, driveID: s.id, title: "\(name): PCIe link downgraded",
                         body: "Now \(Self.linkText(l.currentGTs, l.currentWidth)), previously \(Self.linkText(pg, pw)).")
                }
            }
        } else {
            linkLowSince[k] = nil
            if l.currentGTs != pg || l.currentWidth != pw { b.linkGTs = l.currentGTs; b.linkWidth = l.currentWidth; baselines[k] = b; changed = true }
        }
    }

    private func evalUSBFallback(_ s: DriveSnapshot, _ k: String, _ name: String, _ present: Set<String>, _ now: Date, _ changed: inout Bool) {
        let enc = Self.enclosureName(s.connection)
        guard !enc.isEmpty else { return }
        let since = usbSince[k] ?? now
        usbSince[k] = since
        guard now.timeIntervalSince(since) >= Self.debounce else { return }
        for (tk, seen) in tbSeen where !seen.notified && !present.contains(tk) && Self.namesMatch(seen.enclosure, enc) {
            tbSeen[tk]?.notified = true; changed = true
            if on(.usbFallback) {
                post(.usbFallback, .warning, drive: name, driveID: s.id, title: "\(name): enclosure fell back to USB",
                     body: "\(enc) was seen on USB4 / Thunderbolt and is now on \(s.usbSpeedText). SMART is unavailable and speed is limited.")
            }
        }
    }

    private func evalRemoval(_ present: Set<String>, _ now: Date) {
        for (k, info) in lastSeen where !present.contains(k) {
            let since = missingSince[k] ?? now
            missingSince[k] = since
            guard now.timeIntervalSince(since) >= 3 else { continue }
            lastSeen[k] = nil; missingSince[k] = nil; temp[k] = nil
            if info.mounted, on(.driveRemoved) {
                post(.driveRemoved, .warning, drive: info.name, driveID: nil, title: "\(info.name) disappeared",
                     body: "The drive vanished while its volumes were still mounted. If you did not eject it, this was an unsafe removal.")
            }
        }
        for k in usbSince.keys where !present.contains(k) { usbSince[k] = nil }
    }

    // MARK: Helpers

    nonisolated static func enclosureName(_ c: ConnectionInfo) -> String { [c.enclosureVendor, c.enclosureModel].compactMap { $0 }.joined(separator: " ") }

    nonisolated static func namesMatch(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        return !x.isEmpty && !y.isEmpty && (x == y || x.contains(y) || y.contains(x))
    }

    nonisolated static func linkText(_ gts: Double, _ width: Int) -> String {
        let gen = gts >= 31 ? 5 : gts >= 15 ? 4 : gts >= 7 ? 3 : gts >= 4 ? 2 : 1
        return "Gen\(gen) x\(width)"
    }
}
