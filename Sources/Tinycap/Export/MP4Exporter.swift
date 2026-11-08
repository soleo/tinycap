import AVFoundation
import os
import TinycapCore
import VideoToolbox

/// MP4 export (EX-1, EX-6): decodes the master with AVAssetReader and re-encodes with
/// AVAssetWriter (hardware H.264/HEVC via VideoToolbox), applying trim, bitrate and scale.
/// Kept sound is mixed into one AAC track, which every player plays; with
/// `separateAudioTracks` each source is copied as it is, still its own track (AU-3, AU-6).
/// The App Store Preview preset (DV-6) letterboxes into the accepted size, writes a
/// constant 30 fps and always has a stereo sound track, silent if nothing is kept.
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

        let fps = settings.appPreview ? Double(AppPreview.frameRate) : (nominalFPS > 0 ? Double(nominalFPS) : 30)
        let size = settings.outputSize(for: naturalSize)
        let bitrate = settings.bitrate(width: size.width, height: size.height, frameRate: fps)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: Int(fps * Self.keyframeSeconds),
            AVVideoMaxKeyFrameIntervalDurationKey: Self.keyframeSeconds,
            AVVideoAllowFrameReorderingKey: true,
        ]
        if settings.appPreview {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264High40
        } else if settings.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        } else {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        }

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true // moov first: plays while loading in Slack/GitHub
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.codec == .hevc && !settings.appPreview ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: compression,
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        guard writer.canAdd(input) else { throw ExportError.cannotEncode("unsupported output settings") }
        writer.add(input)

        let frames: () -> CMSampleBuffer?
        if settings.appPreview {
            let constant = ConstantFrameRate(source: output, fps: AppPreview.frameRate, range: range)
            frames = { constant.next() }
        } else {
            frames = { output.copyNextSampleBuffer() }
        }
        var lanes = [EncodePipe.Lane(next: frames, input: input, reportsProgress: true)]
        let sound = try await asset.loadTracks(withMediaType: .audio).filter { options.audioTrackIDs.contains($0.trackID) }
        if settings.appPreview {
            lanes.append(sound.isEmpty
                ? try Self.silentLane(range: range, writer: writer)
                : try Self.mixedSoundLane(for: sound, reader: reader, writer: writer, bitrate: AppPreview.audioBitrate))
        } else if sound.count > 1, !options.separateAudioTracks {
            lanes.append(try Self.mixedSoundLane(for: sound, reader: reader, writer: writer))
        } else {
            for track in sound {
                lanes.append(try await Self.soundLane(for: track, reader: reader, writer: writer))
            }
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

    /// Several sound tracks mixed into one stereo AAC track.
    fileprivate static func mixedSoundLane(for tracks: [AVAssetTrack], reader: AVAssetReader, writer: AVAssetWriter,
                                           bitrate: Int = AudioSource.system.bitrate) throws -> EncodePipe.Lane {
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioSource.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExportError.cannotEncode("can't mix the recording's sound") }
        reader.add(output)

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AudioSource.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: bitrate,
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw ExportError.cannotEncode("can't write the recording's sound") }
        writer.add(input)
        return EncodePipe.Lane(output: output, input: input, reportsProgress: false)
    }

    /// A silent stereo AAC track over `range`: App Store Connect refuses previews
    /// without sound.
    fileprivate static func silentLane(range: CMTimeRange, writer: AVAssetWriter) throws -> EncodePipe.Lane {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AudioSource.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: AppPreview.audioBitrate,
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw ExportError.cannotEncode("can't write a sound track") }
        writer.add(input)
        let silence = try Silence(range: range)
        return EncodePipe.Lane(next: { silence.next() }, input: input, reportsProgress: false)
    }
}

/// Turns a decoded video track into a constant frame rate: one frame every 1/fps
/// seconds across the range, each the newest source frame at that time. Device
/// recordings have frames only where the screen changed, at up to 60 fps.
/// Used on one export queue only.
private final class ConstantFrameRate {
    private let source: AVAssetReaderOutput
    private let interval: CMTime
    private let end: CMTime
    private var tick: CMTime
    private var held: CMSampleBuffer?
    private var upcoming: CMSampleBuffer?
    private var sourceDone = false

