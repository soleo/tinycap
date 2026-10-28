import CoreGraphics
import Foundation

public enum VideoCodec: String, Sendable, CaseIterable, Identifiable {
    case h264, hevc
    public var id: String { rawValue }
    public var displayName: String { self == .h264 ? "H.264" : "HEVC" }
}

/// Output size relative to the recording (EX-6).
public enum OutputScale: Sendable, Equatable, Hashable {
    case full
    case half
    /// Fixed output width in pixels; height follows the aspect ratio. Never upscales.
    case width(Int)

    /// Round-trips through UserDefaults as "full", "half" or "w1280".
    public var storageValue: String {
        switch self {
        case .full: return "full"
        case .half: return "half"
        case .width(let w): return "w\(w)"
        }
    }

    public init(storageValue: String) {
        switch storageValue {
        case "half": self = .half
        case let s where s.hasPrefix("w"):
            if let w = Int(s.dropFirst()), w >= 2 { self = .width(w) } else { self = .full }
        default: self = .full
        }
    }
}

/// Encoder settings for an MP4 export (EX-1, EX-4, EX-6).
public struct ExportSettings: Sendable, Equatable {
    public static let defaultQuality = 0.5

    public var codec: VideoCodec
    /// 0 = smallest file, 1 = best quality.
    public var quality: Double
    public var scale: OutputScale

    public init(codec: VideoCodec = .h264, quality: Double = ExportSettings.defaultQuality, scale: OutputScale = .full) {
        self.codec = codec
        self.quality = min(max(quality, 0), 1)
        self.scale = scale
    }

    public init(defaults: UserDefaults) {
        self.init(
            codec: VideoCodec(rawValue: defaults.string(forKey: PreferenceKey.exportCodec) ?? "") ?? .h264,
            quality: defaults.object(forKey: PreferenceKey.exportQuality) as? Double ?? Self.defaultQuality,
            scale: OutputScale(storageValue: defaults.string(forKey: PreferenceKey.exportScale) ?? "full")
        )
    }

    /// Output pixel size for a source of `sourceSize` pixels. Even dimensions, no upscaling.
    public func outputSize(for sourceSize: CGSize) -> (width: Int, height: Int) {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return (2, 2) }
        let factor: CGFloat
        switch scale {
        case .full: factor = 1
        case .half: factor = 0.5
        case .width(let w): factor = min(1, CGFloat(w) / sourceSize.width)
        }
        return Geometry.pixelSize(for: sourceSize, scale: factor)
    }

    /// Bits per pixel per frame. Screen content compresses well, so the range sits far
    /// below camera-video norms: 0.015 at quality 0, ~0.042 at the default, 0.12 at 1.
    /// The default keeps a 30 s, 1280 px-wide, 30 fps clip under the PRD's 5 MB target.
    public var bitsPerPixel: Double {
        let h264 = 0.015 * pow(8, quality)
        return codec == .hevc ? h264 * 0.65 : h264
    }

    /// Target average bitrate in bits per second.
    public func bitrate(width: Int, height: Int, frameRate: Double) -> Int {
        let fps = min(max(frameRate, 1), 120)
        return max(100_000, Int(Double(width * height) * fps * bitsPerPixel))
    }

    /// Expected file size. Encoders use less on static screens, so this is an upper estimate.
    public func estimatedBytes(sourceSize: CGSize, frameRate: Double, duration: Double) -> Int64 {
        let size = outputSize(for: sourceSize)
        let bits = Double(bitrate(width: size.width, height: size.height, frameRate: frameRate)) * max(duration, 0)
        return Int64(bits / 8 * 1.01) + 4096 // ~1% container overhead + header
    }
}

/// Start and end of the part of a recording to keep (ED-2), in seconds.
public struct TrimRange: Sendable, Equatable {
    public static let minimumLength = 0.1

    public private(set) var start: Double
    public private(set) var end: Double
    public let duration: Double

    public init(duration: Double) {
        self.duration = max(duration, 0)
        start = 0
        end = self.duration
    }

    public var length: Double { end - start }
    public var isTrimmed: Bool { start > 0.0005 || end < duration - 0.0005 }

    /// Moves the start, keeping at least `minimumLength` before the end.
    public mutating func setStart(_ value: Double) {
        start = min(max(value, 0), max(end - Self.minimumLength, 0))
    }

    /// Moves the end, keeping at least `minimumLength` after the start.
    public mutating func setEnd(_ value: Double) {
        end = max(min(value, duration), min(start + Self.minimumLength, duration))
    }

    public mutating func reset() {
        start = 0
        end = duration
    }

    public func clampedPlayhead(_ t: Double) -> Double {
        min(max(t, start), end)
    }
}

public enum ByteSize {
    /// "840 KB", "4.2 MB", "1.3 GB" (decimal units, like Finder).
    public static func format(_ bytes: Int64) -> String {
        let b = Double(max(bytes, 0))
        if b < 1_000_000 { return "\(max(1, Int((b / 1000).rounded()))) KB" }
        if b < 1_000_000_000 { return String(format: "%.1f MB", b / 1_000_000) }
        return String(format: "%.2f GB", b / 1_000_000_000)
    }
}
