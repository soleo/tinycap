import CoreGraphics

/// Edges of a selection rectangle that a resize handle moves.
/// Uses AppKit orientation: `top` is the edge with the larger y value.
public struct ResizeEdges: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let left = ResizeEdges(rawValue: 1 << 0)
    public static let right = ResizeEdges(rawValue: 1 << 1)
    public static let bottom = ResizeEdges(rawValue: 1 << 2)
    public static let top = ResizeEdges(rawValue: 1 << 3)

    /// The eight handles shown around a selection, corners first.
    public static let allHandles: [ResizeEdges] = [
        [.left, .bottom], [.right, .bottom], [.left, .top], [.right, .top],
        .left, .right, .bottom, .top,
    ]
}

public enum Geometry {
    /// Rectangle spanned by two points, regardless of drag direction.
    public static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Converts a rect in AppKit global coordinates (origin at the bottom-left of the
    /// primary display) into the display-local, top-left-origin coordinates that
    /// `SCStreamConfiguration.sourceRect` expects.
    public static func displayLocalRect(_ rect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - screenFrame.minX,
            y: screenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Converts a rect in Core Graphics global coordinates (origin at the top-left of the
    /// primary display, as used by `SCWindow.frame` and `CGWindowList`) into AppKit global
    /// coordinates.
    public static func appKitRect(fromCG rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Moves the given edges of `rect` to `point`. If the drag crosses the opposite edge
    /// the rectangle flips instead of going negative.
    public static func resize(_ rect: CGRect, edges: ResizeEdges, to point: CGPoint) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if edges.contains(.left) { minX = point.x }
        if edges.contains(.right) { maxX = point.x }
        if edges.contains(.bottom) { minY = point.y }
        if edges.contains(.top) { maxY = point.y }
        return Geometry.rect(from: CGPoint(x: minX, y: minY), to: CGPoint(x: maxX, y: maxY))
    }

    /// Shifts `rect` so it lies inside `bounds`, shrinking it only if it is larger than `bounds`.
    public static func keep(_ rect: CGRect, inside bounds: CGRect) -> CGRect {
        var r = rect
        r.size.width = min(r.width, bounds.width)
        r.size.height = min(r.height, bounds.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }

    /// The capture region for a window on its display, in the display-local, top-left
    /// points `sourceRect` expects. Both frames are Core Graphics global coordinates
    /// (`SCWindow.frame`, `SCDisplay.frame`). A window partly off the display is shifted
    /// back inside, keeping its size, so the video size never changes mid-recording.
    public static func windowSourceRect(window: CGRect, display: CGRect) -> CGRect {
        let local = window.offsetBy(dx: -display.minX, dy: -display.minY)
        return keep(local, inside: CGRect(origin: .zero, size: display.size))
    }

    /// The display holding most of `window` (CG global coordinates), else the first one.
    public static func bestDisplayIndex(for window: CGRect, displays: [CGRect]) -> Int? {
        guard !displays.isEmpty else { return nil }
        let areas = displays.map { d -> CGFloat in
            let i = d.intersection(window)
            return i.isNull ? 0 : i.width * i.height
        }
        return areas.indices.max { areas[$0] < areas[$1] }
    }

    /// Output pixel size for a capture of `pointSize` at `scale`. Video encoders need
    /// even dimensions, so each side is rounded down to an even number (minimum 2).
    public static func pixelSize(for pointSize: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        func even(_ v: CGFloat) -> Int { max(2, Int((v * scale).rounded(.down)) & ~1) }
        return (even(pointSize.width), even(pointSize.height))
    }
}
