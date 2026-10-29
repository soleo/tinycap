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
    private var thumbnail: ScreenshotThumbnailController?

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
        // A new capture settles the previous thumbnail: it's saved, as on macOS.
        thumbnail?.saveNow()
        switch settings.afterCapture {
        case .thumbnail:
            let controller = ScreenshotThumbnailController(shot) { [weak self] finished, outcome in
                guard let self else { return }
                if self.thumbnail === finished { self.thumbnail = nil }
                if outcome == .edit { self.openEditor(finished.screenshot) }
            }
            thumbnail = controller
            controller.show()
        case .openEditor:
            openEditor(shot)
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

    private func openEditor(_ shot: Screenshot) {
        let editor = ScreenshotEditorWindowController(shot) { [weak self] closed in
            self?.editors.removeAll { $0 === closed }
        }
        editors.append(editor)
        editor.show()
    }
}
