import AppKit
import ScreenCaptureKit
import TinycapCore

/// One still image of the chosen target, at full Retina resolution (SS-2).
struct Screenshot {
    let image: CGImage
    /// Captured pixels per screen point: 2 on Retina, 1 otherwise. "1×" export divides by this.
    let pixelsPerPoint: Double
}

/// Captures a still with ScreenCaptureKit's `SCScreenshotManager`. No streams or encoders.
@MainActor
enum ScreenshotCapturer {
    static func capture(_ target: CaptureTarget, windowShadow: Bool) async throws -> Screenshot {
        let filter: SCContentFilter
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.captureResolution = .best
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB

        switch target {
        case .display(let display), .area(let display, _):
            filter = SCContentFilter(display: display, excludingApplications: await ownApp().map { [$0] } ?? [], exceptingWindows: [])
        case .window(let window), .windowRegion(let window, _, _):
            filter = SCContentFilter(desktopIndependentWindow: window)
            // Window shots keep the transparent corners; the shadow is optional.
            config.ignoreShadowsSingleWindow = !windowShadow
            config.shouldBeOpaque = false
            config.backgroundColor = .clear
        }

        let scale = Double(filter.pointPixelScale)
        let points: CGSize
        if case .area(_, let rect) = target {
            config.sourceRect = rect
            points = rect.size
        } else {
            points = filter.contentRect.size
        }
        config.width = max(1, Int((points.width * scale).rounded()))
        config.height = max(1, Int((points.height * scale).rounded()))

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return Screenshot(image: image, pixelsPerPoint: scale)
    }

    /// Tinycap itself, so its windows stay out of screen and area shots. Looked up in the
    /// full app list: after the picker closes Tinycap may have no window on screen.
    private static func ownApp() async -> SCRunningApplication? {
        let pid = ProcessInfo.processInfo.processIdentifier
        let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return content?.applications.first { $0.processID == pid }
    }
}
