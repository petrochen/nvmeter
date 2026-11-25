import Foundation
import UserNotifications

/// `NVMeter --test-alerts`: posts one notification per rule (not stored in the event list) and reports what macOS did.
enum TestAlerts {
    private final class Flag: @unchecked Sendable { var done = false }

    static func run() {
        let flag = Flag()
        Task { @MainActor in await go(); flag.done = true }
        while !flag.done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    }

    @MainActor private static func go() async {
        AppSettings.registerDefaults()
        let center = AlertCenter.shared
        guard AlertCenter.canNotify else {
            print("Not running from an .app bundle: UserNotifications is unavailable. Run build/NVMeter.app/Contents/MacOS/NVMeter --test-alerts")
            return
        }
        UNUserNotificationCenter.current().delegate = center
        await center.refreshAuthorization()
        print("Authorization before: \(center.authorization)")
        if center.authorization == "not asked yet" {
            print("Asking macOS for permission (answer the prompt, waiting up to 60 s) ...")
            Task { await center.requestIfNeeded() }
            for _ in 0..<600 {
                try? await Task.sleep(for: .milliseconds(100))
                await center.refreshAuthorization()
                if center.authorization != "not asked yet" { break }
            }
        }
        print("Authorization: \(center.authorization)")
        let name = "Test drive"
        let samples: [(AlertRule, AlertSeverity, String, String)] = [
            (.tempWarning, .warning, "\(name): 75 °C", "Within 10 °C of the drive's warning threshold (85 °C)."),
            (.tempCritical, .critical, "\(name): critical temperature 85 °C", "The drive reached its critical threshold of 85 °C."),
            (.mediaErrors, .critical, "\(name): media errors increased", "Media and data integrity errors: 0 -> 1."),
            (.errorLog, .warning, "\(name): new error log entries", "Error information log entries: 3 -> 5."),
            (.criticalWarning, .critical, "\(name): SMART critical warning", "0x01: spare below threshold"),
            (.spareLow, .critical, "\(name): available spare 10 %", "Spare capacity dropped to the drive's threshold of 10 %."),
            (.wear, .warning, "\(name): 80 % of rated endurance used", "Wear crossed 80 %."),
            (.linkDowngrade, .warning, "\(name): PCIe link downgraded", "Now Gen3 x1, previously Gen4 x1."),
            (.usbFallback, .warning, "\(name): enclosure fell back to USB", "Enclosure was seen on USB4 / Thunderbolt and is now on USB 10 Gb/s."),
            (.driveRemoved, .warning, "\(name) disappeared", "The drive vanished while its volumes were still mounted."),
        ]
        for (r, sev, t, b) in samples {
            center.post(r, sev, drive: name, driveID: nil, title: "[Test] \(t)", body: b, persist: false)
            print("posted \(r.rawValue)")
            try? await Task.sleep(for: .milliseconds(700))
        }
        try? await Task.sleep(for: .seconds(4))
        if AlertCenter.canNotify {
            let c = UNUserNotificationCenter.current()
            let delivered = await c.deliveredNotifications().count
            let pending = await c.pendingNotificationRequests().count
            let s = await c.notificationSettings()
            print("Delivered to Notification Center: \(delivered), pending: \(pending), alert style: \(s.alertSetting.rawValue) (2 = enabled), banner/list: \(s.notificationCenterSetting.rawValue)")
            c.removeAllDeliveredNotifications()
        }
    }
}
