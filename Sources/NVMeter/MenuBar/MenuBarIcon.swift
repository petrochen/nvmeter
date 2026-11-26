import AppKit

/// Menu bar image: hottest temperature, optional throughput. Template (adapts to the menu bar) while all is fine,
/// coloured when a drive needs attention.
struct MenuBarState: Equatable, Sendable {
    var text: String
    var status: HealthStatus
}

enum MenuBarIcon {
    /// The status item is redrawn whenever it gets a new image: reuse the last one while text and status stay the same.
    @MainActor private static var last: (text: String, status: HealthStatus, image: NSImage)?

    @MainActor static func image(text: String, status: HealthStatus) -> NSImage {
        if let l = last, l.text == text, l.status == status { return l.image }
        let img = render(text: text, status: status)
        last = (text, status, img)
        return img
    }

    private static func render(text: String, status: HealthStatus) -> NSImage {
        let colored = status == .caution || status == .bad
        let color: NSColor = status == .bad ? .systemRed : .systemOrange
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colored ? color : NSColor.black]
        let str = NSAttributedString(string: text, attributes: attrs)
        let tsize = str.size()
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        let sym = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        let symW = (sym?.size.width ?? 0) + 3
        let size = NSSize(width: ceil(symW + tsize.width) + 1, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            if let sym {
                let tinted = sym.copy() as! NSImage
                tinted.lockFocus()
                (colored ? color : NSColor.black).set()
                NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
                tinted.unlockFocus()
                tinted.draw(at: NSPoint(x: 0, y: (rect.height - tinted.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
            }
            str.draw(at: NSPoint(x: symW, y: (rect.height - tsize.height) / 2))
            return true
        }
        img.isTemplate = !colored
        img.accessibilityDescription = "NVMeter: \(text)"
        return img
    }
}
