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

    var format: ExportFormat { didSet { persist() } }
    // MP4
    var codec: VideoCodec { didSet { persist() } }
    var quality: Double { didSet { persist() } }
    var scale: OutputScale { didSet { persist() } }
    // WebM
    var webm: WebMSettings { didSet { persist() } }
    // GIF
    var gif: GIFSettings { didSet { persist() } }

    /// "Fit under N MB" for GIF (EX-5).
    enum Fit: Equatable {
        case idle
        case fitting
        case fitted(Int64)
        case cannotFit(Int64)
    }
    private(set) var fit: Fit = .idle

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var estimateTask: Task<Void, Never>?
    @ObservationIgnored private var fitTask: Task<Void, Never>?
    @ObservationIgnored private var applyingFit = false

    init(master: URL) {
        self.master = master
        player = AVPlayer(url: master)
        player.actionAtItemEnd = .pause
        let defaults = UserDefaults.standard
        format = ExportFormat(rawValue: defaults.string(forKey: PreferenceKey.exportFormat) ?? "") ?? .mp4
        gif = GIFSettings(defaults: defaults)
        webm = WebMSettings(defaults: defaults)
        let saved = ExportSettings(defaults: defaults)
        codec = saved.codec
        quality = saved.quality
        scale = saved.scale
        observeTime()
        Task { await load() }
    }

    func tearDown() {
        exportTask?.cancel()
        estimateTask?.cancel()
        fitTask?.cancel()
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

    var mp4Settings: ExportSettings { ExportSettings(codec: codec, quality: quality, scale: scale) }

    var formatSettings: FormatSettings {
        switch format {
        case .mp4: return .mp4(mp4Settings)
        case .webm: return .webm(webm)
        case .gif: return .gif(gif)
        }
    }

    private var exporter: Exporter { Exporters.exporter(for: format) }

    var outputSize: (width: Int, height: Int)? {
        info.map { formatSettings.outputSize(for: $0.pixelSize) }
    }

    /// Exporter options for start…end of the master.
    private func options(start: Double, end: Double) -> ExportOptions {
        ExportOptions(timeRange: CMTimeRange(seconds: start, end), format: formatSettings)
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

        let exporter = self.exporter, master = self.master
        let start = trim.start, end = trim.end
        let options = self.options(start: start, end: end)
        estimateTask = Task {
            do {
                try await Task.sleep(for: delay)
                let bytes = try await exporter.estimateSize(master: master, options: options, start: start, end: end)
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
        d.set(format.rawValue, forKey: PreferenceKey.exportFormat)
        d.set(codec.rawValue, forKey: PreferenceKey.exportCodec)
        d.set(quality, forKey: PreferenceKey.exportQuality)
        d.set(scale.storageValue, forKey: PreferenceKey.exportScale)
        gif.save(to: d)
        webm.save(to: d)
        if case .exported = phase { phase = .ready } // settings changed: offer Export again
        if !applyingFit {
            fitTask?.cancel()
            fit = .idle
        }
        scheduleEstimate()
    }

    func applyGIFPreset(_ preset: GIFPreset) {
        var s = preset.settings
        s.loop = gif.loop
        gif = s
    }

    // MARK: - Fit under N MB (EX-5)

    var fitTargetMB: Int {
        get { max(1, UserDefaults.standard.integer(forKey: PreferenceKey.gifFitTargetMB)) }
        set { UserDefaults.standard.set(max(1, newValue), forKey: PreferenceKey.gifFitTargetMB) }
    }

    /// Tries the current GIF settings, then successively smaller ones, and keeps the
    /// first whose estimate fits. Each try encodes a short sample, so this takes a
    /// second or two.
    func fitGIFUnderTarget() {
        guard format == .gif, let info else { return }
        fitTask?.cancel()
        estimateTask?.cancel()
        fit = .fitting
        let target = Int64(fitTargetMB) * 1_000_000
        let candidates = [gif] + gif.fitLadder(sourceWidth: Int(info.pixelSize.width))
        let master = self.master, start = trim.start, end = trim.end
        let exporter = GIFExporter()

        fitTask = Task {
            var last: (GIFSettings, Int64)?
            for candidate in candidates {
                let options = ExportOptions(timeRange: CMTimeRange(seconds: start, end), format: .gif(candidate))
                guard let bytes = try? await exporter.estimateSize(master: master, options: options, start: start, end: end) else {
                    if Task.isCancelled { return }
                    continue
                }
                if Task.isCancelled { return }
                last = (candidate, bytes)
                if bytes <= target { break }
            }
            guard let (settings, bytes) = last else {
                fit = .idle
                return
            }
            applyingFit = true
            gif = settings
            applyingFit = false
            estimateTask?.cancel()
            estimate = .bytes(bytes)
            fit = bytes <= target ? .fitted(bytes) : .cannotFit(bytes)
        }
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
        fitTask?.cancel()
        fit = .idle
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
            timeRange: trim.isTrimmed ? CMTimeRange(seconds: trim.start, trim.end) : nil,
            format: formatSettings
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
