import AVFoundation
import CoreImage
import os
import TinycapCore

private let log = Logger(subsystem: "app.tinycap.Tinycap", category: "device")

enum DeviceCaptureError: LocalizedError {
    case cannotOpen(String)
    case noPicture
    case cameraAccessDenied

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let name):
            return "Tinycap can't open \(name). Unplug it, plug it back in and try again."
        case .noPicture:
            return "The device isn't sending a picture yet. Unlock it, tap Trust if it asks, and try again."
        case .cameraAccessDenied:
            return "Tinycap needs camera access to see connected iPhones and iPads: macOS lists them as cameras."
        }
    }
}

/// One connected iPhone or iPad (DV-2 to DV-5): an AVCaptureSession that runs while its
/// window is open, for the live preview, and writes a master .mov while recording. The
/// master goes through `CaptureFileWriter`, so preview, trim and export are the same as
/// for Mac recordings. All sample and writer state lives on `queue`.
final class DeviceSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let deviceID: String
    let name: String

    private let queue = DispatchQueue(label: "app.tinycap.device-capture", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let onSizeChange: @MainActor @Sendable (CGSize) -> Void

    // On `queue`.
    /// The newest frame. A device sends frames only when its screen changes, so this is
    /// what the screen shows now.
    private var latest: CMSampleBuffer?
    private var reportedSize: CGSize?
    private var writer: CaptureFileWriter?
    private var outputURL: URL?

    /// `onSizeChange` gets the picture's pixel size on the first frame and whenever the
    /// device rotates.
    init(device: AVCaptureDevice, onSizeChange: @escaping @MainActor @Sendable (CGSize) -> Void) throws {
        deviceID = device.uniqueID
        name = device.localizedName
        self.onSizeChange = onSizeChange
        super.init()

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            log.error("device input failed: \(error.localizedDescription, privacy: .public)")
            throw DeviceCaptureError.cannotOpen(name)
        }
        guard session.canAddInput(input) else { throw DeviceCaptureError.cannotOpen(name) }
        session.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(videoOutput) else { throw DeviceCaptureError.cannotOpen(name) }
        session.addOutput(videoOutput)

        // The writer encodes this to AAC; ask for the master's rate and layout.
        audioOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioSource.sampleRate,
            AVNumberOfChannelsKey: AudioSource.device.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        audioOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
        } else {
            log.notice("\(self.name, privacy: .public) has no sound output")
        }
    }

    // MARK: - Running

    /// `startRunning` blocks until the device answers, so it runs off the main thread.
    func startRunning() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            session.startRunning()
            log.notice("device session running: \(self.session.isRunning, privacy: .public)")
        }
    }

    func stopRunning() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            session.stopRunning()
            queue.async { [self] in latest = nil }
        }
    }

    // MARK: - Samples (on `queue`)

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            latest = sample
            if let size = sample.pixelSize, size != reportedSize {
                reportedSize = size
                let report = onSizeChange
                Task { @MainActor in report(size) }
            }
            writer?.appendCapturedVideo(sample)
        } else {
            writer?.appendCapturedAudio(sample, source: .device)
        }
    }

    private var now: CMTime {
        CMClockGetTime(session.synchronizationClock ?? CMClockGetHostTimeClock())
    }

    // MARK: - Recording

    /// Starts writing to `url`. Recording starts on the picture as it is now; with
    /// `sound` the device's own sound is kept (DV-5).
    func startRecording(to url: URL, sound: Bool) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard writer == nil else { return done.resume(throwing: RecorderError.alreadyRecording) }
                guard let latest, let size = latest.pixelSize else { return done.resume(throwing: DeviceCaptureError.noPicture) }
                do {
                    let writer = try CaptureFileWriter(
                        url: url, width: Self.even(size.width), height: Self.even(size.height), frameRate: 60,
                        sources: sound ? [.device] : [], letterbox: true, queue: queue
                    )
                    if let first = latest.retimed(at: now) { writer.appendCapturedVideo(first) }
                    self.writer = writer
                    outputURL = url
                    log.notice("device recording started: \(Int(size.width), privacy: .public)×\(Int(size.height), privacy: .public), sound \(sound, privacy: .public)")
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    /// Stops writing and returns the finished master.
    func stopRecording() async throws -> URL {
        let (writer, url, end): (CaptureFileWriter?, URL?, CMTime) = await withCheckedContinuation { done in
            queue.async { [self] in
                let result = (writer, outputURL, now)
                writer = nil
                outputURL = nil
                done.resume(returning: result)
            }
        }
        guard let writer, let url else { throw RecorderError.notRecording }
        do {
            try await writer.finish(endingAt: end)
        } catch {
            throw RecorderError.recordingFailed(error.localizedDescription)
        }
        return url
    }

    // MARK: - Screenshots (DV-4)

    /// The screen as it is now, at full resolution. Waits up to `timeout` for the first
    /// frame when the session has only just started.
    func snapshot(timeout: Duration = .seconds(5)) async -> CGImage? {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let image = await currentImage() { return image }
            if ContinuousClock.now >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func currentImage() async -> CGImage? {
        await withCheckedContinuation { done in
            queue.async { [self] in
                guard let latest, let pixels = CMSampleBufferGetImageBuffer(latest) else { return done.resume(returning: nil) }
                let image = CIImage(cvPixelBuffer: pixels)
                let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any])
                done.resume(returning: context.createCGImage(image, from: image.extent))
            }
        }
    }

    private static func even(_ value: CGFloat) -> Int {
        max(2, Int(value.rounded()) / 2 * 2)
    }
}
