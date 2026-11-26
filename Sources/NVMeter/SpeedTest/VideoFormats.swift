import Foundation

/// Approximate data rates of common video formats, in megabits per second.
///
/// Sources and method (all numbers approximate, real rates vary with scene, frame rate and settings):
/// - ProRes 422 Proxy / LT / 422 / HQ / 4444 / 4444 XQ: Apple "Apple ProRes White Paper", target data rates
///   at 3840x2160, 29.97 fps (145 / 328 / 471 / 707 / 1061 / 1591 Mb/s). Other frame rates scale linearly with fps,
///   8K scales with the pixel count (x4).
/// - ProRes RAW and ProRes RAW HQ: Apple ProRes RAW white paper, typical figures at UHD 30 fps (scene dependent).
/// - Blackmagic RAW 3:1 / 12:1 / Q0: Blackmagic Design "Blackmagic RAW speed and size calculator" figures,
///   scaled from 6K (6144x3456) 24 fps by pixel count and frame rate. Q0 sits between 3:1 and 2:1.
/// - H.265 10-bit 4K60: typical camera bit rates (Sony, Canon, Panasonic, iPhone), 150 to 400 Mb/s.
/// - Uncompressed 10-bit 4:2:2: computed exactly (width x height x 2 samples x 10 bit x fps).
struct VideoFormat: Identifiable, Sendable {
    var id: String { name }
    var name: String
    var family: String
    var mbps: Double
    var note: String?
    /// Required rate in MB/s (decimal).
    var mBps: Double { mbps / 8 }
}

enum VideoFormats {
    private static let uhdPixels = 3840.0 * 2160
    private static let k6Pixels = 6144.0 * 3456
    private static let k8Pixels = 8192.0 * 4320

    /// Scaled from a UHD 29.97 fps base rate.
    private static func prores(_ name: String, _ base: Double, fps: Double, k8: Bool = false) -> VideoFormat {
        let res = k8 ? "8K" : "4K"
        let r = base * (fps / 30) * (k8 ? (7680.0 * 4320) / uhdPixels : 1)
        return VideoFormat(name: "\(name) \(res)\(Int(fps))", family: "ProRes", mbps: r, note: k8 ? "scaled by pixel count" : (fps == 60 ? "scaled by fps" : nil))
    }

    private static func braw(_ name: String, _ ratio: Double, k8: Bool, fps: Double = 24) -> VideoFormat {
        let pixels = k8 ? k8Pixels : k6Pixels
        let r = ratio * (pixels / k6Pixels) * (fps / 24)
        return VideoFormat(name: "BRAW \(name) \(k8 ? "8K" : "6K")\(Int(fps))", family: "BRAW", mbps: r, note: "scaled from 6K 24p")
    }

    static let all: [VideoFormat] = {
        let pr: [(String, Double)] = [("ProRes 422 Proxy", 145), ("ProRes 422 LT", 328), ("ProRes 422", 471),
                                      ("ProRes 422 HQ", 707), ("ProRes 4444", 1061), ("ProRes 4444 XQ", 1591)]
        var f: [VideoFormat] = []
        for (n, b) in pr { f.append(prores(n, b, fps: 30)) }
        for (n, b) in pr { f.append(prores(n, b, fps: 60)) }
        for (n, b) in pr { f.append(prores(n, b, fps: 30, k8: true)) }
        f.append(VideoFormat(name: "ProRes RAW 4K30", family: "ProRes RAW", mbps: 800, note: "typical, scene dependent"))
        f.append(VideoFormat(name: "ProRes RAW HQ 4K30", family: "ProRes RAW", mbps: 1200, note: "typical, scene dependent"))
        f.append(VideoFormat(name: "ProRes RAW 4K60", family: "ProRes RAW", mbps: 1600, note: "scaled by fps"))
        f.append(VideoFormat(name: "ProRes RAW HQ 8K30", family: "ProRes RAW", mbps: 4800, note: "scaled by pixel count"))
        // Blackmagic RAW base values at 6K 24p (Mb/s): 12:1 about 530, 3:1 about 2130, Q0 about 2600.
        for (n, r) in [("12:1", 530.0), ("3:1", 2130.0), ("Q0", 2600.0)] {
            f.append(braw(n, r, k8: false))
            f.append(braw(n, r, k8: true))
        }
        f.append(VideoFormat(name: "H.265 10-bit 4K60 (150 Mb/s)", family: "H.265", mbps: 150, note: "low camera setting"))
        f.append(VideoFormat(name: "H.265 10-bit 4K60 (400 Mb/s)", family: "H.265", mbps: 400, note: "high camera setting"))
        f.append(VideoFormat(name: "Uncompressed 10-bit 4:2:2 4K30", family: "Uncompressed", mbps: uhdPixels * 2 * 10 * 30 / 1e6, note: "computed"))
        f.append(VideoFormat(name: "Uncompressed 10-bit 4:2:2 4K60", family: "Uncompressed", mbps: uhdPixels * 2 * 10 * 60 / 1e6, note: "computed"))
        return f
    }()
}

