import Foundation

/// Markdown export, written for pasting into forum posts and issue trackers.
enum ReportMarkdown {
    static func render(_ doc: ReportDocument) -> String {
        let df = ISO8601DateFormatter()
        var out = "# NVMeter drive report\n\n"
        out += "Generated \(df.string(from: doc.generatedAt)) by NVMeter \(doc.app.version) on \(doc.machine.model), macOS \(doc.machine.macOS)\n"
        for d in doc.drives { out += "\n" + drive(d) }
        out += "\n---\nRead-only SMART data from the NVMe health log, collected without privileges or writes to the drive.\n"
        return out
    }

    private static func esc(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|") }

    private static func drive(_ d: ReportDrive) -> String {
        var o = "## \(d.title)\n\n"
        o += "**Health: \(d.health.verdict.uppercased())**\n\n"
        for r in d.health.reasons { o += "- \(r)\n" }
        o += "\n### Drive\n\n| | |\n|---|---|\n"
        func row(_ k: String, _ v: String?) { if let v, !v.isEmpty { o += "| \(k) | \(esc(v)) |\n" } }
        row("Vendor", d.identity.vendor)
        row("Model", d.identity.model)
        row("Serial", d.identity.serial)
        row("Firmware", d.identity.firmware)
        row("Capacity", Fmt.capacity(d.identity.capacityBytes))
        row("NVMe version", d.identity.nvmeVersion)
        row("Interface", d.connection.interface)
        if let l = d.connection.link {
            row("Link", "\(l.current) (\(Int(l.currentGTs)) GT/s), drive supports \(l.max ?? "-")")
        }
        if let e = d.connection.enclosure {
            row("Enclosure", [e.vendor, e.model].compactMap { $0 }.joined(separator: " "))
            row("Enclosure firmware", e.firmware)
        }
        if let c = d.counters {
            o += "\n### Totals\n\n| | |\n|---|---|\n"
            row("Data written", String(format: "%.2f TB", c.terabytesWritten))
            row("Data read", String(format: "%.2f TB", c.terabytesRead))
            row("Power-on hours", HealthEvaluator.num(c.powerOnHours))
            row("Power cycles", HealthEvaluator.num(c.powerCycles))
            row("Unsafe shutdowns", HealthEvaluator.num(c.unsafeShutdowns))
            row("Media errors", HealthEvaluator.num(c.mediaErrors))
            row("Error log entries", HealthEvaluator.num(c.errorLogEntries))
            row("Wear (percentage used)", "\(c.percentageUsed) %")
        }
        if let t = d.temperature {
            o += "\n### Temperature\n\n| | |\n|---|---|\n"
            row("Current", "\(t.currentC) °C")
            row("Warning threshold", t.warningC.map { "\($0) °C" })
            row("Critical threshold", t.criticalC.map { "\($0) °C" })
            row("Time above warning", "\(t.minutesAboveWarning) min")
            row("Time above critical", "\(t.minutesAboveCritical) min")
            if let ch = d.charts, !ch.temperature.isEmpty {
                let v = ch.temperature.map(\.c)
                row("Recent window (\(Int(ch.windowSeconds / 60)) min)",
                    String(format: "min %.0f / avg %.1f / max %.0f °C", v.min()!, v.reduce(0, +) / Double(v.count), v.max()!))
            }
        }
        if !d.smartFields.isEmpty {
            o += "\n### SMART attributes\n\n| Attribute | Value | Status |\n|---|---|---|\n"
            for f in d.smartFields { o += "| \(esc(f.name)) | \(esc(f.value)) | \(f.status) |\n" }
        }
        if !d.volumes.isEmpty {
            o += "\n### Volumes\n\n| Volume | File system | Size | Free |\n|---|---|---|---|\n"
            for v in d.volumes {
                o += "| \(esc(v.name)) | \(v.fileSystem ?? "-") | \(Fmt.capacity(v.sizeBytes)) | \(Fmt.capacity(v.freeBytes)) |\n"
            }
        }
        return o
    }
}
