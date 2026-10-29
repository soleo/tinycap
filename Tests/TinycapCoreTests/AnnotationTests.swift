import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import TinycapCore

final class ArrowGeometryTests: XCTestCase {
    func testSnap45KeepsLengthAndRoundsAngle() {
        let snapped = ArrowGeometry.snap45(from: .zero, to: CGPoint(x: 100, y: 10)) // ~6°
        XCTAssertEqual(snapped.x, hypot(100, 10), accuracy: 0.001)
        XCTAssertEqual(snapped.y, 0, accuracy: 0.001)

        let diagonal = ArrowGeometry.snap45(from: .zero, to: CGPoint(x: 100, y: 90)) // ~42°
        XCTAssertEqual(diagonal.x, diagonal.y, accuracy: 0.001)
        XCTAssertEqual(hypot(diagonal.x, diagonal.y), hypot(100, 90), accuracy: 0.001)
    }

    func testSnapOfZeroLengthIsUnchanged() {
        XCTAssertEqual(ArrowGeometry.snap45(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 5, y: 5)), CGPoint(x: 5, y: 5))
    }

    func testDistanceToSegment() {
        XCTAssertEqual(ArrowGeometry.distance(from: CGPoint(x: 50, y: 10), toSegment: .zero, CGPoint(x: 100, y: 0)), 10, accuracy: 0.001)
        XCTAssertEqual(ArrowGeometry.distance(from: CGPoint(x: -30, y: 40), toSegment: .zero, CGPoint(x: 100, y: 0)), 50, accuracy: 0.001)
    }

    func testHeadSitsBehindTheTip() {
        let arrow = Arrow(start: .zero, end: CGPoint(x: 100, y: 0), color: RGBAColor.presets[0], lineWidth: 8)
        let head = ArrowGeometry.head(arrow)
        XCTAssertLessThan(head.base.x, 100)
        XCTAssertEqual(head.left.x, head.right.x, accuracy: 0.001)
        XCTAssertEqual(head.left.y, -head.right.y, accuracy: 0.001)
        // 40° arms: the spread is wider than the distance back from the tip.
        XCTAssertGreaterThan(abs(head.left.y), (100 - head.base.x) * 0.8)
    }
}

final class AnnotationModelTests: XCTestCase {
    private let red = RGBAColor.presets[0]

    func testHitTestPrefersTopmostAndRespectsTolerance() {
        let arrow = Annotation(.arrow(Arrow(start: CGPoint(x: 0, y: 50), end: CGPoint(x: 200, y: 50), color: red, lineWidth: 4)))
        let text = Annotation(.text(TextLabel(origin: CGPoint(x: 80, y: 30), text: "Hi", fontSize: 30, color: red, hasBackground: false)))
        XCTAssertEqual(AnnotationHitTest.hit(CGPoint(x: 90, y: 45), in: [arrow, text], tolerance: 4)?.id, text.id)
        XCTAssertEqual(AnnotationHitTest.hit(CGPoint(x: 20, y: 54), in: [arrow, text], tolerance: 4)?.id, arrow.id)
        XCTAssertNil(AnnotationHitTest.hit(CGPoint(x: 20, y: 90), in: [arrow, text], tolerance: 4))
    }

    func testMoveAndRestyle() {
        let arrow = Annotation(.arrow(Arrow(start: .zero, end: CGPoint(x: 10, y: 0), color: red, lineWidth: 4)))
        guard case .arrow(let moved) = arrow.moved(by: CGVector(dx: 5, dy: 7)).kind else { return XCTFail() }
        XCTAssertEqual(moved.start, CGPoint(x: 5, y: 7))
        XCTAssertEqual(moved.end, CGPoint(x: 15, y: 7))

        let blue = AnnotationStyle(color: RGBAColor.presets[3], lineWidth: 14, fontSize: 56, textBackground: true)
        guard case .arrow(let styled) = arrow.restyled(blue).kind else { return XCTFail() }
        XCTAssertEqual(styled.color, RGBAColor.presets[3])
        XCTAssertEqual(styled.lineWidth, 14)
    }

    func testTextFrameGrowsWithLinesAndSize() {
        let one = TextLabel(origin: .zero, text: "Hello", fontSize: 20, color: red, hasBackground: false)
        var two = one
        two.text = "Hello\nWorld"
        var big = one
        big.fontSize = 40
        XCTAssertGreaterThan(TextLayout.frame(two).height, TextLayout.frame(one).height * 1.5)
        XCTAssertGreaterThan(TextLayout.frame(big).width, TextLayout.frame(one).width * 1.5)
    }

