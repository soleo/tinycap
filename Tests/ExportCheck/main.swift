// End-to-end check of MP4Exporter without a screen: writes a synthetic, screen-like
// master (static UI with a moving box), exports it with trim / scale / codec settings
// and verifies duration, pixel size and file size. Run via scripts/export-check.sh.
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import TinycapCore
import VPXBridge

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
                try await MP4Exporter().export(master: master, options: ExportOptions(timeRange: range, format: .mp4(c.settings)), to: out) { _ in }
                let elapsed = Date().timeIntervalSince(t0)

                let asset = AVURLAsset(url: out)
                let track = try await asset.loadTracks(withMediaType: .video).first!
                let (size, formats) = try await track.load(.naturalSize, .formatDescriptions)
                let duration = try await asset.load(.duration).seconds
                let expected = c.trim.map { $0.1 - $0.0 } ?? 30
                let codec = formats.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
                let wantCodec: FourCharCode = c.settings.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
                let bytes = fileSize(out)
                let t1 = Date()
                let estimate = try await MP4Exporter().estimateSize(
                    master: master, options: ExportOptions(timeRange: nil, format: .mp4(c.settings)),
                    start: c.trim?.0 ?? 0, end: c.trim?.1 ?? 30
                )
                let estimateTime = Date().timeIntervalSince(t1)
                let ratio = Double(estimate) / Double(max(bytes, 1))
                check(abs(duration - expected) < 0.15, "duration \(String(format: "%.2f", duration)) s, expected \(expected)")
                check(Int(size.width) == c.size.0 && Int(size.height) == c.size.1, "size \(Int(size.width))×\(Int(size.height))")
                check(codec == wantCodec, "codec \(fourCC(codec))")
                check(true, "file \(ByteSize.format(bytes)), encoded in \(String(format: "%.1f", elapsed)) s")
                check((0.5...1.5).contains(ratio),
                      "estimate \(ByteSize.format(estimate)) is \(String(format: "%.2f", ratio))× actual (want 0.5–1.5×), took \(String(format: "%.2f", estimateTime)) s")
            }

            // PRD metric: 30 s, 1280 px-wide clip as MP4 < 5 MB at default quality.
            let metric = fileSize(dir.appendingPathComponent("h264-default-1280.mp4"))
            check(metric < 5_000_000, "PRD metric: 30 s 1280 px MP4 is \(ByteSize.format(metric)) (< 5 MB)")

            // Cancelling stops the export and leaves no partial file.
            print("cancel")
            let cancelled = dir.appendingPathComponent("cancelled.mp4")
            let task = Task {
                try await MP4Exporter().export(master: master, options: ExportOptions(timeRange: nil, format: .mp4(ExportSettings())), to: cancelled) { _ in }
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

            // GIF (M3)
            struct GIFCase { let name: String; let settings: GIFSettings; let trim: (Double, Double)?; let size: (Int, Int) }
            let gifCases = [
                GIFCase(name: "gif-balanced", settings: GIFPreset.balanced.settings, trim: nil, size: (960, 600)),
                GIFCase(name: "gif-small-trimmed-noloop", settings: { var s = GIFPreset.small.settings; s.loop = false; return s }(),
                        trim: (5, 12.5), size: (640, 400)),
                GIFCase(name: "gif-high-dither", settings: GIFPreset.high.settings, trim: (0, 10), size: (1280, 800)),
            ]
            for c in gifCases {
                print(c.name)
                let out = dir.appendingPathComponent(c.name).appendingPathExtension("gif")
                let range = c.trim.map { CMTimeRange(seconds: $0.0, $0.1) }
                let t0 = Date()
                try await GIFExporter().export(master: master, options: ExportOptions(timeRange: range, format: .gif(c.settings)), to: out) { _ in }
                let elapsed = Date().timeIntervalSince(t0)
                let expected = c.trim.map { $0.1 - $0.0 } ?? 30
                let bytes = fileSize(out)

                guard let source = CGImageSourceCreateWithURL(out as CFURL, nil) else {
                    check(false, "ImageIO can open the GIF"); continue
                }
                let count = CGImageSourceGetCount(source)
                var total = 0.0
                for i in 0..<count {
                    let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
                    let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                    total += gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? 0
                }
                let first = CGImageSourceCreateImageAtIndex(source, 0, nil)
                let last = CGImageSourceCreateImageAtIndex(source, count - 1, nil)
                let container = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
                let loop = (container?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int

                let estimate = try await GIFExporter().estimateSize(
                    master: master, options: ExportOptions(timeRange: nil, format: .gif(c.settings)),
                    start: c.trim?.0 ?? 0, end: c.trim?.1 ?? 30
                )
                let ratio = Double(estimate) / Double(max(bytes, 1))

                check(first?.width == c.size.0 && first?.height == c.size.1, "size \(first?.width ?? 0)×\(first?.height ?? 0)")
                check(last != nil && count > 1, "\(count) frames decode")
                check(abs(total - expected) < 0.1, "total delay \(String(format: "%.2f", total)) s, expected \(expected)")
                check((loop == 0) == c.settings.loop, "loop count \(loop.map(String.init) ?? "none") (loop \(c.settings.loop))")
                check(true, "file \(ByteSize.format(bytes)), encoded in \(String(format: "%.1f", elapsed)) s")
                check((0.5...1.5).contains(ratio),
                      "estimate \(ByteSize.format(estimate)) is \(String(format: "%.2f", ratio))× actual (want 0.5–1.5×)")
            }
            let gifMetric = fileSize(dir.appendingPathComponent("gif-balanced.gif"))
            check(gifMetric < 10_000_000, "PRD metric: 30 s clip as GIF at default preset is \(ByteSize.format(gifMetric)) (< 10 MB)")

            print("gif cancel")
            let cancelledGIF = dir.appendingPathComponent("cancelled.gif")
            let gifTask = Task {
                try await GIFExporter().export(master: master, options: ExportOptions(timeRange: nil, format: .gif(GIFPreset.high.settings)), to: cancelledGIF) { _ in }
            }
            try await Task.sleep(for: .milliseconds(150))
            gifTask.cancel()
            if case .failure(let error) = await gifTask.result {
                check(error is CancellationError, "cancel throws CancellationError (\(type(of: error)))")
            } else {
                check(false, "cancel threw nothing (export finished first?)")
            }
            check(!FileManager.default.fileExists(atPath: cancelledGIF.path), "no partial GIF after cancel")

            // WebM (M4)
            struct WebMCase { let name: String; let settings: WebMSettings; let trim: (Double, Double)?; let size: (Int, Int) }
            let webmCases = [
                WebMCase(name: "webm-default", settings: WebMSettings(), trim: nil, size: (2560, 1600)),
                WebMCase(name: "webm-half-trimmed", settings: WebMSettings(quality: 0.3, scale: .half), trim: (5, 12.5), size: (1280, 800)),
            ]
            for c in webmCases {
                print(c.name)
                let out = dir.appendingPathComponent(c.name).appendingPathExtension("webm")
                let range = c.trim.map { CMTimeRange(seconds: $0.0, $0.1) }
                let t0 = Date()
                try await WebMExporter().export(master: master, options: ExportOptions(timeRange: range, format: .webm(c.settings)), to: out) { _ in }
                let elapsed = Date().timeIntervalSince(t0)
                let expected = c.trim.map { $0.1 - $0.0 } ?? 30
                let bytes = fileSize(out)

                var info = TCWebMInfo()
                var err = [CChar](repeating: 0, count: 256)
                let ok = out.path.withCString { tc_webm_inspect($0, &info, &err, err.count) } == 0
                check(ok, "parses as WebM")
                check(info.is_vp9 != 0, "codec V_VP9")
                check(Int(info.width) == c.size.0 && Int(info.height) == c.size.1, "size \(info.width)×\(info.height)")
                check(info.frames > 0 && info.decoded_frames == info.frames,
                      "\(info.decoded_frames)/\(info.frames) frames decode, \(info.keyframes) keyframes")
                let seconds = Double(info.duration_ns) / 1e9
                check(abs(seconds - expected) < 0.1, "duration \(String(format: "%.2f", seconds)) s, expected \(expected)")

                let estimate = try await WebMExporter().estimateSize(
                    master: master, options: ExportOptions(timeRange: nil, format: .webm(c.settings)),
                    start: c.trim?.0 ?? 0, end: c.trim?.1 ?? 30
                )
                let ratio = Double(estimate) / Double(max(bytes, 1))
                check(true, "file \(ByteSize.format(bytes)), encoded in \(String(format: "%.1f", elapsed)) s")
                check((0.5...1.5).contains(ratio),
                      "estimate \(ByteSize.format(estimate)) is \(String(format: "%.2f", ratio))× actual (want 0.5–1.5×)")
            }

            print("webm cancel")
            let cancelledWebM = dir.appendingPathComponent("cancelled.webm")
            let webmTask = Task {
                try await WebMExporter().export(master: master, options: ExportOptions(timeRange: nil, format: .webm(WebMSettings())), to: cancelledWebM) { _ in }
            }
            try await Task.sleep(for: .milliseconds(300))
            webmTask.cancel()
            if case .failure(let error) = await webmTask.result {
                check(error is CancellationError, "cancel throws CancellationError (\(type(of: error)))")
            } else {
                check(false, "cancel threw nothing (export finished first?)")
            }
            check(!FileManager.default.fileExists(atPath: cancelledWebM.path), "no partial WebM after cancel")

            // Sound (M7): separate system and microphone tracks, kept per source in MP4 only.
            print("sound")
            let soundMaster = dir.appendingPathComponent("sound-master.mov")
            try await writeSoundMaster(to: soundMaster, seconds: 10)
            let soundInfo = try await MasterInfo.load(soundMaster)
            check(soundInfo.audioTracks.map(\.source) == [.system, .microphone],
                  "master sound tracks \(soundInfo.audioTracks.map(\.source.rawValue))")
            let mp4 = FormatSettings.mp4(ExportSettings(scale: .full))
            let soundRange = CMTimeRange(start: CMTime(seconds: 2, preferredTimescale: 600), end: CMTime(seconds: 8, preferredTimescale: 600))
            // expected: the sources' tracks when copied; nil for one mixed (unnamed) track.
            let soundCases: [(name: String, keep: [AudioSource], separate: Bool, expected: [AudioSource]?)] = [
                ("mp4-both-mixed", [.system, .microphone], false, nil),
                ("mp4-both-separate", [.system, .microphone], true, [.system, .microphone]),
                ("mp4-mic-only", [.microphone], false, [.microphone]),
                ("mp4-no-sound", [], false, []),
            ]
            for c in soundCases {
                let out = dir.appendingPathComponent(c.name).appendingPathExtension("mp4")
                let ids = soundInfo.audioTracks.filter { c.keep.contains($0.source) }.map(\.trackID)
                try await MP4Exporter().export(master: soundMaster,
                                               options: ExportOptions(timeRange: soundRange, format: mp4, audioTrackIDs: ids,
                                                                      separateAudioTracks: c.separate),
                                               to: out) { _ in }
                let asset = AVURLAsset(url: out)
                let tracks = try await MasterInfo.audioTracks(of: asset)
                if let expected = c.expected {
                    check(tracks.map(\.source) == expected, "\(c.name): sound tracks \(tracks.map(\.source.rawValue))")
                } else {
                    let channels = try await asset.loadTracks(withMediaType: .audio).first?.load(.formatDescriptions).first
                        .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
                    check(tracks.count == 1 && channels == 2, "\(c.name): one stereo track (\(tracks.count) tracks, \(channels ?? 0) channels)")
                }
                for track in try await asset.loadTracks(withMediaType: .audio) {
                    let range = try await track.load(.timeRange)
                    check(abs(range.duration.seconds - 6) < 0.15,
                          "\(c.name): sound track \(track.trackID) lasts \(String(format: "%.2f", range.duration.seconds)) s, expected 6")
                }
                let video = try await asset.load(.duration).seconds
                check(abs(video - 6) < 0.15, "\(c.name): duration \(String(format: "%.2f", video)) s, expected 6")
            }
            let withSound = try await MP4Exporter().estimateSize(
                master: soundMaster,
                options: ExportOptions(timeRange: nil, format: mp4, audioTrackIDs: soundInfo.audioTracks.map(\.trackID)),
                start: 0, end: 10)
            let withoutSound = try await MP4Exporter().estimateSize(
                master: soundMaster, options: ExportOptions(timeRange: nil, format: mp4), start: 0, end: 10)
            check(withSound > withoutSound, "estimate counts sound (\(ByteSize.format(withSound)) vs \(ByteSize.format(withoutSound)) without)")
            let soundWebM = dir.appendingPathComponent("sound-master.webm")
            try await WebMExporter().export(master: soundMaster,
                                            options: ExportOptions(timeRange: nil, format: .webm(WebMSettings()),
                                                                   audioTrackIDs: soundInfo.audioTracks.map(\.trackID)),
                                            to: soundWebM) { _ in }
            check(fileSize(soundWebM) > 0, "WebM from a master with sound exports (video only)")
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

    /// A small master like `CaptureFileWriter` writes: video plus AAC "System Audio"
    /// (stereo) and "Microphone" (mono) tracks of sine tones.
    static func writeSoundMaster(to url: URL, seconds: Int) async throws {
        let fps = 30, rate = AudioSource.sampleRate
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 400,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 400,
        ])
        writer.add(video)
        var sound: [(AudioSource, AVAssetWriterInput, CMAudioFormatDescription)] = []
        for source in AudioSource.allCases {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                AVNumberOfChannelsKey: source.channelCount, AVEncoderBitRateKey: source.bitrate,
            ])
            let name = AVMutableMetadataItem()
            name.identifier = .quickTimeUserDataTrackName
            name.value = source.trackName as NSString
            input.metadata = [name]
            writer.add(input)
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(2 * source.channelCount), mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(2 * source.channelCount), mChannelsPerFrame: UInt32(source.channelCount),
                mBitsPerChannel: 16, mReserved: 0)
            var format: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
            sound.append((source, input, format!))
        }
        guard writer.startWriting() else { throw writer.error ?? ExportError.cannotEncode("can't start sound master") }
        writer.startSession(atSourceTime: .zero)

        let framesPerVideoFrame = rate / fps
        for frame in 0..<(fps * seconds) {
            while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool else { throw ExportError.cannotEncode("no pixel buffer pool") }
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let pb = buffer else { throw ExportError.cannotEncode("no pixel buffer") }
            CVPixelBufferLockBaseAddress(pb, [])
            memset(CVPixelBufferGetBaseAddress(pb), Int32(frame % 255), CVPixelBufferGetDataSize(pb))
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))

            for (source, input, format) in sound {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                let first = frame * framesPerVideoFrame
                let pitch = source == .system ? 440.0 : 220.0
                var samples = [Int16]()
                for i in 0..<framesPerVideoFrame {
                    let value = Int16(sin(2 * .pi * pitch * Double(first + i) / Double(rate)) * 8000)
                    samples += Array(repeating: value, count: source.channelCount)
                }
                input.append(try pcmSample(samples, frames: framesPerVideoFrame, at: first, rate: rate, format: format))
            }
        }
        video.markAsFinished()
        sound.forEach { $0.1.markAsFinished() }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? ExportError.cannotEncode("sound master write failed") }
    }

    static func pcmSample(_ samples: [Int16], frames: Int, at start: Int, rate: Int, format: CMAudioFormatDescription) throws -> CMSampleBuffer {
        let bytes = samples.count * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        guard let block else { throw ExportError.cannotEncode("no block buffer") }
        _ = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(rate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard let sample else { throw ExportError.cannotEncode("no sound sample") }
        return sample
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
