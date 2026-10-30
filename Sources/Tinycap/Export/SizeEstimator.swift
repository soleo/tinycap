import AVFoundation
import TinycapCore

/// Sampled file-size estimate (EX-4) for video formats: encodes two pieces of the
/// actual clip with the real exporter and scales the result to the kept length.
/// Pieces should be one keyframe interval long (see `SizeSampling`).
enum SizeEstimator {
    static func estimate(
        exporter: Exporter,
        master: URL,
        options: ExportOptions,
        pieceLength: Double,
        start: Double,
        end: Double
    ) async throws -> Int64 {
        let measured = try await sample(exporter: exporter, master: master, options: options, pieceLength: pieceLength, start: start, end: end)
        return SizeSampling.extrapolate(sampleBytes: measured.bytes, sampleSeconds: measured.seconds, totalSeconds: end - start)
    }

    /// Encodes the sample windows and returns their measured bytes.
    static func sample(
        exporter: Exporter,
        master: URL,
        options: ExportOptions,
        pieceLength: Double,
        start: Double,
        end: Double
    ) async throws -> (bytes: Int64, seconds: Double) {
        let windows = SizeSampling.windows(start: start, end: end, pieceLength: pieceLength)
        guard !windows.isEmpty else { return (0, 0) }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TinycapEstimate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var bytes: Int64 = 0
        var seconds = 0.0
        for (i, window) in windows.enumerated() {
            try Task.checkCancellation()
            let out = folder.appendingPathComponent("sample\(i)").appendingPathExtension(exporter.fileExtension)
            var piece = options
            piece.timeRange = CMTimeRange(seconds: window.lowerBound, window.upperBound)
            try await exporter.export(master: master, options: piece, to: out) { _ in }
            bytes += try await mediaBytes(of: out)
            seconds += window.upperBound - window.lowerBound
        }
        return (bytes, seconds)
    }

    /// Encoded sample bytes of a file's video and sound tracks, read as compressed
    /// samples (no decode) so the per-file container header of each piece isn't
    /// multiplied up. Formats without such tracks (GIF) use the file size.
    static func mediaBytes(of url: URL) async throws -> Int64 {
        let asset = AVURLAsset(url: url)
        var bytes: Int64 = 0
        for type in [AVMediaType.video, .audio] {
            for track in (try? await asset.loadTracks(withMediaType: type)) ?? [] {
                bytes += (try? await track.load(.totalSampleDataLength)) ?? 0
            }
        }
        guard bytes > 0 else {
            return Int64((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return bytes
    }
}
