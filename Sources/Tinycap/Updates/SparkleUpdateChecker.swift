#if SPARKLE
import AppKit
import Sparkle
import TinycapCore

/// Direct build: Sparkle 2 checks the EdDSA-signed appcast on GitHub once a day
/// (SUScheduledCheckInterval = 86400) and installs in place.
///
/// Tinycap is a menu-bar app, so scheduled checks use Sparkle's gentle reminders: Sparkle
/// stays quiet and Tinycap shows its badge, menu item and notification instead. Choosing
/// the menu item brings Sparkle's alert (Install / Remind Me Later / Skip, with release
/// notes) into focus. User-initiated checks always use Sparkle's own UI.
@MainActor
final class SparkleUpdateChecker: NSObject, UpdateChecker {
    private weak var controller: UpdateController?
    private var updaterController: SPUStandardUpdaterController!

    let handlesChoices = true

    func start(controller: UpdateController) {
        self.controller = controller
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: self
        )
        updaterController.updater.updateCheckInterval = UpdatePolicy.interval
    }

    func setAutomaticChecks(_ enabled: Bool) {
        updaterController.updater.automaticallyChecksForUpdates = enabled
    }

    func checkNow(userInitiated: Bool) {
        if userInitiated {
            NSApp.activate()
            updaterController.checkForUpdates(nil)
        } else {
            updaterController.updater.checkForUpdatesInBackground()
        }
    }

    func install(_ update: AvailableUpdate) {
        NSApp.activate()
        updaterController.checkForUpdates(nil)
    }
}

extension SparkleUpdateChecker: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated {
            let noUpdate = (error as NSError?)?.code == Int(SUError.noUpdateError.rawValue)
            controller?.checkFinished(at: updater.lastUpdateCheckDate ?? Date(), failed: error != nil && !noUpdate)
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { controller?.clear() }
    }

    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        MainActor.assumeIsolated { controller?.checkStarted() }
    }
}

extension SparkleUpdateChecker: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Scheduled checks: Tinycap shows the reminder, not Sparkle.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        let notes = update.itemDescription
        let userInitiated = state.userInitiated
        MainActor.assumeIsolated {
            guard !handleShowingUpdate else { return } // Sparkle is showing it right now
            controller?.found(AvailableUpdate(version: version, releaseNotes: notes), userInitiated: userInitiated)
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { controller?.clear() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { controller?.clear() }
    }
}
#endif
