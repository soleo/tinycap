import AVFoundation
import TinycapCore

/// Format and its options for one export.
enum FormatSettings: Sendable, Equatable {
    case mp4(ExportSettings)
    case webm(WebMSettings)
    case gif(GIFSettings)

    var format: ExportFormat {
        switch self {
        case .mp4: return .mp4
        case .webm: return .webm
        case .gif: return .gif
        }
    }

    func outputSize(for source: CGSize) -> (width: Int, height: Int) {
        switch self {
        case .mp4(let s): return s.outputSize(for: source)
        case .webm(let s): return s.outputSize(for: source)
        case .gif(let s): return s.outputSize(for: source)
        }
    }
}

/// What to export from a master recording.
struct ExportOptions: Sendable {
    /// Part of the master to keep; nil exports all of it.
    var timeRange: CMTimeRange?
    var format: FormatSettings
    /// Sound tracks of the master to keep. Only MP4 carries sound; WebM and GIF ignore it.
    var audioTrackIDs: [CMPersistentTrackID] = []
    /// Keep each sound source as its own track instead of mixing them into one. Browsers
    /// (Chrome, Slack, GitHub) play only the first track, so mixing is the default.
    var separateAudioTracks = false
}

/// Turns the master .mov into a shareable file. One type per format.
protocol Exporter: Sendable {
    var fileExtension: String { get }
    func export(
        master: URL,
        options: ExportOptions,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
    /// Expected file size for exporting start…end with `options` (EX-4).
    func estimateSize(master: URL, options: ExportOptions, start: Double, end: Double) async throws -> Int64
}

enum Exporters {
    static func exporter(for format: ExportFormat) -> Exporter {
        switch format {
        case .mp4: return MP4Exporter()
        case .webm: return WebMExporter()
        case .gif: return GIFExporter()
        }
    }
}

enum ExportError: LocalizedError {
    case noVideoTrack
    case wrongFormat
    case cannotEncode(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The recording has no video."
        case .wrongFormat: return "Internal error: options don't match the exporter."
        case .cannotEncode(let reason): return "Tinycap couldn't encode the video: \(reason)"
        }
    }
}

/// A sound track in a master recording (AU-3).
struct MasterAudioTrack: Sendable, Equatable, Identifiable {
    let trackID: CMPersistentTrackID
    let source: AudioSource
    var id: CMPersistentTrackID { trackID }
}

/// Facts about a master recording, loaded once for the preview and estimates.
struct MasterInfo: Sendable {
    let duration: Double
    /// Encoded pixel size of the video track.
    let pixelSize: CGSize
    let frameRate: Double
    /// System audio, then microphone; empty for recordings without sound.
    let audioTracks: [MasterAudioTrack]

    static func load(_ url: URL) async throws -> MasterInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideoTrack }
        let (size, fps) = try await track.load(.naturalSize, .nominalFrameRate)
        let duration = try await asset.load(.duration)
        return MasterInfo(
            duration: max(duration.seconds.isFinite ? duration.seconds : 0, 0),
            pixelSize: size,
            frameRate: fps > 0 ? Double(fps) : 30,
            audioTracks: try await audioTracks(of: asset)
        )
    }

    /// Sound tracks, identified by the names `CaptureFileWriter` gives them.
    static func audioTracks(of asset: AVAsset) async throws -> [MasterAudioTrack] {
        var tracks: [MasterAudioTrack] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let metadata = try await track.load(.metadata)
            let names = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .quickTimeUserDataTrackName)
            let name = try await names.first?.load(.stringValue)
            let source = name.flatMap(AudioSource.init(trackName:)) ?? .system
            tracks.append(MasterAudioTrack(trackID: track.trackID, source: source))
        }
        return tracks.sorted { ($0.source == .system ? 0 : 1, $0.trackID) < ($1.source == .system ? 0 : 1, $1.trackID) }
    }
}

extension CMTimeRange {
    init(seconds start: Double, _ end: Double) {
        self.init(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
    }
}
