import Foundation

// Drive report: the redacted, serialisable document behind the PDF, JSON and Markdown exports.
// The JSON encoding of `ReportDocument` is the public schema (schemaVersion 1), documented in README.md.

struct ReportOptions: Sendable {
    var hideSerials = false
    var hideVolumes = false
}

struct ReportTempSample: Codable, Sendable { var t: Date; var c: Double }
struct ReportRateSample: Codable, Sendable { var t: Date; var readMBps: Double; var writeMBps: Double }

/// Recent history window. In the app it comes from the in-memory history, in the CLI from a short live sample.
struct ReportChartData: Sendable {
    var windowSeconds: Double
    var temps: [ReportTempSample]
    var rates: [ReportRateSample]
}

struct ReportDocument: Codable, Sendable {
    struct App: Codable, Sendable { var name: String; var version: String }
    struct Machine: Codable, Sendable { var model: String; var macOS: String }
    struct Options: Codable, Sendable { var serialsHidden: Bool; var volumesHidden: Bool }
    var schemaVersion = 1
    var generatedAt: Date
    var app: App
    var machine: Machine
    var options: Options
    var drives: [ReportDrive]
}

struct ReportDrive: Codable, Sendable {
    struct Identity: Codable, Sendable {
        var vendor: String?
        var model: String
        var serial: String
        var firmware: String
        var capacityBytes: UInt64
        var nvmeVersion: String?
        var bsdName: String
    }
    struct Link: Codable, Sendable {
        var current: String
        var max: String?
        var currentGTs: Double
        var currentWidth: Int
        var maxWidth: Int
        var approxBandwidthMBps: Double
    }
    struct Enclosure: Codable, Sendable {
        var vendor: String?
        var model: String?
        var firmware: String?
        var mode: String?
        var linkGbps: Double?
    }
    struct Connection: Codable, Sendable {
        var kind: String
        var interface: String
        var link: Link?
        var enclosure: Enclosure?
    }
    struct Health: Codable, Sendable {
        /// "good", "caution", "bad" or "unknown"
        var verdict: String
        var reasons: [String]
    }
    struct Field: Codable, Sendable {
        var name: String
        var value: String
        /// "good", "caution", "bad" or "unknown"
        var status: String
    }
    struct Counters: Codable, Sendable {
        var criticalWarning: Int
        var temperatureC: Int
        var availableSparePct: Int
        var availableSpareThresholdPct: Int
        var percentageUsed: Int
        var bytesRead: UInt64
        var bytesWritten: UInt64
        var terabytesRead: Double
        var terabytesWritten: Double
        var hostReadCommands: UInt64
        var hostWriteCommands: UInt64
        var controllerBusyMinutes: UInt64
        var powerCycles: UInt64
        var powerOnHours: UInt64
        var unsafeShutdowns: UInt64
        var mediaErrors: UInt64
        var errorLogEntries: UInt64
    }
    struct Temperature: Codable, Sendable {
        var currentC: Int
        var sensorsC: [Int]
        var warningC: Int?
        var criticalC: Int?
        var minutesAboveWarning: UInt32
        var minutesAboveCritical: UInt32
    }
    struct Volume: Codable, Sendable {
        var name: String
        var mountPoint: String?
        var fileSystem: String?
        var sizeBytes: UInt64
        var freeBytes: UInt64
    }
    struct Charts: Codable, Sendable {
        var windowSeconds: Double
        var temperature: [ReportTempSample]
        var throughput: [ReportRateSample]
    }
    var identity: Identity
    var connection: Connection
    var health: Health
    var smartAvailable: Bool
    var warnings: [String]
    var smartFields: [Field]
    var counters: Counters?
    var temperature: Temperature?
    var volumes: [Volume]
    var charts: Charts?

    var title: String { identity.model.isEmpty ? "Disk \(identity.bsdName)" : identity.model }
}

enum ReportBuilder {
    static let maskedSerial = "XXXXXXXX"

