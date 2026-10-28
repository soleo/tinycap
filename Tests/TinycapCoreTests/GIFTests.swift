import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import TinycapCore

/// Decodes with ImageIO, so these tests check the encoder against Apple's GIF reader.
final class GIFEncoderTests: XCTestCase {
    /// A BGRA test frame.
    struct Frame {
        let width: Int, height: Int
        var bytes: [UInt8]
        init(width: Int, height: Int, fill: (Int, Int) -> (UInt8, UInt8, UInt8)) {
            self.width = width
            self.height = height
            bytes = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let (r, g, b) = fill(x, y)
                    let i = (y * width + x) * 4
                    bytes[i] = b; bytes[i + 1] = g; bytes[i + 2] = r
                }
            }
        }
        func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let i = (y * width + x) * 4
            return (bytes[i + 2], bytes[i + 1], bytes[i])
        }
    }

    private let colors: [(UInt8, UInt8, UInt8)] = [
        (255, 255, 255), (30, 30, 30), (0, 102, 255), (230, 40, 40), (40, 180, 90), (250, 200, 0), (128, 128, 128),
    ]

    /// UI-like frames: stripes plus a moving box; 7 exact colors so the palette is lossless.
    private func frames(count: Int, width: Int = 61, height: Int = 37) -> [Frame] {
        (0..<count).map { k in
            Frame(width: width, height: height) { x, y in
                if x >= 5 + k * 6 && x < 15 + k * 6 && y >= 10 && y < 20 { return self.colors[3] }
                if y < 6 { return self.colors[2] }
                return self.colors[(x / 7 + y / 5) % 7 == 3 ? 3 : (x / 7 + y / 5) % 2 == 0 ? 0 : 6]
            }
        }
    }

    private func palette(for frames: [Frame], maxColors: Int = 16) -> GIFPalette {
        var builder = PaletteBuilder()
        for f in frames {
            f.bytes.withUnsafeBytes { builder.add(bgra: $0.baseAddress!, width: f.width, height: f.height, bytesPerRow: f.width * 4, step: 1) }
        }
        return builder.build(maxColors: maxColors, reserveTransparent: true)
    }

    private func encode(_ frames: [Frame], palette: GIFPalette, options: GIFEncoder.Options = .init(), delays: [Int]? = nil) -> (Data, GIFEncoder) {
        var data = Data()
        let encoder = GIFEncoder(width: frames[0].width, height: frames[0].height, palette: palette, options: options) { data.append($0) }
        for (k, f) in frames.enumerated() {
            f.bytes.withUnsafeBytes { encoder.addFrame(bgra: $0.baseAddress!, bytesPerRow: f.width * 4, delay: delays?[k] ?? 10) }
        }
        encoder.finish()
        return (data, encoder)
    }

    /// RGBA pixels of each frame as ImageIO composites them.
    private func decode(_ data: Data) throws -> (frames: [[UInt8]], delays: [Double], loopCount: Int?) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        var frames: [[UInt8]] = [], delays: [Double] = []
        for i in 0..<CGImageSourceGetCount(source) {
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, i, nil))
            var px = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let ctx = try XCTUnwrap(CGContext(data: &px, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            frames.append(px)
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            delays.append(gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? 0)
        }
        let container = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let loop = (container?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
        return (frames, delays, loop)
    }

    private func assertMatches(_ decoded: [UInt8], _ frame: Frame, tolerance: Int = 2, file: StaticString = #filePath, line: UInt = #line) {
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let i = (y * frame.width + x) * 4
                let (r, g, b) = frame.pixel(x, y)
                let ok = abs(Int(decoded[i]) - Int(r)) <= tolerance && abs(Int(decoded[i + 1]) - Int(g)) <= tolerance
                    && abs(Int(decoded[i + 2]) - Int(b)) <= tolerance && decoded[i + 3] == 255
                if !ok {
                    XCTFail("pixel (\(x),\(y)) decoded \(decoded[i..<i + 4]) expected \((r, g, b))", file: file, line: line)
                    return
                }
            }
        }
    }

    func testRoundTripThroughImageIO() throws {
        let input = frames(count: 5)
        let p = palette(for: input)
        XCTAssertEqual(p.colorCount, 4, "4 distinct colors in these frames")
        let (data, encoder) = encode(input, palette: p, delays: [8, 8, 9, 8, 8])
        XCTAssertEqual(encoder.framesWritten, 5)

        let decoded = try decode(data)
        XCTAssertEqual(decoded.frames.count, 5)
        for (k, frame) in input.enumerated() { assertMatches(decoded.frames[k], frame) }
        XCTAssertEqual(decoded.delays.map { Int(($0 * 100).rounded()) }, [8, 8, 9, 8, 8])
        XCTAssertEqual(decoded.loopCount, 0, "loops forever")
    }

    func testDuplicateFramesMergeIntoLongerDelay() throws {
        let f = frames(count: 2)
        let input = [f[0], f[0], f[0], f[1]]
        let (data, encoder) = encode(input, palette: palette(for: input))
        XCTAssertEqual(encoder.framesWritten, 2)
        let decoded = try decode(data)
        XCTAssertEqual(decoded.delays.map { Int(($0 * 100).rounded()) }, [30, 10])
        assertMatches(decoded.frames[1], f[1])
    }

    func testKeepingDuplicatesAndNoLoop() throws {
        let f = frames(count: 1)
        let input = [f[0], f[0], f[0]]
        let (data, encoder) = encode(input, palette: palette(for: input), options: .init(loop: false, dropDuplicates: false))
        XCTAssertEqual(encoder.framesWritten, 3)
        let decoded = try decode(data)
        XCTAssertEqual(decoded.frames.count, 3)
        assertMatches(decoded.frames[2], f[0])
        // No NETSCAPE loop block: viewers play it once (ImageIO reports that as 1).
        XCTAssertNil(data.range(of: Data("NETSCAPE2.0".utf8)))
        XCTAssertNotEqual(decoded.loopCount, 0)
    }

    func testOnlyChangedRegionIsStored() {
        // A big static frame followed by one with a single changed pixel.
        let a = Frame(width: 400, height: 300) { x, y in ((x * 7 % 3 == 0) ? (255, 255, 255) : (30, 30, 30)) }
        var b = a
        b.bytes[(150 * 400 + 200) * 4 + 2] = 230
        let (data, encoder) = encode([a, b], palette: palette(for: [a, b]))
        let first = encoder.firstFrameBytes!
        XCTAssertLessThan(data.count - first, 60, "second frame stores ~1 pixel, not the whole canvas")
    }

    func testLargeNoisyFrameExercisesFullLZWTable() throws {
        // 256-color noise forces 12-bit codes and table clears.
        var seed: UInt32 = 12345
        func next() -> UInt8 { seed = seed &* 1_103_515_245 &+ 12345; return UInt8(truncatingIfNeeded: seed >> 16) }
        var builder = PaletteBuilder()
        let frame = Frame(width: 300, height: 200) { _, _ in
            let v = next() & 0b1110_0000
            return (v, v >> 1, 255 - v)
        }
        frame.bytes.withUnsafeBytes { builder.add(bgra: $0.baseAddress!, width: 300, height: 200, bytesPerRow: 1200, step: 1) }
        let p = builder.build(maxColors: 256, reserveTransparent: true)
        let (data, _) = encode([frame], palette: p)
        let decoded = try decode(data)
        assertMatches(decoded.frames[0], frame)
    }

    func testDitheringStillDecodesAndUsesPalette() throws {
        let gradient = Frame(width: 128, height: 16) { x, _ in (UInt8(x * 2), UInt8(x * 2), UInt8(x * 2)) }
        var builder = PaletteBuilder()
        gradient.bytes.withUnsafeBytes { builder.add(bgra: $0.baseAddress!, width: 128, height: 16, bytesPerRow: 512, step: 1) }
        let p = builder.build(maxColors: 8, reserveTransparent: true)
        let (data, _) = encode([gradient], palette: p, options: .init(dither: true))
        let decoded = try decode(data)
        // Average brightness across each column block should track the gradient.
        let px = decoded.frames[0]
        for block in stride(from: 0, to: 128, by: 32) {
            var sum = 0
            for y in 0..<16 { for x in block..<(block + 32) { sum += Int(px[(y * 128 + x) * 4]) } }
            let mean = sum / (16 * 32)
            let expected = (block + 16) * 2
            XCTAssertLessThan(abs(mean - expected), 24, "block \(block): mean \(mean) vs \(expected)")
        }
    }
}

