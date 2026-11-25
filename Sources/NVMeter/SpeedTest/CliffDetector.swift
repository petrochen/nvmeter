import Foundation

/// Finds the SLC cache cliff in a write-speed series sampled every `interval` seconds.
/// Baseline = median of the first 10 s. The cliff is the first window start where the 10 s median is below
/// 70 % of the baseline and the median of everything after it stays below 70 % too.
enum CliffDetector {
    static func median(_ a: ArraySlice<Double>) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func detect(series: [Double], interval: Double = 0.5, windowSeconds: Double = 10, drop: Double = 0.7) -> CliffInfo? {
        let w = max(2, Int(windowSeconds / interval))
        guard series.count >= 2 * w else { return nil }
        let base = median(series[0..<w])
        guard base > 0 else { return nil }
        let limit = base * drop
        var i = w
        while i + w <= series.count {
            if median(series[i..<(i + w)]) < limit, median(series[i...]) < limit {
                // Refine: the slump starts right after the last fast sample around the detected window.
                var start = max(w, i - w)
                var k = min(i + w, series.count) - 1
                while k >= max(w, i - w) { if series[k] >= limit { start = k + 1; break }; k -= 1 }
                let bytesBefore = series[0..<start].reduce(0, +) * interval * 1e6
                return CliffInfo(fullSpeedGB: bytesBefore / 1e9, fullSpeedMBps: median(series[0..<start]), afterMBps: median(series[start...]))
            }
            i += 1
        }
        return nil
    }
}
