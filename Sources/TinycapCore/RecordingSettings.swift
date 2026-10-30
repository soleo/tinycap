import Foundation

public enum CaptureMode: String, Sendable, CaseIterable {
    case window, screen, area
}

public enum FrameRate: Int, Sendable, CaseIterable, Identifiable {
    case fps15 = 15, fps30 = 30, fps60 = 60
    public var id: Int { rawValue }
    public static let `default` = FrameRate.fps30
}

/// UserDefaults keys, shared by the app code and SwiftUI `@AppStorage`.
public enum PreferenceKey {
    public static let frameRate = "recording.frameRate"
    public static let showsCursor = "recording.showsCursor"
    public static let captureAtNativeScale = "recording.captureAtNativeScale"
    public static let highlightsClicks = "recording.highlightsClicks"
    public static let countdown = "recording.countdown"
    public static let recordsSystemAudio = "recording.systemAudio"
    public static let recordsMicrophone = "recording.microphone"
    /// Unique ID of the chosen input device; empty or missing means the system input.
    public static let microphoneID = "recording.microphoneID"
    /// Record the microphone with macOS voice processing, which removes speaker echo.
    public static let reducesEcho = "recording.reducesEcho"
    public static let lastError = "diagnostics.lastError"
    public static let filenamePattern = "export.filenamePattern"
    public static let saveFolderBookmark = "export.saveFolderBookmark"
    public static let recentRecordings = "recents.paths"
    public static let exportCodec = "export.codec"
    public static let exportQuality = "export.quality"
    public static let exportScale = "export.scale"
    public static let exportFormat = "export.format"
    public static let gifFPS = "gif.fps"
    public static let gifScale = "gif.scale"
    public static let gifColors = "gif.colors"
    public static let gifDither = "gif.dither"
    public static let gifLoop = "gif.loop"
    public static let gifDropDuplicates = "gif.dropDuplicates"
    public static let gifFitTargetMB = "gif.fitTargetMB"
    public static let webmQuality = "webm.quality"
    public static let webmScale = "webm.scale"
    /// MP4 keeps system audio and the microphone as separate tracks instead of one mix.
    public static let separateAudioTracks = "export.separateAudioTracks"

    public static func registerDefaults(in defaults: UserDefaults) {
        defaults.register(defaults: [
            frameRate: FrameRate.default.rawValue,
            showsCursor: true,
            captureAtNativeScale: true,
            highlightsClicks: false,
            countdown: false,
            recordsSystemAudio: false,
            recordsMicrophone: false,
            reducesEcho: true,
            filenamePattern: FilenamePattern.defaultPattern,
            exportCodec: VideoCodec.h264.rawValue,
            exportQuality: ExportSettings.defaultQuality,
            exportScale: OutputScale.full.storageValue,
            exportFormat: ExportFormat.mp4.rawValue,
            gifFitTargetMB: 10,
            separateAudioTracks: false,
        ])
    }
}

/// Options that apply to a single capture.
public struct RecordingSettings: Sendable, Equatable {
    public var frameRate: FrameRate
    public var showsCursor: Bool
    /// Capture at the display's Retina scale (true) or at 1× (false).
    public var captureAtNativeScale: Bool
    /// Draw a ring at each mouse click (RC-4).
    public var highlightsClicks: Bool
    /// Show a 3-2-1 countdown before capture begins (MB, optional).
    public var countdown: Bool
    /// Record everything the Mac plays, in every mode (AU-1).
    public var recordsSystemAudio: Bool
    /// Record the microphone (AU-2).
    public var recordsMicrophone: Bool
    /// Input device to record from; nil means the system input.
    public var microphoneID: String?
    /// Remove speaker sound from the microphone (voice processing). On by default.
    public var reducesEcho: Bool

    public init(
        frameRate: FrameRate = .default,
        showsCursor: Bool = true,
        captureAtNativeScale: Bool = true,
        highlightsClicks: Bool = false,
        countdown: Bool = false,
        recordsSystemAudio: Bool = false,
        recordsMicrophone: Bool = false,
        microphoneID: String? = nil,
        reducesEcho: Bool = true
    ) {
        self.frameRate = frameRate
        self.showsCursor = showsCursor
        self.captureAtNativeScale = captureAtNativeScale
        self.highlightsClicks = highlightsClicks
        self.countdown = countdown
        self.recordsSystemAudio = recordsSystemAudio
        self.recordsMicrophone = recordsMicrophone
        self.microphoneID = microphoneID
        self.reducesEcho = reducesEcho
    }

    /// The sound sources this recording captures, in track order.
    public var audioSources: [AudioSource] {
        (recordsSystemAudio ? [.system] : []) + (recordsMicrophone ? [.microphone] : [])
    }

    public init(defaults: UserDefaults) {
        self.init(
            frameRate: FrameRate(rawValue: defaults.integer(forKey: PreferenceKey.frameRate)) ?? .default,
            showsCursor: defaults.object(forKey: PreferenceKey.showsCursor) as? Bool ?? true,
            captureAtNativeScale: defaults.object(forKey: PreferenceKey.captureAtNativeScale) as? Bool ?? true,
            highlightsClicks: defaults.bool(forKey: PreferenceKey.highlightsClicks),
            countdown: defaults.bool(forKey: PreferenceKey.countdown),
            recordsSystemAudio: defaults.bool(forKey: PreferenceKey.recordsSystemAudio),
            recordsMicrophone: defaults.bool(forKey: PreferenceKey.recordsMicrophone),
            microphoneID: defaults.string(forKey: PreferenceKey.microphoneID).flatMap { $0.isEmpty ? nil : $0 },
            reducesEcho: defaults.object(forKey: PreferenceKey.reducesEcho) as? Bool ?? true
        )
    }
}

/// Most-recent-first list of saved recordings, capped at `limit`.
public struct RecentList: Sendable, Equatable {
    public private(set) var paths: [String]
    public let limit: Int

    public init(paths: [String] = [], limit: Int = 10) {
        self.limit = limit
        self.paths = Array(paths.prefix(limit))
    }

    public mutating func add(_ path: String) {
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > limit { paths.removeLast(paths.count - limit) }
    }
}
