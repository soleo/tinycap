import AVFoundation
import TinycapCore

/// Live file-size estimate (EX-4): encodes two keyframe-interval-long pieces of the
/// actual clip with the real exporter and scales the result to the kept length.
/// Works for any `Exporter`.
enum SizeEstimator {
    static func estimate(
        exporter: Exporter,
        master: URL,
        settings: ExportSettings,
        start: Double,
        end: Double
    ) async throws -> Int64 {
        let measured = try await sample(exporter: exporter, master: master, settings: settings, start: start, end: end)
        return SizeSampling.extrapolate(sampleBytes: measured.bytes, sampleSeconds: measured.seconds, totalSeconds: end - start)
    }

    /// Encodes the sample windows and returns their measured bytes.
    static func sample(
        exporter: Exporter,
        master: URL,
        settings: ExportSettings,
        start: Double,
        end: Double
    ) async throws -> (bytes: Int64, seconds: Double) {
        let windows = SizeSampling.windows(start: start, end: end, pieceLength: exporter.samplePieceLength)
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
            let range = CMTimeRange(
                start: CMTime(seconds: window.lowerBound, preferredTimescale: 600),
                end: CMTime(seconds: window.upperBound, preferredTimescale: 600)
            )
            try await exporter.export(master: master, options: ExportOptions(timeRange: range, settings: settings), to: out) { _ in }
            bytes += try await mediaBytes(of: out)
            seconds += window.upperBound - window.lowerBound
        }
        return (bytes, seconds)
    }

    /// Encoded frame bytes of a file, read as compressed samples (no decode) so the
    /// per-file container header of each piece isn't multiplied up. Formats without
    /// video tracks (GIF) use the file size.
    static func mediaBytes(of url: URL) async throws -> Int64 {
        let asset = AVURLAsset(url: url)
        guard let track = (try? await asset.loadTracks(withMediaType: .video))?.first,
              let bytes = try? await track.load(.totalSampleDataLength), bytes > 0
        else {
            return Int64((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return bytes
    }
}
