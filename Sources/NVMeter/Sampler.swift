import Foundation

/// Polls the registry. Not thread safe: call `tick` from one task at a time.
final class Sampler: @unchecked Sendable {
    private let scanner = DriveScanner()
    private var prev: [UInt64: (IOCounters, TimeInterval)] = [:]
    private var rates: [UInt64: Throughput] = [:]
    private var smart: [UInt64: SMARTSnapshot] = [:]
    private var smartErrors: [UInt64: String] = [:]
    private var lastFull: TimeInterval = -.infinity

    /// Seconds between SMART / link / volume refreshes.
    var smartInterval: TimeInterval = 5
    /// True when the last `tick` refreshed SMART data.
    private(set) var lastTickRefreshed = false

    /// One 1 Hz step. Set `full` to force a SMART read right now.
    func tick(full: Bool = false) -> [DriveSnapshot] {
        let now = ProcessInfo.processInfo.systemUptime
        let changed = scanner.scan()
        let doFull = full || changed || now - lastFull >= smartInterval
        if doFull { lastFull = now }
        lastTickRefreshed = doFull

        for d in scanner.devices.values {
            if let c = d.counters() {
                if let (p, t) = prev[d.key], now > t, c.bytesRead >= p.bytesRead, c.bytesWritten >= p.bytesWritten {
                    let dt = now - t
                    rates[d.key] = Throughput(
                        readMBps: Double(c.bytesRead - p.bytesRead) / dt / 1e6,
                        writeMBps: Double(c.bytesWritten - p.bytesWritten) / dt / 1e6,
                        readIOPS: Double(c.opsRead &- p.opsRead) / dt,
                        writeIOPS: Double(c.opsWritten &- p.opsWritten) / dt)
                }
                prev[d.key] = (c, now)
            }
            if doFull {
                if !changed { scanner.refresh(d) }
                if let r = d.reader {
                    var s = r.readSMART()
                    if s == nil { s = r.readSMART() }          // one immediate retry
                    if let s { smart[d.key] = s; smartErrors[d.key] = nil }
                    else {
                        smartErrors[d.key] = String(format: "SMART read failed (0x%08x), showing last good values", UInt32(bitPattern: r.lastError))
                        lastFull = now - smartInterval + 1      // try again in about a second
                    }
                }
            }
        }
        for k in prev.keys where scanner.devices[k] == nil { prev[k] = nil; rates[k] = nil; smart[k] = nil; smartErrors[k] = nil }

        return scanner.devices.values
            .sorted { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }
            .map(snapshot)
    }

    private func snapshot(_ d: DriveDevice) -> DriveSnapshot {
        let s = smart[d.key]
        let ident = d.reader?.identify
        let (health, rows) = HealthEvaluator.evaluate(smart: s, identify: ident)
        var warnings: [String] = []
        if !d.smartCapable || d.reader == nil {
            var w = "SMART unavailable"
            if d.connection.kind == "usb", let g = d.connection.linkGbps {
                let expect = g >= 20 ? "~2 GB/s" : (g >= 10 ? "~1 GB/s" : "~450 MB/s")
                w = "Connected at USB \(Int(g)) Gb/s: SMART unavailable, expect \(expect)"
            }
            warnings.append(w)
        } else if let e = smartErrors[d.key] ?? d.smartError { warnings.append(e) }
        if let l = d.link, l.currentGen < l.maxGen {
            warnings.append("Link speed is below the drive's capability (running PCIe \(l.currentGen).0, drive supports \(l.maxGen).0)")
        }
        var snap = DriveSnapshot(
            id: d.stableID, bsdName: d.bsdName,
            model: ident?.model.isEmpty == false ? ident!.model : d.model,
            serial: d.serial,
            firmware: ident?.firmware.isEmpty == false ? ident!.firmware : d.firmware,
            capacityBytes: d.capacity, interconnect: d.interconnect, location: d.location,
            smartCapable: d.smartCapable && d.reader != nil, smartError: smartErrors[d.key] ?? d.smartError,
            identify: ident, smart: s, link: d.link, connection: d.connection, interface: "", volumes: d.volumes,
            counters: d.counters() ?? IOCounters(bytesRead: 0, bytesWritten: 0, opsRead: 0, opsWritten: 0),
            throughput: rates[d.key] ?? Throughput(readMBps: 0, writeMBps: 0, readIOPS: 0, writeIOPS: 0),
            warnings: warnings, health: health, attributes: rows,
            vendor: nil, bridgeChip: d.connection.kind == "usb" ? VendorCatalog.bridgeChip(model: d.model) : nil)
        snap.interface = snap.interfaceDescription
        if snap.bridgeChip == nil {
            snap.vendor = VendorCatalog.identify(vid: ident?.pciVendorID, ssvid: ident?.subsystemVendorID, model: snap.model)
        }
        return snap
    }
}

extension DriveSnapshot {
    /// "PCIe 4.0 x1 via USB4 40 Gb/s, OWC Express 4M2"
    var interfaceDescription: String {
        if let l = link {
            return connection.kind == "pcie" || connection.kind == "internal"
                ? "\(l.label) (\(connection.summary))" : "\(l.label) via \(connection.summary)"
        }
        return connection.kind == "internal" ? "Apple Fabric, \(connection.summary)" : connection.summary
    }
}
