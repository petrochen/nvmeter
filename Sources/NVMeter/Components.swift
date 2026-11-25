import SwiftUI

extension HealthStatus {
    var color: Color {
        switch self {
        case .good: .green
        case .caution: .orange
        case .bad: .red
        case .unknown: .gray
        }
    }
    var title: String {
        switch self {
        case .good: "Good"
        case .caution: "Caution"
        case .bad: "Bad"
        case .unknown: "Unknown"
        }
    }
}

enum Fmt {
    static func capacity(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        if b >= 1e12 { return String(format: "%.2f TB", b / 1e12) }
        if b >= 1e9 { return String(format: "%.1f GB", b / 1e9) }
        return String(format: "%.0f MB", b / 1e6)
    }
    static func rate(_ mbps: Double) -> String {
        mbps >= 100 ? String(format: "%.0f MB/s", mbps) : String(format: "%.1f MB/s", mbps)
    }
    static func temp(_ c: Int?) -> String { c.map { "\($0) °C" } ?? "-" }
}

struct StatusDot: View {
    let status: HealthStatus
    var body: some View {
        Circle().fill(status.color).frame(width: 10, height: 10)
            .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
            .accessibilityLabel(status.title)
    }
}

/// Big CrystalDiskInfo-style status tile.
struct HealthTile: View {
    let title: String
    let value: String
    let subtitle: String?
    let color: Color
    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(.white)
            if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.white.opacity(0.85)) }
        }
        .frame(width: 150, height: 96)
        .background(RoundedRectangle(cornerRadius: 12).fill(color.gradient))
    }
}

struct Card<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.headline) }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}
