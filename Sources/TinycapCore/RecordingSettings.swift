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
    public static let filenamePattern = "export.filenamePattern"
    public static let saveFolderBookmark = "export.saveFolderBookmark"
    public static let recentRecordings = "recents.paths"
    public static let exportCodec = "export.codec"
    public static let exportQuality = "export.quality"
    public static let exportScale = "export.scale"

    public static func registerDefaults(in defaults: UserDefaults) {
        defaults.register(defaults: [
            frameRate: FrameRate.default.rawValue,
            showsCursor: true,
            captureAtNativeScale: true,
            filenamePattern: FilenamePattern.defaultPattern,
            exportCodec: VideoCodec.h264.rawValue,
            exportQuality: ExportSettings.defaultQuality,
            exportScale: OutputScale.full.storageValue,
        ])
    }
}

/// Options that apply to a single capture.
public struct RecordingSettings: Sendable, Equatable {
    public var frameRate: FrameRate
    public var showsCursor: Bool
    /// Capture at the display's Retina scale (true) or at 1× (false).
    public var captureAtNativeScale: Bool

    public init(frameRate: FrameRate = .default, showsCursor: Bool = true, captureAtNativeScale: Bool = true) {
        self.frameRate = frameRate
        self.showsCursor = showsCursor
        self.captureAtNativeScale = captureAtNativeScale
    }

    public init(defaults: UserDefaults) {
        self.init(
            frameRate: FrameRate(rawValue: defaults.integer(forKey: PreferenceKey.frameRate)) ?? .default,
            showsCursor: defaults.object(forKey: PreferenceKey.showsCursor) as? Bool ?? true,
            captureAtNativeScale: defaults.object(forKey: PreferenceKey.captureAtNativeScale) as? Bool ?? true
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
