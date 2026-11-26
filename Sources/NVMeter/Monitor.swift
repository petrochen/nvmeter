import SwiftUI
import Observation

struct TempPoint: Identifiable, Sendable { let t: Date; let c: Double; var id: Date { t } }
struct RatePoint: Identifiable, Sendable { let t: Date; let read: Double; let write: Double; var id: Date { t } }

enum AppTab: String, Hashable { case drives, graphs, events, speed }

/// UI-facing state: latest snapshots plus in-memory history (v0.1: not persisted).
@MainActor @Observable
final class Monitor {
    var drives: [DriveSnapshot] = []
    var raidSets: [RAIDSetInfo] = []
    var selection: String?
    var tab: AppTab = .drives
    var lastTick = Date()
    let speedRunner = SpeedTestRunner()
    let alerts = AlertCenter.shared
    /// Screenshot mode only: pretend the cursor hovers this many seconds before "now".
    var simulatedHoverAge: TimeInterval?
    /// Screenshot mode only: scroll the drive detail to "Usage & lifetime".
    var scrollToUsage = false
    private(set) var tempHistory: [String: [TempPoint]] = [:]
    private(set) var rateHistory: [String: [RatePoint]] = [:]
    private(set) var totalHistory: [RatePoint] = []

    static let maxHistory: TimeInterval = 2 * 3600 + 60
    /// Custom drive names by drive key.
    private(set) var names: [String: String] = [:]
    /// Down-sampled history from the store for the 24 h / 7 d / 30 d windows.
    private(set) var long: LongSeries?
    @ObservationIgnored let store = HistoryStore.shared
    @ObservationIgnored private lazy var recorder = HistoryRecorder(store: store)
    @ObservationIgnored private let sampler = Sampler()
    @ObservationIgnored private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        let sampler = self.sampler
        names = store.names()
        NotificationCenter.default.addObserver(forName: .nvmeterHistoryDeleted, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearMemoryHistory() }
        }
        task = Task { [weak self] in
            await self?.preload()
            while !Task.isCancelled {
                let d = UserDefaults.standard.double(forKey: "smartInterval")
                sampler.smartInterval = d >= 1 ? d : 5
                let (snaps, sets) = await Task.detached(priority: .utility) { (sampler.tick(), sampler.extras.raidSets) }.value
                let refreshed = sampler.lastTickRefreshed
                if sets != self?.raidSets { self?.raidSets = sets }
                self?.apply(snaps, refreshedSMART: refreshed)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func apply(_ snaps: [DriveSnapshot], refreshedSMART: Bool) {
        let now = Date()
        lastTick = now
        let cutoff = now.addingTimeInterval(-Self.maxHistory)
        var totalR = 0.0, totalW = 0.0
        for s in snaps {
            Self.bridgeGap(&rateHistory[s.id, default: []], now: now)
            rateHistory[s.id, default: []].append(RatePoint(t: now, read: s.throughput.readMBps, write: s.throughput.writeMBps))
            totalR += s.throughput.readMBps; totalW += s.throughput.writeMBps
            if refreshedSMART, let t = s.temperatureC {
                tempHistory[s.id, default: []].append(TempPoint(t: now, c: Double(t)))
            }
        }
        Self.bridgeGap(&totalHistory, now: now)
        totalHistory.append(RatePoint(t: now, read: totalR, write: totalW))
        Self.trim(&totalHistory, cutoff: cutoff) { $0.t }
        for k in rateHistory.keys { Self.trim(&rateHistory[k]!, cutoff: cutoff) { $0.t } }
        for k in tempHistory.keys { Self.trim(&tempHistory[k]!, cutoff: cutoff) { $0.t } }
        recorder.ingest(snaps, refreshedSMART: refreshedSMART, now: now)
        var snaps = snaps
        for i in snaps.indices { snaps[i].customName = names[snaps[i].id] }
        if snaps != drives { drives = snaps }
        alerts.evaluate(snaps, now: now)
        ExtraAlerts.shared.evaluate(snaps, raidSets: raidSets, center: alerts)
        ConnectCheck.shared.evaluate(snaps, now: now)      // before autoSnapshot: a brand new drive has no snapshot yet
        if refreshedSMART { SnapshotStore.autoSnapshot(snaps) }
        LinkMemory.shared.observe(snaps)
        if !EnclosureTopology.isValidSelection(selection, drives: snaps) { selection = snaps.first?.id }
    }

    private static func trim<T>(_ a: inout [T], cutoff: Date, time: (T) -> Date) {
        if let first = a.first, time(first) < cutoff, let i = a.firstIndex(where: { time($0) >= cutoff }) { a.removeFirst(i) }
    }

    /// Hover values at time `t` for one drive (nil id = all drives: totals and hottest temperature).
    func hoverValues(at t: Date, id: String?, window: TimeInterval) -> HoverValues {
        if let id {
            let r = Self.nearest(rates(id, window: window), t) { $0.t }
            let c = Self.nearest(tempSeries(id, window: window), t, maxGap: tempGap(window)) { $0.t }
            return HoverValues(time: r?.t ?? t, tempC: c?.c, read: r?.read, write: r?.write, hottest: false)
        }
        let r = Self.nearest(totals(window: window), t) { $0.t }
        let temps = drives.compactMap { d in Self.nearest(tempSeries(d.id, window: window), t, maxGap: tempGap(window)) { $0.t }?.c }
        return HoverValues(time: r?.t ?? t, tempC: temps.max(), read: r?.read, write: r?.write, hottest: true)
    }

    /// Nearest element by time in a time-sorted array (binary search).
    static func nearest<T>(_ a: [T], _ t: Date, maxGap: TimeInterval = .infinity, time: (T) -> Date) -> T? {
        guard !a.isEmpty else { return nil }
        var lo = 0, hi = a.count
        while lo < hi { let mid = (lo + hi) / 2; if time(a[mid]) < t { lo = mid + 1 } else { hi = mid } }
        let cands = [lo - 1, lo].filter { a.indices.contains($0) }
        let best = cands.min { abs(time(a[$0]).timeIntervalSince(t)) < abs(time(a[$1]).timeIntervalSince(t)) }!
        return abs(time(a[best]).timeIntervalSince(t)) <= maxGap ? a[best] : nil
    }

    var selected: DriveSnapshot? { drives.first { $0.id == selection } }

    // MARK: Chart helpers

    /// Windows up to 2 h come from memory (refilled from the store at launch), longer ones from the store.
    static let memoryWindow: TimeInterval = 7200

    private func tempSeries(_ id: String, window: TimeInterval) -> [TempPoint] {
        if window > Self.memoryWindow { return long?.window == window ? long?.temps[id] ?? [] : [] }
        return tempHistory[id] ?? []
    }

    private func tempGap(_ window: TimeInterval) -> TimeInterval {
        window > Self.memoryWindow ? Double(LongSeries.bucket(for: window)) * 2 : 30
    }

    func temps(_ id: String, window: TimeInterval) -> [TempPoint] {
        if window > Self.memoryWindow { return tempSeries(id, window: window) }
        let from = lastTick.addingTimeInterval(-window)
        return (tempHistory[id] ?? []).filter { $0.t >= from }
    }

    func rates(_ id: String, window: TimeInterval) -> [RatePoint] {
        if window > Self.memoryWindow { return long?.window == window ? long?.rates[id] ?? [] : [] }
        return Self.decimate((rateHistory[id] ?? []).filter { $0.t >= lastTick.addingTimeInterval(-window) })
    }

    func totals(window: TimeInterval) -> [RatePoint] {
        if window > Self.memoryWindow { return long?.window == window ? long?.totals ?? [] : [] }
        return Self.decimate(totalHistory.filter { $0.t >= lastTick.addingTimeInterval(-window) })
    }

    // MARK: Persistent history

    /// Refills the in-memory 2 h history from the store so graphs survive a restart.
    private func preload() async {
        let rows = await store.recentRaw(since: Date().addingTimeInterval(-Self.maxHistory))
        guard !rows.isEmpty else { return }
        var totalsByTS: [Int64: (Double, Double)] = [:]
        var rates: [String: [RatePoint]] = [:], temps: [String: [TempPoint]] = [:]
        for r in rows {
            let t = Date(timeIntervalSince1970: Double(r.ts))
            rates[r.key, default: []].append(RatePoint(t: t, read: r.read, write: r.write))
            if let c = r.temp { temps[r.key, default: []].append(TempPoint(t: t, c: c)) }
            let o = totalsByTS[r.ts] ?? (0, 0)
            totalsByTS[r.ts] = (o.0 + r.read, o.1 + r.write)
        }
        for (k, v) in rates { rateHistory[k] = Self.fillGaps(v, gap: 5) + (rateHistory[k] ?? []) }
        for (k, v) in temps { tempHistory[k] = v + (tempHistory[k] ?? []) }
        let tot = totalsByTS.keys.sorted().map { RatePoint(t: Date(timeIntervalSince1970: Double($0)), read: totalsByTS[$0]!.0, write: totalsByTS[$0]!.1) }
        totalHistory = Self.fillGaps(tot, gap: 5) + totalHistory
    }

    /// Loads the down-sampled series for a window longer than 2 h.
    func refreshLong(window: TimeInterval) async {
        guard window > Self.memoryWindow else { return }
        let now = Date(), b = LongSeries.bucket(for: window)
        let data = await store.series(from: now.addingTimeInterval(-window), to: now.addingTimeInterval(1), bucket: b)
        var temps: [String: [TempPoint]] = [:], rates: [String: [RatePoint]] = [:]
        var totalsByTS: [Double: (Double, Double)] = [:]
        for (k, pts) in data {
            rates[k] = Self.fillGaps(pts.map { RatePoint(t: Date(timeIntervalSince1970: $0.ts), read: $0.read, write: $0.write) }, gap: Double(b) * 2.5)
            temps[k] = pts.compactMap { p in p.temp.map { TempPoint(t: Date(timeIntervalSince1970: p.ts), c: $0) } }
            for p in pts { let o = totalsByTS[p.ts] ?? (0, 0); totalsByTS[p.ts] = (o.0 + p.read, o.1 + p.write) }
        }
        let tot = totalsByTS.keys.sorted().map { RatePoint(t: Date(timeIntervalSince1970: $0), read: totalsByTS[$0]!.0, write: totalsByTS[$0]!.1) }
        long = LongSeries(window: window, temps: temps, rates: rates, totals: Self.fillGaps(tot, gap: Double(b) * 2.5))
    }

    private func clearMemoryHistory() {
        tempHistory = [:]; rateHistory = [:]; totalHistory = []; long = nil
    }

    func rename(_ id: String, to name: String?) {
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n, !n.isEmpty { names[id] = n } else { names[id] = nil }
        store.setName(key: id, name: n)
        for i in drives.indices where drives[i].id == id { drives[i].customName = names[id] }
    }

    /// Inserts zero points at the edges of a hole so charts do not draw a line across it.
    static func fillGaps(_ pts: [RatePoint], gap: TimeInterval) -> [RatePoint] {
        var out: [RatePoint] = []
        out.reserveCapacity(pts.count)
        for p in pts {
            if let l = out.last, p.t.timeIntervalSince(l.t) > gap {
                out.append(RatePoint(t: l.t.addingTimeInterval(1), read: 0, write: 0))
                out.append(RatePoint(t: p.t.addingTimeInterval(-1), read: 0, write: 0))
            }
            out.append(p)
        }
        return out
    }

    private static func bridgeGap(_ a: inout [RatePoint], now: Date) {
        guard let l = a.last, now.timeIntervalSince(l.t) > 5 else { return }
        a.append(RatePoint(t: l.t.addingTimeInterval(1), read: 0, write: 0))
        a.append(RatePoint(t: now.addingTimeInterval(-1), read: 0, write: 0))
    }

    /// Averages into buckets so a 2 h window stays cheap to draw.
    static func decimate(_ pts: [RatePoint], maxCount: Int = 360) -> [RatePoint] {
        guard pts.count > maxCount else { return pts }
        let stride = Int((Double(pts.count) / Double(maxCount)).rounded(.up))
        return Swift.stride(from: 0, to: pts.count, by: stride).map { i in
            let chunk = pts[i..<min(i + stride, pts.count)]
            let n = Double(chunk.count)
            return RatePoint(t: chunk[chunk.startIndex + chunk.count / 2].t,
                             read: chunk.reduce(0) { $0 + $1.read } / n, write: chunk.reduce(0) { $0 + $1.write } / n)
        }
    }
}

/// Store-backed series for a window longer than the in-memory history.
struct LongSeries: Sendable {
    var window: TimeInterval
    var temps: [String: [TempPoint]]
    var rates: [String: [RatePoint]]
    var totals: [RatePoint]

    /// Bucket seconds per window: 24 h -> 5 min, 7 d -> 30 min, 30 d -> 2 h (about 300 to 360 points).
    static func bucket(for window: TimeInterval) -> Int { window <= 86400 ? 300 : (window <= 7 * 86400 ? 1800 : 7200) }
}

extension Notification.Name { static let nvmeterHistoryDeleted = Notification.Name("nvmeterHistoryDeleted") }

struct HoverValues: Sendable {
    var time: Date
    var tempC: Double?
    var read: Double?
    var write: Double?
    var hottest: Bool
}
