import AVFoundation
import ScreenCaptureKit
import os
import TinycapCore

/// What to record, resolved to ScreenCaptureKit objects.
enum CaptureTarget {
    case display(SCDisplay)
    /// `rect` is in the display's local, top-left-origin points.
    case area(SCDisplay, rect: CGRect)
    case window(SCWindow)
    /// One window, captured as its region of the display so Tinycap's click overlay can
    /// be drawn over it. `rect` is display-local, top-left points; it follows the window.
    case windowRegion(SCWindow, on: SCDisplay, rect: CGRect)
}

enum RecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case codecUnavailable
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "A recording is already in progress."
        case .notRecording: return "Nothing is being recorded."
        case .codecUnavailable: return "This Mac can't write H.264 video."
        case .recordingFailed(let reason): return "The recording failed: \(reason)"
        }
    }
}

/// Records a capture target straight to a master H.264 .mov. Without sound it uses
/// SCStream with SCRecordingOutput (macOS 15). With sound (AU-1–AU-3) a second,
/// audio-only stream captures the whole system and the microphone, and
/// `CaptureFileWriter` writes both streams' samples into one file. Frames stream to
/// disk; nothing is held in memory.
@MainActor
final class ScreenRecorder: NSObject {
    /// Called when the system stops the stream on its own (window closed, display
    /// unplugged, the user stopped sharing from the menu bar's privacy indicator).
    var onUnexpectedStop: ((Error?) -> Void)?

    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    private var recordingOutput: SCRecordingOutput?
    /// Recordings with sound: the audio-only stream and the writer for both streams.
    private var audioStream: SCStream?
    private var fileWriter: CaptureFileWriter?
    private var echoCancelledMic: EchoCancelledMicrophone?
    private let discardingOutput = DiscardingStreamOutput()
    private var outputURL: URL?
    private var finishContinuation: CheckedContinuation<Void, Error>?
    /// Identifies the current stop so a late timeout can't finish a later recording.
    private var stopID = 0
    private var isStopping = false

    var isRecording: Bool { stream != nil }

