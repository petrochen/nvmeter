#!/usr/bin/env swift
// Generates NVMeter's app icon from Resources/AppIcon.svg.
// Usage (from the repo root):  swift scripts/make-icon.swift
// Writes build/AppIcon.iconset/*.png, Resources/AppIcon.icns (via iconutil) and docs/icon.png (512 px preview).
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let artworkURL = URL(fileURLWithPath: "Resources/AppIcon.svg")
guard let artwork = NSImage(contentsOf: artworkURL) else { fatalError("Cannot load AppIcon.svg") }
artwork.cacheMode = .never

func render(px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    ctx.interpolationQuality = .high
    artwork.draw(in: CGRect(x: 0, y: 0, width: px, height: px))
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