final class GIFPaletteTests: XCTestCase {
    func testExactColorsWhenFewerThanPaletteSize() {
        var b = PaletteBuilder()
        for _ in 0..<100 { b.add(r: 10, g: 200, b: 30) }
        b.add(r: 250, g: 250, b: 250)
        let p = b.build(maxColors: 32, reserveTransparent: true)
        XCTAssertEqual(p.colorCount, 2)
        XCTAssertEqual(p.transparentIndex, 2)
        XCTAssertEqual(p.tableBits, 2)
        let i = Int(p.index(r: 10, g: 200, b: 30))
        XCTAssertTrue(p.color(at: i) == (10, 200, 30))
    }

    func testMedianCutLimitsColorsAndMapsNearest() {
        var b = PaletteBuilder()
        for v in 0..<256 { b.add(r: UInt8(v), g: UInt8(255 - v), b: 128) }
        let p = b.build(maxColors: 16, reserveTransparent: true)
        XCTAssertEqual(p.colorCount, 15)
        XCTAssertEqual(p.tableBits, 4)
        for v in stride(from: 0, to: 256, by: 17) {
            let c = p.color(at: Int(p.index(r: UInt8(v), g: UInt8(255 - v), b: 128)))
            XCTAssertLessThan(abs(Int(c.r) - v), 24)
        }
    }

