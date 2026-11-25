import AppKit
import SwiftUI

/// `NVMeter --screenshot <dir> [--appearance dark|light] [--warmup seconds]`
/// Renders the app's own window to PNG files (no Screen Recording permission needed) and quits.
/// Graphs are captured with a simulated hover crosshair 20 s before "now".
@MainActor
enum ScreenshotMode {
    static func value(_ flag: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static func applyAppearance() {
        switch value("--appearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    static func runIfRequested(_ monitor: Monitor) async {
        applyAppearance()
        guard let dirPath = value("--screenshot") else { return }
        let suffix = value("--appearance") ?? "light"
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let warmup = Double(value("--warmup") ?? "") ?? 60
        try? await Task.sleep(for: .seconds(warmup))        // let history build up
        let savedWindow = UserDefaults.standard.object(forKey: "graphWindow")
        if CommandLine.arguments.contains("--seed-demo") {
            DemoSeed.run(drives: monitor.drives.filter { $0.smart != nil }, store: monitor.store)
        }
        let shots: [(AppTab, (DriveSnapshot) -> Bool, String)] = [
            (.drives, { $0.connection.kind == "thunderbolt" }, "drives"),
            (.drives, { $0.isUSBOther }, "drives-usb"),
            (.drives, { $0.connection.kind == "thunderbolt" }, "enclosure"),
            (.graphs, { _ in true }, "graphs"),
            (.graphs, { _ in true }, "graphs-24h"),
            (.graphs, { _ in true }, "graphs-7d"),
            (.drives, { $0.id == worn(monitor, 0) }, "drives-usage"),          // most worn drive (carries the demo media errors)
            (.drives, { $0.id == worn(monitor, 1) }, "drives-usage-2"),
            (.speed, { _ in true }, "speedtest"),
        ]
        SpeedHistory.shared.demo = SpeedDemo.results()
        for (tab, pick, name) in shots {
            monitor.tab = tab
            monitor.scrollToUsage = false
            if name == "graphs" { UserDefaults.standard.set(300.0, forKey: "graphWindow") }
            if name == "graphs-24h" { UserDefaults.standard.set(86400.0, forKey: "graphWindow") }
            if name == "graphs-7d" { UserDefaults.standard.set(604800.0, forKey: "graphWindow") }
            if name.hasPrefix("drives-usage") { try? await Task.sleep(for: .seconds(1)); monitor.scrollToUsage = true }
            if let d = monitor.drives.first(where: pick) { monitor.selection = name == "enclosure" ? EnclosureTopology.selectionID(for: d) : d.id }
            monitor.simulatedHoverAge = tab == .graphs ? 20 : nil
            try? await Task.sleep(for: .seconds(name.hasPrefix("graphs-") || name.hasPrefix("drives-usage") ? 4 : 2))
            snapshot(to: dir.appendingPathComponent("\(name)-\(suffix).png"))
        }
        UserDefaults.standard.set(savedWindow, forKey: "graphWindow")      // do not leave the user's app on another window
        MenuBarShots.render(monitor, dir: dir, suffix: suffix)
        NSApp.terminate(nil)
    }

    private static func worn(_ m: Monitor, _ rank: Int) -> String? {
        let l = m.drives.filter { $0.smart != nil }.sorted { ($0.smart?.percentageUsed ?? 0) > ($1.smart?.percentageUsed ?? 0) }
        return l.indices.contains(rank) ? l[rank].id : nil
    }

    private static func snapshot(to url: URL) {
        guard let view = NSApp.windows.first(where: { $0.isVisible && $0.title == "NVMeter" })?.contentView?.superview ?? NSApp.windows.first?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
    }
}