    init(source: AVAssetReaderOutput, fps: Int, range: CMTimeRange) {
        self.source = source
        interval = CMTime(value: 1, timescale: CMTimeScale(fps))
        tick = range.start
        end = range.end
    }

    func next() -> CMSampleBuffer? {
        while tick < end {
            if upcoming == nil, !sourceDone {
                upcoming = source.copyNextSampleBuffer()
                if upcoming == nil { sourceDone = true }
            }
            // Take every source frame due by this tick; the last one is shown.
            if let frame = upcoming, held == nil || frame.presentationTimeStamp <= tick {
                held = frame
                upcoming = nil
                continue
            }
            guard let held else { return nil }
            let time = tick
            tick = tick + interval
            return held.retimed(at: time, duration: interval)
        }
        return nil
    }
}

/// Silent 48 kHz stereo PCM in 0.1 s buffers across a time range.
private final class Silence {
    private static let framesPerBuffer = 4800
    private let format: CMAudioFormatDescription
    private var time: CMTime
    private let end: CMTime

    init(range: CMTimeRange) throws {
        var description = AudioStreamBasicDescription(
            mSampleRate: Float64(AudioSource.sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0,
                                                    layout: nil, magicCookieSize: 0, magicCookie: nil,
                                                    extensions: nil, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw ExportError.cannotEncode("can't make a silent track") }
        self.format = format
        time = CMTimeConvertScale(range.start, timescale: CMTimeScale(AudioSource.sampleRate), method: .roundTowardZero)
        end = range.end
    }

    func next() -> CMSampleBuffer? {
        guard time < end else { return nil }
        let remaining = Int(CMTimeConvertScale(end - time, timescale: CMTimeScale(AudioSource.sampleRate), method: .roundAwayFromZero).value)
        let frames = min(Self.framesPerBuffer, max(remaining, 1))
        let bytes = frames * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr,
              let block,
              CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) == noErr
        else { return nil }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
                                                                   formatDescription: format, sampleCount: frames,
                                                                   presentationTimeStamp: time, packetDescriptions: nil,
                                                                   sampleBufferOut: &sample) == noErr
        else { return nil }
        time = time + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(AudioSource.sampleRate))
        return sample
    }
}

/// Moves samples from reader to writer, one background queue per track so the reader
/// is drained evenly. The AVFoundation objects are only touched from those queues (and
/// before/after they run), so this is safe to share.
private final class EncodePipe: @unchecked Sendable {
    struct Lane {
        /// The next sample to write; nil when there are no more.
        let next: () -> CMSampleBuffer?
        let input: AVAssetWriterInput
        /// The video lane drives the progress bar.
        let reportsProgress: Bool

        init(next: @escaping () -> CMSampleBuffer?, input: AVAssetWriterInput, reportsProgress: Bool) {
            self.next = next
            self.input = input
            self.reportsProgress = reportsProgress
        }

        init(output: AVAssetReaderOutput, input: AVAssetWriterInput, reportsProgress: Bool) {
            self.init(next: { output.copyNextSampleBuffer() }, input: input, reportsProgress: reportsProgress)
        }
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
    /// One per lane, held while that lane touches the reader or writer. See `waitForLanes()`.
    private let laneLocks: [NSLock]
    /// Only touched on the progress lane's queue.
    private var lastReported = -1.0

    init(reader: AVAssetReader, lanes: [Lane], writer: AVAssetWriter, range: CMTimeRange,
         progress: @escaping @Sendable (Double) -> Void) {
        self.reader = reader
        self.lanes = lanes
        laneLocks = lanes.map { _ in NSLock() }
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
        waitForLanes()

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
            laneLocks[index].withLock {
                let total = max(range.duration.seconds, 0.001)
                let lane = lanes[index]
                let input = lane.input
                while running.withLock({ $0[index] != nil }), input.isReadyForMoreMediaData {
                    guard !cancelled.withLock({ $0 }), let sample = lane.next() else {
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
    }

    /// Waits until no lane is mid-sample. Cancelling or failing ends the lanes at once,
    /// but a lane's queue may still be reading or appending a sample; cancelling the
    /// reader or writer under it crashes (#31). Lanes that run after this see they've
    /// ended and touch nothing.
    private func waitForLanes() {
        for lock in laneLocks { lock.withLock {} }
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
