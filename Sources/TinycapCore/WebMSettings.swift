import CoreGraphics
import Foundation

/// WebM (VP9) export options (EX-2). VP9 runs in constrained-quality mode: the quality
/// slider picks a CQ level, and a bitrate cap stops busy scenes from ballooning.
public struct WebMSettings: Sendable, Equatable {
    public static let defaultQuality = 0.5
    /// Encoder speed (libvpx cpu-used): 5 is a good balance for offline screen content.
    public static let cpuUsed = 5

    /// 0 = smallest file, 1 = best quality.
    public var quality: Double
    public var scale: OutputScale

    public init(quality: Double = WebMSettings.defaultQuality, scale: OutputScale = .full) {
        self.quality = min(max(quality, 0), 1)
        self.scale = scale
    }

    public init(defaults: UserDefaults) {
        self.init(
            quality: defaults.object(forKey: PreferenceKey.webmQuality) as? Double ?? Self.defaultQuality,
            scale: OutputScale(storageValue: defaults.string(forKey: PreferenceKey.webmScale) ?? "full")
        )
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(quality, forKey: PreferenceKey.webmQuality)
        defaults.set(scale.storageValue, forKey: PreferenceKey.webmScale)
    }

    /// VP9 CQ level, 50 (smallest) … 20 (best); 35 at the default.
    public var cqLevel: Int { Int((50 - 30 * quality).rounded()) }

    public func outputSize(for sourceSize: CGSize) -> (width: Int, height: Int) {
        ExportSettings(scale: scale).outputSize(for: sourceSize)
    }

    /// Bitrate ceiling in kbps: 4× the MP4 target at the same quality, at least 500.
    public func maxBitrateKbps(width: Int, height: Int, frameRate: Double) -> Int {
        let mp4 = ExportSettings(quality: quality).bitrate(width: width, height: height, frameRate: frameRate)
        return max(500, mp4 * 4 / 1000)
    }
}
