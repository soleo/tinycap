import AppKit
import ScreenCaptureKit
import os
import TinycapCore

private let log = Logger(subsystem: "app.tinycap.Tinycap", category: "recording")

/// Runs one recording end to end: select → record → stop → preview.
@MainActor
final class RecordingCoordinator {
    enum State: Equatable {
        case idle
        case selecting
        case recording(startedAt: Date)
        case saving
    }

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    var onStateChange: ((State) -> Void)?
    /// False while a screenshot is being taken, so the two overlays never stack.
    var canStart: () -> Bool = { true }

    /// Selecting, counting down, recording, saving or exporting: no update reminders now (UP-3).
    var isBusy: Bool {
        state != .idle || countdown != nil || previews.contains { $0.model.isExporting }
    }

    private let recorder = ScreenRecorder()
    private let onNeedsPermission: () -> Void
    private var border: RecordingBorderWindow?
    private var countdown: CountdownController?
    private var clicks: ClickHighlighter?
    private var windowTracker: Timer?
    private var previews: [PreviewWindowController] = []

    init(onNeedsPermission: @escaping () -> Void) {
        self.onNeedsPermission = onNeedsPermission
        recorder.onUnexpectedStop = { [weak self] _ in
            // Keep whatever was captured before the system ended the stream.
            self?.stop()
        }
    }

    // MARK: - Start

    func begin(_ mode: CaptureMode) {
        guard state == .idle, canStart() else { return }
        // No CGPreflightScreenCaptureAccess gate here: it can stay false after the user
        // grants access until the app restarts. ScreenCaptureKit gives the real answer.
        state = .selecting

        Task {
            do {
                // Fail before recording, not after, if the save folder isn't writable.
                _ = try SaveLocation.shared.preparedFolder()
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let selection = await CaptureSelector.select(mode, content: content, purpose: .record) else {
                    state = .idle
                    return
                }
                let settings = RecordingSettings(defaults: .standard)
                if settings.countdown, let rect = selection.countdownRect {
                    let countdown = CountdownController()
                    self.countdown = countdown
                    let completed = await countdown.run(over: rect)
                    self.countdown = nil
                    guard completed else {
                        state = .idle
                        return
                    }
                }
                try await startRecording(selection.target, settings: settings, content: content, borderRect: selection.borderRect)
            } catch {
                state = .idle
                if Permissions.isPermissionError(error) {
                    Permissions.requestScreenRecordingAccess()
                    onNeedsPermission()
                } else {
                    present(error, title: "Tinycap couldn't start recording")
                }
            }
        }
    }

    private func startRecording(
        _ target: CaptureTarget,
        settings: RecordingSettings,
        content: SCShareableContent,
        borderRect: CGRect?
    ) async throws {
        let master = try Self.newMasterURL()

        // A window on its own can't show Tinycap's click rings, so with click highlighting
        // on, record the window's region of its display instead and follow it (RC-4, RC-6).
        var target = target
        if settings.highlightsClicks, case .window(let window) = target,
           let index = Geometry.bestDisplayIndex(for: window.frame, displays: content.displays.map(\.frame)) {
            let display = content.displays[index]
            target = .windowRegion(window, on: display,
                                   rect: Geometry.windowSourceRect(window: window.frame, display: display.frame))
        }

        var ownWindows: [SCWindow] = []
        if settings.highlightsClicks, let window = await startClickHighlighter(for: target) {
            ownWindows.append(window)
        }

        // Find Tinycap in a list that includes apps with no window on screen: after the
        // picker closes Tinycap may have none, and the earlier on-screen-only list
        // leaves it out. Without it, nothing of Tinycap's is excluded, and the
        // click overlay (an exception to that exclusion) would be hidden instead.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let allApps = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let ownApp = (allApps?.applications ?? content.applications).first { $0.processID == ownPID }
        if ownApp == nil {
            log.error("Tinycap not found in shareable applications; its own windows will be captured")
        }

        do {
            try await recorder.start(
                target: target,
                settings: settings,
                excludingApp: ownApp,
                includingOwnWindows: ownWindows,
                outputURL: master
            )
        } catch {
            stopClickHighlighter()
            throw error
        }

        if let borderRect {
            let border = RecordingBorderWindow(globalRect: borderRect)
            border.orderFrontRegardless()
            self.border = border
        }
        if case .windowRegion(let window, let display, _) = target {
            trackWindow(window.windowID, on: display.frame)
        }
        state = .recording(startedAt: Date())
    }

