// End-to-end check of MP4Exporter without a screen: writes a synthetic, screen-like
// master (static UI with a moving box), exports it with trim / scale / codec settings
// and verifies duration, pixel size and file size. Run via scripts/export-check.sh.
import AVFoundation
import CoreGraphics
import Foundation
import TinycapCore

@main
struct ExportCheck {
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
            .appendingPathComponent("work", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { print("ERROR \(error)"); exit(1) }

        var failures = 0
        func check(_ ok: Bool, _ message: String) {
            print((ok ? "  ok   " : "  FAIL ") + message)
            if !ok { failures += 1 }
        }

        do {
            let master = dir.appendingPathComponent("master.mov")
            let start = Date()
            try await writeMaster(to: master, width: 2560, height: 1600, fps: 30, seconds: 30)
            print("master: 2560×1600, 30 fps, 30 s (\(fileSize(master)) bytes, \(String(format: "%.1f", Date().timeIntervalSince(start))) s to write)")

            let info = try await MasterInfo.load(master)
            check(abs(info.duration - 30) < 0.1, "master duration \(info.duration)")

            struct Case { let name: String; let settings: ExportSettings; let trim: (Double, Double)?; let size: (Int, Int) }
            let cases = [
                Case(name: "h264-default-1280", settings: ExportSettings(scale: .width(1280)), trim: nil, size: (1280, 800)),
                Case(name: "h264-half-trimmed", settings: ExportSettings(scale: .half), trim: (5, 12.5), size: (1280, 800)),
                Case(name: "hevc-full", settings: ExportSettings(codec: .hevc, scale: .full), trim: (0, 10), size: (2560, 1600)),
            ]

            for c in cases {
                print(c.name)
                let out = dir.appendingPathComponent(c.name).appendingPathExtension("mp4")
                let range = c.trim.map {
                    CMTimeRange(start: CMTime(seconds: $0.0, preferredTimescale: 600), end: CMTime(seconds: $0.1, preferredTimescale: 600))
                }
                let t0 = Date()
                try await MP4Exporter().export(master: master, options: ExportOptions(timeRange: range, settings: c.settings), to: out) { _ in }
                let elapsed = Date().timeIntervalSince(t0)

                let asset = AVURLAsset(url: out)
                let track = try await asset.loadTracks(withMediaType: .video).first!
                let (size, formats) = try await track.load(.naturalSize, .formatDescriptions)
                let duration = try await asset.load(.duration).seconds
                let expected = c.trim.map { $0.1 - $0.0 } ?? 30
                let codec = formats.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
                let wantCodec: FourCharCode = c.settings.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
                let bytes = fileSize(out)
                let estimate = c.settings.estimatedBytes(sourceSize: CGSize(width: 2560, height: 1600), frameRate: 30, duration: expected)

                check(abs(duration - expected) < 0.15, "duration \(String(format: "%.2f", duration)) s, expected \(expected)")
                check(Int(size.width) == c.size.0 && Int(size.height) == c.size.1, "size \(Int(size.width))×\(Int(size.height))")
                check(codec == wantCodec, "codec \(fourCC(codec))")
                check(bytes <= estimate, "file \(ByteSize.format(bytes)) ≤ estimate \(ByteSize.format(estimate)), encoded in \(String(format: "%.1f", elapsed)) s")
            }

            // PRD metric: 30 s, 1280 px-wide clip as MP4 < 5 MB at default quality.
            let metric = fileSize(dir.appendingPathComponent("h264-default-1280.mp4"))
            check(metric < 5_000_000, "PRD metric: 30 s 1280 px MP4 is \(ByteSize.format(metric)) (< 5 MB)")

            // Cancelling stops the export and leaves no partial file.
            print("cancel")
            let cancelled = dir.appendingPathComponent("cancelled.mp4")
            let task = Task {
                try await MP4Exporter().export(master: master, options: ExportOptions(timeRange: nil, settings: ExportSettings()), to: cancelled) { _ in }
            }
            try await Task.sleep(for: .milliseconds(150))
            task.cancel()
            let result = await task.result
            if case .failure(let error) = result {
                check(error is CancellationError, "cancel throws CancellationError (\(type(of: error)))")
            } else {
                check(false, "cancel threw nothing (export finished first?)")
            }
            check(!FileManager.default.fileExists(atPath: cancelled.path), "no partial file after cancel")
        } catch {
            print("ERROR \(error)")
            failures += 1
        }

        print(failures == 0 ? "PASS" : "FAILED (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    static func fourCC(_ code: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "\(code)"
    }

    /// Mostly static "UI" (panels, text-like bars) with a box moving across, like a screen recording.
    static func writeMaster(to url: URL, width: Int, height: Int, fps: Int32, seconds: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 20_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ExportError.cannotEncode("can't start master") }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<(Int(fps) * seconds) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool else { throw ExportError.cannotEncode("no pixel buffer pool") }
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let pb = buffer else { throw ExportError.cannotEncode("no pixel buffer") }
            CVPixelBufferLockBaseAddress(pb, [])
            let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )!
            ctx.setFillColor(CGColor(gray: 0.96, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(CGColor(gray: 0.88, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 480, height: height))
            ctx.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: height - 80, width: width, height: 80))
            for row in 0..<40 {
                ctx.setFillColor(CGColor(gray: 0.3, alpha: 1))
                ctx.fill(CGRect(x: 540, y: 100 + row * 34, width: 300 + (row * 97) % 900, height: 12))
            }
            let x = 600 + Double(frame % 300) * 5
            ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: x, y: 700, width: 160, height: 160))
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? ExportError.cannotEncode("master write failed") }
    }
}
