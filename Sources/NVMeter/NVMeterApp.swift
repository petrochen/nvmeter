import SwiftUI

struct ContentView: View {
    @Environment(Monitor.self) private var monitor
    var body: some View {
        @Bindable var m = monitor
        TabView(selection: $m.tab) {
            DrivesView().tabItem { Label("Drives", systemImage: "externaldrive") }.tag(AppTab.drives)
            GraphsView().tabItem { Label("Graphs", systemImage: "chart.xyaxis.line") }.tag(AppTab.graphs)
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
            HistorySettingsSection()
        }.formStyle(.grouped).padding(20).frame(width: 440)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { HistoryStore.shared.flush() }
}

struct NVMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var monitor = Monitor()

    var body: some Scene {
        WindowGroup("NVMeter") {
            ContentView()
                .environment(monitor)
                .task {
                    ScreenshotMode.applyAppearance()
                    monitor.start()
                    await ScreenshotMode.runIfRequested(monitor)
                }
        }
        .defaultSize(width: 1100, height: 760)
        Settings { SettingsView() }
    }
}
