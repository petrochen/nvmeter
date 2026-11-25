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
        let shots: [(AppTab, (DriveSnapshot) -> Bool, String)] = [
            (.drives, { $0.connection.kind == "thunderbolt" }, "drives"),
            (.drives, { $0.isUSBOther }, "drives-usb"),
            (.graphs, { _ in true }, "graphs"),
        ]
        for (tab, pick, name) in shots {
            monitor.tab = tab
            if let d = monitor.drives.first(where: pick) { monitor.selection = d.id }
            monitor.simulatedHoverAge = tab == .graphs ? 20 : nil
            try? await Task.sleep(for: .seconds(2))
            snapshot(to: dir.appendingPathComponent("\(name)-\(suffix).png"))
        }
        MenuBarShots.render(monitor, dir: dir, suffix: suffix)
        NSApp.terminate(nil)
    }

    private static func snapshot(to url: URL) {
        guard let view = NSApp.windows.first(where: { $0.isVisible && $0.title == "NVMeter" })?.contentView?.superview ?? NSApp.windows.first?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
    }
}
