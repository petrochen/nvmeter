import Foundation

/// Turns raw SMART data into CrystalDiskInfo-style rows with a status each, and an overall badge.
enum HealthEvaluator {
    static let fallbackWarnC = 70
    static let fallbackCritC = 80

    static func num(_ v: UInt64) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = ","
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    static func tb(_ bytes: UInt64) -> String { String(format: "%.2f TB", Double(bytes) / 1e12) }

    static func hours(_ h: UInt64) -> String {
        let d = Double(h) / 24
        return d >= 1 ? "\(num(h)) h (\(String(format: "%.1f", d)) days)" : "\(num(h)) h"
    }

    static func criticalWarningText(_ w: UInt8) -> String {
        if w == 0 { return "None (0x00)" }
        let names = ["spare below threshold", "temperature", "reliability degraded", "read-only mode",
                     "volatile memory backup failed", "persistent memory region read-only"]
        let on = names.enumerated().filter { w & (1 << UInt8($0.offset)) != 0 }.map(\.element)
        return String(format: "0x%02X: ", w) + on.joined(separator: ", ")
    }

    static func tempStatus(_ t: Int, warn: Int?, crit: Int?) -> HealthStatus {
        if t >= (crit ?? fallbackCritC) { return .bad }
        if t >= (warn ?? fallbackWarnC) { return .caution }
        return .good
    }

    static func evaluate(smart s: SMARTSnapshot?, identify: IdentifyInfo?) -> (HealthStatus, [AttributeRow]) {
        guard let s else { return (.unknown, []) }
        let warn = identify?.warningTempC, crit = identify?.criticalTempC
        var rows: [AttributeRow] = []
        func add(_ n: String, _ v: String, _ st: HealthStatus = .good, overall: Bool = true) {
            rows.append(AttributeRow(name: n, value: v, status: st, affectsOverall: overall))
        }
        add("Critical Warning", criticalWarningText(s.criticalWarning), s.criticalWarning == 0 ? .good : .bad)
        add("Composite Temperature", "\(s.temperatureC) °C", tempStatus(s.temperatureC, warn: warn, crit: crit))
        for (i, t) in s.sensorsC.enumerated() {
            add("Temperature Sensor \(i + 1)", "\(t) °C", tempStatus(t, warn: warn, crit: crit))
        }
        let spareSt: HealthStatus = s.availableSparePct <= s.availableSpareThresholdPct ? .bad
            : (s.availableSparePct < 100 && s.availableSparePct <= s.availableSpareThresholdPct + 20 ? .caution : .good)
        add("Available Spare", "\(s.availableSparePct) %", spareSt)
        add("Available Spare Threshold", "\(s.availableSpareThresholdPct) %", .good, overall: false)
        add("Percentage Used (wear)", "\(s.percentageUsed) %", s.percentageUsed >= 100 ? .bad : (s.percentageUsed >= 80 ? .caution : .good))
        add("Data Units Read", "\(num(s.dataUnitsRead))  [\(tb(s.bytesRead))]")
        add("Data Units Written", "\(num(s.dataUnitsWritten))  [\(tb(s.bytesWritten))]")
        add("Host Read Commands", num(s.hostReadCommands))
        add("Host Write Commands", num(s.hostWriteCommands))
        add("Controller Busy Time", "\(num(s.controllerBusyMinutes)) min")
        add("Power Cycles", num(s.powerCycles))
        add("Power On Hours", hours(s.powerOnHours))
        add("Unsafe Shutdowns", num(s.unsafeShutdowns))
        add("Media and Data Integrity Errors", num(s.mediaErrors), s.mediaErrors > 0 ? .caution : .good)
        add("Error Information Log Entries", num(s.errorLogEntries))
        add("Warning Composite Temperature Time", "\(num(UInt64(s.warningTempMinutes))) min",
            s.warningTempMinutes > 0 ? .caution : .good, overall: false)
        add("Critical Composite Temperature Time", "\(num(UInt64(s.criticalTempMinutes))) min",
            s.criticalTempMinutes > 0 ? .caution : .good, overall: false)
        let overall = rows.filter(\.affectsOverall).map(\.status).max() ?? .good
        return (overall, rows)
    }
}
