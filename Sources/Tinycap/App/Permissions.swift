import AppKit
import CoreGraphics
import ScreenCaptureKit

enum Permissions {
    static var hasScreenRecordingAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// Adds Tinycap to the Screen Recording list in System Settings (prompts the first time).
    static func requestScreenRecordingAccess() {
        _ = CGRequestScreenCaptureAccess()
    }

    /// macOS often reports a new grant only to a fresh process, so onboarding offers this.
    @MainActor
    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    /// True when ScreenCaptureKit refused because Screen Recording isn't allowed.
    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.userDeclined.rawValue
    }

    @MainActor
    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
