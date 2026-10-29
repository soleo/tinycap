import CoreGraphics
import CoreText
import Foundation

/// A color stored as sRGB components, so annotations are `Codable` and render the same
/// in the editor and the exported file.
public struct RGBAColor: Codable, Hashable, Sendable {
    public var red: Double, green: Double, blue: Double, alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// AN-5: the six preset colors. The default is a vivid pink-red (#FF265E) that stands
    /// out on light and dark UI alike.
    public static let presets: [RGBAColor] = [
        RGBAColor(red: 1.00, green: 0.149, blue: 0.369), // pink #FF265E
        RGBAColor(red: 1.00, green: 0.80, blue: 0.00), // yellow
        RGBAColor(red: 0.20, green: 0.78, blue: 0.35), // green
        RGBAColor(red: 0.00, green: 0.48, blue: 1.00), // blue
        RGBAColor(red: 0.00, green: 0.00, blue: 0.00), // black
        RGBAColor(red: 1.00, green: 1.00, blue: 1.00), // white
    ]

    /// Black or white, whichever reads better on top of this color.
    public var contrasting: RGBAColor {
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance > 0.6 ? RGBAColor(red: 0, green: 0, blue: 0) : RGBAColor(red: 1, green: 1, blue: 1)
    }
}

/// The style new marks get; the last-used one is remembered (AN-5).
public struct AnnotationStyle: Codable, Equatable, Sendable {
    public var color: RGBAColor
    /// Arrow thickness in image pixels.
    public var lineWidth: Double
    /// Text size in image pixels.
    public var fontSize: Double
    /// Solid background behind text, for legibility (AN-2).
    public var textBackground: Bool

    public init(color: RGBAColor = RGBAColor.presets[0], lineWidth: Double = 8, fontSize: Double = 36, textBackground: Bool = false) {
        self.color = color
        self.lineWidth = lineWidth
        self.fontSize = fontSize
        self.textBackground = textBackground
    }

    public static let lineWidths: [Double] = [4, 8, 14]
    public static let fontSizes: [Double] = [24, 36, 56]
}

public struct Arrow: Codable, Equatable, Sendable {
    /// Tail and tip, in image pixels with the origin at the top left.
    public var start: CGPoint
    public var end: CGPoint
    public var color: RGBAColor
    public var lineWidth: Double
    /// How far the middle of the arrow bows sideways, in image pixels (0 = straight).
    /// Positive bends to the left of the start → end direction (with y down, that is
    /// counterclockwise on screen). Kept in pixels, so moving an end keeps the curve.
    public var bend: Double

    public init(start: CGPoint, end: CGPoint, color: RGBAColor, lineWidth: Double, bend: Double = 0) {
        self.start = start; self.end = end; self.color = color; self.lineWidth = lineWidth; self.bend = bend
    }
}

public struct TextLabel: Codable, Equatable, Sendable {
    /// Top-left corner of the text box, in image pixels.
    public var origin: CGPoint
    public var text: String
    public var fontSize: Double
    public var color: RGBAColor
    public var hasBackground: Bool

    public init(origin: CGPoint, text: String, fontSize: Double, color: RGBAColor, hasBackground: Bool) {
        self.origin = origin; self.text = text; self.fontSize = fontSize; self.color = color; self.hasBackground = hasBackground
    }
}

/// AN-6: a rectangle or ellipse outline.
public struct ShapeMark: Codable, Equatable, Sendable {
    public enum Form: String, Codable, Sendable { case rectangle, ellipse }
    public var form: Form
    /// The outline's center line, in image pixels.
    public var rect: CGRect
    public var color: RGBAColor
    public var lineWidth: Double

    public init(form: Form, rect: CGRect, color: RGBAColor, lineWidth: Double) {
        self.form = form; self.rect = rect; self.color = color; self.lineWidth = lineWidth
    }
}

/// AN-9 and AN-6: a freehand pen line, or a wide see-through highlighter stroke.
public struct Stroke: Codable, Equatable, Sendable {
    /// The path as drawn, in image pixels.
    public var points: [CGPoint]
    public var color: RGBAColor
    /// The style's thickness. A highlighter is drawn wider (`drawnWidth`).
    public var lineWidth: Double
    public var isHighlighter: Bool

