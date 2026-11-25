import SwiftUI
import ServiceManagement

struct MenuBarSettingsSection: View {
    @AppStorage(AlertKeys.menuBarTotal) private var showTotal = false
    @AppStorage(AlertKeys.keepRunning) private var keepRunning = true
    @AppStorage(AlertKeys.hideDock) private var hideDock = false
    @State private var loginText = LoginItem.statusText
    @State private var loginOn = LoginItem.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Section("Menu bar") {
            Toggle("Show total MB/s next to the temperature", isOn: $showTotal)
            Toggle("Keep running in menu bar when window is closed", isOn: $keepRunning)
            Toggle("Always hide the Dock icon", isOn: $hideDock)
            Toggle("Launch at login", isOn: $loginOn)
                .onChange(of: loginOn) { _, on in
                    loginError = LoginItem.set(on)
                    loginText = LoginItem.statusText
                    loginOn = LoginItem.status == .enabled || LoginItem.status == .requiresApproval
                }
            HStack {
                Text("Status: \(loginText)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if LoginItem.status == .requiresApproval {
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }.font(.caption)
                }
            }
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
        }
    }
}

struct AlertSettingsSection: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage(AlertKeys.enabled) private var enabled = true
    @AppStorage(AlertKeys.system) private var system = true
    @AppStorage(AlertKeys.tempOffset) private var offset = 10

    var body: some View {
        Section("Alerts") {
            Toggle("Detect problems and record events", isOn: $enabled)
                .onChange(of: enabled) { _, on in if on { Task { await monitor.alerts.requestIfNeeded() } } }
            Toggle("Show macOS notifications", isOn: $system)
                .onChange(of: system) { _, on in if on { Task { await monitor.alerts.requestIfNeeded() } } }
                .disabled(!enabled)
            Text("macOS permission: \(monitor.alerts.authorization)").font(.caption).foregroundStyle(.secondary)
            Stepper("Warn \(offset) °C before the drive's warning threshold", value: $offset, in: 0...30)
                .disabled(!enabled)
            ForEach(AlertRule.allCases) { r in RuleToggle(rule: r).disabled(!enabled) }
            Text("Temperature alerts clear 3 °C below the trigger and do not repeat within 30 minutes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await monitor.alerts.refreshAuthorization() }
    }
}

private struct RuleToggle: View {
    let rule: AlertRule
    @AppStorage private var on: Bool
    init(rule: AlertRule) { self.rule = rule; _on = AppStorage(wrappedValue: rule.defaultOn, rule.key) }
    var body: some View { Toggle(rule.title, isOn: $on) }
}
