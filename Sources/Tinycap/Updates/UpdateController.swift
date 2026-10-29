import AppKit
import Observation
import TinycapCore
import UserNotifications

/// One per build, chosen at compile time (PRD Technical → Updater):
/// Sparkle in the direct build. The App Store build has none; the App Store updates it.
@MainActor
protocol UpdateChecker: AnyObject {
    /// Starts the daily schedule. Found updates are reported to `controller.found(_:)`.
    func start(controller: UpdateController)
    func checkNow(userInitiated: Bool)
    func setAutomaticChecks(_ enabled: Bool)
    /// Update Now: install in place.
    func install(_ update: AvailableUpdate)
    /// The checker shows its own window with the three choices (Sparkle does).
    var handlesChoices: Bool { get }
}

/// Holds the update state the menu bar, Settings and notifications read, and applies the
/// reminder rules: gentle (UP-2), never while busy (UP-3), the three actions (UP-4).
@MainActor
@Observable
final class UpdateController: NSObject {
    static let shared = UpdateController()

    /// A newer version the user should hear about, or nil.
    private(set) var available: AvailableUpdate?
    private(set) var lastCheck: Date?
    private(set) var isChecking = false
    private(set) var lastCheckFailed = false

    var checksEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: UpdatePolicy.Key.checksEnabled) }
        set {
            UserDefaults.standard.set(newValue, forKey: UpdatePolicy.Key.checksEnabled)
            checker?.setAutomaticChecks(newValue)
        }
    }

    /// Called whenever `available` changes, so the menu-bar icon can redraw.
    @ObservationIgnored var onChange: (() -> Void)?
    /// True while selecting, recording or exporting (UP-3). Set by the app delegate.
    @ObservationIgnored var isBusy: () -> Bool = { false }

    private var checker: UpdateChecker?

    /// False in builds without an updater (a direct build made without a Sparkle key).
    var isAvailable: Bool { checker != nil }
    @ObservationIgnored private var pending: AvailableUpdate?
    @ObservationIgnored private var idleTimer: Timer?

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start(with checker: UpdateChecker) {
        UserDefaults.standard.register(defaults: [UpdatePolicy.Key.checksEnabled: true])
        lastCheck = UpdatePolicy(defaults: .standard).lastCheck
        self.checker = checker
        UNUserNotificationCenter.current().delegate = self
        checker.start(controller: self)
        checker.setAutomaticChecks(checksEnabled)
    }

    // MARK: - Reports from the checker

    func checkStarted() {
        isChecking = true
    }

    func checkFinished(at date: Date, failed: Bool) {
        isChecking = false
        lastCheckFailed = failed
        lastCheck = date
        var policy = UpdatePolicy(defaults: .standard)
        policy.lastCheck = date
        policy.save(to: .standard)
    }

    /// A newer version was found by a scheduled check (or a manual one, `userInitiated`).
    func found(_ update: AvailableUpdate, userInitiated: Bool) {
        let policy = UpdatePolicy(defaults: .standard)
        // A manual check always shows what it found; a scheduled one respects skip and tomorrow.
        guard userInitiated || policy.shouldRemind(found: update.version, current: currentVersion, now: Date()) else { return }
        pending = update
        deliverWhenIdle()
    }

    /// The checker found nothing, or the user acted on the update in the checker's own UI.
    func clear() {
        pending = nil
        setAvailable(nil)
    }

    // MARK: - Reminders

    /// UP-3: hold everything while the user is selecting, recording or exporting.
    private func deliverWhenIdle() {
        idleTimer?.invalidate()
        guard isBusy() else {
            deliverPending()
            return
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isBusy() else { return }
                self.idleTimer?.invalidate()
                self.idleTimer = nil
                self.deliverPending()
            }
        }
    }

    private func deliverPending() {
        guard let update = pending else { return }
        pending = nil
        setAvailable(update)

        var policy = UpdatePolicy(defaults: .standard)
        guard policy.shouldNotify(version: update.version) else { return }
        policy.markNotified(update.version)
        policy.save(to: .standard)
        postNotification(for: update)
    }

    private func setAvailable(_ update: AvailableUpdate?) {
        guard available != update else { return }
        available = update
        onChange?()
    }

    private func postNotification(for update: AvailableUpdate) {
        let content = UNMutableNotificationContent()
        content.title = "Tinycap \(update.version) is available"
        content.body = "Choose Update to Tinycap \(update.version) in the menu bar when you're ready."
        let request = UNNotificationRequest(identifier: "update-\(update.version)", content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            // Provisional: delivered quietly to Notification Center, no permission prompt.
            guard (try? await center.requestAuthorization(options: [.alert, .provisional])) == true else { return }
            try? await center.add(request)
        }
    }

    // MARK: - Actions (UP-4)

    /// The menu item and the notification: show the choices for the available update.
    func showUpdate() {
        guard let update = available, let checker else { return }
        if checker.handlesChoices {
            checker.install(update) // Sparkle brings its alert (Install / Remind Me Later / Skip) into focus
        } else {
            presentChoices(for: update)
        }
    }

    func checkNow() {
        checker?.checkNow(userInitiated: true)
    }

    private func presentChoices(for update: AvailableUpdate) {
        let alert = NSAlert()
        alert.messageText = "Tinycap \(update.version) is available"
        alert.informativeText = "You have \(currentVersion)."
        if let notes = update.releaseNotes, !notes.isEmpty { // UP-7
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 140))
            text.string = notes
            text.isEditable = false
            text.drawsBackground = false
            let scroll = NSScrollView(frame: text.frame)
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            alert.accessoryView = scroll
        }
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Remind Me Tomorrow")
        alert.addButton(withTitle: "Skip This Version")
        NSApp.activate()

        var policy = UpdatePolicy(defaults: .standard)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            checker?.install(update)
        case .alertSecondButtonReturn:
            policy.remindTomorrow(now: Date())
            policy.save(to: .standard)
            clear()
        default:
            policy.skip(update.version)
            policy.save(to: .standard)
            clear()
        }
    }
}

extension UpdateController: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { UpdateController.shared.showUpdate() }
    }
}