    public init(points: [CGPoint], color: RGBAColor, lineWidth: Double, isHighlighter: Bool) {
        self.points = points; self.color = color; self.lineWidth = lineWidth; self.isHighlighter = isHighlighter
    }

    /// Thin, Medium and Thick give a 20, 28 or 40 px highlighter: wide enough to cover a line of text.
    public var drawnWidth: Double { isHighlighter ? lineWidth * 2 + 12 : lineWidth }

    /// How opaque a highlighter is; text under it stays readable.
    public static let highlighterAlpha = 0.4
}

/// AN-8: a numbered step badge. Numbers follow the badges' order: 1, 2, 3…
public struct Badge: Codable, Equatable, Sendable {
    public var center: CGPoint
    public var number: Int
    public var color: RGBAColor
    /// The style's text size; the badge is a little larger.
    public var fontSize: Double

    public init(center: CGPoint, number: Int, color: RGBAColor, fontSize: Double) {
        self.center = center; self.number = number; self.color = color; self.fontSize = fontSize
    }

    /// Small, Medium and Large give 31, 47 or 73 px circles.
    public var diameter: Double { (fontSize * 1.3).rounded() }
}

public struct Annotation: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case arrow(Arrow)
        case text(TextLabel)
        /// AN-7: a pixelated area. Always drawn under arrows and text, and burned into the
        /// exported pixels.
        case redaction(CGRect)
        /// AN-8: the part of the image to export. At most one per document.
        case crop(CGRect)
        case shape(ShapeMark)
        case stroke(Stroke)
        case badge(Badge)
    }

    /// The rectangle of a redaction, crop or shape: what its corner handles move.
    public var rect: CGRect? {
        switch kind {
        case .redaction(let r), .crop(let r): return r
        case .shape(let s): return s.rect
        case .arrow, .text, .stroke, .badge: return nil
        }
    }

    public func withRect(_ rect: CGRect) -> Annotation {
        var copy = self
        switch kind {
        case .redaction: copy.kind = .redaction(rect)
        case .crop: copy.kind = .crop(rect)
        case .shape(var s):
            s.rect = rect
            copy.kind = .shape(s)
        case .arrow, .text, .stroke, .badge: break
        }
        return copy
    }

    public var id: UUID
    public var kind: Kind

    public init(id: UUID = UUID(), _ kind: Kind) {
        self.id = id
        self.kind = kind
    }

    /// Bounding box in image pixels, including the arrowhead or the text padding.
    public var bounds: CGRect {
        switch kind {
        case .arrow(let a):
            let head = ArrowGeometry.head(a)
            let points = ArrowGeometry.samples(a) + [head.left, head.right]
            let xs = points.map(\.x), ys = points.map(\.y)
            let rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            return rect.insetBy(dx: -a.lineWidth / 2, dy: -a.lineWidth / 2)
        case .text(let t):
            return TextLayout.frame(t)
        case .redaction(let r), .crop(let r):
            return r
        case .shape(let s):
            return s.rect.standardized.insetBy(dx: -s.lineWidth / 2, dy: -s.lineWidth / 2)
        case .stroke(let s):
            guard let first = s.points.first else { return .null }
            let rect = s.points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
            return rect.insetBy(dx: -s.drawnWidth / 2, dy: -s.drawnWidth / 2)
        case .badge(let b):
            return BadgeLayout.frame(b)
        }
    }

    public func moved(by delta: CGVector) -> Annotation {
        var copy = self
        switch kind {
        case .arrow(var a):
            a.start.x += delta.dx; a.start.y += delta.dy
            a.end.x += delta.dx; a.end.y += delta.dy
            copy.kind = .arrow(a)
        case .text(var t):
            t.origin.x += delta.dx; t.origin.y += delta.dy
            copy.kind = .text(t)
        case .redaction(let r), .crop(let r):
            return withRect(r.offsetBy(dx: delta.dx, dy: delta.dy))
        case .shape(let s):
            return withRect(s.rect.offsetBy(dx: delta.dx, dy: delta.dy))
        case .stroke(var s):
            s.points = s.points.map { CGPoint(x: $0.x + delta.dx, y: $0.y + delta.dy) }
            copy.kind = .stroke(s)
        case .badge(var b):
            b.center.x += delta.dx; b.center.y += delta.dy
            copy.kind = .badge(b)
        }
        return copy
    }

    /// Applies a style change to this mark (color always; width or size by kind).
    public func restyled(_ style: AnnotationStyle) -> Annotation {
        var copy = self
        switch kind {
        case .arrow(var a):
            a.color = style.color
            a.lineWidth = style.lineWidth
            copy.kind = .arrow(a)
        case .text(var t):
            t.color = style.color
            t.fontSize = style.fontSize
            t.hasBackground = style.textBackground
            copy.kind = .text(t)
        case .shape(var s):
            s.color = style.color
            s.lineWidth = style.lineWidth
            copy.kind = .shape(s)
        case .stroke(var s):
            s.color = style.color
            s.lineWidth = style.lineWidth
            copy.kind = .stroke(s)
        case .badge(var b):
            b.color = style.color
            b.fontSize = style.fontSize
            copy.kind = .badge(b)
        case .redaction, .crop:
            break
        }
        return copy
    }

    /// Numbers the badges 1, 2, 3… in list order, so deleting one closes the gap.
    public static func numberingBadges(_ annotations: [Annotation]) -> [Annotation] {
        var number = 0
        return annotations.map { annotation in
            guard case .badge(var badge) = annotation.kind else { return annotation }
            number += 1
            guard badge.number != number else { return annotation }
            badge.number = number
            var copy = annotation
            copy.kind = .badge(badge)
            return copy
        }
    }

    /// The number a new badge gets.
    public static func nextBadgeNumber(in annotations: [Annotation]) -> Int {
        annotations.filter { if case .badge = $0.kind { return true } else { return false } }.count + 1
    }
}

