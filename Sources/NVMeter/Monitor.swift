import SwiftUI
import Observation

struct TempPoint: Identifiable, Sendable { let t: Date; let c: Double; var id: Date { t } }
struct RatePoint: Identifiable, Sendable { let t: Date; let read: Double; let write: Double; var id: Date { t } }

enum AppTab: String, Hashable { case drives, graphs }

/// UI-facing state: latest snapshots plus in-memory history (v0.1: not persisted).
@MainActor @Observable
final class Monitor {
    var drives: [DriveSnapshot] = []
    var selection: String?
    var tab: AppTab = .drives
    var lastTick = Date()
    private(set) var tempHistory: [String: [TempPoint]] = [:]
    private(set) var rateHistory: [String: [RatePoint]] = [:]
    private(set) var totalHistory: [RatePoint] = []

    static let maxHistory: TimeInterval = 2 * 3600 + 60
    @ObservationIgnored private let sampler = Sampler()
    @ObservationIgnored private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        let sampler = self.sampler
        task = Task { [weak self] in
            while !Task.isCancelled {
                let d = UserDefaults.standard.double(forKey: "smartInterval")
                sampler.smartInterval = d >= 1 ? d : 5
                let snaps = await Task.detached(priority: .utility) { sampler.tick() }.value
                let refreshed = sampler.lastTickRefreshed
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
            rateHistory[s.id, default: []].append(RatePoint(t: now, read: s.throughput.readMBps, write: s.throughput.writeMBps))
            totalR += s.throughput.readMBps; totalW += s.throughput.writeMBps
            if refreshedSMART, let t = s.smart?.temperatureC {
                tempHistory[s.id, default: []].append(TempPoint(t: now, c: Double(t)))
            }
        }
        totalHistory.append(RatePoint(t: now, read: totalR, write: totalW))
        Self.trim(&totalHistory, cutoff: cutoff) { $0.t }
        for k in rateHistory.keys { Self.trim(&rateHistory[k]!, cutoff: cutoff) { $0.t } }
        for k in tempHistory.keys { Self.trim(&tempHistory[k]!, cutoff: cutoff) { $0.t } }
        if snaps != drives { drives = snaps }
        if selection == nil || !snaps.contains(where: { $0.id == selection }) { selection = snaps.first?.id }
    }

    private static func trim<T>(_ a: inout [T], cutoff: Date, time: (T) -> Date) {
        if let first = a.first, time(first) < cutoff, let i = a.firstIndex(where: { time($0) >= cutoff }) { a.removeFirst(i) }
    }

    var selected: DriveSnapshot? { drives.first { $0.id == selection } }

    // MARK: Chart helpers

    func temps(_ id: String, window: TimeInterval) -> [TempPoint] {
        let from = lastTick.addingTimeInterval(-window)
        return (tempHistory[id] ?? []).filter { $0.t >= from }
    }

    func rates(_ id: String, window: TimeInterval) -> [RatePoint] {
        Self.decimate((rateHistory[id] ?? []).filter { $0.t >= lastTick.addingTimeInterval(-window) })
    }

    func totals(window: TimeInterval) -> [RatePoint] {
        Self.decimate(totalHistory.filter { $0.t >= lastTick.addingTimeInterval(-window) })
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
