import Foundation

/// Streaming GIF89a encoder tuned for screen recordings.
///
/// - One global palette (from `PaletteBuilder`) keeps colors stable across frames.
/// - Each frame after the first stores only the bounding box of pixels that changed;
///   unchanged pixels inside the box use the transparent index, which LZW compresses
///   to almost nothing. Frames are drawn with disposal "leave in place".
/// - Frames identical to the previous one are merged by extending its delay.
/// - Optional ordered (8×8 Bayer) dithering, which unlike error diffusion doesn't
///   shimmer between frames or defeat the change detection.
///
/// Pure Swift, no ImageIO, so it is unit-testable and has no license constraints.
public final class GIFEncoder {
    public struct Options: Sendable {
        public var loop: Bool
        public var dither: Bool
        public var dropDuplicates: Bool
        public init(loop: Bool = true, dither: Bool = false, dropDuplicates: Bool = true) {
            self.loop = loop
            self.dither = dither
            self.dropDuplicates = dropDuplicates
        }
    }

    public let width: Int
    public let height: Int
    public let palette: GIFPalette
    public let options: Options
    public private(set) var bytesWritten = 0
    /// Bytes of the header and first frame, known once the second frame (or finish)
    /// flushes it. The size estimator counts this once rather than per sample piece.
    public private(set) var firstFrameBytes: Int?
    public private(set) var framesWritten = 0

    private let write: (Data) -> Void
    private var current: [UInt8]
    private var previous: [UInt8]?
    private var pending: Frame?
    private var finished = false
    private let ditherOffsets: [Int]

    private struct Frame {
        var x: Int, y: Int, w: Int, h: Int
        var lzw: [UInt8]
        var delay: Int
        var transparent: Bool
    }

    public init(width: Int, height: Int, palette: GIFPalette, options: Options = Options(), write: @escaping (Data) -> Void) {
        precondition(width > 0 && height > 0 && width <= 65535 && height <= 65535)
        self.width = width
        self.height = height
        self.palette = palette
        self.options = options
        self.write = write
        current = [UInt8](repeating: 0, count: width * height)

        // Bayer 8×8 thresholds centred on zero, scaled to roughly half the spacing
        // between palette colors.
        let bayer: [Int] = [
            0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26,
            12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
            3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
            15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21,
        ]
        let spread = 255.0 / cbrt(Double(max(palette.colorCount, 2))) * 0.5
        ditherOffsets = bayer.map { Int(((Double($0) + 0.5) / 64 - 0.5) * spread) }

        writeHeader()
    }

    // MARK: - Frames

    /// Adds a BGRA frame of `width` × `height` shown for `delay` centiseconds.
    public func addFrame(bgra: UnsafeRawPointer, bytesPerRow: Int, delay: Int) {
        precondition(!finished, "addFrame after finish")
        quantize(bgra, bytesPerRow: bytesPerRow)

        guard var prev = previous else {
            previous = current
            push(Frame(x: 0, y: 0, w: width, h: height, lzw: compress(current),
                       delay: delay, transparent: false))
            return
        }

        guard let box = changedBox(prev) else {
            repeatLastFrame(delay: delay)
            return
        }

        // Changed box with unchanged pixels made transparent, then remember the new state.
        var sub = [UInt8](repeating: 0, count: box.w * box.h)
        let t = palette.transparentIndex
        for row in 0..<box.h {
            let base = (box.y + row) * width + box.x
            for col in 0..<box.w {
                let i = base + col
                let c = current[i]
                sub[row * box.w + col] = (t != nil && c == prev[i]) ? t! : c
                prev[i] = c
            }
        }
        previous = prev
        push(Frame(x: box.x, y: box.y, w: box.w, h: box.h, lzw: compress(sub),
                   delay: delay, transparent: t != nil))
    }

    /// The source frame didn't change: lengthen the last frame, or (if duplicates are
    /// kept) add a 1×1 frame that redraws an unchanged pixel.
    public func repeatLastFrame(delay: Int) {
        precondition(!finished, "repeatLastFrame after finish")
        guard pending != nil, let prev = previous else { return }
        if options.dropDuplicates {
            pending!.delay += delay
            return
        }
        let pixel = palette.transparentIndex ?? prev[0]
        push(Frame(x: 0, y: 0, w: 1, h: 1, lzw: compress([pixel]),
                   delay: delay, transparent: palette.transparentIndex != nil))
    }

    /// Writes the last frame and the trailer. Safe to call once.
    public func finish() {
        guard !finished else { return }
        flushPending()
        emit([0x3B])
        finished = true
    }

    private func push(_ frame: Frame) {
        flushPending()
        pending = frame
    }

    private func flushPending() {
        guard let f = pending else { return }
        pending = nil
        var out: [UInt8] = []
        // Graphic Control Extension: disposal 1 (leave in place), optional transparency.
        let delay = min(max(f.delay, 1), 65535)
        out += [0x21, 0xF9, 0x04, UInt8(1 << 2) | (f.transparent ? 1 : 0)]
        out += le16(delay)
        out += [f.transparent ? (palette.transparentIndex ?? 0) : 0, 0x00]
        // Image Descriptor: no local color table, not interlaced.
        out += [0x2C] + le16(f.x) + le16(f.y) + le16(f.w) + le16(f.h) + [0x00]
        out.append(UInt8(minCodeSize))
        var i = 0
        while i < f.lzw.count {
            let n = min(255, f.lzw.count - i)
            out.append(UInt8(n))
            out += f.lzw[i..<(i + n)]
            i += n
        }
        out.append(0x00)
        emit(out)
        framesWritten += 1
        if firstFrameBytes == nil { firstFrameBytes = bytesWritten }
    }

