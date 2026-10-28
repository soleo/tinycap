// Turns the reference artwork (TinyCapIcon.png) into a macOS app icon master:
// removes the flat light backdrop around the rounded tile, crops to the tile and
// centers it on a 1024×1024 transparent canvas using Apple's 824 px icon grid.
//
// usage: make-icon <source.png> <output-1024.png> [AppIcon.icns] [preview.png]
// Also writes the .icns (PNG-encoded entries, 16–1024 px) and a preview of the icon
// on a dark backdrop to check the cut-out edge.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard (3...5).contains(args.count) else { fail("usage: make-icon <source.png> <output.png> [AppIcon.icns] [preview.png]") }

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { fail("cannot read \(args[1])") }

let w = image.width, h = image.height
var pixels = [UInt8](repeating: 0, count: w * h * 4)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let info = CGImageAlphaInfo.premultipliedLast.rawValue
guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: info)
else { fail("cannot create bitmap") }
ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

// Backdrop = light, nearly neutral pixels reachable from the edges (4-connected, so
// the tile's pixel-art outline stops the fill even along its stair-stepped corners).
func isBackdrop(_ i: Int) -> Bool {
    let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
    return min(r, g, b) >= 228 && max(r, g, b) - min(r, g, b) <= 16
}

var clear = [Bool](repeating: false, count: w * h)
var stack: [Int] = []
for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }
while let p = stack.popLast() {
    if clear[p] || !isBackdrop(p * 4) { continue }
    clear[p] = true
    let x = p % w, y = p / w
    if x > 0 { stack.append(p - 1) }
    if x < w - 1 { stack.append(p + 1) }
    if y > 0 { stack.append(p - w) }
    if y < h - 1 { stack.append(p + w) }
}

// Soften the cut: pixels next to the cleared area that are still very light get
// partial alpha so the edge doesn't keep a pale fringe.
var alpha = [UInt8](repeating: 255, count: w * h)
for p in 0..<(w * h) where clear[p] { alpha[p] = 0 }
for p in 0..<(w * h) where !clear[p] {
    let x = p % w, y = p / w
    let touches = (x > 0 && clear[p - 1]) || (x < w - 1 && clear[p + 1]) || (y > 0 && clear[p - w]) || (y < h - 1 && clear[p + w])
    if touches {
        let i = p * 4
        let lum = (Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])) / 3
        if lum > 200 { alpha[p] = UInt8(max(0, min(255, (255 - lum) * 255 / 55))) }
    }
}

var minX = w, minY = h, maxX = -1, maxY = -1
for p in 0..<(w * h) where alpha[p] > 0 {
    let x = p % w, y = p / w
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
}
guard maxX >= minX else { fail("no artwork found") }

for p in 0..<(w * h) {
    let a = Int(alpha[p]), i = p * 4
    pixels[i] = UInt8(Int(pixels[i]) * a / 255)
    pixels[i + 1] = UInt8(Int(pixels[i + 1]) * a / 255)
    pixels[i + 2] = UInt8(Int(pixels[i + 2]) * a / 255)
    pixels[i + 3] = UInt8(a)
}
guard let cutout = ctx.makeImage() else { fail("cannot make image") }

// Bitmap rows run top to bottom; CGImage cropping uses the same orientation.
let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
guard let tile = cutout.cropping(to: crop) else { fail("cannot crop") }

let canvas = 1024, body = 824.0
let scale = body / Double(max(tile.width, tile.height))
let tw = Double(tile.width) * scale, th = Double(tile.height) * scale
guard let out = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
else { fail("cannot create canvas") }
out.interpolationQuality = .high
out.draw(tile, in: CGRect(x: (Double(canvas) - tw) / 2, y: (Double(canvas) - th) / 2, width: tw, height: th))

guard let result = out.makeImage() else { fail("cannot render icon") }

func pngData(_ image: CGImage) -> Data {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
    else { fail("cannot encode PNG") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("cannot encode PNG") }
    return data as Data
}

func writePNG(_ image: CGImage, to path: String) {
    do { try pngData(image).write(to: URL(fileURLWithPath: path)) } catch { fail("cannot write \(path): \(error)") }
}

func bigEndian(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

func render(_ image: CGImage, size: Int, background: CGColor? = nil) -> CGImage {
    guard let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
    else { fail("cannot create \(size) px canvas") }
    if let background {
        c.setFillColor(background)
        c.fill(CGRect(x: 0, y: 0, width: size, height: size))
    }
    c.interpolationQuality = .high
    c.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let r = c.makeImage() else { fail("cannot render \(size) px") }
    return r
}

writePNG(result, to: args[2])

if args.count >= 4 {
    // ICNS = "icns" + total length, then (OSType, length incl. 8-byte header, PNG) entries.
    let entries: [(String, Int)] = [
        ("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64), ("ic07", 128),
        ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024),
    ]
    var body = Data()
    for (type, size) in entries {
        let png = pngData(size == 1024 ? result : render(result, size: size))
        body.append(type.data(using: .ascii)!)
        body.append(bigEndian(UInt32(png.count + 8)))
        body.append(png)
    }
    var icns = "icns".data(using: .ascii)!
    icns.append(bigEndian(UInt32(body.count + 8)))
    icns.append(body)
    do { try icns.write(to: URL(fileURLWithPath: args[3])) } catch { fail("cannot write \(args[3]): \(error)") }
}
if args.count == 5 {
    writePNG(render(result, size: 512, background: CGColor(gray: 0.18, alpha: 1)), to: args[4])
}
print("tile \(tile.width)×\(tile.height) px → \(Int(tw))×\(Int(th)) on \(canvas)×\(canvas)")
