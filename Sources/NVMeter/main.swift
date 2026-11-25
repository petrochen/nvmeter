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
NVMeterApp.main()