    // MARK: - Pixels

    private func quantize(_ bgra: UnsafeRawPointer, bytesPerRow: Int) {
        let dither = options.dither
        current.withUnsafeMutableBufferPointer { out in
            palette.lut.withUnsafeBufferPointer { lut in
                ditherOffsets.withUnsafeBufferPointer { offsets in
                    for y in 0..<height {
                        let row = bgra.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                        let outRow = y * width
                        let ditherRow = (y & 7) * 8
                        for x in 0..<width {
                            let p = row + x * 4
                            var b = Int(p[0]), g = Int(p[1]), r = Int(p[2])
                            if dither {
                                let d = offsets[ditherRow + (x & 7)]
                                r = min(max(r + d, 0), 255); g = min(max(g + d, 0), 255); b = min(max(b + d, 0), 255)
                            }
                            out[outRow + x] = lut[(r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)]
                        }
                    }
                }
            }
        }
    }

    private func changedBox(_ prev: [UInt8]) -> (x: Int, y: Int, w: Int, h: Int)? {
        var minX = width, maxX = -1, minY = height, maxY = -1
        current.withUnsafeBufferPointer { cur in
            prev.withUnsafeBufferPointer { old in
                for y in 0..<height {
                    let base = y * width
                    // Fast whole-row check first; most rows of a screen recording are unchanged.
                    if memcmp(cur.baseAddress! + base, old.baseAddress! + base, width) == 0 { continue }
                    minY = min(minY, y); maxY = y
                    var x = 0
                    while x < width && cur[base + x] == old[base + x] { x += 1 }
                    minX = min(minX, x)
                    var r = width - 1
                    while r > x && cur[base + r] == old[base + r] { r -= 1 }
                    maxX = max(maxX, r)
                }
            }
        }
        guard maxY >= 0 else { return nil }
        return (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    // MARK: - Container

    private var minCodeSize: Int { max(2, palette.tableBits) }

    private func writeHeader() {
        var out: [UInt8] = Array("GIF89a".utf8)
        // Logical Screen Descriptor with a global color table.
        out += le16(width) + le16(height)
        out += [0x80 | 0x70 | UInt8(palette.tableBits - 1), 0x00, 0x00]
        out += palette.rgb
        if options.loop {
            // NETSCAPE2.0 application extension: loop forever.
            out += [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [0x03, 0x01, 0x00, 0x00, 0x00]
        }
        emit(out)
    }

    private func emit(_ bytes: [UInt8]) {
        bytesWritten += bytes.count
        write(Data(bytes))
    }

    private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

    // MARK: - LZW

    private func compress(_ pixels: [UInt8]) -> [UInt8] {
        GIFLZW.encode(pixels, minCodeSize: minCodeSize)
    }
}

/// GIF-flavoured LZW: variable code width from minCodeSize+1 up to 12 bits, a clear
/// code when the table fills, LSB-first bit packing.
enum GIFLZW {
    private static let tableSize = 5003 // prime, as in the classic `compress`

    static func encode(_ pixels: [UInt8], minCodeSize: Int) -> [UInt8] {
        let clear = 1 << minCodeSize
        let end = clear + 1
        var out: [UInt8] = []
        out.reserveCapacity(pixels.count / 2 + 16)

        var bitBuffer: UInt32 = 0
        var bitCount = 0
        var codeSize = minCodeSize + 1
        func emit(_ code: Int) {
            bitBuffer |= UInt32(code) << UInt32(bitCount)
            bitCount += codeSize
            while bitCount >= 8 {
                out.append(UInt8(bitBuffer & 0xFF))
                bitBuffer >>= 8
                bitCount -= 8
            }
        }

        var keys = [Int32](repeating: -1, count: tableSize)
        var codes = [UInt16](repeating: 0, count: tableSize)
        var nextCode = clear + 2

        emit(clear)
        guard let first = pixels.first else {
            emit(end)
            if bitCount > 0 { out.append(UInt8(bitBuffer & 0xFF)) }
            return out
        }

        var prefix = Int(first)
        for i in 1..<pixels.count {
            let c = Int(pixels[i])
            let key = Int32(prefix << 8 | c)
            var h = (c << 4 ^ prefix) % tableSize
            let step = h == 0 ? 1 : tableSize - h
            var found = false
            while keys[h] != -1 {
                if keys[h] == key { found = true; break }
                h -= step
                if h < 0 { h += tableSize }
            }
            if found {
                prefix = Int(codes[h])
                continue
            }
            emit(prefix)
            if nextCode < 4096 {
                keys[h] = key
                codes[h] = UInt16(nextCode)
                nextCode += 1
                // The decoder widens its codes one entry later than it adds them, so the
                // encoder widens as soon as the next code would no longer fit.
                if nextCode > (1 << codeSize) && codeSize < 12 { codeSize += 1 }
            } else {
                emit(clear)
                keys = [Int32](repeating: -1, count: tableSize)
                nextCode = clear + 2
                codeSize = minCodeSize + 1
            }
            prefix = c
        }
        emit(prefix)
        emit(end)
        if bitCount > 0 { out.append(UInt8(bitBuffer & 0xFF)) }
        return out
    }
}
