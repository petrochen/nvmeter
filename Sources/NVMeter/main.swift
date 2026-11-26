import AppKit
import Foundation

// --hide-serials masks serial numbers (UI and dump) so output can be shared.
// Held in the volatile argument domain so the flag does not stick in the user's preferences.
if CommandLine.arguments.contains("--hide-serials") {
    var args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    args["hideSerials"] = true
    UserDefaults.standard.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
}

if StoreCLI.runIfRequested() { exit(0) }

if CommandLine.arguments.contains("--dump") {
    Dump.run()
    exit(0)
}
if CommandLine.arguments.contains("--test-alerts") {
    TestAlerts.run()
    exit(0)
}
if CommandLine.arguments.contains("--test-login-item") {
    LoginItem.selfTest()
    exit(0)
}
if let code = ReportCLI.handle(CommandLine.arguments) { exit(code) }
if CommandLine.arguments.contains("--speedtest") { SpeedCLI.run() }
if CommandLine.arguments.contains("--speedtest-selftest") {
    SpeedCLI.selfTest()
    exit(0)
}
if CommandLine.arguments.contains("--volume") { MountCLI.run() }
if CommandLine.arguments.contains("--mcp") { MCPServer.run() }
if CommandLine.arguments.contains("--enclosure-test") { EnclosureTestCLI.run() }

// One app instance: two would record the same history twice and double every notification.
// Screenshot mode renders its own windows and may run next to the app.
if !CommandLine.arguments.contains("--screenshot"), let id = Bundle.main.bundleIdentifier,
   let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.processIdentifier != getpid() && !$0.isTerminated }) {
    other.activate()
    FileHandle.standardError.write(Data("NVMeter is already running (pid \(other.processIdentifier)): activated it instead\n".utf8))
    exit(0)
}
NVMeterApp.main()
