import AppKit
import SwiftUI
import TinycapCore

/// One window per finished recording. The master file is deleted when the window
/// closes; until then it stays on disk, so a crash or quit never loses the clip.
@MainActor
final class PreviewWindowController: NSObject, NSWindowDelegate {
    let model: PreviewModel
    private let window: NSWindow
    private let onClose: (PreviewWindowController) -> Void

    init(master: URL, onClose: @escaping (PreviewWindowController) -> Void) {
        model = PreviewModel(master: master)
        self.onClose = onClose
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Tinycap Preview"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("TinycapPreview")
        window.contentViewController = NSHostingController(
            rootView: PreviewView(model: model, onDiscard: { [weak self] in self?.discard() })
        )
        window.contentMinSize = NSSize(width: 560, height: 480)
    }

    func show() {
        if !window.setFrameUsingName("TinycapPreview") { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Asks before closing a recording that hasn't been exported.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.isExporting {
            model.cancelExport()
        }
        guard model.exportedURL == nil, model.info != nil else { return true }
        return confirmDiscard()
    }

    func windowWillClose(_ notification: Notification) {
        model.tearDown()
        try? FileManager.default.removeItem(at: model.master)
        onClose(self)
    }

    private func discard() {
        if model.exportedURL != nil || confirmDiscard() {
            window.delegate = nil
            model.tearDown()
            try? FileManager.default.removeItem(at: model.master)
            window.close()
            onClose(self)
        }
    }

    private func confirmDiscard() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Discard this recording?"
        alert.informativeText = "It hasn't been exported. Discarding deletes it."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }
}
