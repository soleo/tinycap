import AppKit
import ScreenCaptureKit
import TinycapCore

/// Runs one recording end to end: select → record → stop → save.
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
    private let exporter: Exporter = MP4Exporter()
    private let onNeedsPermission: () -> Void
    private var border: RecordingBorderWindow?

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
                guard let (target, borderRect) = await select(mode, content: content) else {
                    state = .idle
                    return
                }
                try await startRecording(target, content: content, borderRect: borderRect)
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

    private func select(_ mode: CaptureMode, content: SCShareableContent) async -> (CaptureTarget, CGRect?)? {
        switch mode {
        case .area:
            guard let selection = await AreaSelectionController().run(),
                  let display = content.displays.first(where: { $0.displayID == selection.displayID })
            else { return nil }
            let local = Geometry.displayLocalRect(selection.globalRect, screenFrame: selection.screenFrame)
            return (.area(display, rect: local), selection.globalRect)

        case .window:
            guard let windowID = await WindowPickerController(content: content).run(),
                  let window = content.windows.first(where: { $0.windowID == windowID })
            else { return nil }
            return (.window(window), nil)

        case .screen:
            guard let displayID = await ScreenPickerController().run(),
                  let display = content.displays.first(where: { $0.displayID == displayID })
            else { return nil }
            return (.display(display), nil)
        }
    }

    private func startRecording(_ target: CaptureTarget, content: SCShareableContent, borderRect: CGRect?) async throws {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApp = content.applications.first { $0.processID == ownPID }
        let master = try Self.newMasterURL()

        try await recorder.start(
            target: target,
            settings: RecordingSettings(defaults: .standard),
            excludingApp: ownApp,
            outputURL: master
        )

        if let borderRect {
            let border = RecordingBorderWindow(globalRect: borderRect)
            border.orderFrontRegardless()
            self.border = border
        }
        state = .recording(startedAt: Date())
    }

    /// Masters live in Application Support so a crash leaves them recoverable.
    private static func newMasterURL() throws -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("Tinycap/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    }

    // MARK: - Stop

    func stop() {
        guard case .recording = state else { return }
        state = .saving
        border?.orderOut(nil)
        border = nil

        Task {
            let master: URL
            do {
                master = try await recorder.stop()
            } catch {
                state = .idle
                present(error, title: "Tinycap couldn't finish the recording")
                return
            }
            do {
                let destination = try await save(master)
                try? FileManager.default.removeItem(at: master)
                RecentRecordings.add(destination)
                state = .idle
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                state = .idle
                presentSaveFailure(error, master: master)
            }
        }
    }

    /// The master is kept when export fails, so the clip is never lost.
    private func presentSaveFailure(_ error: Error, master: URL) {
        let alert = NSAlert()
        alert.messageText = "Tinycap couldn't save the recording"
        alert.informativeText = error.localizedDescription
            + "\n\nThe original recording was kept. You can choose another save folder in Settings."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Show Recording")
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([master])
        }
    }

    private func save(_ master: URL) async throws -> URL {
        let folder = try SaveLocation.shared.preparedFolder()
        let pattern = FilenamePattern(UserDefaults.standard.string(forKey: PreferenceKey.filenamePattern) ?? "")
        let destination = FilenamePattern.uniqueURL(
            in: folder,
            baseName: pattern.baseName(for: Date()),
            pathExtension: exporter.fileExtension
        )
        try await exporter.export(master: master, timeRange: nil, to: destination)
        return destination
    }

    // MARK: - Errors

    private func present(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate()
        alert.runModal()
    }
}
