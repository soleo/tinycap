import AVFoundation
import TinycapCore

/// What to export from a master recording.
struct ExportOptions: Sendable {
    /// Part of the master to keep; nil exports all of it.
    var timeRange: CMTimeRange?
    var settings: ExportSettings
}

/// Turns the master .mov into a shareable file. One type per format (MP4 now;
/// GIF in M3, WebM in M4).
protocol Exporter: Sendable {
    var fileExtension: String { get }
    func export(
        master: URL,
        options: ExportOptions,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
}

enum ExportError: LocalizedError {
    case noVideoTrack
    case cannotEncode(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The recording has no video."
        case .cannotEncode(let reason): return "Tinycap couldn't encode the video: \(reason)"
        }
    }
}

/// Facts about a master recording, loaded once for the preview and estimates.
struct MasterInfo: Sendable {
    let duration: Double
    /// Encoded pixel size of the video track.
    let pixelSize: CGSize
    let frameRate: Double

    static func load(_ url: URL) async throws -> MasterInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideoTrack }
        let (size, fps) = try await track.load(.naturalSize, .nominalFrameRate)
        let duration = try await asset.load(.duration)
        return MasterInfo(
            duration: max(duration.seconds.isFinite ? duration.seconds : 0, 0),
            pixelSize: size,
            frameRate: fps > 0 ? Double(fps) : 30
        )
    }
}
