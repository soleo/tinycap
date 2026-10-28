import AppKit
import TinycapCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: RecordingCoordinator!
    private var statusItem: StatusItemController!
    private var controlWindow: ControlWindowController!
    private let hotKeys = HotKeyCenter()
    private let settingsWindow = SettingsWindowController()
    private let onboarding = OnboardingWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        PreferenceKey.registerDefaults(in: .standard)

        coordinator = RecordingCoordinator(onNeedsPermission: { [weak self] in self?.onboarding.show() })
        statusItem = StatusItemController(
            coordinator: coordinator,
            openSettings: { [weak self] in self?.settingsWindow.show() }
        )
        controlWindow = ControlWindowController(
            coordinator: coordinator,
            openSettings: { [weak self] in self?.settingsWindow.show() }
        )
        registerHotKeys()

        if !Permissions.hasScreenRecordingAccess {
            onboarding.show()
        }
    }

    /// Opening Tinycap again while it runs shows a small window instead of nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controlWindow.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        SaveLocation.shared.stopAccessing()
    }

    private func registerHotKeys() {
        for shortcut in Shortcut.allCases {
            hotKeys.register(shortcut.hotKey) { [weak self] in
                guard let self else { return }
                switch shortcut {
                case .recordArea: self.coordinator.begin(.area)
                case .recordWindow: self.coordinator.begin(.window)
                case .recordScreen: self.coordinator.begin(.screen)
                case .stop: self.coordinator.stop()
                }
            }
        }
    }
}
