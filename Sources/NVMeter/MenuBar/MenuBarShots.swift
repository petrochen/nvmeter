import AppKit
import SwiftUI

/// Offscreen renders of the menu bar item and its popover for `--screenshot`.
@MainActor
enum MenuBarShots {
    static func render(_ monitor: Monitor, dir: URL, suffix: String) {
        let dark = suffix == "dark"
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!

        // Popover
        let host = NSHostingView(rootView: MenuPopover().environment(monitor).background(Color(nsColor: .windowBackgroundColor)))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = appearance
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: dir.appendingPathComponent("menubar-popover-\(suffix).png")) }
        }

        // Menu bar icon on a bar-like background, 4x.
        let h = monitor.hottest
        let icon = MenuBarIcon.image(text: monitor.menuBarText, status: h?.status ?? .unknown)
        let scale: CGFloat = 4
        let w = Int((icon.size.width + 16) * scale), ht = Int(24 * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: ht, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        (dark ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: w, height: ht).fill()
        let target = NSRect(x: 8 * scale, y: (CGFloat(ht) - icon.size.height * scale) / 2, width: icon.size.width * scale, height: icon.size.height * scale)
        if icon.isTemplate && dark {
            let t = NSImage(size: target.size, flipped: false) { r in
                icon.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
            }
            t.draw(in: target)
        } else {
            icon.draw(in: target)
        }
        NSGraphicsContext.restoreGraphicsState()
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: dir.appendingPathComponent("menubar-icon-\(suffix).png")) }
    }
}
