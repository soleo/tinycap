import AVFoundation
import os
import TinycapCore
import VideoToolbox

/// MP4 export (EX-1, EX-6): decodes the master with AVAssetReader and re-encodes with
/// AVAssetWriter (hardware H.264/HEVC via VideoToolbox), applying trim, bitrate and scale.
struct MP4Exporter: Exporter {
    let fileExtension = "mp4"

    func export(
        master: URL,
        options: ExportOptions,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: master)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideoTrack }
        let (naturalSize, nominalFPS, transform) = try await track.load(.naturalSize, .nominalFrameRate, .preferredTransform)
        let duration = try await asset.load(.duration)
        let range = options.timeRange ?? CMTimeRange(start: .zero, duration: duration)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExportError.cannotEncode("can't read the recording") }
        reader.add(output)

        let fps = nominalFPS > 0 ? Double(nominalFPS) : 30
        let size = options.settings.outputSize(for: naturalSize)
        let bitrate = options.settings.bitrate(width: size.width, height: size.height, frameRate: fps)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: Int(fps * 2),
            AVVideoAllowFrameReorderingKey: true,
        ]
        if options.settings.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        } else {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        }

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true // moov first: plays while loading in Slack/GitHub
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: options.settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: compression,
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        guard writer.canAdd(input) else { throw ExportError.cannotEncode("unsupported output settings") }
        writer.add(input)

        let pipe = EncodePipe(reader: reader, output: output, writer: writer, input: input, range: range, progress: progress)
        do {
            try await pipe.run()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

/// Moves samples from reader to writer on a background queue. The AVFoundation objects
/// are only touched from that queue (and before/after it runs), so this is safe to share.
private final class EncodePipe: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let range: CMTimeRange
    private let progress: @Sendable (Double) -> Void
    private let queue = DispatchQueue(label: "app.tinycap.export", qos: .userInitiated)
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    /// Only touched on `queue`.
    private var lastReported = -1.0

    init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, writer: AVAssetWriter,
         input: AVAssetWriterInput, range: CMTimeRange, progress: @escaping @Sendable (Double) -> Void) {
        self.reader = reader
        self.output = output
        self.writer = writer
        self.input = input
        self.range = range
        self.progress = progress
    }

    func run() async throws {
        guard reader.startReading() else {
            throw ExportError.cannotEncode(reader.error?.localizedDescription ?? "can't read the recording")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw ExportError.cannotEncode(writer.error?.localizedDescription ?? "can't write the file")
        }
        writer.startSession(atSourceTime: range.start)

        await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                pump(done)
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }

        if cancelled.withLock({ $0 }) {
            reader.cancelReading()
            writer.cancelWriting()
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw ExportError.cannotEncode(reader.error?.localizedDescription ?? "reading failed")
        }
        if writer.status == .failed {
            reader.cancelReading()
            throw ExportError.cannotEncode(writer.error?.localizedDescription ?? "writing failed")
        }
        writer.endSession(atSourceTime: range.end)
        await writer.finishWriting()
        if writer.status != .completed {
            throw ExportError.cannotEncode(writer.error?.localizedDescription ?? "writing failed")
        }
        progress(1)
    }

    private func pump(_ done: CheckedContinuation<Void, Never>) {
        let total = max(range.duration.seconds, 0.001)
        input.requestMediaDataWhenReady(on: queue) { [self] in
            while input.isReadyForMoreMediaData {
                if cancelled.withLock({ $0 }) {
                    input.markAsFinished()
                    done.resume()
                    return
                }
                guard let sample = output.copyNextSampleBuffer() else {
                    input.markAsFinished()
                    done.resume()
                    return
                }
                guard input.append(sample) else {
                    input.markAsFinished()
                    done.resume()
                    return
                }
                let t = (CMSampleBufferGetPresentationTimeStamp(sample) - range.start).seconds
                let fraction = min(max(t / total, 0), 0.99)
                if fraction - lastReported >= 0.01 {
                    lastReported = fraction
                    progress(fraction)
                }
            }
        }
    }
}