// MARK: - Geometry

public enum ArrowGeometry {
    /// AN-1: with Shift, the arrow snaps to the nearest 45° direction, keeping its length.
    public static func snap45(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return end }
        let step = Double.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: start.x + length * cos(angle), y: start.y + length * sin(angle))
    }

    // MARK: Curve
    //
    // A bent arrow is a quadratic Bézier from `start` to `end`. Its control point sits on
    // the perpendicular through the chord's midpoint, twice as far out as `bend`, so the
    // curve's own midpoint is exactly `bend` from the chord.

    /// Unit vector perpendicular to the chord (left of start → end), and the chord length.
    public static func normal(_ arrow: Arrow) -> (CGVector, Double) {
        let dx = arrow.end.x - arrow.start.x, dy = arrow.end.y - arrow.start.y
        let length = max(hypot(dx, dy), 0.0001)
        return (CGVector(dx: dy / length, dy: -dx / length), length)
    }

    public static func control(_ arrow: Arrow) -> CGPoint {
        let (n, _) = normal(arrow)
        let mid = CGPoint(x: (arrow.start.x + arrow.end.x) / 2, y: (arrow.start.y + arrow.end.y) / 2)
        return CGPoint(x: mid.x + n.dx * arrow.bend * 2, y: mid.y + n.dy * arrow.bend * 2)
    }

    public static func point(_ arrow: Arrow, at t: Double) -> CGPoint {
        let c = control(arrow), u = 1 - t
        return CGPoint(x: u * u * arrow.start.x + 2 * u * t * c.x + t * t * arrow.end.x,
                       y: u * u * arrow.start.y + 2 * u * t * c.y + t * t * arrow.end.y)
    }

    /// The bend handle: the curve's midpoint.
    public static func midpoint(_ arrow: Arrow) -> CGPoint { point(arrow, at: 0.5) }

    /// The bend that puts the curve's midpoint at (the projection of) `p`. Within `snap`
    /// pixels of straight it snaps to 0.
    public static func bend(_ arrow: Arrow, through p: CGPoint, snap: Double) -> Double {
        let (n, _) = normal(arrow)
        let mid = CGPoint(x: (arrow.start.x + arrow.end.x) / 2, y: (arrow.start.y + arrow.end.y) / 2)
        let value = (p.x - mid.x) * n.dx + (p.y - mid.y) * n.dy
        return abs(value) < snap ? 0 : value
    }

    /// Points along the shaft, start to end (two for a straight arrow).
    public static func samples(_ arrow: Arrow, count: Int = 32) -> [CGPoint] {
        guard arrow.bend != 0 else { return [arrow.start, arrow.end] }
        return (0...count).map { point(arrow, at: Double($0) / Double(count)) }
    }

    /// Distance from `p` to the shaft.
    public static func distance(from p: CGPoint, to arrow: Arrow) -> Double {
        let pts = samples(arrow)
        return zip(pts, pts.dropFirst()).map { distance(from: p, toSegment: $0, $1) }.min() ?? .infinity
    }

    /// The open chevron head: the ends of its two arms, and the point on the shaft level
    /// with them. The tip is `arrow.end`; the head points along the curve at the tip.
    public static func head(_ arrow: Arrow) -> (left: CGPoint, right: CGPoint, base: CGPoint) {
        let from = arrow.bend == 0 ? arrow.start : control(arrow)
        let dx = arrow.end.x - from.x, dy = arrow.end.y - from.y
        let length = max((dx * dx + dy * dy).squareRoot(), 0.0001)
        let arm = min(max(arrow.lineWidth * 3, 12), normal(arrow).1 * 0.7)
        let ux = dx / length, uy = dy / length
        let back = arm * cos(Double.pi / 4.5), side = arm * sin(Double.pi / 4.5) // 40° arms
        let base = CGPoint(x: arrow.end.x - ux * back, y: arrow.end.y - uy * back)
        let left = CGPoint(x: base.x - uy * side, y: base.y + ux * side)
        let right = CGPoint(x: base.x + uy * side, y: base.y - ux * side)
        return (left, right, base)
    }

    public static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

