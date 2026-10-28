import AppKit
import AVFoundation
import Observation
import TinycapCore

/// State behind one preview window: playback inside the trim range, export settings,
/// the live size estimate and the export itself.
@MainActor
@Observable
final class PreviewModel {
    enum Phase: Equatable {
        case loading
        case ready
        case exporting(progress: Double)
        case exported(URL)
        case failed(String)
    }

    let master: URL
    let player: AVPlayer
    private(set) var info: MasterInfo?
    private(set) var phase: Phase = .loading
    var trim = TrimRange(duration: 0)
    private(set) var playhead: Double = 0
    private(set) var isPlaying = false

    enum Estimate: Equatable {
        case none
        /// A new estimate is running; the last value (if any) stays on screen, dimmed.
        case estimating(previous: Int64?)
        case bytes(Int64)
        case unavailable
    }
    private(set) var estimate: Estimate = .none

    var codec: VideoCodec { didSet { persist() } }
    var quality: Double { didSet { persist() } }
    var scale: OutputScale { didSet { persist() } }

    private let exporter: Exporter = MP4Exporter()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var estimateTask: Task<Void, Never>?

    init(master: URL) {
        self.master = master
        player = AVPlayer(url: master)
        player.actionAtItemEnd = .pause
        let saved = ExportSettings(defaults: .standard)
        codec = saved.codec
        quality = saved.quality
        scale = saved.scale
        observeTime()
        Task { await load() }
    }

    func tearDown() {
        exportTask?.cancel()
        estimateTask?.cancel()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    private func load() async {
        do {
            let info = try await MasterInfo.load(master)
            self.info = info
            trim = TrimRange(duration: info.duration)
            phase = .ready
            scheduleEstimate(delay: .zero)
        } catch {
            phase = .failed("This recording can't be opened: \(error.localizedDescription)")
        }
    }

    // MARK: - Settings

    var settings: ExportSettings { ExportSettings(codec: codec, quality: quality, scale: scale) }

    var outputSize: (width: Int, height: Int)? {
        info.map { settings.outputSize(for: $0.pixelSize) }
    }

    /// Re-estimates after settings or trim settle. Encodes ~2 s of the real clip.
    private func scheduleEstimate(delay: Duration = .milliseconds(400)) {
        estimateTask?.cancel()
        guard info != nil else { return }
        let previous: Int64?
        switch estimate {
        case .bytes(let b): previous = b
        case .estimating(let p): previous = p
        default: previous = nil
        }
        estimate = .estimating(previous: previous)

        let exporter = self.exporter, master = self.master, settings = self.settings
        let start = trim.start, end = trim.end
        estimateTask = Task {
            do {
                try await Task.sleep(for: delay)
                let bytes = try await SizeEstimator.estimate(exporter: exporter, master: master, settings: settings, start: start, end: end)
                try Task.checkCancellation()
                estimate = .bytes(bytes)
            } catch is CancellationError {
                // Superseded by a newer estimate.
            } catch {
                estimate = .unavailable
            }
        }
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(codec.rawValue, forKey: PreferenceKey.exportCodec)
        d.set(quality, forKey: PreferenceKey.exportQuality)
        d.set(scale.storageValue, forKey: PreferenceKey.exportScale)
        if case .exported = phase { phase = .ready } // settings changed: offer Export again
        scheduleEstimate()
    }

    // MARK: - Playback

    private func observeTime() {
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        playhead = t
        isPlaying = player.rate != 0
        // Loop inside the trim range while playing.
        if isPlaying, t >= trim.end - 0.01 {
            seek(to: trim.start)
        }
    }

    func togglePlay() {
        if player.rate != 0 {
            player.pause()
            isPlaying = false
        } else {
            if playhead < trim.start || playhead >= trim.end - 0.05 { seek(to: trim.start) }
            player.play()
            isPlaying = true
        }
    }

    func seek(to t: Double) {
        let clamped = min(max(t, 0), trim.duration)
        playhead = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setTrimStart(_ t: Double) {
        trim.setStart(t)
        seek(to: trim.start)
        invalidateExport()
    }

    func setTrimEnd(_ t: Double) {
        trim.setEnd(t)
        seek(to: trim.end)
        invalidateExport()
    }

    func setStartAtPlayhead() { setTrimStart(playhead) }
    func setEndAtPlayhead() { setTrimEnd(playhead) }

    func resetTrim() {
        trim.reset()
        invalidateExport()
    }

    /// Trim changed: the exported file no longer matches, and the estimate is stale.
    private func invalidateExport() {
        if case .exported = phase { phase = .ready }
        scheduleEstimate()
    }

    // MARK: - Export

    var isExporting: Bool {
        if case .exporting = phase { return true }
        return false
    }

    var exportedURL: URL? {
        if case .exported(let url) = phase { return url }
        return nil
    }

    var canExport: Bool { info != nil && !isExporting }

    func export() {
        guard canExport else { return }
        let destination: URL
        do {
            destination = try SaveLocation.shared.nextDestination(pathExtension: exporter.fileExtension)
        } catch {
            phase = .failed("Can't write to the save folder: \(error.localizedDescription)")
            return
        }
        player.pause()
        phase = .exporting(progress: 0)

        let options = ExportOptions(
            timeRange: trim.isTrimmed ? CMTimeRange(
                start: CMTime(seconds: trim.start, preferredTimescale: 600),
                end: CMTime(seconds: trim.end, preferredTimescale: 600)
            ) : nil,
            settings: settings
        )
        let exporter = self.exporter
        let master = self.master
        exportTask = Task {
            do {
                try await exporter.export(master: master, options: options, to: destination) { fraction in
                    Task { @MainActor in
                        guard case .exporting = self.phase else { return }
                        self.phase = .exporting(progress: fraction)
                    }
                }
                RecentRecordings.add(destination)
                phase = .exported(destination)
            } catch is CancellationError {
                phase = .ready
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    func dismissError() {
        phase = info == nil ? .loading : .ready
    }

    // MARK: - After export (EX-7)

    func copyExportedFile() {
        guard let url = exportedURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    func revealExportedFile() {
        guard let url = exportedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