    func testEmptyHistogram() {
        let p = PaletteBuilder().build(maxColors: 64, reserveTransparent: false)
        XCTAssertEqual(p.colorCount, 1)
        XCTAssertNil(p.transparentIndex)
    }
}

final class GIFSettingsTests: XCTestCase {
    func testDelaysSumToDuration() {
        for fps in [5, 7, 12, 15, 24, 30] {
            let frames = fps * 10
            let total = (0..<frames).reduce(0) { $0 + GIFTiming.delay(ofFrame: $1, fps: fps) }
            XCTAssertEqual(total, 1000, "fps \(fps)")
        }
        XCTAssertEqual((0..<6).map { GIFTiming.delay(ofFrame: $0, fps: 12) }, [8, 9, 8, 8, 9, 8])
        XCTAssertEqual(GIFTiming.frameCount(duration: 2.01, fps: 10), 21)
    }

    func testPresetsAndClamping() {
        XCTAssertEqual(GIFSettings().preset, .balanced)
        XCTAssertEqual(GIFPreset.small.settings.preset, .small)
        XCTAssertNil(GIFSettings(fps: 20).preset)
        XCTAssertEqual(GIFSettings(fps: 99).fps, 30)
        XCTAssertEqual(GIFSettings(colors: 100).colors, 128)
    }

    func testFitLadderGetsSmallerAndStops() {
        let ladder = GIFPreset.high.settings.fitLadder(sourceWidth: 2560)
        XCTAssertEqual(ladder.first, GIFSettings(fps: 15, scale: .width(1280), colors: 256, dither: false))
        XCTAssertEqual(ladder[1].colors, 128)
        XCTAssertEqual(ladder[2].colors, 64)
        XCTAssertEqual(ladder[3].fps, 10)
        XCTAssertEqual(ladder[4].fps, 8)
        let widths = ladder.compactMap { s -> Int? in if case .width(let w) = s.scale { return w } else { return nil } }
        XCTAssertEqual(widths.last, 320)
        XCTAssertEqual(widths, widths.sorted(by: >))
        XCTAssertTrue(GIFSettings(fps: 8, scale: .width(320), colors: 64).fitLadder(sourceWidth: 2560).isEmpty)
    }

    func testDefaultsRoundTrip() {
        let defaults = UserDefaults(suiteName: "GIFSettingsTests-\(UUID().uuidString)")!
        XCTAssertEqual(GIFSettings(defaults: defaults), GIFPreset.balanced.settings)
        let custom = GIFSettings(fps: 20, scale: .half, colors: 64, dither: true, loop: false, dropDuplicates: false)
        custom.save(to: defaults)
        XCTAssertEqual(GIFSettings(defaults: defaults), custom)
    }
}
