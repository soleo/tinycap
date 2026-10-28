import CoreGraphics
import Foundation

public enum ExportFormat: String, Sendable, CaseIterable, Identifiable {
    case mp4, gif
    public var id: String { rawValue }
    public var displayName: String { self == .mp4 ? "MP4" : "GIF" }
    public var fileExtension: String { rawValue }
}

/// GIF export options (EX-3, EX-5).
public struct GIFSettings: Sendable, Equatable {
    public static let frameRates = 5...30
    public static let colorChoices = [32, 64, 128, 256]

    public var fps: Int
    public var scale: OutputScale
    /// Palette size including the slot reserved for transparency.
    public var colors: Int
    /// Ordered (Bayer) dithering: smoother gradients, larger files. Stable across frames.
    public var dither: Bool
    public var loop: Bool
    /// Merge frames that are identical after quantization into one longer frame.
    public var dropDuplicates: Bool

    public init(fps: Int = 12, scale: OutputScale = .width(960), colors: Int = 128,
                dither: Bool = false, loop: Bool = true, dropDuplicates: Bool = true) {
        self.fps = min(max(fps, GIFSettings.frameRates.lowerBound), GIFSettings.frameRates.upperBound)
        self.scale = scale
        self.colors = GIFSettings.colorChoices.contains(colors) ? colors : 128
        self.dither = dither
        self.loop = loop
        self.dropDuplicates = dropDuplicates
    }

    public init(defaults: UserDefaults) {
        let preset = GIFPreset.balanced.settings
        self.init(
            fps: defaults.object(forKey: PreferenceKey.gifFPS) as? Int ?? preset.fps,
            scale: (defaults.string(forKey: PreferenceKey.gifScale)).map(OutputScale.init(storageValue:)) ?? preset.scale,
            colors: defaults.object(forKey: PreferenceKey.gifColors) as? Int ?? preset.colors,
            dither: defaults.object(forKey: PreferenceKey.gifDither) as? Bool ?? preset.dither,
            loop: defaults.object(forKey: PreferenceKey.gifLoop) as? Bool ?? preset.loop,
            dropDuplicates: defaults.object(forKey: PreferenceKey.gifDropDuplicates) as? Bool ?? preset.dropDuplicates
        )
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(fps, forKey: PreferenceKey.gifFPS)
        defaults.set(scale.storageValue, forKey: PreferenceKey.gifScale)
        defaults.set(colors, forKey: PreferenceKey.gifColors)
        defaults.set(dither, forKey: PreferenceKey.gifDither)
        defaults.set(loop, forKey: PreferenceKey.gifLoop)
        defaults.set(dropDuplicates, forKey: PreferenceKey.gifDropDuplicates)
    }

    /// Output pixel size; never upscales. GIF has no even-size rule, but even sizes keep
    /// half-scale exact, so this shares the MP4 rounding.
    public func outputSize(for sourceSize: CGSize) -> (width: Int, height: Int) {
        ExportSettings(scale: scale).outputSize(for: sourceSize)
    }

    /// The preset these settings match, if any (loop is left to the user).
    public var preset: GIFPreset? {
        GIFPreset.allCases.first { p in
            let s = p.settings
            return s.fps == fps && s.scale == scale && s.colors == colors && s.dither == dither && s.dropDuplicates == dropDuplicates
        }
    }

    /// Successively smaller settings for "fit under N MB", gentlest first: dithering off,
    /// fewer colors, lower frame rate, then narrower output in 20% steps down to 320 px.
    public func fitLadder(sourceWidth: Int) -> [GIFSettings] {
        var ladder: [GIFSettings] = []
        var s = self
        func push() { if ladder.last != s, s != self { ladder.append(s) } }
        if s.dither { s.dither = false; push() }
        for c in [128, 64] where s.colors > c { s.colors = c; push() }
        for f in [10, 8] where s.fps > f { s.fps = f; push() }
        var width = s.outputSize(for: CGSize(width: sourceWidth, height: sourceWidth)).width
        while width > 320 {
            width = max(320, Int(Double(width) * 0.8))
            s.scale = .width(width)
            push()
        }
        return ladder
    }
}

public enum GIFPreset: String, Sendable, CaseIterable, Identifiable {
    case small, balanced, high
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }

    /// Balanced is the default; it keeps a 30 s UI clip under the PRD's 10 MB target.
    public var settings: GIFSettings {
        switch self {
        case .small: return GIFSettings(fps: 10, scale: .width(640), colors: 64, dither: false)
        case .balanced: return GIFSettings(fps: 12, scale: .width(960), colors: 128, dither: false)
        case .high: return GIFSettings(fps: 15, scale: .width(1280), colors: 256, dither: true)
        }
    }
}

/// Frame timing for a constant-rate GIF from a variable-rate recording.
public enum GIFTiming {
    /// Time of output frame `k`, in seconds from the start of the kept range.
    public static func time(ofFrame k: Int, fps: Int) -> Double {
        Double(k) / Double(max(fps, 1))
    }

    /// Delay of frame `k` in centiseconds. Rounds the frame boundaries, not each delay,
    /// so the total never drifts from the clip length (e.g. 12 fps → 8, 8, 9, 8, 8, 9…).
    public static func delay(ofFrame k: Int, fps: Int) -> Int {
        let f = Double(max(fps, 1))
        return Int((Double(k + 1) * 100 / f).rounded()) - Int((Double(k) * 100 / f).rounded())
    }

    /// Number of output frames for a clip of `duration` seconds.
    public static func frameCount(duration: Double, fps: Int) -> Int {
        max(1, Int((duration * Double(max(fps, 1))).rounded(.up)))
    }
}
