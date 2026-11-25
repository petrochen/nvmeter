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

func gradient(_ stops: [(CGFloat, UInt32)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { rgb($0.1) } as CFArray, locations: stops.map { $0.0 })!
}

/// Superellipse ("squircle") path approximating the macOS icon shape.
func squircle(_ rect: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let cx = rect.midX, cy = rect.midY, a = rect.width / 2, b = rect.height / 2
    let steps = 360
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

/// Draws the icon in a 1024 x 1024 coordinate space (y up). `simple` = tiny sizes: stick outline + graph line only.
func draw(_ ctx: CGContext, simple: Bool) {
    // Big Sur icon grid: 824 px body centred in the 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(body)

    // Drop shadow + base fill.
    if !simple {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0x000000, 0.45))
        ctx.addPath(shape); ctx.setFillColor(rgb(0x10151F)); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.drawLinearGradient(gradient([(0, 0x0A0E17), (1, 0x232C40)]), start: CGPoint(x: 512, y: 100),
                           end: CGPoint(x: 512, y: 924), options: [])
    if !simple {   // soft top light (vertical fade, no hard edges)
        ctx.drawLinearGradient(CGGradient(colorsSpace: space, colors: [rgb(0x6F8FD0, 0.30), rgb(0x6F8FD0, 0.0)] as CFArray, locations: [0, 1])!,
                               start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    }

    // ---- M.2 stick (landscape), left edge = gold connector.
    let pcb = CGRect(x: 190, y: 392, width: 644, height: 236)
    let pcbPath = CGPath(roundedRect: pcb, cornerWidth: 26, cornerHeight: 26, transform: nil)
    if simple {
        ctx.setStrokeColor(rgb(0xDDE6F5)); ctx.setLineWidth(34)
        ctx.addPath(pcbPath); ctx.strokePath()
        ctx.setFillColor(rgb(0xF2C14E))
        ctx.fill(CGRect(x: pcb.minX - 10, y: pcb.minY + 40, width: 74, height: pcb.height - 80))
    } else {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: rgb(0x000000, 0.5))
        ctx.addPath(pcbPath); ctx.setFillColor(rgb(0x0E5A4A)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(pcbPath); ctx.clip()
        ctx.drawLinearGradient(gradient([(0, 0x0B4A3D), (1, 0x16806A)]), start: CGPoint(x: 0, y: pcb.minY),
                               end: CGPoint(x: 0, y: pcb.maxY), options: [])
        // gold edge connector fingers (left)
        let fingers = 11
        let fh = (pcb.height - 36) / CGFloat(fingers)
        for i in 0..<fingers {
            let y = pcb.minY + 18 + CGFloat(i) * fh
            ctx.setFillColor(rgb(0xF2C14E))
            ctx.fill(CGRect(x: pcb.minX, y: y + fh * 0.18, width: 62, height: fh * 0.64))
        }
        // key notch
        ctx.setFillColor(rgb(0x0B4A3D)); ctx.fill(CGRect(x: pcb.minX, y: pcb.midY - 5, width: 70, height: 10))
        ctx.restoreGState()
        // mounting hole on the right
        ctx.setFillColor(rgb(0x1B2335)); ctx.fillEllipse(in: CGRect(x: pcb.maxX - 62, y: pcb.midY - 24, width: 48, height: 48))
        ctx.setStrokeColor(rgb(0xF2C14E)); ctx.setLineWidth(5); ctx.strokeEllipse(in: CGRect(x: pcb.maxX - 62, y: pcb.midY - 24, width: 48, height: 48))
        // two chips: controller (small) + NAND (large)
        for (x, w) in [(CGFloat(300), CGFloat(128)), (CGFloat(452), CGFloat(236))] {
            let r = CGRect(x: x, y: pcb.minY + 52, width: w, height: pcb.height - 104)
            let rp = CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil)
            ctx.saveGState(); ctx.addPath(rp); ctx.clip()
            ctx.drawLinearGradient(gradient([(0, 0x0D1118), (1, 0x2B3447)]), start: CGPoint(x: 0, y: r.minY),
                                   end: CGPoint(x: 0, y: r.maxY), options: [])
            ctx.restoreGState()
            ctx.setStrokeColor(rgb(0x6C7A96, 0.7)); ctx.setLineWidth(3); ctx.addPath(rp); ctx.strokePath()
            ctx.setFillColor(rgb(0x8FA0BF, 0.8)); ctx.fillEllipse(in: CGRect(x: r.minX + 12, y: r.maxY - 24, width: 9, height: 9))
        }
    }

    // ---- Live graph line, cool blue -> orange -> red, over the stick.
    let pts: [CGPoint] = [(150, 330), (262, 372), (350, 345), (452, 470), (548, 438), (640, 590), (730, 560), (820, 700), (890, 664)]
        .map { CGPoint(x: $0.0, y: $0.1 + (simple ? 20 : 0)) }
    let line = CGMutablePath()
    line.move(to: pts[0])
    for i in 1..<pts.count {                      // smooth: quadratic through midpoints
        let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
        if i == 1 { line.addLine(to: mid) } else { line.addQuadCurve(to: mid, control: pts[i - 1]) }
    }
    line.addLine(to: pts.last!)
    let lw: CGFloat = simple ? 64 : 38
    let hot = gradient([(0, 0x2F9BFF), (0.45, 0x40D6E0), (0.7, 0xFF9F1C), (1, 0xFF3B30)])
    if !simple {
        // glow
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 36, color: rgb(0xFF8A1C, 0.55))
        ctx.addPath(line); ctx.setStrokeColor(rgb(0xFF9F1C, 0.01)); ctx.setLineWidth(lw); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.strokePath(); ctx.restoreGState()
    }
    // dark under-stroke for legibility over the PCB
    ctx.addPath(line); ctx.setStrokeColor(rgb(0x0A0E17, simple ? 0.0 : 0.55)); ctx.setLineWidth(lw + 14)
    ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.strokePath()
    // gradient stroke
    ctx.saveGState()
    ctx.addPath(line); ctx.setLineWidth(lw); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(hot, start: CGPoint(x: 150, y: 0), end: CGPoint(x: 890, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
    // live dot at the end
    if !simple {
        let e = pts.last!
        ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillEllipse(in: CGRect(x: e.x - 20, y: e.y - 20, width: 40, height: 40))
        ctx.setStrokeColor(rgb(0xFF3B30)); ctx.setLineWidth(10); ctx.strokeEllipse(in: CGRect(x: e.x - 20, y: e.y - 20, width: 40, height: 40))
    }
    ctx.restoreGState()

    if !simple {   // rim light
        ctx.addPath(shape); ctx.setStrokeColor(rgb(0xFFFFFF, 0.10)); ctx.setLineWidth(3); ctx.strokePath()
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
