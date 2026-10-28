import Foundation

/// A GIF color table plus a lookup table that maps any color to its palette index.
public struct GIFPalette: Sendable {
    /// RGB triples, padded to `1 << tableBits` entries.
    public let rgb: [UInt8]
    /// Colors in use, excluding the transparent slot.
    public let colorCount: Int
    /// Index that marks "unchanged since the previous frame", if reserved.
    public let transparentIndex: UInt8?
    /// The GIF table holds `1 << tableBits` entries (1…8).
    public let tableBits: Int
    /// 15-bit color (5 bits per channel, r<<10 | g<<5 | b) → palette index.
    let lut: [UInt8]

    @inline(__always)
    public func index(r: UInt8, g: UInt8, b: UInt8) -> UInt8 {
        lut[Int(r >> 3) << 10 | Int(g >> 3) << 5 | Int(b >> 3)]
    }

    public func color(at index: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        (rgb[index * 3], rgb[index * 3 + 1], rgb[index * 3 + 2])
    }
}

/// Collects a color histogram from frames and builds a palette by median cut.
/// Colors are binned at 5 bits per channel, but each bin keeps the sum of its exact
/// colors, so palette entries are true averages and flat UI colors come out exact.
public struct PaletteBuilder: Sendable {
    private var counts = [UInt32](repeating: 0, count: 32768)
    private var sums = [UInt64](repeating: 0, count: 32768 * 3)

    public init() {}

    public var isEmpty: Bool { !counts.contains { $0 > 0 } }

    public mutating func add(r: UInt8, g: UInt8, b: UInt8, weight: UInt32 = 1) {
        let bin = Int(r >> 3) << 10 | Int(g >> 3) << 5 | Int(b >> 3)
        counts[bin] &+= weight
        sums[bin * 3] &+= UInt64(r) * UInt64(weight)
        sums[bin * 3 + 1] &+= UInt64(g) * UInt64(weight)
        sums[bin * 3 + 2] &+= UInt64(b) * UInt64(weight)
    }

    /// Adds every `step`-th pixel in both directions of a BGRA frame.
    public mutating func add(bgra: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int, step: Int = 2) {
        let s = max(step, 1)
        var y = 0
        while y < height {
            let row = bgra.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            var x = 0
            while x < width {
                let p = row + x * 4
                add(r: p[2], g: p[1], b: p[0])
                x += s
            }
            y += s
        }
    }

    /// `maxColors` is the GIF table size to fill (a power of two); one slot is kept for
    /// transparency when `reserveTransparent` is set.
    public func build(maxColors: Int, reserveTransparent: Bool) -> GIFPalette {
        let target = max(1, min(maxColors, 256) - (reserveTransparent ? 1 : 0))

        // Occupied bins with their average colors.
        var bins: [Int] = []
        var avg = [(r: Int, g: Int, b: Int)](repeating: (0, 0, 0), count: 32768)
        for bin in 0..<32768 where counts[bin] > 0 {
            bins.append(bin)
            let c = UInt64(counts[bin])
            avg[bin] = (Int(sums[bin * 3] / c), Int(sums[bin * 3 + 1] / c), Int(sums[bin * 3 + 2] / c))
        }
        if bins.isEmpty { bins = [0]; avg[0] = (0, 0, 0) }

        // Median cut over bin ranges [start, end) of `bins`. Each box caches its pixel
        // count and widest channel, so a split only measures the two new boxes.
        func channel(_ bin: Int, _ ch: Int) -> Int {
            ch == 0 ? avg[bin].r : ch == 1 ? avg[bin].g : avg[bin].b
        }
        struct Box { var start: Int; var end: Int; var count: UInt64; var axis: Int; var range: Int }
        func makeBox(_ start: Int, _ end: Int) -> Box {
            var lo = (255, 255, 255), hi = (0, 0, 0)
            var total: UInt64 = 0
            for i in start..<end {
                let bin = bins[i]
                total += UInt64(counts[bin])
                let c = avg[bin]
                lo = (min(lo.0, c.r), min(lo.1, c.g), min(lo.2, c.b))
                hi = (max(hi.0, c.r), max(hi.1, c.g), max(hi.2, c.b))
            }
            let ranges = [hi.0 - lo.0, hi.1 - lo.1, hi.2 - lo.2]
            let axis = ranges.firstIndex(of: ranges.max()!)!
            return Box(start: start, end: end, count: max(total, 1), axis: axis, range: ranges[axis])
        }
        var boxes = [makeBox(0, bins.count)]

        while boxes.count < target {
            // Split the box with the most pixels × widest spread.
            var best = -1
            var bestScore = 0.0
            for (i, box) in boxes.enumerated() where box.end - box.start > 1 && box.range > 0 {
                let score = Double(box.count) * Double(box.range + 1)
                if score > bestScore { best = i; bestScore = score }
            }
            guard best >= 0 else { break }
            let box = boxes[best]
            let axis = box.axis
            bins[box.start..<box.end].sort { channel($0, axis) < channel($1, axis) }

            let half = box.count / 2
            var running: UInt64 = 0
            var split = box.start + 1
            for i in box.start..<(box.end - 1) {
                running += UInt64(counts[bins[i]])
                split = i + 1
                if running >= half { break }
            }
            boxes[best] = makeBox(box.start, split)
            boxes.append(makeBox(split, box.end))
        }

        // Palette entries: count-weighted average of each box.
        var colors: [(r: UInt8, g: UInt8, b: UInt8)] = []
        var lut = [UInt8](repeating: 0, count: 32768)
        var occupied = [Bool](repeating: false, count: 32768)
        for (index, box) in boxes.enumerated() {
            var r: UInt64 = 0, g: UInt64 = 0, b: UInt64 = 0, n: UInt64 = 0
            for i in box.start..<box.end {
                let bin = bins[i]
                r += sums[bin * 3]; g += sums[bin * 3 + 1]; b += sums[bin * 3 + 2]
                n += UInt64(counts[bin])
                lut[bin] = UInt8(index)
                occupied[bin] = true
            }
            n = max(n, 1)
            colors.append((UInt8(r / n), UInt8(g / n), UInt8(b / n)))
        }

        // Unoccupied bins (reached by dithering or unseen frames) → nearest color.
        for bin in 0..<32768 where !occupied[bin] {
            let r = (bin >> 10 & 31) << 3 | 4, g = (bin >> 5 & 31) << 3 | 4, b = (bin & 31) << 3 | 4
            var bestIndex = 0
            var bestDistance = Int.max
            for (i, c) in colors.enumerated() {
                let dr = r - Int(c.r), dg = g - Int(c.g), db = b - Int(c.b)
                let d = 2 * dr * dr + 4 * dg * dg + 3 * db * db // rough perceptual weights
                if d < bestDistance { bestDistance = d; bestIndex = i }
            }
            lut[bin] = UInt8(bestIndex)
        }

        let entries = colors.count + (reserveTransparent ? 1 : 0)
        var bits = 1
        while (1 << bits) < entries { bits += 1 }
        var rgb = [UInt8](repeating: 0, count: (1 << bits) * 3)
        for (i, c) in colors.enumerated() {
            rgb[i * 3] = c.r; rgb[i * 3 + 1] = c.g; rgb[i * 3 + 2] = c.b
        }
        return GIFPalette(
            rgb: rgb,
            colorCount: colors.count,
            transparentIndex: reserveTransparent ? UInt8(colors.count) : nil,
            tableBits: bits,
            lut: lut
        )
    }
}
