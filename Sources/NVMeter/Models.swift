import Foundation

// MARK: - SMART

struct SMARTSnapshot: Codable, Equatable, Sendable {
    var criticalWarning: UInt8
    var temperatureC: Int
    var sensorsC: [Int]
    var availableSparePct: Int
    var availableSpareThresholdPct: Int
    var percentageUsed: Int
    var dataUnitsRead: UInt64
    var dataUnitsWritten: UInt64
    var bytesRead: UInt64
    var bytesWritten: UInt64
    var hostReadCommands: UInt64
    var hostWriteCommands: UInt64
    var controllerBusyMinutes: UInt64
    var powerCycles: UInt64
    var powerOnHours: UInt64
    var unsafeShutdowns: UInt64
    var mediaErrors: UInt64
    var errorLogEntries: UInt64
    var warningTempMinutes: UInt32
    var criticalTempMinutes: UInt32

    /// One NVMe data unit = 1000 x 512 bytes.
    var terabytesRead: Double { Double(bytesRead) / 1e12 }
    var terabytesWritten: Double { Double(bytesWritten) / 1e12 }
}

struct IdentifyInfo: Codable, Equatable, Sendable {
    var model: String
    var serial: String
    var firmware: String
    var warningTempC: Int?
    var criticalTempC: Int?
    var nvmeVersion: String?
    var pciVendorID: UInt16?
    var subsystemVendorID: UInt16?
    var namespaces: UInt32
}

// MARK: - Link / connection

struct PCIeLink: Codable, Equatable, Sendable {
    var currentGen: Int
    var currentGTs: Double
    var currentWidth: Int
    var maxGen: Int
    var maxGTs: Double
    var maxWidth: Int
    var tunnelled: Bool
    /// Approximate usable bandwidth of the current link in MB/s (decimal).
    var bandwidthMBps: Double
    var label: String { "PCIe \(currentGen).0 x\(currentWidth)" }
}

struct ConnectionInfo: Codable, Equatable, Sendable {
    /// "internal", "thunderbolt", "usb", "pcie", "other"
    var kind: String
    var summary: String
    var enclosureVendor: String?
    var enclosureModel: String?
    var mode: String?
    var linkGbps: Double?
    var firmware: String?
    /// Registry id of the enclosure's Thunderbolt switch / USB device; drives sharing it share one link.
    var enclosureID: UInt64?
    /// PCIe downstream port number of the enclosure's bridge that this drive sits behind (see Enclosure/).
    var slotPort: Int?
    /// Mac-side port, e.g. "Port 3".
    var hostPort: String?
}

struct VolumeInfo: Codable, Equatable, Sendable, Identifiable {
    var name: String
    var bsdName: String
    var mountPoint: String
    var fileSystem: String?
    var sizeBytes: UInt64
    var freeBytes: UInt64
    var id: String { bsdName }
}

// MARK: - Throughput

struct Throughput: Codable, Equatable, Sendable {
    var readMBps: Double
    var writeMBps: Double
    var readIOPS: Double
    var writeIOPS: Double
}

struct IOCounters: Codable, Equatable, Sendable {
    var bytesRead: UInt64
    var bytesWritten: UInt64
    var opsRead: UInt64
    var opsWritten: UInt64
}

// MARK: - Health

enum HealthStatus: String, Codable, Sendable, Comparable {
    case unknown, good, caution, bad
    private var rank: Int {
        switch self { case .unknown: 0; case .good: 1; case .caution: 2; case .bad: 3 }
    }
    static func < (a: HealthStatus, b: HealthStatus) -> Bool { a.rank < b.rank }
}

struct AttributeRow: Codable, Equatable, Sendable, Identifiable {
    var name: String
    var value: String
    var status: HealthStatus
    /// Rows that only describe history (e.g. time spent above warning temp) do not affect the overall badge.
    var affectsOverall: Bool = true
    var id: String { name }
}

// MARK: - Drive

/// Everything known about one physical disk at one point in time.
struct DriveSnapshot: Codable, Equatable, Sendable, Identifiable {
    var id: String            // stable across reconnects: serial (or registry id fallback)
    var bsdName: String
    var model: String
    var serial: String
    var firmware: String
    var capacityBytes: UInt64
    var interconnect: String
    var location: String
    var smartCapable: Bool
    var smartError: String?
    var identify: IdentifyInfo?
    var smart: SMARTSnapshot?
    var link: PCIeLink?
    var connection: ConnectionInfo
    var interface: String
    var volumes: [VolumeInfo]
    var counters: IOCounters
    var throughput: Throughput
    var warnings: [String]
    var health: HealthStatus
    var attributes: [AttributeRow]
    var vendor: Vendor?
    /// Set for USB disks whose reported product is a known USB-NVMe bridge chip, e.g. "Realtek RTL9201R".
    var bridgeChip: String?
    /// User-chosen name (stored by drive key in the history database).
    var customName: String?

    /// USB disk without SMART, or one that only shows its bridge chip: not a real drive model.
    var isUSBOther: Bool { connection.kind == "usb" && (bridgeChip != nil || !smartCapable) }

    var displayName: String {
        if let n = customName, !n.isEmpty { return n }
        let names = volumes.filter { !$0.name.isEmpty }.map(\.name)
        if !names.isEmpty { return names.joined(separator: ", ") }
        return isUSBOther ? "USB drive" : model
    }

    var usbSpeedText: String { connection.linkGbps.map { "USB \(Int($0)) Gb/s" } ?? "USB" }

    var subtitle: String {
        if isUSBOther {
            if let b = bridgeChip { return "via \(b) USB bridge · \(usbSpeedText)" }
            return "\(model) · \(usbSpeedText)"
        }
        return "\(model) · \(bsdName)"
    }
}
