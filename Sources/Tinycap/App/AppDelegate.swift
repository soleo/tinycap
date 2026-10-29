import AppKit
import TinycapCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: RecordingCoordinator!
    private let screenshots = ScreenshotCoordinator()
    private var statusItem: StatusItemController!
    private var controlWindow: ControlWindowController!
    private let settingsWindow = SettingsWindowController()
    private let onboarding = OnboardingWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        PreferenceKey.registerDefaults(in: .standard)

        MainMenu.install()
        coordinator = RecordingCoordinator(onNeedsPermission: { [weak self] in self?.onboarding.show() })
        coordinator.canStart = { [weak self] in !(self?.screenshots.isSelecting ?? false) }
        screenshots.canStart = { [weak self] in self?.coordinator.state == .idle }
        screenshots.onNeedsPermission = { [weak self] in self?.onboarding.show() }
        statusItem = StatusItemController(
            coordinator: coordinator,
            screenshots: screenshots,
            openSettings: { [weak self] in self?.settingsWindow.show() }
        )
        controlWindow = ControlWindowController(
            coordinator: coordinator,
            openSettings: { [weak self] in self?.settingsWindow.show() }
        )
        registerHotKeys()
        startUpdates()

        if !Permissions.hasScreenRecordingAccess {
            onboarding.show()
        } else {
            coordinator.offerUnsavedRecordings()
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

    private func startUpdates() {
        let updates = UpdateController.shared
        updates.isBusy = { [weak self] in
            guard let self else { return false }
            return self.coordinator.isBusy || self.screenshots.isSelecting
        }
        #if SPARKLE
        updates.start(with: SparkleUpdateChecker())
        #elseif APP_STORE
        updates.start(with: AppStoreUpdateChecker())
        #endif
        // Otherwise (a direct build without a Sparkle key) there is no updater.
    }

    private func registerHotKeys() {
        let manager = ShortcutManager.shared
        manager.handler = { [weak self] action in
            guard let self else { return }
            switch action {
            case .screenshotArea: self.screenshots.begin(.area)
            case .recordArea: self.coordinator.begin(.area)
            case .recordWindow: self.coordinator.begin(.window)
            case .recordScreen: self.coordinator.begin(.screen)
            case .stop: self.coordinator.stop()
            }
        }
        manager.reload()
    }
}
