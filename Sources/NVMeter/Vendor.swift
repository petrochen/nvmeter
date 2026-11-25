import SwiftUI
import AppKit

/// Drive vendor with optional Simple Icons artwork (CC0, bundled under Resources/Logos) and a brand colour.
struct Vendor: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let short: String
    let hex: String
    /// File name (without extension) of a bundled Simple Icons SVG; nil means "render a text badge".
    let svg: String?
}

enum VendorCatalog {
    // Brand colours of the Simple Icons vendors come from simple-icons data. The text-badge colours are approximations.
    static let all: [String: Vendor] = Dictionary(uniqueKeysWithValues: [
        Vendor(id: "apple", name: "Apple", short: "Apple", hex: "000000", svg: "apple"),
        Vendor(id: "samsung", name: "Samsung", short: "Samsung", hex: "1428A0", svg: "samsung"),
        Vendor(id: "intel", name: "Intel", short: "Intel", hex: "0071C5", svg: "intel"),
        Vendor(id: "corsair", name: "Corsair", short: "Corsair", hex: "231F20", svg: "corsair"),
        Vendor(id: "seagate", name: "Seagate", short: "Seagate", hex: "6EBE49", svg: "seagate"),
        Vendor(id: "toshiba", name: "Toshiba", short: "Toshiba", hex: "FF0000", svg: "toshiba"),
        Vendor(id: "kingston", name: "Kingston", short: "Kingston", hex: "000000", svg: "kingston"),
        // Not in Simple Icons: text badges.
        Vendor(id: "wd", name: "Western Digital", short: "WD", hex: "0061AA", svg: nil),
        Vendor(id: "wdblack", name: "WD Black", short: "WD Black", hex: "231F20", svg: nil),
        Vendor(id: "sandisk", name: "SanDisk", short: "SanDisk", hex: "ED1C24", svg: nil),
        Vendor(id: "solidigm", name: "Solidigm", short: "Solidigm", hex: "1D4ED8", svg: nil),
        Vendor(id: "crucial", name: "Crucial", short: "Crucial", hex: "D81F26", svg: nil),
        Vendor(id: "micron", name: "Micron", short: "Micron", hex: "0072BC", svg: nil),
        Vendor(id: "skhynix", name: "SK hynix", short: "SK hynix", hex: "EA002C", svg: nil),
        Vendor(id: "sabrent", name: "Sabrent", short: "Sabrent", hex: "F26522", svg: nil),
        Vendor(id: "adata", name: "ADATA", short: "ADATA", hex: "E8452C", svg: nil),
        Vendor(id: "xpg", name: "XPG", short: "XPG", hex: "00A0E9", svg: nil),
        Vendor(id: "lexar", name: "Lexar", short: "Lexar", hex: "E4002B", svg: nil),
        Vendor(id: "kioxia", name: "KIOXIA", short: "KIOXIA", hex: "D3000F", svg: nil),
        Vendor(id: "teamgroup", name: "TeamGroup", short: "TeamGroup", hex: "F58220", svg: nil),
        Vendor(id: "pny", name: "PNY", short: "PNY", hex: "00539B", svg: nil),
        Vendor(id: "hikvision", name: "Hikvision", short: "Hikvision", hex: "D3000F", svg: nil),
    ].map { ($0.id, $0) })

    /// Model-name rules win over PCI IDs because Phison-based drives (Corsair, Sabrent, ...) report the controller vendor.
    private static let modelRules: [(String, String)] = [
        ("CORSAIR", "corsair"), ("SAMSUNG", "samsung"), ("APPLE", "apple"), ("INTEL", "intel"), ("SOLIDIGM", "solidigm"),
        ("WD_BLACK", "wdblack"), ("WD BLACK", "wdblack"), ("SANDISK", "sandisk"), ("SDSS", "sandisk"),
        ("WDS", "wd"), ("WDC", "wd"), ("WD ", "wd"), ("WESTERN", "wd"),
        ("CRUCIAL", "crucial"), ("MICRON", "micron"), ("KINGSTON", "kingston"),
        ("SK HYNIX", "skhynix"), ("HFS", "skhynix"), ("HFM", "skhynix"), ("SEAGATE", "seagate"), ("FIRECUDA", "seagate"),
        ("SABRENT", "sabrent"), ("XPG", "xpg"), ("ADATA", "adata"), ("LEXAR", "lexar"), ("TOSHIBA", "toshiba"),
        ("KIOXIA", "kioxia"), ("TEAM", "teamgroup"), ("PNY", "pny"), ("HIKVISION", "hikvision"), ("HS-SSD", "hikvision"),
    ]
    private static let pciIDs: [UInt16: String] = [
        0x106B: "apple", 0x144D: "samsung", 0x15B7: "wd", 0x8086: "intel", 0x025E: "solidigm", 0x1344: "micron",
        0xC0A9: "crucial", 0x2646: "kingston", 0x1C5C: "skhynix", 0x1BB1: "seagate", 0x1CC1: "adata",
        0x1D97: "lexar", 0x1179: "toshiba", 0x1E0F: "kioxia",
    ]   // 0x1987 (Phison) is deliberately absent: it is a controller vendor, not a brand.

