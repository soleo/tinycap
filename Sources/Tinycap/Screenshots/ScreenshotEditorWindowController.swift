import AppKit
import SwiftUI
import TinycapCore

/// One window per screenshot. As the window's delegate it sits in the responder chain, so
/// the Edit and File menu commands (⌘C, ⌘S, ⌘Z, ⇧⌘Z, Delete) reach the editor. While a
/// text label is being typed, the text field handles them first.
@MainActor
final class ScreenshotEditorWindowController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    let model: ScreenshotEditorModel
    private let window: NSWindow
    private let onClose: (ScreenshotEditorWindowController) -> Void

    init(_ shot: Screenshot, onClose: @escaping (ScreenshotEditorWindowController) -> Void) {
        model = ScreenshotEditorModel(shot)
        self.onClose = onClose
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Tinycap Screenshot"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: ScreenshotEditorView(model: model))
        window.setContentSize(Self.initialSize(for: shot))
        window.center()
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// The image at its point size plus the bars, capped to most of the screen.
    private static func initialSize(for shot: Screenshot) -> NSSize {
        let points = NSSize(width: Double(shot.image.width) / shot.pixelsPerPoint, height: Double(shot.image.height) / shot.pixelsPerPoint)
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        return NSSize(width: min(max(points.width + 32, 720), screen.width * 0.85),
                      height: min(max(points.height + 32 + 96, 460), screen.height * 0.85))
    }

    // MARK: - NSWindowDelegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        model.undoManager
    }

    func windowWillClose(_ notification: Notification) {
        onClose(self)
    }

    // MARK: - Menu commands

    @objc func copy(_ sender: Any?) {
        model.copyToPasteboard()
    }

    @objc func saveDocument(_ sender: Any?) {
        model.save()
    }

    @objc func undo(_ sender: Any?) {
        model.undoManager.undo()
    }

    @objc func redo(_ sender: Any?) {
        model.undoManager.redo()
    }

    @objc func delete(_ sender: Any?) {
        model.deleteSelected()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            item.title = model.undoManager.canUndo ? "Undo \(model.undoManager.undoActionName)" : "Undo"
            return model.undoManager.canUndo
        case #selector(redo(_:)):
            item.title = model.undoManager.canRedo ? "Redo \(model.undoManager.redoActionName)" : "Redo"
            return model.undoManager.canRedo
        case #selector(delete(_:)):
            return model.selectedID != nil
        default:
            return true
        }
    }
}
