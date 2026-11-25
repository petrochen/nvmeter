import AppKit
import SwiftUI

/// `NVMeter --screenshot <dir>`: renders both tabs of the app's own window to PNG files and quits.
/// Used for verification without needing the Screen Recording permission.
@MainActor
enum ScreenshotMode {
    static func runIfRequested(_ monitor: Monitor) async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--screenshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(16))    // let history build up a little
        if let d = monitor.drives.first(where: { $0.connection.kind == "thunderbolt" }) { monitor.selection = d.id }
        for (tab, name) in [(AppTab.drives, "drives.png"), (AppTab.graphs, "graphs.png")] {
            monitor.tab = tab
            try? await Task.sleep(for: .seconds(2))
            snapshot(to: dir.appendingPathComponent(name))
        }
        NSApp.terminate(nil)
    }

    private static func snapshot(to url: URL) {
        guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView?.superview ?? NSApp.windows.first?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
    }
}
