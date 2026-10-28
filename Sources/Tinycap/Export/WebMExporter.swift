import Accelerate
import AVFoundation
import os
import TinycapCore
import VPXBridge

/// WebM export (EX-2): decodes the master to BT.709 I420 planes, scales them with vImage
/// if needed and encodes VP9 with libvpx into a WebM file (libwebm) via VPXBridge.
/// Frames keep their real timing, so static stretches of a screen recording cost
/// almost nothing.
struct WebMExporter: Exporter {
    let fileExtension = "webm"
    static let keyframeSeconds = 2.0

    func export(
        master: URL,
        options: ExportOptions,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard case .webm(let settings) = options.format else { throw ExportError.wrongFormat }
        let job = try await WebMJob.make(master: master, range: options.timeRange, settings: settings)
        try? FileManager.default.removeItem(at: destination)
        do {
            try await job.run(to: destination, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func estimateSize(master: URL, options: ExportOptions, start: Double, end: Double) async throws -> Int64 {
        try await SizeEstimator.estimate(exporter: self, master: master, options: options,
                                         pieceLength: Self.keyframeSeconds, start: start, end: end)
    }
}

/// One WebM encode. The asset and track are loaded up front; the reader and encoder
/// are created and used only on the job's queue.
private final class WebMJob: @unchecked Sendable {
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let start: Double
    private let end: Double
    private let settings: WebMSettings
    private let sourceSize: CGSize
    private let frameRate: Double
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    private static let queue = DispatchQueue(label: "app.tinycap.webm", qos: .userInitiated)

    private init(asset: AVURLAsset, track: AVAssetTrack, start: Double, end: Double,
                 settings: WebMSettings, sourceSize: CGSize, frameRate: Double) {
        self.asset = asset
        self.track = track
        self.start = start
        self.end = end
        self.settings = settings
        self.sourceSize = sourceSize
        self.frameRate = frameRate
    }

    static func make(master: URL, range: CMTimeRange?, settings: WebMSettings) async throws -> WebMJob {
        let asset = AVURLAsset(url: master)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideoTrack }
        let (size, fps) = try await track.load(.naturalSize, .nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        let start = range.map { $0.start.seconds } ?? 0
        let end = range.map { $0.end.seconds } ?? duration
        return WebMJob(asset: asset, track: track, start: start, end: max(end, start + 0.01), settings: settings,
                       sourceSize: size, frameRate: fps > 0 ? Double(fps) : 30)
    }

    func run(to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Self.queue.async {
                    do {
                        try self.encode(to: destination, progress: progress)
                        continuation.resume()
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

    private func encode(to destination: URL, progress: @Sendable (Double) -> Void) throws {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(seconds: start, end)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8Planar,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ExportError.cannotEncode("can't read the recording") }
        defer { reader.cancelReading() }

        let size = settings.outputSize(for: sourceSize)
        var config = TCWebMConfig(
            width: Int32(size.width),
            height: Int32(size.height),
            frame_rate: frameRate,
            cq_level: Int32(settings.cqLevel),
            max_bitrate_kbps: Int32(settings.maxBitrateKbps(width: size.width, height: size.height, frameRate: frameRate)),
            keyframe_interval: Int32((frameRate * WebMExporter.keyframeSeconds).rounded()),
            cpu_used: Int32(WebMSettings.cpuUsed),
            threads: Int32(min(max(ProcessInfo.processInfo.activeProcessorCount, 2), 8))
        )
        var error = [CChar](repeating: 0, count: 256)
        guard let writer = destination.path.withCString({ tc_webm_open($0, &config, &error, error.count) }) else {
            throw ExportError.cannotEncode(message(error))
        }
        var finished = false
        defer { if !finished { tc_webm_abort(writer) } }

        let planes = PlaneScaler(width: size.width, height: size.height)
        var held: (buffer: CVPixelBuffer, ms: Int64)?
        var lastMs: Int64 = -1
        let total = max(end - start, 0.001)

        func encodeHeld(until endMs: Int64) throws {
            guard let (buffer, ms) = held else { return }
            if isCancelled { throw CancellationError() }
            try planes.withPlanes(buffer) { y, ys, u, us, v, vs in
                if tc_webm_write_frame(writer, y, Int32(ys), u, Int32(us), v, Int32(vs), ms, max(endMs - ms, 1), &error, error.count) != 0 {
                    throw ExportError.cannotEncode(message(error))
                }
            }
            progress(min(Double(ms) / 1000 / total, 0.99))
        }

        // Variable frame rate: each frame lasts until the next one starts.
        while let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            var ms = Int64(((CMSampleBufferGetPresentationTimeStamp(sample).seconds - start) * 1000).rounded())
            ms = max(ms, lastMs + 1, 0) // strictly increasing timestamps
            try encodeHeld(until: ms)
            held = (image, ms)
            lastMs = ms
        }
        if reader.status == .failed { throw reader.error ?? ExportError.cannotEncode("reading failed") }
        try encodeHeld(until: max(Int64((total * 1000).rounded()), lastMs + 1))

        finished = true
        if tc_webm_finish(writer, &error, error.count) != 0 {
            throw ExportError.cannotEncode(message(error))
        }
        progress(1)
    }
}

/// Text from a C error buffer (NUL-terminated).
private func message(_ buffer: [CChar]) -> String {
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return bytes.isEmpty ? "unknown error" : String(decoding: bytes, as: UTF8.self)
}

/// Hands out the Y, U and V planes of a 4:2:0 planar buffer, scaled with vImage when
/// the output size differs.
private final class PlaneScaler {
    private let width: Int
    private let height: Int
    private var y: [UInt8]
    private var u: [UInt8]
    private var v: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        y = [UInt8](repeating: 0, count: width * height)
        u = [UInt8](repeating: 128, count: (width / 2) * (height / 2))
        v = [UInt8](repeating: 128, count: (width / 2) * (height / 2))
    }

    typealias Planes = (UnsafePointer<UInt8>, Int, UnsafePointer<UInt8>, Int, UnsafePointer<UInt8>, Int) throws -> Void

    func withPlanes(_ buffer: CVPixelBuffer, _ body: Planes) throws {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) == 3,
              let sy = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let su = CVPixelBufferGetBaseAddressOfPlane(buffer, 1),
              let sv = CVPixelBufferGetBaseAddressOfPlane(buffer, 2)
        else { throw ExportError.cannotEncode("unexpected frame format") }

        let srcW = CVPixelBufferGetWidthOfPlane(buffer, 0), srcH = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rows = (CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), CVPixelBufferGetBytesPerRowOfPlane(buffer, 1),
                    CVPixelBufferGetBytesPerRowOfPlane(buffer, 2))

        if srcW == width && srcH == height {
            try body(sy.assumingMemoryBound(to: UInt8.self), rows.0,
                     su.assumingMemoryBound(to: UInt8.self), rows.1,
                     sv.assumingMemoryBound(to: UInt8.self), rows.2)
            return
        }
        try scale(sy, w: srcW, h: srcH, rowBytes: rows.0, into: &y, w: width, h: height)
        try scale(su, w: CVPixelBufferGetWidthOfPlane(buffer, 1), h: CVPixelBufferGetHeightOfPlane(buffer, 1),
                  rowBytes: rows.1, into: &u, w: width / 2, h: height / 2)
        try scale(sv, w: CVPixelBufferGetWidthOfPlane(buffer, 2), h: CVPixelBufferGetHeightOfPlane(buffer, 2),
                  rowBytes: rows.2, into: &v, w: width / 2, h: height / 2)
        try y.withUnsafeBufferPointer { yp in
            try u.withUnsafeBufferPointer { up in
                try v.withUnsafeBufferPointer { vp in
                    try body(yp.baseAddress!, width, up.baseAddress!, width / 2, vp.baseAddress!, width / 2)
                }
            }
        }
    }

    private func scale(_ src: UnsafeMutableRawPointer, w: Int, h: Int, rowBytes: Int,
                       into dst: inout [UInt8], w dw: Int, h dh: Int) throws {
        var s = vImage_Buffer(data: src, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: rowBytes)
        let error = dst.withUnsafeMutableBytes { d -> vImage_Error in
            var t = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(dh), width: vImagePixelCount(dw), rowBytes: dw)
            return vImageScale_Planar8(&s, &t, nil, vImage_Flags(kvImageHighQualityResampling))
        }
        guard error == kvImageNoError else { throw ExportError.cannotEncode("scaling failed (\(error))") }
    }
}
