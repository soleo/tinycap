import AppKit
import TinycapCore

/// App Store build: once a day, asks Apple's public lookup API for the store version and
/// compares it with ours. Update Now opens the App Store page; it never downloads or
/// installs, since Mac App Store apps must update through the store.
@MainActor
final class AppStoreUpdateChecker: UpdateChecker {
    private weak var controller: UpdateController?
    private var scheduler: NSBackgroundActivityScheduler?
    private var launchTask: Task<Void, Never>?

    let handlesChoices = false

    func start(controller: UpdateController) {
        self.controller = controller
    }

    func setAutomaticChecks(_ enabled: Bool) {
        scheduler?.invalidate()
        scheduler = nil
        launchTask?.cancel()
        guard enabled else { return }

        // UP-1: at launch if the last check was over 24 h ago, then every 24 h.
        if UpdatePolicy(defaults: .standard).isCheckDue(now: Date()) {
            launchTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10)) // let launch settle first
                guard !Task.isCancelled else { return }
                self?.checkNow(userInitiated: false)
            }
        }
        let scheduler = NSBackgroundActivityScheduler(identifier: "app.tinycap.Tinycap.update-check")
        scheduler.repeats = true
        scheduler.interval = UpdatePolicy.interval
        scheduler.tolerance = 60 * 60
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                self?.checkNow(userInitiated: false)
                completion(.finished)
            }
        }
        self.scheduler = scheduler
    }

    func checkNow(userInitiated: Bool) {
        guard let controller, !controller.isChecking,
              let bundleID = Bundle.main.bundleIdentifier, let url = AppStoreLookup.url(bundleID: bundleID)
        else { return }
        controller.checkStarted()
        Task {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("Tinycap", forHTTPHeaderField: "User-Agent")
            let result = try? await URLSession.shared.data(for: request)
            let update = result.flatMap { data, response in
                (response as? HTTPURLResponse)?.statusCode == 200 ? AppStoreLookup.parse(data) : nil
            }
            controller.checkFinished(at: Date(), failed: result == nil)

            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            if let update, let new = AppVersion(update.version), let installed = AppVersion(current), new > installed {
                controller.found(update, userInitiated: userInitiated)
            } else {
                controller.clear()
                if userInitiated { Self.showUpToDate(failed: result == nil) }
            }
        }
    }

    func install(_ update: AvailableUpdate) {
        guard let url = update.storeURL else { return }
        NSWorkspace.shared.open(url)
    }

    private static func showUpToDate(failed: Bool) {
        let alert = NSAlert()
        alert.messageText = failed ? "Tinycap couldn't check for updates" : "Tinycap is up to date"
        alert.informativeText = failed ? "Check your internet connection and try again." : "No newer version is on the App Store."
        NSApp.activate()
        alert.runModal()
    }
}
