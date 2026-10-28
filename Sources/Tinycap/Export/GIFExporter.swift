import Accelerate
import AVFoundation
import os
import TinycapCore

/// GIF export (EX-3, EX-5). Two passes over the master: the first builds one palette
/// from frames spread across the kept range, the second resamples to the target frame
/// rate, scales with vImage and streams frames into `GIFEncoder`. Nothing but the
/// current frame is held in memory.
struct GIFExporter: Exporter {
    let fileExtension = "gif"

    func export(
        master: URL,
        options: ExportOptions,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard case .gif(let settings) = options.format else { throw ExportError.wrongFormat }
        let job = try await GIFJob.make(master: master, range: options.timeRange, settings: settings)

        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw ExportError.cannotEncode("can't create \(destination.lastPathComponent)")
        }
        let sink = try FileSink(url: destination)
        do {
            _ = try await job.run(sink: sink, progress: progress)
            try sink.close()
        } catch {
            try? sink.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Encodes two 2 s pieces in memory. The first frame of a GIF is a full picture and
    /// later frames only store changes, so the first frame's bytes are counted once and
    /// the rest scaled by duration; scaling everything would overstate static clips.
    func estimateSize(master: URL, options: ExportOptions, start: Double, end: Double) async throws -> Int64 {
        guard case .gif(let settings) = options.format else { throw ExportError.wrongFormat }
        let windows = SizeSampling.windows(start: start, end: end, pieceLength: 2)
        guard !windows.isEmpty else { return 0 }

        var firstFrames: [Int64] = []
        var restBytes: Int64 = 0
        var seconds = 0.0
        for window in windows {
            try Task.checkCancellation()
            let job = try await GIFJob.make(master: master, range: CMTimeRange(seconds: window.lowerBound, window.upperBound), settings: settings)
            let counter = CountingSink()
            let stats = try await job.run(sink: counter, progress: { _ in })
            let first = Int64(stats.firstFrameBytes ?? stats.bytesWritten)
            firstFrames.append(first)
            restBytes += Int64(stats.bytesWritten) - first
            seconds += window.upperBound - window.lowerBound
        }
        let firstFrame = firstFrames.reduce(0, +) / Int64(firstFrames.count)
        return firstFrame + SizeSampling.extrapolate(sampleBytes: restBytes, sampleSeconds: seconds, totalSeconds: end - start, containerOverhead: 1)
    }
}

// MARK: - Output sinks

protocol ByteSink: AnyObject, Sendable {
    func write(_ data: Data)
}

/// Streams to a file; the first write error is kept and reported on close.
private final class FileSink: ByteSink, @unchecked Sendable {
    private let handle: FileHandle
    private var error: Error?

    init(url: URL) throws { handle = try FileHandle(forWritingTo: url) }

    func write(_ data: Data) {
        guard error == nil else { return }
        do { try handle.write(contentsOf: data) } catch { self.error = error }
    }

    func close() throws {
        try handle.close()
        if let error { throw error }
    }
}

private final class CountingSink: ByteSink, @unchecked Sendable {
    func write(_ data: Data) {}
}

// MARK: - Job

/// One GIF encode of a time range. The asset and track are loaded up front; readers
/// are created and used only on the job's queue.
private final class GIFJob: @unchecked Sendable {
    struct Stats { let bytesWritten: Int; let firstFrameBytes: Int?; let frames: Int }

    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let start: Double
    private let end: Double
    private let settings: GIFSettings
    private let sourceSize: CGSize
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    private static let queue = DispatchQueue(label: "app.tinycap.gif", qos: .userInitiated)

    private init(asset: AVURLAsset, track: AVAssetTrack, start: Double, end: Double, settings: GIFSettings, sourceSize: CGSize) {
        self.asset = asset
        self.track = track
        self.start = start
        self.end = end
        self.settings = settings
        self.sourceSize = sourceSize
    }

    static func make(master: URL, range: CMTimeRange?, settings: GIFSettings) async throws -> GIFJob {
        let asset = AVURLAsset(url: master)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideoTrack }
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        let start = range.map { $0.start.seconds } ?? 0
        let end = range.map { $0.end.seconds } ?? duration
        return GIFJob(asset: asset, track: track, start: start, end: max(end, start + 0.01), settings: settings, sourceSize: size)
    }

    func run(sink: ByteSink, progress: @escaping @Sendable (Double) -> Void) async throws -> Stats {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Stats, Error>) in
                Self.queue.async {
                    do {
                        continuation.resume(returning: try self.encode(sink: sink, progress: progress))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    private var isCancelled: Bool { cancelled.withLock { $0 } }

    private func makeReader() throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(seconds: start, end)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ExportError.cannotEncode("can't read the recording") }
        return (reader, output)
    }

