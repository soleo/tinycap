import Foundation

public enum ScreenshotFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case png, jpeg
    public var id: String { rawValue }
    public var displayName: String { self == .png ? "PNG" : "JPEG" }
    public var fileExtension: String { self == .png ? "png" : "jpg" }
}

/// SS-3: what happens right after a screenshot is taken.
public enum AfterCapture: String, CaseIterable, Codable, Identifiable, Sendable {
    case openEditor, copy, save
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .openEditor: return "Open the editor"
        case .copy: return "Copy to the clipboard"
        case .save: return "Save to the folder"
        }
    }
}

/// SX-3: full captured pixels (2× on Retina) or half (1×, point size).
public enum ScreenshotScale: String, CaseIterable, Codable, Identifiable, Sendable {
    case retina, standard
    public var id: String { rawValue }
    public var displayName: String { self == .retina ? "2× (Retina)" : "1×" }

    /// Multiplier on the captured pixels. A 1× capture (non-Retina display) stays 1.
    public func factor(pixelsPerPoint: Double) -> Double {
        self == .retina || pixelsPerPoint <= 1 ? 1 : 1 / pixelsPerPoint
    }
}

public struct ScreenshotSettings: Equatable, Sendable {
    public var afterCapture: AfterCapture
    public var format: ScreenshotFormat
    public var jpegQuality: Double
    public var scale: ScreenshotScale
    /// SS-2: window screenshots keep transparency; the shadow is optional.
    public var windowShadow: Bool
    public var style: AnnotationStyle

    public init(afterCapture: AfterCapture = .openEditor, format: ScreenshotFormat = .png, jpegQuality: Double = 0.85,
                scale: ScreenshotScale = .retina, windowShadow: Bool = true, style: AnnotationStyle = AnnotationStyle()) {
        self.afterCapture = afterCapture
        self.format = format
        self.jpegQuality = jpegQuality
        self.scale = scale
        self.windowShadow = windowShadow
        self.style = style
    }

    public enum Key {
        public static let afterCapture = "screenshot.afterCapture"
        public static let format = "screenshot.format"
        public static let jpegQuality = "screenshot.jpegQuality"
        public static let scale = "screenshot.scale"
        public static let windowShadow = "screenshot.windowShadow"
        public static let style = "screenshot.style"
    }

    /// The red that was the default before the pink preset, mapped to pink on load.
    static let retiredRed = RGBAColor(red: 1.00, green: 0.23, blue: 0.19)

    public init(defaults: UserDefaults) {
        let fallback = ScreenshotSettings()
        var style = defaults.data(forKey: Key.style).flatMap { try? JSONDecoder().decode(AnnotationStyle.self, from: $0) } ?? fallback.style
        if style.color == Self.retiredRed { style.color = RGBAColor.presets[0] }
        self.init(
            afterCapture: defaults.string(forKey: Key.afterCapture).flatMap(AfterCapture.init(rawValue:)) ?? fallback.afterCapture,
            format: defaults.string(forKey: Key.format).flatMap(ScreenshotFormat.init(rawValue:)) ?? fallback.format,
            jpegQuality: defaults.object(forKey: Key.jpegQuality) as? Double ?? fallback.jpegQuality,
            scale: defaults.string(forKey: Key.scale).flatMap(ScreenshotScale.init(rawValue:)) ?? fallback.scale,
            windowShadow: defaults.object(forKey: Key.windowShadow) as? Bool ?? fallback.windowShadow,
            style: style
        )
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(afterCapture.rawValue, forKey: Key.afterCapture)
        defaults.set(format.rawValue, forKey: Key.format)
        defaults.set(jpegQuality, forKey: Key.jpegQuality)
        defaults.set(scale.rawValue, forKey: Key.scale)
        defaults.set(windowShadow, forKey: Key.windowShadow)
        defaults.set(try? JSONEncoder().encode(style), forKey: Key.style)
    }

    /// Remembers the last-used annotation style (AN-5) without touching other settings.
    public static func saveStyle(_ style: AnnotationStyle, to defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(style), forKey: Key.style)
    }
}
