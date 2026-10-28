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

    private let recorder = ScreenRecorder()
    private let onNeedsPermission: () -> Void
    private var border: RecordingBorderWindow?
    private var countdown: CountdownController?
    private var clicks: ClickHighlighter?
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
        guard state == .idle else { return }
        // No CGPreflightScreenCaptureAccess gate here: it can stay false after the user
        // grants access until the app restarts. ScreenCaptureKit gives the real answer.
        state = .selecting

        Task {
            do {
                // Fail before recording, not after, if the save folder isn't writable.
                _ = try SaveLocation.shared.preparedFolder()
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let selection = await select(mode, content: content) else {
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

    /// What the user picked, plus where to draw the border and the countdown
    /// (both in AppKit global coordinates).
    private struct Selection {
        var target: CaptureTarget
        var borderRect: CGRect?
        var countdownRect: CGRect?
    }

    private func select(_ mode: CaptureMode, content: SCShareableContent) async -> Selection? {
        switch mode {
        case .area:
            guard let selection = await AreaSelectionController().run(),
                  let display = content.displays.first(where: { $0.displayID == selection.displayID })
            else { return nil }
            let local = Geometry.displayLocalRect(selection.globalRect, screenFrame: selection.screenFrame)
            return Selection(target: .area(display, rect: local), borderRect: selection.globalRect, countdownRect: selection.globalRect)

        case .window:
            guard let windowID = await WindowPickerController(content: content).run(),
                  let window = content.windows.first(where: { $0.windowID == windowID })
            else { return nil }
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let frame = Geometry.appKitRect(fromCG: window.frame, primaryScreenHeight: primaryHeight)
            return Selection(target: .window(window), countdownRect: frame)

        case .screen:
            guard let displayID = await ScreenPickerController().run(),
                  let display = content.displays.first(where: { $0.displayID == displayID })
            else { return nil }
            let frame = NSScreen.screens.first { $0.displayID == displayID }?.frame
            return Selection(target: .display(display), countdownRect: frame)
        }
    }

    private func startRecording(
        _ target: CaptureTarget,
        settings: RecordingSettings,
        content: SCShareableContent,
        borderRect: CGRect?
    ) async throws {
        let master = try Self.newMasterURL()

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
        state = .recording(startedAt: Date())
    }

    /// Shows the click overlay on the recorded screen and returns its window for the
    /// capture filter. Nil for window recordings or if the overlay can't be found.
    private func startClickHighlighter(for target: CaptureTarget) async -> SCWindow? {
        let display: SCDisplay
        switch target {
        case .display(let d), .area(let d, _): display = d
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