/// Measured speeds feeding the verdict.
struct VerdictInput: Sendable {
    var writeMBps: Double?
    var readMBps: Double?
    var writeSource: String
    var readSource: String
}

enum Verdict {
    static func streams(_ measured: Double?, _ f: VideoFormat) -> Int? {
        guard let m = measured, m > 0 else { return nil }
        return Int((m / f.mBps).rounded(.down))
    }

    /// Picks the most relevant measurements for one drive from its history (newest first).
    static func input(from history: [SpeedResult]) -> VerdictInput? {
        let sustained = history.first { $0.mode == .sustained && !$0.cancelled && $0.write != nil }
        let quick = history.first { ($0.mode == .quick || $0.mode == .live) && !$0.cancelled && $0.write != nil }
        var w: Double?, ws = ""
        if let s = sustained {
            w = s.cliff?.afterMBps ?? s.write?.avgMBps
            ws = s.cliff != nil ? "sustained write after the cache cliff" : "sustained write (no cliff seen)"
        } else if let q = quick {
            w = q.write?.avgMBps; ws = q.mode == .live ? "live loop write" : "quick write"
        }
        let r = quick?.read?.avgMBps
        guard w != nil || r != nil else { return nil }
        return VerdictInput(writeMBps: w, readMBps: r, writeSource: ws, readSource: quick?.mode == .live ? "live loop read" : "quick read")
    }
}

/// "Will it work?" grid: one codec at common resolutions and frame rates.
enum FormatGrid {
    struct Resolution: Identifiable, Sendable { var name: String; var width: Double; var height: Double; var id: String { name } }
    struct Codec: Identifiable, Sendable {
        var name: String
        /// Mb/s per pixel per frame.
        var bitsPerPixelFrame: Double
        var id: String { name }
        func mBps(_ r: Resolution, fps: Double) -> Double { bitsPerPixelFrame * r.width * r.height * fps / 8 }
    }

    static let resolutions = [
        Resolution(name: "HD", width: 1920, height: 1080), Resolution(name: "4K UHD", width: 3840, height: 2160),
        Resolution(name: "6K", width: 6144, height: 3456), Resolution(name: "8K", width: 7680, height: 4320),
    ]
    static let frameRates: [Double] = [24, 25, 30, 50, 60]

    private static let uhdFrame = 3840.0 * 2160 * 29.97
    private static let k6Frame = 6144.0 * 3456 * 24
    /// Same sources as `VideoFormats`: ProRes from Apple's UHD 29.97 targets, BRAW from 6K 24p, uncompressed computed.
    static let codecs: [Codec] = [
        Codec(name: "ProRes 422 LT", bitsPerPixelFrame: 328 / uhdFrame),
        Codec(name: "ProRes 422", bitsPerPixelFrame: 471 / uhdFrame),
        Codec(name: "ProRes 422 HQ", bitsPerPixelFrame: 707 / uhdFrame),
        Codec(name: "ProRes 4444", bitsPerPixelFrame: 1061 / uhdFrame),
        Codec(name: "ProRes 4444 XQ", bitsPerPixelFrame: 1591 / uhdFrame),
        Codec(name: "BRAW 12:1", bitsPerPixelFrame: 530 / k6Frame),
        Codec(name: "BRAW 3:1", bitsPerPixelFrame: 2130 / k6Frame),
        Codec(name: "Uncompressed 10-bit 4:2:2", bitsPerPixelFrame: 20 / 1e6),
    ]
}
