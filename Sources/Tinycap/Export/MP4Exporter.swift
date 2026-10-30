import AVFoundation
import os
import TinycapCore
import VideoToolbox

/// MP4 export (EX-1, EX-6): decodes the master with AVAssetReader and re-encodes with
/// AVAssetWriter (hardware H.264/HEVC via VideoToolbox), applying trim, bitrate and scale.
/// Kept sound tracks are copied as they are, each still its own track (AU-3, AU-6).
struct MP4Exporter: Exporter {
    let fileExtension = "mp4"
    static let keyframeSeconds = 2.0

    func estimateSize(master: URL, options: ExportOptions, start: Double, end: Double) async throws -> Int64 {
        try await SizeEstimator.estimate(exporter: self, master: master, options: options,
                                         pieceLength: Self.keyframeSeconds, start: start, end: end)
    }

    func export(
        master: URL,
        options: ExportOptions,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard case .mp4(let settings) = options.format else { throw ExportError.wrongFormat }
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
        let size = settings.outputSize(for: naturalSize)
        let bitrate = settings.bitrate(width: size.width, height: size.height, frameRate: fps)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: Int(fps * Self.keyframeSeconds),
            AVVideoMaxKeyFrameIntervalDurationKey: Self.keyframeSeconds,
            AVVideoAllowFrameReorderingKey: true,
        ]
        if settings.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        } else {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        }

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true // moov first: plays while loading in Slack/GitHub
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: compression,
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        guard writer.canAdd(input) else { throw ExportError.cannotEncode("unsupported output settings") }
        writer.add(input)

        var lanes = [EncodePipe.Lane(output: output, input: input, reportsProgress: true)]
        for track in try await asset.loadTracks(withMediaType: .audio) where options.audioTrackIDs.contains(track.trackID) {
            lanes.append(try await Self.soundLane(for: track, reader: reader, writer: writer))
        }

        let pipe = EncodePipe(reader: reader, lanes: lanes, writer: writer, range: range, progress: progress)
        do {
            try await pipe.run()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

extension MP4Exporter {
    /// A sound track copied without re-encoding, keeping its name.
    fileprivate static func soundLane(for track: AVAssetTrack, reader: AVAssetReader, writer: AVAssetWriter) async throws -> EncodePipe.Lane {
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExportError.cannotEncode("can't read the recording's sound") }
        reader.add(output)

        let format = try await track.load(.formatDescriptions).first
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false
        input.metadata = try await track.load(.metadata)
        guard writer.canAdd(input) else { throw ExportError.cannotEncode("can't write the recording's sound") }
        writer.add(input)
        return EncodePipe.Lane(output: output, input: input, reportsProgress: false)
    }
}

/// Moves samples from reader to writer, one background queue per track so the reader
/// is drained evenly. The AVFoundation objects are only touched from those queues (and
/// before/after they run), so this is safe to share.
private final class EncodePipe: @unchecked Sendable {
    struct Lane {
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        /// The video lane drives the progress bar.
        let reportsProgress: Bool
    }

    private let reader: AVAssetReader
    private let lanes: [Lane]
    private let writer: AVAssetWriter
    private let range: CMTimeRange
    private let progress: @Sendable (Double) -> Void
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    /// Lanes still running, by index. A lane that fails ends them all, so none waits on
    /// a writer that has stopped.
    private let running = OSAllocatedUnfairLock(initialState: [Int: CheckedContinuation<Void, Never>]())
    /// Only touched on the progress lane's queue.
    private var lastReported = -1.0

    init(reader: AVAssetReader, lanes: [Lane], writer: AVAssetWriter, range: CMTimeRange,
         progress: @escaping @Sendable (Double) -> Void) {
        self.reader = reader
        self.lanes = lanes
        self.writer = writer
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
            await withTaskGroup(of: Void.self) { group in
                for i in lanes.indices {
                    group.addTask {
                        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                            self.running.withLock { $0[i] = done }
                            self.pump(index: i, on: DispatchQueue(label: "app.tinycap.export.\(i)", qos: .userInitiated))
                        }
                    }
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
            finishAll()
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

    /// Lanes are reached through `self` (shareable) rather than captured.
    private func pump(index: Int, on queue: DispatchQueue) {
        lanes[index].input.requestMediaDataWhenReady(on: queue) { [self] in
            let total = max(range.duration.seconds, 0.001)
            let lane = lanes[index]
            let (input, output) = (lane.input, lane.output)
            while input.isReadyForMoreMediaData {
                guard running.withLock({ $0[index] != nil }) else { return }
                guard !cancelled.withLock({ $0 }), let sample = output.copyNextSampleBuffer() else {
                    input.markAsFinished()
                    finish(index)
                    return
                }
                guard input.append(sample) else {
                    input.markAsFinished()
                    finishAll()
                    return
                }
                guard lane.reportsProgress else { continue }
                let t = (CMSampleBufferGetPresentationTimeStamp(sample) - range.start).seconds
                let fraction = min(max(t / total, 0), 0.99)
                if fraction - lastReported >= 0.01 {
                    lastReported = fraction
                    progress(fraction)
                }
            }
        }
    }

    private func finish(_ index: Int) {
        running.withLock { $0.removeValue(forKey: index) }?.resume()
    }

    private func finishAll() {
        let all = running.withLock { lanes in
            defer { lanes.removeAll() }
            return Array(lanes.values)
        }
        all.forEach { $0.resume() }
    }
}