public enum AnnotationHitTest {
    /// The topmost annotation under `point`, within `tolerance` image pixels.
    public static func hit(_ point: CGPoint, in annotations: [Annotation], tolerance: Double) -> Annotation? {
        annotations.reversed().first { annotation in
            switch annotation.kind {
            case .arrow(let a):
                return ArrowGeometry.distance(from: point, to: a) <= tolerance + a.lineWidth / 2
                    || annotation.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
                        && ArrowGeometry.distance(from: point, toSegment: ArrowGeometry.head(a).base, a.end) <= tolerance + a.lineWidth * 2
            case .text, .redaction:
                return annotation.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
            case .crop:
                return false // the crop is edited with the Crop tool, not selected like a mark
            case .shape(let s):
                // Only the outline, so marks and shapes inside it can still be picked.
                return ShapeGeometry.distance(from: point, to: s) <= tolerance + s.lineWidth / 2
            case .stroke(let s):
                return StrokeGeometry.distance(from: point, to: s.points) <= tolerance + s.drawnWidth / 2
            case .badge:
                return annotation.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
            }
        }
    }
}

/// Measures and lays out text labels with the system font.
public enum TextLayout {
    /// Bold system font (SF Pro): heavy enough to read at a glance on a busy screenshot.
    public static func font(size: Double) -> CTFont {
        CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    }

    /// Padding around the text, used for the background and hit-testing.
    public static func padding(fontSize: Double) -> Double { (fontSize * 0.25).rounded() }

    public static func lines(_ label: TextLabel, color: CGColor? = nil) -> [CTLine] {
        let font = font(size: label.fontSize)
        var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        if let color { attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color }
        return label.text.components(separatedBy: "\n").map { line in
            CTLineCreateWithAttributedString(NSAttributedString(string: line.isEmpty ? " " : line, attributes: attributes))
        }
    }

