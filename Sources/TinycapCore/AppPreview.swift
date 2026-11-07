import CoreGraphics
import Foundation

/// The kind of iPhone or iPad a recording came from, told apart by the screen's shape.
public enum DeviceKind: Sendable, Equatable {
    /// Face ID iPhones: about 9:19.5.
    case iPhone
    /// iPhones with a Home button: 9:16.
    case homeButtonIPhone
    /// iPads: 3:4 to about 2:3.
    case iPad

    /// Short side over long side, so portrait and landscape give the same answer.
    public init(pixelSize: CGSize) {
        let short = min(pixelSize.width, pixelSize.height)
        let long = max(pixelSize.width, pixelSize.height)
        let ratio = long > 0 ? short / long : 0
        switch ratio {
        case ..<0.51: self = .iPhone              // 0.46
        case ..<0.62: self = .homeButtonIPhone    // 0.5625
        default: self = .iPad                     // 0.66–0.75
        }
    }

    /// Pixels per point, so a device screenshot's "1×" export is the screen's point size.
    public static func pointScale(for pixelSize: CGSize) -> Double {
        let long = max(pixelSize.width, pixelSize.height)
        switch DeviceKind(pixelSize: pixelSize) {
        case .iPad: return 2
        case .homeButtonIPhone: return long < 1500 ? 2 : 3
        case .iPhone: return 3
        }
    }
}

/// App Store app preview video rules (DV-6): one accepted size per device family,
/// H.264 at 30 fps, stereo AAC, 15–30 seconds long.
public enum AppPreview {
    public static let frameRate = 30
    /// App Store Connect accepts 10–12 Mbps.
    public static let videoBitrate = 11_000_000
    public static let audioBitrate = 256_000
    public static let durationRange: ClosedRange<Double> = 15...30

    /// The accepted size for a recording of `source` pixels; landscape recordings get the
    /// landscape size. Other shapes are letterboxed into it.
    public static func size(for source: CGSize) -> (width: Int, height: Int) {
        let portrait: (width: Int, height: Int)
        switch DeviceKind(pixelSize: source) {
        case .iPhone: portrait = (886, 1920)
        case .homeButtonIPhone: portrait = (1080, 1920)
        case .iPad: portrait = (1200, 1600)
        }
        return source.width > source.height ? (portrait.height, portrait.width) : portrait
    }

    /// A short note when a clip of `seconds` would be refused, nil when it's fine.
    public static func durationProblem(_ seconds: Double) -> String? {
        // Half a frame of slack, so a clip trimmed to "15.0 s" isn't flagged.
        let slack = 0.5 / Double(frameRate)
        if seconds < durationRange.lowerBound - slack {
            return "App previews must be at least 15 seconds; this clip is \(format(seconds))."
        }
        if seconds > durationRange.upperBound + slack {
            return "App previews can be at most 30 seconds; this clip is \(format(seconds)). Trim it."
        }
        return nil
    }

    private static func format(_ seconds: Double) -> String {
        String(format: "%.1f s", seconds)
    }
}