    func start(
        target: CaptureTarget,
        settings: RecordingSettings,
        excludingApp ownApp: SCRunningApplication?,
        includingOwnWindows ownWindows: [SCWindow] = [],
        audioDisplay: SCDisplay? = nil,
        outputURL: URL
    ) async throws {
        guard stream == nil else { throw RecorderError.alreadyRecording }

        let filter: SCContentFilter
        switch target {
        case .display(let display), .area(let display, _):
            filter = SCContentFilter(display: display, excludingApplications: ownApp.map { [$0] } ?? [],
                                  // Exceptions only apply to excluded apps; with none, ours are captured anyway.
                                  exceptingWindows: ownApp == nil ? [] : ownWindows)
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
        case .windowRegion(let window, let display, _):
            // Only the chosen window and Tinycap's overlay; nothing else on the display.
            filter = SCContentFilter(display: display, including: [window] + ownWindows)
        }

        let scale = settings.captureAtNativeScale ? CGFloat(filter.pointPixelScale) : 1
        let config = SCStreamConfiguration()
        let pointSize: CGSize
        switch target {
        case .area(_, let rect), .windowRegion(_, _, let rect):
            config.sourceRect = rect
            pointSize = rect.size
        default:
            pointSize = filter.contentRect.size
        }
        let pixels = Geometry.pixelSize(for: pointSize, scale: scale)
        config.width = pixels.width
        config.height = pixels.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate.rawValue))
        config.showsCursor = settings.showsCursor
        config.capturesAudio = false
        config.captureResolution = settings.captureAtNativeScale ? .best : .nominal
        config.queueDepth = 6

        let sources = settings.audioSources
        if !sources.isEmpty {
            guard let audioDisplay else { throw RecorderError.recordingFailed("No display to record sound from.") }
            try await startWithSound(filter: filter, config: config, settings: settings, sources: sources,
                                     audioDisplay: audioDisplay, excludingApp: ownApp, outputURL: outputURL)
            return
        }

        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL = outputURL
        recordingConfig.outputFileType = .mov
        guard recordingConfig.availableVideoCodecTypes.contains(.h264) else { throw RecorderError.codecUnavailable }
        recordingConfig.videoCodecType = .h264

        Logger(subsystem: "app.tinycap.Tinycap", category: "recording").notice(
            "stream start: own windows included \(ownWindows.map(\.windowID), privacy: .public), excluding own app \(ownApp != nil, privacy: .public), source \(String(describing: config.sourceRect), privacy: .public)")
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let output = SCRecordingOutput(configuration: recordingConfig, delegate: self)
        try stream.addRecordingOutput(output)

        self.stream = stream
        self.configuration = config
        self.recordingOutput = output
        self.outputURL = outputURL
        isStopping = false
        do {
            try await stream.startCapture()
        } catch {
            reset()
            throw error
        }
    }

    private func startWithSound(
        filter: SCContentFilter,
        config: SCStreamConfiguration,
        settings: RecordingSettings,
        sources: [AudioSource],
        audioDisplay: SCDisplay,
        excludingApp ownApp: SCRunningApplication?,
        outputURL: URL
    ) async throws {
        let writer = try CaptureFileWriter(url: outputURL, width: config.width, height: config.height,
                                           frameRate: settings.frameRate.rawValue, sources: sources)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)

        // Sound comes from the whole display, minus Tinycap, whatever the video shows.
        let audioFilter = SCContentFilter(display: audioDisplay, excludingApplications: ownApp.map { [$0] } ?? [],
                                          exceptingWindows: [])
        let audioConfig = SCStreamConfiguration()
        audioConfig.width = 2
        audioConfig.height = 2
        audioConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        audioConfig.showsCursor = false
        audioConfig.capturesAudio = sources.contains(.system)
        audioConfig.excludesCurrentProcessAudio = true
        audioConfig.sampleRate = AudioSource.sampleRate
        audioConfig.channelCount = AudioSource.system.channelCount
        // With echo reduction the mic comes from voice processing instead (see below).
        let micFromStream = sources.contains(.microphone) && !settings.reducesEcho
        audioConfig.captureMicrophone = micFromStream
        audioConfig.microphoneCaptureDeviceID = settings.microphoneID
        let audioStream = SCStream(filter: audioFilter, configuration: audioConfig, delegate: self)
        try audioStream.addStreamOutput(discardingOutput, type: .screen, sampleHandlerQueue: writer.queue)
        if sources.contains(.system) {
            try audioStream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
        }
        if micFromStream {
            try audioStream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue)
        }
        let echoCancelledMic = sources.contains(.microphone) && settings.reducesEcho
            ? EchoCancelledMicrophone { [weak writer] sample in writer?.appendMicrophone(sample) }
            : nil

        Logger(subsystem: "app.tinycap.Tinycap", category: "recording").notice(
            "stream start with sound: \(sources.map(\.rawValue), privacy: .public), mic \(settings.microphoneID ?? "default", privacy: .public), echo reduction \(echoCancelledMic != nil, privacy: .public)")
        self.stream = stream
        self.audioStream = audioStream
        self.configuration = config
        self.fileWriter = writer
        self.echoCancelledMic = echoCancelledMic
        self.outputURL = outputURL
        isStopping = false
        do {
            // Sound first, so the first video frame already has sound to go with it.
            try echoCancelledMic?.start(deviceID: settings.microphoneID)
            try await audioStream.startCapture()
            try await stream.startCapture()
        } catch {
            echoCancelledMic?.stop()
            try? await audioStream.stopCapture()
            writer.cancel()
            reset()
            throw error
        }
    }

    /// Moves the captured region (window-region recordings follow their window).
    /// The output size stays the same, so the video doesn't change shape.
    func moveSource(to rect: CGRect) async {
        guard let stream, let configuration, !isStopping, configuration.sourceRect != rect else { return }
        configuration.sourceRect = rect
        try? await stream.updateConfiguration(configuration)
    }

    /// Stops capture and waits until the master file is finalized on disk.
    func stop() async throws -> URL {
        guard let stream, let outputURL else { throw RecorderError.notRecording }
        isStopping = true
        defer { reset() }

        if let fileWriter {
            try? await stream.stopCapture()
            try? await audioStream?.stopCapture()
            echoCancelledMic?.stop()
            do {
                try await fileWriter.finish()
            } catch {
                throw RecorderError.recordingFailed(error.localizedDescription)
            }
            return outputURL
        }

        stopID += 1
        let id = stopID
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            finishContinuation = continuation
            Task {
                do {
                    try await stream.stopCapture()
                } catch {
                    // The stream may already be stopped by the system; the recording
                    // output still finishes the file in that case.
                }
                // Guard against a missing finish callback so Stop never hangs.
                try? await Task.sleep(for: .seconds(5))
                if self.stopID == id { self.resumeFinish(with: nil) }
            }
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw RecorderError.recordingFailed("No video was written.")
        }
        return outputURL
    }

    private func resumeFinish(with error: Error?) {
        guard let continuation = finishContinuation else { return }
        finishContinuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    private func reset() {
        stream = nil
        configuration = nil
        recordingOutput = nil
        audioStream = nil
        fileWriter = nil
        echoCancelledMic = nil
        outputURL = nil
        isStopping = false
    }
}

extension ScreenRecorder: SCStreamDelegate, SCRecordingOutputDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let stoppedStream = ObjectIdentifier(stream)
        Task { @MainActor in
            let ours = [self.stream, self.audioStream].compactMap { $0 }.contains { ObjectIdentifier($0) == stoppedStream }
            guard !self.isStopping, ours else { return }
            self.onUnexpectedStop?(error)
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.resumeFinish(with: nil) }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            if self.finishContinuation != nil {
                self.resumeFinish(with: RecorderError.recordingFailed(error.localizedDescription))
            } else if !self.isStopping {
                self.onUnexpectedStop?(error)
            }
        }
    }
}
