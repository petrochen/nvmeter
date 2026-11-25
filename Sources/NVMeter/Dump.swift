import Foundation

struct DumpDocument: Codable {
    var app = "NVMeter"
    var version: String
    var generatedAt: Date
    var machine: String
    var sampleSeconds: Double
    var drives: [DriveSnapshot]
}

enum Dump {
    /// Prints one JSON document with everything known about every disk, including a ~2 s throughput sample.
    static func run() {
        let sampler = Sampler()
        _ = sampler.tick(full: true)
        let t0 = ProcessInfo.processInfo.systemUptime
        Thread.sleep(forTimeInterval: 2.0)
        let drives = sampler.tick(full: true)
        let dt = ProcessInfo.processInfo.systemUptime - t0
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let doc = DumpDocument(version: appVersion, generatedAt: Date(), machine: ProcessInfo.processInfo.hostName,
                               sampleSeconds: (dt * 100).rounded() / 100, drives: drives)
        if let data = try? enc.encode(doc) { FileHandle.standardOutput.write(data); print() }
    }
}

let appVersion = "0.1.0"
