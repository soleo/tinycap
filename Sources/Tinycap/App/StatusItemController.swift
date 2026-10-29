import AppKit
import TinycapCore

/// Owns the menu-bar item. Idle: shows the menu. Recording: shows a red dot and the
/// elapsed time, and a click stops the recording (MB-3).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let coordinator: RecordingCoordinator
    private let screenshots: ScreenshotCoordinator
    private let openSettings: () -> Void
    private let menu = NSMenu()
    private var timerTask: Task<Void, Never>?

    init(coordinator: RecordingCoordinator, screenshots: ScreenshotCoordinator, openSettings: @escaping () -> Void) {
        self.coordinator = coordinator
        self.screenshots = screenshots
        self.openSettings = openSettings
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        coordinator.onStateChange = { [weak self] state in self?.apply(state) }
        UpdateController.shared.onChange = { [weak self] in
            guard let self else { return }
            self.apply(self.coordinator.state)
        }
        apply(coordinator.state)
    }

    // MARK: - State

    private func apply(_ state: RecordingCoordinator.State) {
        timerTask?.cancel()
        timerTask = nil
        guard let button = statusItem.button else { return }

        switch state {
        case .idle, .selecting:
            statusItem.menu = menu
            button.action = nil
            let update = UpdateController.shared.available
            button.image = update == nil ? MenuBarIcon.idle : MenuBarIcon.idleWithUpdate
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = update.map { "Tinycap — version \($0.version) is available" } ?? "Tinycap"
            button.setAccessibilityLabel(update == nil ? "Tinycap" : "Tinycap, update available")

        case .recording(let startedAt):
            statusItem.menu = nil
            button.target = self
            button.action = #selector(stopClicked)
            button.image = MenuBarIcon.recording
            button.imagePosition = .imageLeading
            let stopKey = ShortcutManager.shared.combo(for: .stop).map { " (\($0.displayString))" } ?? ""
            button.toolTip = "Click to stop recording\(stopKey)"
            updateElapsed(since: startedAt)
            timerTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    self?.updateElapsed(since: startedAt)
                }
            }

        case .saving: // finishing the master file; the preview opens next
            statusItem.menu = nil
            button.action = nil
            button.image = MenuBarIcon.idle
            button.imagePosition = .imageLeading
            button.attributedTitle = Self.timerTitle("Finishing…")
            button.setAccessibilityLabel("Tinycap is finishing the recording")
        }
    }

    private func updateElapsed(since start: Date) {
        let text = ElapsedTime.format(Date().timeIntervalSince(start))
        statusItem.button?.attributedTitle = Self.timerTitle(text)
        statusItem.button?.setAccessibilityLabel("Recording, \(text). Click to stop.")
    }

    private static func timerTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(string: " " + text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        ])
    }

    @objc private func stopClicked() {
        coordinator.stop()
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let busy = coordinator.state != .idle

        if let update = UpdateController.shared.available {
            let item = NSMenuItem(title: "Update to Tinycap \(update.version)…", action: #selector(showUpdate), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
            menu.addItem(item)
            menu.addItem(.separator())
        }

        // Screenshots first (SS-1): Area / Window / Screen.
        for (title, mode) in [("Screenshot Area", CaptureMode.area), ("Screenshot Window", .window), ("Screenshot Screen", .screen)] {
            let item = NSMenuItem(title: title, action: #selector(screenshot(_:)), keyEquivalent: "")
            if mode == .area, let combo = ShortcutManager.shared.combo(for: .screenshotArea) {
                if let key = combo.menuKeyEquivalent {
                    item.keyEquivalent = key
                    item.keyEquivalentModifierMask = combo.eventModifierFlags
                } else {
                    item.toolTip = combo.displayString
                }
            }
            item.representedObject = mode.rawValue
            item.target = self
            item.isEnabled = !busy
            menu.addItem(item)
        }
        menu.addItem(.separator())

        for (action, mode) in [(ShortcutAction.recordWindow, CaptureMode.window), (.recordScreen, .screen), (.recordArea, .area)] {
            let combo = ShortcutManager.shared.combo(for: action)
            let item = NSMenuItem(title: action.title, action: #selector(record(_:)), keyEquivalent: combo?.menuKeyEquivalent ?? "")
            if let combo, combo.menuKeyEquivalent != nil {
                item.keyEquivalentModifierMask = combo.eventModifierFlags
            } else if let combo {
                item.toolTip = combo.displayString
            }
            item.representedObject = mode.rawValue
            item.target = self
            item.isEnabled = !busy
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu()
        menu.addItem(recentItem)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let bug = NSMenuItem(title: "Report a Bug…", action: #selector(reportBug), keyEquivalent: "")
        bug.target = self
        menu.addItem(bug)
        let feedback = NSMenuItem(title: "Send Feedback…", action: #selector(sendFeedback), keyEquivalent: "")
        feedback.target = self
        menu.addItem(feedback)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Tinycap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func recentMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let recents = RecentRecordings.urls
        if recents.isEmpty {
            let empty = NSMenuItem(title: "No Recordings Yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        for url in recents {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = self
            item.image = NSWorkspace.shared.icon(forFile: url.path)
            item.image?.size = NSSize(width: 16, height: 16)
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let folder = NSMenuItem(title: "Show Save Folder", action: #selector(showSaveFolder), keyEquivalent: "")
        folder.target = self
        submenu.addItem(folder)
        if !recents.isEmpty {
            let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecents), keyEquivalent: "")
            clear.target = self
            submenu.addItem(clear)
        }
        return submenu
    }

    @objc private func record(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = CaptureMode(rawValue: raw) else { return }
        coordinator.begin(mode)
    }

    @objc private func screenshot(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = CaptureMode(rawValue: raw) else { return }
        screenshots.begin(mode)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func showSaveFolder() {
        if let url = try? SaveLocation.shared.preparedFolder() {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func clearRecents() {
        RecentRecordings.clear()
    }

    @objc private func showUpdate() {
        UpdateController.shared.showUpdate()
    }

    @objc private func reportBug() {
        Diagnostics.open(.bug)
    }

    @objc private func sendFeedback() {
        Diagnostics.open(.feature)
    }

    @objc private func showSettings() {
        openSettings()
    }
}
