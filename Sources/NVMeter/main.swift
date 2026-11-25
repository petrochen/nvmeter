import Foundation

if CommandLine.arguments.contains("--dump") {
    Dump.run()
    exit(0)
}
NVMeterApp.main()
