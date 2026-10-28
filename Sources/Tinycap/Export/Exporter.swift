import AVFoundation

/// Turns the master .mov into a shareable file. One type per format (MP4 now;
/// GIF in M3, WebM in M4).
protocol Exporter: Sendable {
    var fileExtension: String { get }
    func export(master: URL, timeRange: CMTimeRange?, to destination: URL) async throws
}

enum ExportError: LocalizedError {
    case cannotCreateSession
    var errorDescription: String? { "Tinycap couldn't prepare the video for export." }
}

/// MP4 export. The master is already H.264, so this remuxes without re-encoding
/// (fast, lossless). Quality and scale controls arrive with M2 and will re-encode.
struct MP4Exporter: Exporter {
    let fileExtension = "mp4"

    func export(master: URL, timeRange: CMTimeRange? = nil, to destination: URL) async throws {
        let asset = AVURLAsset(url: master)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.cannotCreateSession
        }
        session.shouldOptimizeForNetworkUse = true // moov atom first, so it plays while loading in Slack/GitHub
        if let timeRange { session.timeRange = timeRange }
        try await session.export(to: destination, as: .mp4)
    }
}
