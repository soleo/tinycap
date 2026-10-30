import AVFoundation
import CoreAudio
import os
import TinycapCore

private let log = Logger(subsystem: "app.tinycap.Tinycap", category: "recording")

/// Records the microphone through macOS voice processing (the echo cancellation FaceTime
/// uses), which removes the Mac's own output from the mic. Without it, system sound
/// played on speakers reaches the mic a few milliseconds late and echoes in the mix.
///
/// Samples are stamped on the host clock, the clock ScreenCaptureKit stamps video with,
/// and handed to `CaptureFileWriter` as microphone samples.
final class EchoCancelledMicrophone: @unchecked Sendable {
    enum MicError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return "The microphone couldn't start: \(reason)"
            }
        }
    }

    private let engine = AVAudioEngine()
    private let onSample: @Sendable (CMSampleBuffer) -> Void

    init(onSample: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.onSample = onSample
    }

    /// `deviceID` is the input's unique ID (Core Audio UID); nil uses the system input.
    func start(deviceID: String?) throws {
        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            throw MicError.unavailable("voice processing: \(error.localizedDescription)")
        }
        // Keep other sound at its normal level while recording.
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)

        if let deviceID {
            if let device = Self.audioDeviceID(forUID: deviceID) {
                do {
                    try input.auAudioUnit.setDeviceID(device)
                } catch {
                    log.error("couldn't select microphone \(deviceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            } else {
                log.error("microphone \(deviceID, privacy: .public) not found in Core Audio")
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicError.unavailable("no input format")
        }
        let onSample = self.onSample
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, time in
            guard time.isHostTimeValid, let sample = Self.sampleBuffer(from: buffer, hostTime: time.hostTime) else { return }
            onSample(sample)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw MicError.unavailable(error.localizedDescription)
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: - Helpers

    /// A PCM buffer as a sample buffer timed on the host clock.
    private static func sampleBuffer(from buffer: AVAudioPCMBuffer, hostTime: UInt64) -> CMSampleBuffer? {
        let frames = CMItemCount(buffer.frameLength)
        guard frames > 0 else { return nil }
        let rate = CMTimeScale(buffer.format.sampleRate)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: rate),
            presentationTimeStamp: CMClockMakeHostTimeFromSystemUnits(hostTime),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: buffer.format.formatDescription, sampleCount: frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sample, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: buffer.audioBufferList
        ) == noErr else { return nil }
        return sample
    }

    /// Core Audio device for a UID (an input's `AVCaptureDevice.uniqueID`).
    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }
}
