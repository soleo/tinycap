import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws annotations with Core Graphics. The editor and the exporter both use this, so
/// what you see is what you export.
public enum AnnotationRenderer {
    /// Draws into a context whose coordinates are image pixels with the origin at the top
    /// left (y grows down). The editor's Canvas context is already like that; `flatten`
    /// sets it up for a bitmap.
    public static func draw(_ annotations: [Annotation], in context: CGContext) {
        for annotation in annotations {
            switch annotation.kind {
            case .arrow(let arrow): draw(arrow, in: context)
            case .text(let label): draw(label, in: context)
            case .shape(let shape): draw(shape, in: context)
            case .stroke(let stroke): draw(stroke, in: context)
            case .badge(let badge): draw(badge, in: context)
            case .redaction, .crop: break // drawn by drawRedactions / applied by flatten
            }
        }
    }

    // MARK: - Redaction (AN-7)

    /// Mosaic block size for a redaction: large enough that text can't be read back.
    public static func blockSize(for rect: CGRect) -> Int {
        max(12, Int((min(rect.width, rect.height) / 4).rounded()))
    }

    /// The pixels under `rect`, replaced by flat blocks of their average color.
    public static func pixelated(_ image: CGImage, rect: CGRect) -> CGImage? {
        guard let r = RectGeometry.clamp(rect, toImage: CGSize(width: image.width, height: image.height)),
              let patch = image.cropping(to: r), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let block = blockSize(for: r)
        let cols = max(1, Int((r.width / Double(block)).rounded(.up)))
        let rows = max(1, Int((r.height / Double(block)).rounded(.up)))
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        // Shrink to one pixel per block (averaging), then scale back up with no smoothing.
        guard let small = CGContext(data: nil, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info),
              let big = CGContext(data: nil, width: Int(r.width), height: Int(r.height), bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
        else { return nil }
        small.interpolationQuality = .medium
        small.draw(patch, in: CGRect(x: 0, y: 0, width: cols, height: rows))
        guard let tiny = small.makeImage() else { return nil }
        big.interpolationQuality = .none
        // Align the blocks to the patch's top edge.
        big.draw(tiny, in: CGRect(x: 0, y: Double(Int(r.height)) - Double(rows * block), width: Double(cols * block), height: Double(rows * block)))
        return big.makeImage()
    }

    /// Draws each redaction's pixelated patch, in a top-left, image-pixel context.
    public static func drawRedactions(_ annotations: [Annotation], base: CGImage, in context: CGContext) {
        let size = CGSize(width: base.width, height: base.height)
        for annotation in annotations {
            guard case .redaction(let rect) = annotation.kind,
                  let r = RectGeometry.clamp(rect, toImage: size),
                  let patch = pixelated(base, rect: r) else { continue }
            drawImage(patch, in: r, context: context)
        }
    }

    /// Draws an image upright in a context whose y axis points down.
    public static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    /// The crop in a list of annotations, clipped to the image.
    public static func crop(in annotations: [Annotation], imageSize: CGSize) -> CGRect? {
        for annotation in annotations {
            if case .crop(let r) = annotation.kind { return RectGeometry.clamp(r, toImage: imageSize) }
        }
        return nil
    }

    /// A tapered shaft (thin tail, full width at the head), straight or bent, and an open
    /// chevron head with round ends, in one color with a soft shadow.
    public static func draw(_ arrow: Arrow, in context: CGContext) {
        let w = arrow.lineWidth
        let head = ArrowGeometry.head(arrow)
        let tail = w * 0.3, full = w / 2

        // The shaft's outline: offset each sample sideways by a width that grows from the
        // tail to the head, down one side and back up the other.
        let pts = ArrowGeometry.samples(arrow)
        var left: [CGPoint] = [], right: [CGPoint] = []
        for (i, p) in pts.enumerated() {
            let prev = pts[max(0, i - 1)], next = pts[min(pts.count - 1, i + 1)]
            let dx = next.x - prev.x, dy = next.y - prev.y
            let len = max(hypot(dx, dy), 0.0001)
            let nx = -dy / len, ny = dx / len
            let half = tail + (full - tail) * Double(i) / Double(max(1, pts.count - 1))
            left.append(CGPoint(x: p.x + nx * half, y: p.y + ny * half))
            right.append(CGPoint(x: p.x - nx * half, y: p.y - ny * half))
        }

        context.saveGState()
        softShadow(context, size: w)
        context.setFillColor(arrow.color.cgColor)
        context.setStrokeColor(arrow.color.cgColor)
        context.beginTransparencyLayer(auxiliaryInfo: nil)

        context.addLines(between: left + right.reversed())
        context.closePath()
        context.fillPath()
        context.fillEllipse(in: CGRect(x: arrow.start.x - tail, y: arrow.start.y - tail, width: tail * 2, height: tail * 2))

        // Head: two arms meeting at the tip.
        context.setLineWidth(w)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: head.left)
        context.addLine(to: arrow.end)
        context.addLine(to: head.right)
        context.strokePath()

        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// AN-6: a rectangle (slightly rounded corners) or ellipse outline with the arrows' shadow.
    public static func draw(_ shape: ShapeMark, in context: CGContext) {
        let r = shape.rect.standardized
        guard r.width > 0, r.height > 0 else { return }
        context.saveGState()
        softShadow(context, size: shape.lineWidth)
        context.setStrokeColor(shape.color.cgColor)
        context.setLineWidth(shape.lineWidth)
        context.setLineJoin(.round)
        switch shape.form {
        case .rectangle:
            let radius = ShapeGeometry.cornerRadius(shape)
            context.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        case .ellipse:
            context.addEllipse(in: r)
        }
        context.strokePath()
        context.restoreGState()
    }

    /// AN-9 pen: an opaque, rounded line with a soft shadow. AN-6 highlighter: a wide,
    /// see-through line with no shadow, drawn as one layer so its own overlaps don't darken.
    public static func draw(_ stroke: Stroke, in context: CGContext) {
        guard !stroke.points.isEmpty else { return }
        context.saveGState()
        if stroke.isHighlighter {
            context.setAlpha(Stroke.highlighterAlpha)
        } else {
            softShadow(context, size: stroke.lineWidth)
        }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setStrokeColor(stroke.color.cgColor)
        context.setLineWidth(stroke.drawnWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if stroke.points.count == 1, let p = stroke.points.first {
            context.setFillColor(stroke.color.cgColor)
            context.fillEllipse(in: CGRect(x: p.x - stroke.drawnWidth / 2, y: p.y - stroke.drawnWidth / 2,
                                           width: stroke.drawnWidth, height: stroke.drawnWidth))
        } else {
            context.addPath(StrokeGeometry.path(stroke.points))
            context.strokePath()
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// AN-8: a filled circle (a pill from 10 up) with a thin white ring and the number in
    /// black or white, whichever reads better on the color.
    public static func draw(_ badge: Badge, in context: CGContext) {
        let frame = BadgeLayout.frame(badge)
        let radius = frame.height / 2
        let shape = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.saveGState()
        softShadow(context, size: badge.diameter * 0.2)
        context.setFillColor(badge.color.cgColor)
        context.addPath(shape)
        context.fillPath()
        context.restoreGState()
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        context.setLineWidth(max(1.5, badge.diameter * 0.05))
        context.addPath(shape)
        context.strokePath()

        let font = BadgeLayout.font(badge)
        let line = BadgeLayout.line(badge, color: badge.color.contrasting.cgColor)
        let width = Double(CTLineGetTypographicBounds(line, nil, nil, nil))
        // Digits are cap-height tall: center that between the baseline and the cap line.
        let capHeight = Double(CTFontGetCapHeight(font))
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: frame.midX - width / 2, y: frame.midY + capHeight / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// A soft, low shadow that lifts marks off any background without an outline.
    private static func softShadow(_ context: CGContext, size: Double) {
        context.setShadow(offset: .zero, blur: max(3, size * 0.9), color: CGColor(gray: 0, alpha: 0.28))
    }

    public static func draw(_ label: TextLabel, in context: CGContext) {
        let frame = TextLayout.frame(label)
        let pad = TextLayout.padding(fontSize: label.fontSize)
        let lineHeight = TextLayout.lineHeight(fontSize: label.fontSize)
        let font = TextLayout.font(size: label.fontSize)
        let ascent = Double(CTFontGetAscent(font))

        context.saveGState()
        if label.hasBackground {
            context.setFillColor(label.color.cgColor)
            context.addPath(CGPath(roundedRect: frame, cornerWidth: pad, cornerHeight: pad, transform: nil))
            context.fillPath()
        } else {
            softShadow(context, size: label.fontSize * 0.25)
        }
        let textColor = label.hasBackground ? label.color.contrasting : label.color
        // Core Text draws with y up; flip each line around its baseline.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (index, line) in TextLayout.lines(label, color: textColor.cgColor).enumerated() {
            context.textPosition = CGPoint(x: frame.minX + pad, y: frame.minY + pad + ascent + lineHeight * Double(index))
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }

    /// The size of the exported image in pixels: the crop (or the whole image) × scale.
    public static func outputSize(imageSize: CGSize, annotations: [Annotation], scale: Double) -> (width: Int, height: Int) {
        let area = crop(in: annotations, imageSize: imageSize) ?? CGRect(origin: .zero, size: imageSize)
        return (max(1, Int((area.width * scale).rounded())), max(1, Int((area.height * scale).rounded())))
    }

    /// SX-1: the base image with redactions burned in and annotations drawn on top, cut to
    /// the crop, scaled by `scale` (1 = full captured pixels, 0.5 = "1×" on Retina).
    public static func flatten(_ image: CGImage, annotations: [Annotation], scale: Double = 1) -> CGImage? {
        let imageSize = CGSize(width: image.width, height: image.height)
        let area = crop(in: annotations, imageSize: imageSize) ?? CGRect(origin: .zero, size: imageSize)
        let (width, height) = outputSize(imageSize: imageSize, annotations: annotations, scale: scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Top-left, image-pixel coordinates, with the crop's corner at the origin.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        context.translateBy(x: -area.minX, y: -area.minY)
        context.interpolationQuality = .high
        context.saveGState()
        context.translateBy(x: 0, y: imageSize.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: imageSize))
        context.restoreGState()
        drawRedactions(annotations, base: image, in: context)
        draw(annotations, in: context)
        return context.makeImage()
    }
}

/// SX-2 and SX-4: PNG or JPEG through ImageIO, with no metadata copied in.
public enum ScreenshotEncoder {
    public static func encode(_ image: CGImage, format: ScreenshotFormat, jpegQuality: Double) -> Data? {
        let data = NSMutableData()
        let type = format == .png ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [:]
        var source = image
        if format == .jpeg {
            options[kCGImageDestinationLossyCompressionQuality] = max(0.05, min(1, jpegQuality))
            // JPEG has no alpha: put transparent window corners on white, not black.
            source = opaque(image) ?? image
        }
        // A fresh CGImage carries no EXIF, GPS or device fields; nothing else is added.
        CGImageDestinationAddImage(destination, source, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func opaque(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }
}