    /// Shows the click overlay on the recorded screen and returns its window for the
    /// capture filter. Nil for window recordings or if the overlay can't be found.
    private func startClickHighlighter(for target: CaptureTarget) async -> SCWindow? {
        let display: SCDisplay
        switch target {
        case .display(let d), .area(let d, _), .windowRegion(_, let d, _): display = d
        case .window: return nil
        }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == display.displayID }) else { return nil }

        let highlighter = ClickHighlighter(screen: screen)
        highlighter.start()
        clicks = highlighter
        // The window server can take a moment to list a new window.
        for _ in 0..<5 {
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
               let window = content.windows.first(where: { $0.windowID == highlighter.windowID }) {
                let pid = ProcessInfo.processInfo.processIdentifier
                log.notice("click overlay found: window \(window.windowID, privacy: .public) layer \(window.windowLayer, privacy: .public) onScreen \(window.isOnScreen, privacy: .public) frame \(String(describing: window.frame), privacy: .public) owner pid \(window.owningApplication?.processID ?? -1, privacy: .public) (own \(pid, privacy: .public))")
                return window
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        log.error("click overlay window \(highlighter.windowID, privacy: .public) not found in shareable content")
        stopClickHighlighter()
        return nil
    }

    /// Follows a window-region recording's window ten times a second: moves the capture
    /// region when the window moves, and stops the recording when the window closes,
    /// as a single-window capture would.
    private func trackWindow(_ windowID: CGWindowID, on displayFrame: CGRect) {
        windowTracker?.invalidate()
        windowTracker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[CFString: Any]])?.first,
                      let boundsDict = info[kCGWindowBounds] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
                else {
                    log.notice("recorded window \(windowID, privacy: .public) closed; stopping")
                    self.stop()
                    return
                }
                let rect = Geometry.windowSourceRect(window: bounds, display: displayFrame)
                Task { await self.recorder.moveSource(to: rect) }
            }
        }
    }

    private func stopWindowTracker() {
        windowTracker?.invalidate()
        windowTracker = nil
    }

    private func stopClickHighlighter() {
        clicks?.stop()
        clicks = nil
    }

    /// Masters live in Application Support so a crash or quit leaves them recoverable.
    private static var mastersFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Tinycap/Recordings", isDirectory: true)
    }

    private static func newMasterURL() throws -> URL {
        try FileManager.default.createDirectory(at: mastersFolder, withIntermediateDirectories: true)
        return mastersFolder.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    }

    // MARK: - Stop

    func stop() {
        guard case .recording = state else { return }
        state = .saving
        border?.orderOut(nil)
        border = nil
        stopClickHighlighter()
        stopWindowTracker()

        Task {
            do {
                let master = try await recorder.stop()
                state = .idle
                openPreview(master)
            } catch {
                state = .idle
                present(error, title: "Tinycap couldn't finish the recording")
            }
        }
    }

    // MARK: - Preview

    private func openPreview(_ master: URL) {
        let controller = PreviewWindowController(master: master) { [weak self] closed in
            self?.previews.removeAll { $0 === closed }
        }
        previews.append(controller)
        controller.show()
    }

    /// Masters left behind by a quit or crash (RC reliability). Offered once at launch.
    func offerUnsavedRecordings() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.mastersFolder, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let masters = files.filter { $0.pathExtension == "mov" }
        guard !masters.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = masters.count == 1
            ? "Tinycap found a recording that wasn't exported"
            : "Tinycap found \(masters.count) recordings that weren't exported"
        alert.informativeText = "Open them to trim and export, or delete them."
        alert.addButton(withTitle: masters.count == 1 ? "Open" : "Open All")
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            masters.prefix(5).forEach(openPreview)
        case .alertSecondButtonReturn:
            masters.forEach { try? FileManager.default.removeItem(at: $0) }
        default:
            break
        }
    }

    // MARK: - Errors

    private func present(_ error: Error, title: String) {
        Diagnostics.record(error, context: title)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate()
        alert.runModal()
    }
}