    static func machineInfo() -> ReportDocument.Machine {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        let model = String(cString: buf)
        return .init(model: model.isEmpty ? "unknown" : model, macOS: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    static func make(drives: [DriveSnapshot], charts: [String: ReportChartData], options: ReportOptions,
                     now: Date = Date()) -> ReportDocument {
        ReportDocument(generatedAt: now, app: .init(name: "NVMeter", version: appVersion), machine: machineInfo(),
                       options: .init(serialsHidden: options.hideSerials, volumesHidden: options.hideVolumes),
                       drives: drives.map { drive($0, charts: charts[$0.id], options: options) })
    }

    static func gb(_ v: Double) -> String { String(format: "%.0f", v) }

    static func drive(_ d: DriveSnapshot, charts: ReportChartData?, options: ReportOptions) -> ReportDrive {
        var serial = d.serial
        if options.hideSerials && !serial.isEmpty { serial = maskedSerial }
        let ident = ReportDrive.Identity(
            vendor: d.vendor?.name, model: d.isUSBOther ? (d.bridgeChip.map { "USB drive (via \($0) bridge)" } ?? d.model) : d.model,
            serial: serial, firmware: d.firmware, capacityBytes: d.capacityBytes,
            nvmeVersion: d.identify?.nvmeVersion, bsdName: d.bsdName)
        var link: ReportDrive.Link?
        if let l = d.link {
            link = .init(current: "PCIe \(l.currentGen).0 x\(l.currentWidth)", max: "PCIe \(l.maxGen).0 x\(l.maxWidth)",
                         currentGTs: l.currentGTs, currentWidth: l.currentWidth, maxWidth: l.maxWidth,
                         approxBandwidthMBps: l.bandwidthMBps)
        }
        var encl: ReportDrive.Enclosure?
        let c = d.connection
        if c.enclosureVendor != nil || c.enclosureModel != nil || c.firmware != nil || c.mode != nil {
            encl = .init(vendor: c.enclosureVendor, model: c.enclosureModel, firmware: c.firmware, mode: c.mode, linkGbps: c.linkGbps)
        }
        let conn = ReportDrive.Connection(kind: c.kind, interface: d.interface, link: link, enclosure: encl)

        // Verdict reasons: every non-good row that counts towards the badge, plus warnings.
        var reasons: [String] = []
        for a in d.attributes where a.status != .good && a.affectsOverall {
            reasons.append("\(a.name): \(a.value) (\(a.status.rawValue))")
        }
        for a in d.attributes where a.status != .good && !a.affectsOverall {
            reasons.append("\(a.name): \(a.value) (informational)")
        }
        reasons.append(contentsOf: d.warnings)
        if d.health == .good && reasons.isEmpty { reasons.append("All SMART attributes within normal limits") }
        let health = ReportDrive.Health(verdict: d.health.rawValue, reasons: reasons)

        let fields = d.attributes.map { ReportDrive.Field(name: $0.name, value: $0.value, status: $0.status.rawValue) }
        var counters: ReportDrive.Counters?
        var temp: ReportDrive.Temperature?
        if let s = d.smart {
            counters = .init(criticalWarning: Int(s.criticalWarning), temperatureC: s.temperatureC,
                             availableSparePct: s.availableSparePct, availableSpareThresholdPct: s.availableSpareThresholdPct,
                             percentageUsed: s.percentageUsed, bytesRead: s.bytesRead, bytesWritten: s.bytesWritten,
                             terabytesRead: (s.terabytesRead * 1000).rounded() / 1000,
                             terabytesWritten: (s.terabytesWritten * 1000).rounded() / 1000,
                             hostReadCommands: s.hostReadCommands, hostWriteCommands: s.hostWriteCommands,
                             controllerBusyMinutes: s.controllerBusyMinutes, powerCycles: s.powerCycles,
                             powerOnHours: s.powerOnHours, unsafeShutdowns: s.unsafeShutdowns,
                             mediaErrors: s.mediaErrors, errorLogEntries: s.errorLogEntries)
            temp = .init(currentC: s.temperatureC, sensorsC: s.sensorsC, warningC: d.identify?.warningTempC,
                         criticalC: d.identify?.criticalTempC, minutesAboveWarning: s.warningTempMinutes,
                         minutesAboveCritical: s.criticalTempMinutes)
        }
        var vols: [ReportDrive.Volume] = []
        for (i, v) in d.volumes.enumerated() {
            vols.append(.init(name: options.hideVolumes ? "Volume \(i + 1)" : v.name,
                              mountPoint: options.hideVolumes ? nil : v.mountPoint,
                              fileSystem: v.fileSystem, sizeBytes: v.sizeBytes, freeBytes: v.freeBytes))
        }
        var ch: ReportDrive.Charts?
        if let charts, !(charts.temps.isEmpty && charts.rates.isEmpty) {
            ch = .init(windowSeconds: charts.windowSeconds, temperature: downsample(charts.temps, 120) { a, b in
                ReportTempSample(t: a[a.count / 2].t, c: a.reduce(0) { $0 + $1.c } / Double(a.count)) },
                       throughput: downsample(charts.rates, 120) { a, _ in
                ReportRateSample(t: a[a.count / 2].t, readMBps: a.reduce(0) { $0 + $1.readMBps } / Double(a.count),
                                 writeMBps: a.reduce(0) { $0 + $1.writeMBps } / Double(a.count)) })
        }
        return ReportDrive(identity: ident, connection: conn, health: health, smartAvailable: d.smart != nil,
                           warnings: d.warnings, smartFields: fields, counters: counters, temperature: temp,
                           volumes: vols, charts: ch)
    }

    private static func downsample<T>(_ a: [T], _ maxCount: Int, _ merge: ([T], Int) -> T) -> [T] {
        guard a.count > maxCount else { return a }
        let stride = Int((Double(a.count) / Double(maxCount)).rounded(.up))
        return Swift.stride(from: 0, to: a.count, by: stride).map { merge(Array(a[$0..<min($0 + stride, a.count)]), 0) }
    }
}

extension ReportDocument {
    func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }
}
