import AVFoundation
import ScreenCaptureKit
import TinycapCore

/// What to record, resolved to ScreenCaptureKit objects.
enum CaptureTarget {
    case display(SCDisplay)
    /// `rect` is in the display's local, top-left-origin points.
    case area(SCDisplay, rect: CGRect)
    case window(SCWindow)
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

/// Records a capture target straight to a master H.264 .mov using SCStream with
/// SCRecordingOutput (macOS 15). Frames stream to disk; nothing is held in memory.
@MainActor
final class ScreenRecorder: NSObject {
    /// Called when the system stops the stream on its own (window closed, display
    /// unplugged, the user stopped sharing from the menu bar's privacy indicator).
    var onUnexpectedStop: ((Error?) -> Void)?

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
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
        outputURL: URL
    ) async throws {
        guard stream == nil else { throw RecorderError.alreadyRecording }

        let filter: SCContentFilter
        switch target {
        case .display(let display), .area(let display, _):
            filter = SCContentFilter(display: display, excludingApplications: ownApp.map { [$0] } ?? [], exceptingWindows: [])
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let scale = settings.captureAtNativeScale ? CGFloat(filter.pointPixelScale) : 1
        let config = SCStreamConfiguration()
        let pointSize: CGSize
        if case .area(_, let rect) = target {
            config.sourceRect = rect
            pointSize = rect.size
        } else {
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

        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL = outputURL
        recordingConfig.outputFileType = .mov
        guard recordingConfig.availableVideoCodecTypes.contains(.h264) else { throw RecorderError.codecUnavailable }
        recordingConfig.videoCodecType = .h264

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let output = SCRecordingOutput(configuration: recordingConfig, delegate: self)
        try stream.addRecordingOutput(output)

        self.stream = stream
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

    /// Stops capture and waits until the master file is finalized on disk.
    func stop() async throws -> URL {
        guard let stream, let outputURL else { throw RecorderError.notRecording }
        isStopping = true
        defer { reset() }

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
        recordingOutput = nil
        outputURL = nil
        isStopping = false
    }
}

extension ScreenRecorder: SCStreamDelegate, SCRecordingOutputDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let stoppedStream = ObjectIdentifier(stream)
        Task { @MainActor in
            guard !self.isStopping, let current = self.stream, ObjectIdentifier(current) == stoppedStream else { return }
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
