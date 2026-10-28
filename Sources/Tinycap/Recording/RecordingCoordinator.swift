import AppKit
import ScreenCaptureKit
import TinycapCore

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
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate()
        alert.runModal()
    }
}