    private func encode(sink: ByteSink, progress: @Sendable (Double) -> Void) throws -> Stats {
        let palette = try buildPalette(progress: progress)
        let out = settings.outputSize(for: sourceSize)
        let encoder = GIFEncoder(
            width: out.width, height: out.height, palette: palette,
            options: .init(loop: settings.loop, dither: settings.dither, dropDuplicates: settings.dropDuplicates),
            write: { sink.write($0) }
        )
        let scaler = Scaler(width: out.width, height: out.height)

        let (reader, output) = try makeReader()
        defer { reader.cancelReading() }
        let fps = settings.fps
        let total = GIFTiming.frameCount(duration: end - start, fps: fps)
        var k = 0
        var held: CVPixelBuffer?
        var heldID = 0
        var lastEncodedID = -1

        func emit() throws {
            guard let buffer = held else { return }
            if isCancelled { throw CancellationError() }
            let delay = GIFTiming.delay(ofFrame: k, fps: fps)
            if heldID == lastEncodedID {
                encoder.repeatLastFrame(delay: delay)
            } else {
                try scaler.withScaled(buffer) { pointer, bytesPerRow in
                    encoder.addFrame(bgra: pointer, bytesPerRow: bytesPerRow, delay: delay)
                }
                lastEncodedID = heldID
            }
            k += 1
            if k % 4 == 0 { progress(0.15 + 0.85 * Double(k) / Double(total)) }
        }

        // Output frame k shows the newest source frame at or before start + k/fps.
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds - start
            while held != nil, k < total, GIFTiming.time(ofFrame: k, fps: fps) < pts { try emit() }
            if k >= total { break }
            if let image = CMSampleBufferGetImageBuffer(sample) {
                held = image
                heldID += 1
            }
        }
        if reader.status == .failed { throw reader.error ?? ExportError.cannotEncode("reading failed") }
        while held != nil, k < total { try emit() }

        encoder.finish()
        progress(1)
        return Stats(bytesWritten: encoder.bytesWritten, firstFrameBytes: encoder.firstFrameBytes, frames: encoder.framesWritten)
    }

    /// Histogram of up to 24 frames spread over the range, sampling ~150k pixels each.
    private func buildPalette(progress: @Sendable (Double) -> Void) throws -> GIFPalette {
        let (reader, output) = try makeReader()
        defer { reader.cancelReading() }
        var builder = PaletteBuilder()
        let samples = 24.0
        let interval = (end - start) / samples
        var next = 0.0
        while let sample = output.copyNextSampleBuffer() {
            if isCancelled { throw CancellationError() }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds - start
            guard t >= next || builder.isEmpty, let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            next = t + interval
            CVPixelBufferLockBaseAddress(image, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(image) else { continue }
            let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image)
            let step = max(1, Int((Double(w * h) / 150_000).squareRoot()))
            builder.add(bgra: base, width: w, height: h, bytesPerRow: CVPixelBufferGetBytesPerRow(image), step: step)
            progress(0.15 * min(t / max(end - start, 0.001), 1))
        }
        if reader.status == .failed { throw reader.error ?? ExportError.cannotEncode("reading failed") }
        return builder.build(maxColors: settings.colors, reserveTransparent: true)
    }
}

/// Scales BGRA pixel buffers to the output size with vImage (no-op when sizes match).
private final class Scaler {
    private let width: Int
    private let height: Int
    private var buffer: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        buffer = [UInt8](repeating: 0, count: width * height * 4)
    }

    func withScaled(_ image: CVPixelBuffer, _ body: (UnsafeRawPointer, Int) -> Void) throws {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image) else { throw ExportError.cannotEncode("empty frame") }
        let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image)
        let rowBytes = CVPixelBufferGetBytesPerRow(image)
        if w == width && h == height {
            body(base, rowBytes)
            return
        }
        var src = vImage_Buffer(data: base, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: rowBytes)
        let error = buffer.withUnsafeMutableBytes { dstBytes -> vImage_Error in
            var dst = vImage_Buffer(data: dstBytes.baseAddress, height: vImagePixelCount(height),
                                    width: vImagePixelCount(width), rowBytes: width * 4)
            return vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
        }
        guard error == kvImageNoError else { throw ExportError.cannotEncode("scaling failed (\(error))") }
        buffer.withUnsafeBytes { body($0.baseAddress!, width * 4) }
    }
}
