import Foundation

/// Plans the sample encodes behind the live size estimate (EX-4) and scales their
/// result up to the whole clip. Sampling the real content matters: a mostly static
/// screen encodes ~10× smaller than a bitrate formula predicts.
///
/// Each piece is one keyframe interval long. A fresh encode spends extra bits right
/// after its first keyframe; a full export pays that once per interval, so pieces of
/// the same length have the same cost structure and scale proportionally. (Shorter
/// pieces measured ~2× high per second.)
public enum SizeSampling {
    public static let defaultPieces = 2

    /// `pieces` windows of `pieceLength` seconds spread over start…end. Clips no longer
    /// than ~1.25× the total sample are encoded whole, which makes their estimate exact.
    public static func windows(start: Double, end: Double, pieceLength: Double, pieces: Int = SizeSampling.defaultPieces) -> [ClosedRange<Double>] {
        let length = end - start
        guard length > 0 else { return [] }
        let n = max(pieces, 1)
        let piece = max(pieceLength, 0.1)
        if length <= piece * Double(n) * 1.25 { return [start...end] }
        return (0..<n).map { i in
            // Centers at 1/(2n), 3/(2n), … of the range, so pieces never overlap.
            let center = start + length * (Double(2 * i + 1) / Double(2 * n))
            let lo = min(max(center - piece / 2, start), end - piece)
            return lo...(lo + piece)
        }
    }

    /// Scales sampled bytes to the full length, plus one container header.
    public static func extrapolate(sampleBytes: Int64, sampleSeconds: Double, totalSeconds: Double, containerOverhead: Int64 = 4096) -> Int64 {
        guard sampleSeconds > 0, totalSeconds > 0 else { return containerOverhead }
        let perSecond = Double(sampleBytes) / sampleSeconds
        return Int64(perSecond * totalSeconds) + containerOverhead
    }
}
