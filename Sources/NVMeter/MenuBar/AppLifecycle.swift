import AppKit
import ServiceManagement
import SwiftUI

extension Notification.Name {
    static let nvmeterShowMain = Notification.Name("nvmeter.showMain")
}

enum AppRouter {
    /// Asks the menu bar label (which owns the openWindow action) to bring up the main window, optionally on a drive.
    @MainActor static func showMain(driveID: String?) {
        NotificationCenter.default.post(name: .nvmeterShowMain, object: nil, userInfo: driveID.map { ["driveID": $0] })
    }
}

/// Dock icon only while a real window is open (activation policy switching).
@MainActor
final class AppLifecycle {
    static let shared = AppLifecycle()
    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
        let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification,
                                          NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
        for n in names {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))   // willClose fires while the window is still visible
                    self?.update()
                }
            }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }

    private var hasRegularWindow: Bool {
        NSApp.windows.contains { w in
            !(w is NSPanel) && w.styleMask.contains(.titled) && (w.isVisible || w.isMiniaturized)
        }
    }

    func update() {
        let hide = UserDefaults.standard.bool(forKey: AlertKeys.hideDock)
        let want: NSApplication.ActivationPolicy = (hide || !hasRegularWindow) ? .accessory : .regular
        guard NSApp.activationPolicy() != want else { return }
        NSApp.setActivationPolicy(want)
        if want == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    func bringToFront() {
        if !UserDefaults.standard.bool(forKey: AlertKeys.hideDock) { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Launch at login through SMAppService (macOS 13+). The app is ad-hoc signed, so the status is shown rather than assumed.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var statusText: String {
        switch status {
        case .enabled: "Enabled"
        case .requiresApproval: "Requires approval in System Settings > General > Login Items"
        case .notRegistered: "Not registered"
        case .notFound: "Not supported for this build (app not found by the login item service)"
        @unknown default: "Unknown"
        }
    }

    /// Returns an error description, or nil on success.
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch { return error.localizedDescription }
    }

    /// `NVMeter --test-login-item`: registers, reads the status, unregisters again and reports each step.
    static func selfTest() {
        print("Status before: \(statusText)")
        let was = status
        if let e = set(true) { print("register() failed: \(e)") } else { print("register() succeeded") }
        print("Status after register: \(statusText)")
        if was == .notRegistered || was == .notFound {
            if let e = set(false) { print("unregister() failed: \(e)") } else { print("unregister() succeeded (left as before)") }
            print("Status after unregister: \(statusText)")
        }
    }
}
