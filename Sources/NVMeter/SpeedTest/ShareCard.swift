import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// "Share" menu: renders a result card to PNG and saves it or copies it. The cards carry drive models and numbers
/// only: no serial numbers, volume names or links.
struct ShareButton: View {
    let title: String
    let content: AnyView

    var body: some View {
        Menu {
            Button("Save Image…") { save() }
            Button("Copy Image") { copy() }
        } label: { Label("Share", systemImage: "square.and.arrow.up") }
            .menuStyle(.borderlessButton).fixedSize()
            .help("A picture of this result for a review, a forum post or a message")
    }

    @MainActor static func render(_ view: AnyView) -> NSImage? {
        let r = ImageRenderer(content: view.environment(\.colorScheme, .light))
        r.scale = 2
        return r.nsImage
    }

    @MainActor static func png(_ view: AnyView) -> Data? {
        guard let img = render(view), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func save() {
        guard let data = Self.png(content) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(title) \(Date().formatted(.iso8601.year().month().day())).png"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
    }

    private func copy() {
        guard let img = Self.render(content) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }
}

/// Common frame of a share card: header with the app name and date, content, footer.
struct ShareCardFrame<Content: View>: View {
    let subtitle: String
    let date: Date
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                if let icon = NSImage(named: "AppIcon") ?? NSApp?.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 34, height: 34).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 8 }
                }
                Text("NVMeter").font(.system(size: 26, weight: .bold, design: .rounded))
                Text(subtitle).font(.system(size: 18)).foregroundStyle(.secondary)
                Spacer()
                Text(date.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 15)).foregroundStyle(.secondary)
            }
            content
            Text("Measured with NVMeter, a free macOS monitor for SSDs and drive enclosures.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 960, alignment: .leading)
        .background(LinearGradient(colors: [Color(white: 0.98), Color(white: 0.93)], startPoint: .top, endPoint: .bottom))
    }
}

struct BigNumber: View {
    let label: String
    let value: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
            Text(value).font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
        }
    }
}

struct SpeedShareCard: View {
    let result: SpeedResult
    var body: some View {
        ShareCardFrame(subtitle: "Speed test", date: result.date) {
            Text(result.driveName).font(.system(size: 22, weight: .semibold))
            HStack(spacing: 48) {
                switch result.mode {
                case .random:
                    ForEach(result.random ?? [], id: \.queueDepth) { s in
                        BigNumber(label: s.queueDepth == 1 ? "Small files, one at a time" : "Small files, many at once",
                                  value: String(format: "%.0f/s", s.iops), tint: .blue)
                    }
                default:
                    if let w = result.write { BigNumber(label: "Write", value: Fmt.rate(w.avgMBps), tint: .orange) }
                    if let r = result.read { BigNumber(label: "Read", value: Fmt.rate(r.avgMBps), tint: .blue) }
                    if let t = result.tempMaxC { BigNumber(label: "Peak temperature", value: "\(t) °C", tint: .red) }
                }
            }
            Text(ResultCard.plain(result)).font(.system(size: 17)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct EnclosureShareCard: View {
    let result: EnclosureTestResult

    /// Findings with "slot 1 (Volume name)" shortened to "slot 1": the card never shows volume names.
    private var anonymised: [String] {
        result.scenarios.flatMap(result.findings).map { f in
            result.drives.reduce(f) { $0.replacingOccurrences(of: " (\($1.name))", with: "") }
        }
    }
    var body: some View {
        ShareCardFrame(subtitle: "Enclosure test", date: result.date) {
            Text("\(result.enclosureName) · \(result.linkText)").font(.system(size: 22, weight: .semibold))
            HStack(spacing: 48) {
                ForEach(result.scenarios.filter { $0.scenario != .heat }) { s in
                    BigNumber(label: s.scenario.title, value: String(format: "%.2f GB/s", (s.totalRead + s.totalWrite) / 1000),
                              tint: s.scenario == .writeAll ? .orange : .blue)
                }
                if let maxC = result.heat.values.compactMap(\.maxC).max() { BigNumber(label: "Hottest drive", value: "\(maxC) °C", tint: .red) }
            }
            if let best = result.scenarios.max(by: { ($0.totalRead + $0.totalWrite) < ($1.totalRead + $1.totalWrite) }) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(result.drives.filter { best.perDrive[$0.id] != nil }) { d in
                        let r = best.perDrive[d.id]!
                        HStack(spacing: 12) {
                            Text(d.slot.map { "Slot \($0)" } ?? "Drive").font(.system(size: 15, weight: .semibold)).frame(width: 64, alignment: .leading)
                            Text(d.linkText ?? "").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                            ShareBar(value: r.total, scale: max(d.ceilingMBps, r.total, 1), tint: r.write > r.read ? .orange : .blue)
                            Text(Fmt.rate(r.total)).font(.system(size: 15).monospacedDigit()).frame(width: 110, alignment: .trailing)
                        }
                    }
                    Text("\(best.scenario.title): each bar against what its slot's PCIe link can carry.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            ForEach(anonymised.prefix(3), id: \.self) { f in
                Text("• " + f).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ShareBar: View {
    let value: Double
    let scale: Double
    let tint: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(tint.gradient).frame(width: g.size.width * min(1, value / scale))
            }
        }.frame(height: 12)
    }
}
