import Foundation

// --hide-serials masks serial numbers (UI and dump) so output can be shared.
if CommandLine.arguments.contains("--hide-serials") { UserDefaults.standard.set(true, forKey: "hideSerials") }

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
NVMeterApp.main()