    public static func lineHeight(fontSize: Double) -> Double {
        let font = font(size: fontSize)
        return Double(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)).rounded(.up)
    }

    /// The text box including padding, in image pixels.
    public static func frame(_ label: TextLabel) -> CGRect {
        let width = lines(label).map { Double(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0
        let height = lineHeight(fontSize: label.fontSize) * Double(max(1, label.text.components(separatedBy: "\n").count))
        let pad = padding(fontSize: label.fontSize)
        return CGRect(x: label.origin.x, y: label.origin.y, width: width.rounded(.up) + pad * 2, height: height + pad * 2)
    }
}

/// Rectangles for redactions and the crop: corner handles and corner drags.
public enum RectGeometry {
    /// Corners in the order top-left, top-right, bottom-right, bottom-left (y down).
    public static func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    /// Moves corner `index` to `p`, keeping the opposite corner fixed. Never smaller than
    /// `minimum` on either side; the result can flip if dragged past the opposite corner.
    public static func drag(_ r: CGRect, corner index: Int, to p: CGPoint, minimum: Double = 4) -> CGRect {
        let opposite = corners(r)[(index + 2) % 4]
        var rect = Geometry.rect(from: opposite, to: p)
        rect.size.width = max(rect.width, minimum)
        rect.size.height = max(rect.height, minimum)
        if p.x < opposite.x { rect.origin.x = opposite.x - rect.width }
        if p.y < opposite.y { rect.origin.y = opposite.y - rect.height }
        return rect
    }

    /// `r` clipped to the image; nil if nothing is left.
    public static func clamp(_ r: CGRect, toImage size: CGSize) -> CGRect? {
        let clipped = r.standardized.intersection(CGRect(origin: .zero, size: size)).integral
        return clipped.isNull || clipped.width < 1 || clipped.height < 1 ? nil : clipped
    }
}

public enum ShapeGeometry {
    /// With Shift: a square from `start`, as large as the drag's longer side, toward `end`.
    public static func square(from start: CGPoint, to end: CGPoint) -> CGRect {
        let dx = end.x - start.x, dy = end.y - start.y
        let side = max(abs(dx), abs(dy))
        return Geometry.rect(from: start, to: CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side)))
    }

    /// Distance from `p` to the outline's center line.
    public static func distance(from p: CGPoint, to shape: ShapeMark) -> Double {
        let r = shape.rect.standardized
        switch shape.form {
        case .rectangle:
            let corners = RectGeometry.corners(r)
            return (0..<4).map { ArrowGeometry.distance(from: p, toSegment: corners[$0], corners[($0 + 1) % 4]) }.min()!
        case .ellipse:
            let points = outline(r, count: 72)
            return zip(points, points.dropFirst() + [points[0]]).map { ArrowGeometry.distance(from: p, toSegment: $0, $1) }.min()!
        }
    }

    /// Points around an ellipse inscribed in `rect`.
    public static func outline(_ rect: CGRect, count: Int) -> [CGPoint] {
        (0..<count).map { i in
            let angle = Double(i) / Double(count) * 2 * Double.pi
            return CGPoint(x: rect.midX + rect.width / 2 * cos(angle), y: rect.midY + rect.height / 2 * sin(angle))
        }
    }

    /// Corner radius for a rectangle outline: slightly soft, never more than the shape allows.
    public static func cornerRadius(_ shape: ShapeMark) -> Double {
        let r = shape.rect.standardized
        return max(0, min(shape.lineWidth * 1.5, r.width / 2 - 0.01, r.height / 2 - 0.01))
    }
}

public enum StrokeGeometry {
    /// Adds `p` to a stroke being drawn unless it is within `spacing` of the last point,
    /// which keeps paths small without visibly changing them.
    public static func appending(_ p: CGPoint, to points: [CGPoint], spacing: Double) -> [CGPoint] {
        guard let last = points.last else { return [p] }
        return hypot(p.x - last.x, p.y - last.y) < spacing ? points : points + [p]
    }

    /// Total length along the points.
    public static func length(_ points: [CGPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    public static func distance(from p: CGPoint, to points: [CGPoint]) -> Double {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else { return hypot(p.x - first.x, p.y - first.y) }
        return zip(points, points.dropFirst()).map { ArrowGeometry.distance(from: p, toSegment: $0, $1) }.min()!
    }

    /// A smooth path through the points: straight to the first midpoint, then quadratic
    /// curves with each point as the control, which rounds off the mouse's jitter.
    public static func path(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}

public enum BadgeLayout {
    /// The number's font: bold system digits at a size that fits the circle.
    public static func font(_ badge: Badge) -> CTFont { TextLayout.font(size: (badge.diameter * 0.55).rounded()) }

    public static func line(_ badge: Badge, color: CGColor? = nil) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font(badge)]
        if let color { attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color }
        return CTLineCreateWithAttributedString(NSAttributedString(string: String(badge.number), attributes: attributes))
    }

    /// A circle, or a pill for numbers too wide for one (10 and up).
    public static func frame(_ badge: Badge) -> CGRect {
        let textWidth = Double(CTLineGetTypographicBounds(line(badge), nil, nil, nil))
        let width = max(badge.diameter, (textWidth + badge.diameter * 0.5).rounded(.up))
        return CGRect(x: badge.center.x - width / 2, y: badge.center.y - badge.diameter / 2, width: width, height: badge.diameter)
    }
}
