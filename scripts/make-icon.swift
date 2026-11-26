#!/usr/bin/env swift
// Generates NVMeter's app icon from code (CoreGraphics only, original artwork).
// Usage (from the repo root):  swift scripts/make-icon.swift
// Writes build/AppIcon.iconset/*.png, Resources/AppIcon.icns (via iconutil) and docs/icon.png (512 px preview).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// Front panel of a four-bay enclosure with one illuminated slot.
func draw(_ ctx: CGContext, simple: Bool) {
    func panel(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat, _ color: UInt32) {
        let rect = CGRect(x: x, y: y, width: w, height: h)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(rgb(color))
        ctx.fillPath()
    }
    panel(80, 80, 864, 864, 195, 0x223932)
    panel(164, 238, 696, 548, 76, 0xE7E9D9)
    for index in 0..<4 {
        let x = CGFloat(226 + 150 * index)
        panel(x, 312, 116, 400, 28, 0x34493F)
        if index == 1 {
            panel(x + (simple ? 0 : 13), 432, simple ? 116 : 90, 245, 13, 0xF3B367)
        }
    }
}

func render(px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    draw(ctx, simple: px <= 32)
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, to url: URL) {
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil)
    precondition(CGImageDestinationFinalize(d), "could not write \(url.path)")
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
try fm.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
try fm.createDirectory(at: root.appendingPathComponent("Resources"), withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    writePNG(render(px: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(px: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
writePNG(render(px: 512), to: root.appendingPathComponent("docs/icon.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try p.run(); p.waitUntilExit()
precondition(p.terminationStatus == 0, "iconutil failed")
print("Wrote Resources/AppIcon.icns and docs/icon.png")