    func testAnnotationsRoundTripAsJSON() throws {
        let items = [
            Annotation(.arrow(Arrow(start: .zero, end: CGPoint(x: 3, y: 4), color: red, lineWidth: 8))),
            Annotation(.text(TextLabel(origin: CGPoint(x: 1, y: 2), text: "Note", fontSize: 36, color: red, hasBackground: true))),
        ]
        XCTAssertEqual(try JSONDecoder().decode([Annotation].self, from: JSONEncoder().encode(items)), items)
    }

    func testContrastingColor() {
        XCTAssertEqual(RGBAColor.presets[1].contrasting, RGBAColor(red: 0, green: 0, blue: 0)) // yellow → black text
        XCTAssertEqual(RGBAColor.presets[3].contrasting, RGBAColor(red: 1, green: 1, blue: 1)) // blue → white text
    }
}

final class ScreenshotRenderTests: XCTestCase {
    private func solidImage(width: Int, height: Int, gray: CGFloat, alpha: CGFloat = 1) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// RGBA at (x, y) with y measured from the top.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return data
    }

    func testFlattenDrawsArrowWhereTheModelSays() {
        let base = solidImage(width: 200, height: 100, gray: 1)
        // A horizontal red arrow near the top: y is measured from the top.
        let arrow = Annotation(.arrow(Arrow(start: CGPoint(x: 10, y: 20), end: CGPoint(x: 190, y: 20), color: RGBAColor.presets[0], lineWidth: 8)))
        let flat = AnnotationRenderer.flatten(base, annotations: [arrow])!
        XCTAssertEqual(flat.width, 200)
        let onArrow = pixel(flat, x: 60, y: 20)
        XCTAssertGreaterThan(onArrow[0], 200)
        XCTAssertLessThan(onArrow[1], 120, "the arrow is pink at the top")
        let below = pixel(flat, x: 60, y: 80)
        XCTAssertEqual(below[1], 255, "the bottom stays white")
    }

    func testFlattenAtHalfScale() {
        let flat = AnnotationRenderer.flatten(solidImage(width: 200, height: 100, gray: 1), annotations: [], scale: 0.5)!
        XCTAssertEqual(flat.width, 100)
        XCTAssertEqual(flat.height, 50)
    }

    func testTextWithBackgroundIsDrawn() {
        let base = solidImage(width: 300, height: 120, gray: 1)
        let label = Annotation(.text(TextLabel(origin: CGPoint(x: 10, y: 10), text: "Hello", fontSize: 40,
                                               color: RGBAColor.presets[3], hasBackground: true)))
        let flat = AnnotationRenderer.flatten(base, annotations: [label])!
        let frame = label.bounds
        let corner = pixel(flat, x: Int(frame.minX) + 4, y: Int(frame.midY))
        XCTAssertGreaterThan(corner[2], 200, "blue background behind the text")
        XCTAssertLessThan(corner[0], 60)
    }

    func testPNGKeepsAlphaAndJPEGIsOpaqueWithoutMetadata() throws {
        let image = solidImage(width: 40, height: 30, gray: 0.5, alpha: 0.5)
        let png = try XCTUnwrap(ScreenshotEncoder.encode(image, format: .png, jpegQuality: 0.8))
        let jpeg = try XCTUnwrap(ScreenshotEncoder.encode(image, format: .jpeg, jpegQuality: 0.8))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])

        for data in [png, jpeg] {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            XCTAssertNil(props[kCGImagePropertyGPSDictionary], "no location")
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            XCTAssertNil(tiff[kCGImagePropertyTIFFMake], "no device make")
            XCTAssertNil(tiff[kCGImagePropertyTIFFModel], "no device model")
            XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 40)
        }
        let pngProps = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, nil) as? [CFString: Any]
        XCTAssertEqual(pngProps?[kCGImagePropertyHasAlpha] as? Bool, true)
        let decoded = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(jpeg as CFData, nil)!, 0, nil)!
        XCTAssertGreaterThan(pixel(decoded, x: 20, y: 15)[0], 150, "transparent areas become light, not black")
    }

    func testJPEGQualityChangesSize() throws {
        // A noisy image, so quality matters.
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var seed: UInt32 = 7
        for y in 0..<64 { for x in 0..<64 {
            seed = seed &* 1_103_515_245 &+ 12345
            context.setFillColor(CGColor(gray: CGFloat(seed % 256) / 255, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        let image = context.makeImage()!
        let low = try XCTUnwrap(ScreenshotEncoder.encode(image, format: .jpeg, jpegQuality: 0.2))
        let high = try XCTUnwrap(ScreenshotEncoder.encode(image, format: .jpeg, jpegQuality: 0.95))
        XCTAssertLessThan(low.count, high.count)
    }
}

final class ScreenshotSettingsTests: XCTestCase {
    func testDefaultsAndRoundTrip() {
        let defaults = UserDefaults(suiteName: "tinycap.tests.screenshot")!
        defaults.removePersistentDomain(forName: "tinycap.tests.screenshot")
        XCTAssertEqual(ScreenshotSettings(defaults: defaults), ScreenshotSettings())
        XCTAssertEqual(ScreenshotSettings().afterCapture, .thumbnail)
        XCTAssertEqual(ScreenshotSettings().format, .png)

        var settings = ScreenshotSettings(afterCapture: .copy, format: .jpeg, jpegQuality: 0.6, scale: .standard, windowShadow: false)
        settings.style.color = RGBAColor.presets[2]
        settings.save(to: defaults)
        XCTAssertEqual(ScreenshotSettings(defaults: defaults), settings)

        ScreenshotSettings.saveStyle(AnnotationStyle(lineWidth: 14), to: defaults)
        XCTAssertEqual(ScreenshotSettings(defaults: defaults).style.lineWidth, 14)
        XCTAssertEqual(ScreenshotSettings(defaults: defaults).format, .jpeg, "saving the style leaves other settings alone")
    }

    func testScaleFactor() {
        XCTAssertEqual(ScreenshotScale.retina.factor(pixelsPerPoint: 2), 1)
        XCTAssertEqual(ScreenshotScale.standard.factor(pixelsPerPoint: 2), 0.5)
        XCTAssertEqual(ScreenshotScale.standard.factor(pixelsPerPoint: 1), 1)
    }
}

final class ScreenshotFilenameTests: XCTestCase {
    func testDefaultPatternBecomesScreenshotCustomStays() {
        XCTAssertEqual(FilenamePattern().forScreenshots.pattern, "Screenshot {date} at {time}")
        XCTAssertEqual(FilenamePattern("Clip {date}").forScreenshots.pattern, "Clip {date}")
    }
}

final class StyleMigrationTests: XCTestCase {
    func testRetiredRedBecomesPink() {
        let defaults = UserDefaults(suiteName: "tinycap.tests.style")!
        defaults.removePersistentDomain(forName: "tinycap.tests.style")
        ScreenshotSettings.saveStyle(AnnotationStyle(color: ScreenshotSettings.retiredRed), to: defaults)
        XCTAssertEqual(ScreenshotSettings(defaults: defaults).style.color, RGBAColor.presets[0])
        ScreenshotSettings.saveStyle(AnnotationStyle(color: RGBAColor.presets[3]), to: defaults)
        XCTAssertEqual(ScreenshotSettings(defaults: defaults).style.color, RGBAColor.presets[3])
    }
}

final class BentArrowTests: XCTestCase {
    private let pink = RGBAColor.presets[0]

    func testMidpointSitsBendAwayFromTheChord() {
        let arrow = Arrow(start: .zero, end: CGPoint(x: 200, y: 0), color: pink, lineWidth: 8, bend: 40)
        let mid = ArrowGeometry.midpoint(arrow)
        XCTAssertEqual(mid.x, 100, accuracy: 0.001)
        XCTAssertEqual(abs(mid.y), 40, accuracy: 0.001)
    }

    func testBendThroughPointAndSnap() {
        let arrow = Arrow(start: .zero, end: CGPoint(x: 200, y: 0), color: pink, lineWidth: 8)
        let bent = ArrowGeometry.bend(arrow, through: CGPoint(x: 90, y: -30), snap: 5)
        var check = arrow
        check.bend = bent
        XCTAssertEqual(ArrowGeometry.midpoint(check).y, -30, accuracy: 0.001)
        XCTAssertEqual(ArrowGeometry.bend(arrow, through: CGPoint(x: 100, y: 3), snap: 5), 0, "near the line snaps straight")
    }

    func testHeadFollowsTheCurve() {
        let straight = Arrow(start: .zero, end: CGPoint(x: 200, y: 0), color: pink, lineWidth: 8)
        var bent = straight
        bent.bend = 60
        // Straight: the head's arms are symmetric about the x axis. Bent: they tilt.
        let s = ArrowGeometry.head(straight), b = ArrowGeometry.head(bent)
        XCTAssertEqual(s.left.y + s.right.y, 0, accuracy: 0.001)
        XCTAssertGreaterThan(abs(b.left.y + b.right.y), 4)
    }

    func testHitTestFollowsTheCurve() {
        let arrow = Annotation(.arrow(Arrow(start: .zero, end: CGPoint(x: 200, y: 0), color: pink, lineWidth: 6, bend: 50)))
        let mid = ArrowGeometry.midpoint({ if case .arrow(let a) = arrow.kind { return a }; fatalError() }())
        XCTAssertNotNil(AnnotationHitTest.hit(mid, in: [arrow], tolerance: 4))
        XCTAssertNil(AnnotationHitTest.hit(CGPoint(x: 100, y: 0), in: [arrow], tolerance: 4), "the chord itself is empty")
    }

    func testMovingKeepsTheBend() {
        let arrow = Annotation(.arrow(Arrow(start: .zero, end: CGPoint(x: 100, y: 0), color: pink, lineWidth: 6, bend: 25)))
        guard case .arrow(let moved) = arrow.moved(by: CGVector(dx: 10, dy: 10)).kind else { return XCTFail() }
        XCTAssertEqual(moved.bend, 25)
    }
}

final class CropAndRedactTests: XCTestCase {
    /// Vertical black/white stripes 2 px wide: fine detail that pixelation must wipe out.
    private func stripes(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for x in stride(from: 0, to: width, by: 4) { context.fill(CGRect(x: x, y: 0, width: 2, height: height)) }
        return context.makeImage()!
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return data
    }

    func testRedactionFlattensDetailOnlyInsideTheRect() {
        let base = stripes(width: 200, height: 100)
        let flat = AnnotationRenderer.flatten(base, annotations: [Annotation(.redaction(CGRect(x: 0, y: 0, width: 100, height: 100)))])!
        // Inside: neighbouring columns that were black and white now match (one block).
        let a = pixel(flat, x: 10, y: 10), b = pixel(flat, x: 12, y: 10)
        XCTAssertEqual(Int(a[0]), Int(b[0]), accuracy: 2)
        XCTAssertGreaterThan(a[0], 60); XCTAssertLessThan(a[0], 200) // a gray average, not black or white
        // Outside: stripes untouched.
        XCTAssertLessThan(pixel(flat, x: 152, y: 10)[0], 30)
        XCTAssertGreaterThan(pixel(flat, x: 154, y: 10)[0], 220)
    }

    func testArrowsDrawOverRedactions() {
        let base = stripes(width: 200, height: 100)
        let flat = AnnotationRenderer.flatten(base, annotations: [
            Annotation(.arrow(Arrow(start: CGPoint(x: 10, y: 50), end: CGPoint(x: 190, y: 50), color: RGBAColor.presets[0], lineWidth: 10))),
            Annotation(.redaction(CGRect(x: 0, y: 0, width: 200, height: 100))), // later in the list, still underneath
        ])!
        let p = pixel(flat, x: 80, y: 50)
        XCTAssertGreaterThan(p[0], 200); XCTAssertLessThan(p[1], 120)
    }

    func testCropSetsTheOutputAndOffsetsMarks() {
        let base = stripes(width: 200, height: 100)
        let crop = Annotation(.crop(CGRect(x: 50, y: 20, width: 80, height: 40)))
        let arrow = Annotation(.arrow(Arrow(start: CGPoint(x: 55, y: 40), end: CGPoint(x: 125, y: 40), color: RGBAColor.presets[0], lineWidth: 8)))
        let flat = AnnotationRenderer.flatten(base, annotations: [crop, arrow])!
        XCTAssertEqual(flat.width, 80); XCTAssertEqual(flat.height, 40)
        let onArrow = pixel(flat, x: 30, y: 20) // (80, 40) in the full image
        XCTAssertGreaterThan(onArrow[0], 200); XCTAssertLessThan(onArrow[1], 120)
        XCTAssertEqual(AnnotationRenderer.outputSize(imageSize: CGSize(width: 200, height: 100), annotations: [crop], scale: 0.5).width, 40)
    }

    func testCropOutsideTheImageIsClipped() {
        let crop = Annotation(.crop(CGRect(x: 150, y: -20, width: 100, height: 60)))
        XCTAssertEqual(AnnotationRenderer.crop(in: [crop], imageSize: CGSize(width: 200, height: 100)), CGRect(x: 150, y: 0, width: 50, height: 40))
    }

    func testCornerDragKeepsOppositeCorner() {
        let r = CGRect(x: 10, y: 10, width: 100, height: 50)
        XCTAssertEqual(RectGeometry.drag(r, corner: 2, to: CGPoint(x: 150, y: 90)), CGRect(x: 10, y: 10, width: 140, height: 80))
        XCTAssertEqual(RectGeometry.drag(r, corner: 0, to: CGPoint(x: 0, y: 0)), CGRect(x: 0, y: 0, width: 110, height: 60))
        XCTAssertEqual(RectGeometry.drag(r, corner: 2, to: CGPoint(x: 11, y: 11)).width, 4, "never thinner than the minimum")
    }

    func testCropIsNotSelectableButRedactionIs() {
        let crop = Annotation(.crop(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let redaction = Annotation(.redaction(CGRect(x: 20, y: 20, width: 30, height: 30)))
        XCTAssertEqual(AnnotationHitTest.hit(CGPoint(x: 30, y: 30), in: [crop, redaction], tolerance: 2)?.id, redaction.id)
        XCTAssertNil(AnnotationHitTest.hit(CGPoint(x: 80, y: 80), in: [crop, redaction], tolerance: 2))
    }
}
