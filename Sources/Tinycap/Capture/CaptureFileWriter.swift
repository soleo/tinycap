import AVFoundation
import ScreenCaptureKit
import TinycapCore

/// Writes a master .mov with sound (AU-3): an H.264 video track plus one AAC track per
/// sound source, all timed on the host clock that ScreenCaptureKit stamps every sample
/// with. Video comes from the recording's stream and sound from a separate audio stream,
/// so sound is the whole system's even when the video is a single window (AU-1).
///
/// Recordings without sound don't use this; they keep `SCRecordingOutput`.
final class CaptureFileWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    enum WriterError: LocalizedError {
        case noVideo
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noVideo: return "No video was captured."
            case .failed(let reason): return reason
            }
        }
    }

    /// Every sample handler and all writer state run on this queue.
    let queue = DispatchQueue(label: "app.tinycap.capture-writer", qos: .userInitiated)

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: [AudioSource: AVAssetWriterInput]
    private var sessionStart: CMTime?
    private var lastTime: CMTime = .zero
    private var isFinishing = false

    init(url: URL, width: Int, height: Int, frameRate: Int, sources: [AudioSource]) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        // A high bitrate: the master is re-encoded on export, so it only has to be clean.
        let bitrate = Double(width * height * frameRate) * 0.2
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(bitrate, 2_000_000),
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        video.expectsMediaDataInRealTime = true

        var audio: [AudioSource: AVAssetWriterInput] = [:]
        for source in sources {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: AudioSource.sampleRate,
                AVNumberOfChannelsKey: source.channelCount,
                AVEncoderBitRateKey: source.bitrate,
            ])
            input.expectsMediaDataInRealTime = true
            let name = AVMutableMetadataItem()
            name.identifier = .quickTimeUserDataTrackName
            name.value = source.trackName as NSString
            input.metadata = [name]
            audio[source] = input
        }
        self.audio = audio

        super.init()
        for input in [video] + sources.compactMap({ audio[$0] }) {
            guard writer.canAdd(input) else { throw WriterError.failed("Can't write \(input.mediaType.rawValue) to the recording.") }
            writer.add(input)
        }
        guard writer.startWriting() else {
            throw WriterError.failed(writer.error?.localizedDescription ?? "Can't start writing the recording.")
        }
    }

    // MARK: - Samples (on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !isFinishing, writer.status == .writing, sample.isValid else { return }
        switch type {
        case .screen: appendVideo(sample)
        case .audio: appendAudio(sample, to: audio[.system])
        case .microphone: appendAudio(sample, to: audio[.microphone])
        @unknown default: break
        }
    }

    private func appendVideo(_ sample: CMSampleBuffer) {
        // ScreenCaptureKit also sends idle and blank frames with no new image; skip them.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete
        else { return }
        let time = sample.presentationTimeStamp
        if sessionStart == nil {
            // The file starts at the first frame; sound from before it is dropped.
            writer.startSession(atSourceTime: time)
            sessionStart = time
        }
        guard video.isReadyForMoreMediaData, video.append(sample) else { return }
        lastTime = max(lastTime, time)
    }

    private func appendAudio(_ sample: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let input, let start = sessionStart else { return }
        let time = sample.presentationTimeStamp
        guard time >= start, input.isReadyForMoreMediaData, input.append(sample) else { return }
        let end = time + sample.duration
        lastTime = max(lastTime, end.isValid ? end : time)
    }

    // MARK: - Finish

    /// Closes the file after the streams have stopped. The last video frame is held
    /// until the last sound, so a still screen at the end doesn't cut the sound short.
    func finish() async throws {
        let started: Bool = await withCheckedContinuation { done in
            queue.async { [self] in
                isFinishing = true
                guard sessionStart != nil, writer.status == .writing else {
                    if writer.status == .writing { writer.cancelWriting() }
                    done.resume(returning: false)
                    return
                }
                video.markAsFinished()
                audio.values.forEach { $0.markAsFinished() }
                writer.endSession(atSourceTime: lastTime)
                done.resume(returning: true)
            }
        }
        if writer.status == .failed {
            throw WriterError.failed(writer.error?.localizedDescription ?? "Writing the recording failed.")
        }
        guard started else { throw WriterError.noVideo }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw WriterError.failed(writer.error?.localizedDescription ?? "Writing the recording failed.")
        }
    }

    /// Discards the file (the recording couldn't start).
    func cancel() {
        queue.async { [self] in
            if writer.status == .writing { writer.cancelWriting() }
        }
    }
}

/// Receives the audio stream's screen frames, which nothing uses. Without an output for
/// them ScreenCaptureKit logs an error for every frame.
final class DiscardingStreamOutput: NSObject, SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {}
}
