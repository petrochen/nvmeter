import Foundation

/// Turns the 1 Hz snapshots into history rows: one sample per drive per second, one SMART snapshot per
/// drive per hour (and immediately when a drive shows up). Call from one thread only.
final class HistoryRecorder: @unchecked Sendable {
    private let store: HistoryStore
    private var lastSnapshot: [String: Double] = [:]
    private var known: Set<String> = []
    static let snapshotInterval: Double = 3600

    init(store: HistoryStore = .shared) { self.store = store }

    func ingest(_ snaps: [DriveSnapshot], refreshedSMART: Bool, now: Date = Date()) {
        let ts = Int64(now.timeIntervalSince1970)
        var pts: [SamplePoint] = []
        pts.reserveCapacity(snaps.count)
        let present = Set(snaps.map(\.id))
        for s in snaps {
            if !known.contains(s.id) { known.insert(s.id); store.noteDrive(key: s.id, model: s.model, at: ts) }
            pts.append(SamplePoint(key: s.id, ts: ts, temp: refreshedSMART ? s.temperatureC.map { Double($0) } : nil,
                                   read: s.throughput.readMBps, write: s.throughput.writeMBps))
            if let sm = s.smart, refreshedSMART, now.timeIntervalSince1970 - (lastSnapshot[s.id] ?? -.infinity) >= Self.snapshotInterval {
                lastSnapshot[s.id] = now.timeIntervalSince1970
                store.record(snapshot: Self.row(key: s.id, ts: now.timeIntervalSince1970, sm))
            }
        }
        // A drive that disappears gets an immediate snapshot when it comes back.
        for k in lastSnapshot.keys where !present.contains(k) { lastSnapshot[k] = nil }
        known.formIntersection(present)
        store.record(pts)
    }

    static func row(key: String, ts: Double, _ s: SMARTSnapshot) -> SmartRow {
        SmartRow(key: key, ts: ts.rounded(), unitsRead: s.dataUnitsRead, unitsWritten: s.dataUnitsWritten,
                 powerOnHours: s.powerOnHours, powerCycles: s.powerCycles, unsafeShutdowns: s.unsafeShutdowns,
                 mediaErrors: s.mediaErrors, errorLogEntries: s.errorLogEntries, percentageUsed: s.percentageUsed,
                 availableSpare: s.availableSparePct, warnTempMinutes: s.warningTempMinutes, critTempMinutes: s.criticalTempMinutes,
                 criticalWarning: Int(s.criticalWarning), tempC: s.temperatureC)
    }
}
