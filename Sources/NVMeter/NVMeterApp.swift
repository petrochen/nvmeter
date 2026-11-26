import SwiftUI

/// Whether the main window can be seen. SwiftUI keeps updating a closed or fully covered window's views every
/// second (measured: ~5 % CPU with the window closed), so its content is only built while it is visible.
@MainActor @Observable
final class WindowState {
    static let shared = WindowState()
    var mainVisible = true
}

struct ContentView: View {
    @Environment(Monitor.self) private var monitor
    private var windowState = WindowState.shared
    @ViewBuilder var body: some View {
        if windowState.mainVisible || CommandLine.arguments.contains("--screenshot") {
            tabs
        } else {
            Color.clear.frame(minWidth: 940, minHeight: 640)
        }
    }

    private var tabs: some View {
        @Bindable var m = monitor
        return TabView(selection: $m.tab) {
            DrivesView().tabItem { Label("Drives", systemImage: "externaldrive") }.tag(AppTab.drives)
            GraphsView().tabItem { Label("Graphs", systemImage: "chart.xyaxis.line") }.tag(AppTab.graphs)
            SpeedTestView().tabItem { Label("Speed Test", systemImage: "speedometer") }.tag(AppTab.speed)
            EventsView().tabItem { Label("Events", systemImage: "bell") }.tag(AppTab.events)
        }
        .frame(minWidth: 940, minHeight: 640)
    }
}

struct SettingsView: View {
    @AppStorage("smartInterval") private var interval: Double = 5
    @AppStorage("showDisksWithoutSMART") private var showNoSMART = true
    @AppStorage("hideSerials") private var hideSerials = false
    var body: some View {
        Form {
            Picker("SMART poll interval", selection: $interval) {
                ForEach([2.0, 5, 10, 30, 60], id: \.self) { Text("\(Int($0)) s").tag($0) }
            }
            Toggle("Show disks without SMART", isOn: $showNoSMART)
            Toggle("Hide serial numbers", isOn: $hideSerials)
            Text("Throughput is always sampled every second.").font(.caption).foregroundStyle(.secondary)
            MenuBarSettingsSection()
            DriveSettingsSection()
            AlertSettingsSection()
            HistorySettingsSection()
        }.formStyle(.grouped).frame(width: 520, height: 760)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !CommandLine.arguments.contains("--screenshot") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { LoginItem.offerOnce() } }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: AlertKeys.keepRunning)
    }
    func applicationWillTerminate(_ notification: Notification) {
        HistoryStore.shared.flush()
        MainActor.assumeIsolated { ConnectCheck.shared.save() }
    }
}

struct NVMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var monitor = Monitor()

    init() {
        AppSettings.registerDefaults()
        AlertCenter.shared.setUp()
        AppLifecycle.shared.install()
        Task.detached(priority: .utility) { SpeedEngine.cleanStale() }
    }

    var body: some Scene {
        Window("NVMeter", id: "main") {
            ContentView()
                .environment(monitor)
                .task {
                    ScreenshotMode.applyAppearance()
                    monitor.start()
                    await ScreenshotMode.runIfRequested(monitor)
                }
        }
        .defaultSize(width: 1100, height: 760)
        .commands { ReportCommands() }
        MenuBarExtra(isInserted: .constant(true)) {
            MenuPopover().environment(monitor)
        } label: {
            MenuBarLabel().environment(monitor)
        }
        .menuBarExtraStyle(.window)
        Settings { SettingsView().environment(monitor) }
    }
}
