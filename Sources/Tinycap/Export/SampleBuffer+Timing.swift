import AVFoundation

extension CMSampleBuffer {
    var pixelSize: CGSize? {
        guard let pixels = CMSampleBufferGetImageBuffer(self) else { return nil }
        return CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
    }

    /// The same picture at another time.
    func retimed(at time: CMTime, duration: CMTime = .invalid) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: self, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleBufferOut: &copy
        )
        return status == noErr ? copy : nil
    }
}
