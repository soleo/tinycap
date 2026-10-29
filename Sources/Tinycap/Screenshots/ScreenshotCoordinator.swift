import AppKit
import ScreenCaptureKit
import TinycapCore

/// Runs one screenshot: pick the target on the shared overlay (SS-1), capture (SS-2),
/// then open the editor, copy or save (SS-3).
@MainActor
final class ScreenshotCoordinator {
    private(set) var isSelecting = false
    /// Screenshots wait while a recording is being set up or running.
    var canStart: () -> Bool = { true }
    var onNeedsPermission: () -> Void = {}

    private var editors: [ScreenshotEditorWindowController] = []

    var hasEditorOpen: Bool { !editors.isEmpty }

    func begin(_ mode: CaptureMode) {
        guard !isSelecting, canStart() else { return }
        isSelecting = true

        Task {
            defer { isSelecting = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let selection = await CaptureSelector.select(mode, content: content, purpose: .screenshot) else { return }
                let settings = ScreenshotSettings(defaults: .standard)
                let shot = try await ScreenshotCapturer.capture(selection.target, windowShadow: settings.windowShadow)
                deliver(shot, settings: settings)
            } catch {
                if Permissions.isPermissionError(error) {
                    Permissions.requestScreenRecordingAccess()
                    onNeedsPermission()
                } else {
                    Diagnostics.record(error, context: "Screenshot")
                    let alert = NSAlert()
                    alert.messageText = "Tinycap couldn't take the screenshot"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    NSApp.activate()
                    alert.runModal()
                }
            }
        }
    }

    private func deliver(_ shot: Screenshot, settings: ScreenshotSettings) {
        switch settings.afterCapture {
        case .openEditor:
            let editor = ScreenshotEditorWindowController(shot) { [weak self] closed in
                self?.editors.removeAll { $0 === closed }
            }
            editors.append(editor)
            editor.show()
        case .copy:
            let model = ScreenshotEditorModel(shot)
            if model.copyToPasteboard() { NSSound(named: "Tink")?.play() }
        case .save:
            let model = ScreenshotEditorModel(shot)
            model.save()
            if model.savedURL != nil {
                NSSound(named: "Tink")?.play()
            } else if let message = model.message {
                let alert = NSAlert()
                alert.messageText = "Tinycap couldn't save the screenshot"
                alert.informativeText = message
                NSApp.activate()
                alert.runModal()
            }
        }
    }
}