    static func identify(vid: UInt16?, ssvid: UInt16?, model: String) -> Vendor? {
        let m = model.uppercased()
        if let r = modelRules.first(where: { m.hasPrefix($0.0) || m.contains(" " + $0.0) }) { return all[r.1] }
        if m.range(of: "^CT\\d", options: .regularExpression) != nil { return all["crucial"] }
        for id in [ssvid, vid] {
            if let id, let key = pciIDs[id] { return all[key] }
        }
        return nil
    }

    /// Known USB-NVMe bridge chips (they hide the drive's real identity).
    static let bridges: [(token: String, vendor: String)] = [
        ("RTL9201", "Realtek"), ("RTL9210", "Realtek"), ("RTL9211", "Realtek"), ("RTL9220", "Realtek"),
        ("ASM2362", "ASMedia"), ("ASM2364", "ASMedia"), ("ASM2463", "ASMedia"), ("ASM1352", "ASMedia"), ("ASM235CM", "ASMedia"),
        ("JMS583", "JMicron"), ("JMS581", "JMicron"), ("JMS580", "JMicron"), ("JMS586", "JMicron"),
        ("VL716", "VIA Labs"), ("VL817", "VIA Labs"),
    ]

    static func bridgeChip(model: String) -> String? {
        let m = model.uppercased()
        guard let b = bridges.first(where: { m.contains($0.token) }) else { return nil }
        return "\(b.vendor) \(model.trimmingCharacters(in: .whitespaces))"
    }
}

// MARK: - Rendering

enum LogoCache {
    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]
    static func image(_ name: String) -> NSImage? {
        if let i = cache[name] { return i }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "Logos"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        cache[name] = img
        return img
    }
}

extension Vendor {
    /// Brand colour, adjusted so it keeps contrast in the current appearance (near-black brands turn light in dark mode).
    var tint: Color {
        let hexValue = UInt32(hex, radix: 16) ?? 0
        let r = CGFloat((hexValue >> 16) & 0xFF) / 255, g = CGFloat((hexValue >> 8) & 0xFF) / 255, b = CGFloat(hexValue & 0xFF) / 255
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if dark && lum < 0.25 {      // mix towards white
                let k: CGFloat = lum < 0.1 ? 0.85 : 0.55
                return NSColor(red: r + (1 - r) * k, green: g + (1 - g) * k, blue: b + (1 - b) * k, alpha: 1)
            }
            if !dark && lum > 0.75 { return NSColor.labelColor }
            return NSColor(red: r, green: g, blue: b, alpha: 1)
        })
    }
}

/// Simple Icons logo tinted with the brand colour, or a text badge for vendors it does not have.
struct VendorLogo: View {
    let vendor: Vendor?
    var height: CGFloat = 28

    var body: some View {
        Group {
            if let vendor {
                if let svg = vendor.svg, let img = LogoCache.image(svg) {
                    Image(nsImage: img).renderingMode(.template).resizable().scaledToFit().foregroundStyle(vendor.tint)
                        .padding(height * 0.12)
                } else {
                    Text(vendor.short).font(.system(size: height * 0.42, weight: .heavy, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.5).foregroundStyle(vendor.tint).padding(.horizontal, 3)
                        .background(RoundedRectangle(cornerRadius: height * 0.2).strokeBorder(vendor.tint.opacity(0.6), lineWidth: 1))
                }
            } else {
                Image(systemName: "externaldrive").resizable().scaledToFit().foregroundStyle(.secondary).padding(height * 0.15)
            }
        }
        .frame(width: height * 1.9, height: height)
        .accessibilityLabel(vendor?.name ?? "Unknown vendor")
    }
}
