import Foundation

/// Alert rules. Every rule has its own on/off switch in Settings.
enum AlertRule: String, CaseIterable, Codable, Sendable, Identifiable {
    case tempWarning, tempCritical, mediaErrors, errorLog, criticalWarning, spareLow, wear
    case linkDowngrade, usbFallback, driveRemoved, raidDegraded, driveConnected, readOnlyMount

    var id: String { rawValue }
    var key: String { "alert.rule.\(rawValue)" }

    var title: String {
        switch self {
        case .tempWarning: "Temperature near the drive's warning threshold"
        case .tempCritical: "Critical temperature reached"
        case .mediaErrors: "Media and data integrity errors increased"
        case .errorLog: "Error log entries increased"
        case .criticalWarning: "SMART critical warning flag set"
        case .spareLow: "Available spare below threshold"
        case .wear: "Wear (percentage used) crossed 80 / 90 / 100 %"
        case .linkDowngrade: "PCIe link slower than before"
        case .usbFallback: "Enclosure fell back from USB4 / Thunderbolt to USB"
        case .driveRemoved: "Drive with mounted volumes disappeared"
        case .raidDegraded: "RAID set degraded"
        case .readOnlyMount: "A drive set to always mount read-only could not be remounted"
        case .driveConnected: "Drive connected: what changed since it was last seen (unsafe shutdowns, use elsewhere, errors)"
        }
    }

    var defaultOn: Bool {
        switch self {
        case .errorLog, .driveRemoved: false   // error log grows on harmless commands; removal can be a normal eject
        default: true
        }
    }
}

enum AlertKeys {
    static let enabled = "alerts.enabled"                 // master switch for rules and events
    static let system = "alerts.systemNotifications"      // post macOS notifications
    static let tempOffset = "alerts.tempOffset"           // warn N degrees before the drive threshold
    static let menuBarTotal = "menuBar.showTotal"
    static let keepRunning = "app.keepRunningInMenuBar"
    static let hideDock = "app.alwaysHideDock"
    static let events = "alerts.events"
    static let baselines = "alerts.baselines"
    static let tbSeen = "alerts.tbSeen"
}

enum AppSettings {
    /// Must run before any view or evaluator reads the keys.
    static func registerDefaults() {
        var d: [String: Any] = [
            AlertKeys.enabled: true, AlertKeys.system: true, AlertKeys.tempOffset: 10,
            AlertKeys.menuBarTotal: false, AlertKeys.keepRunning: true, AlertKeys.hideDock: false,
        ]
        for r in AlertRule.allCases { d[r.key] = r.defaultOn }
        UserDefaults.standard.register(defaults: d)
    }
}

enum AlertSeverity: String, Codable, Sendable { case info, warning, critical }

struct AlertEvent: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    var date: Date
    var rule: AlertRule
    var severity: AlertSeverity
    var drive: String
    var title: String
    var body: String
    var driveID: String?
}
