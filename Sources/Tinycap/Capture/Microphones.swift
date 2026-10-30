import AppKit
import AVFoundation
import TinycapCore

/// Input devices and Microphone permission (AU-2, AU-4).
enum Microphones {
    /// Every connected input: built-in, USB, audio interfaces, Bluetooth and aggregate
    /// devices. IDs are what ScreenCaptureKit takes as `microphoneCaptureDeviceID`.
    static func available() -> [MicrophoneDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices
            .map { MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Name of the input macOS records from when no device is chosen.
    static var systemDefaultName: String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Asks the first time; afterwards returns the saved answer without asking.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    @MainActor
    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    /// Turns the microphone on: asks for permission, and if it's refused explains how to
    /// allow it. Returns whether the microphone can be used.
    @MainActor
    static func enable() async -> Bool {
        if await requestAccess() { return true }
        let alert = NSAlert()
        alert.messageText = "Tinycap can't use the microphone"
        alert.informativeText = "Allow Tinycap in System Settings → Privacy & Security → Microphone, then turn the microphone on again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { openSettings() }
        return false
    }

    /// Turns microphone recording on or off from the menu, the area bar or Settings.
    /// Turning it on asks for permission first and stays off if that's refused.
    /// Returns whether the microphone ends up on.
    @MainActor
    @discardableResult
    static func setRecording(_ on: Bool) async -> Bool {
        let allowed = on ? await enable() : false
        UserDefaults.standard.set(allowed, forKey: PreferenceKey.recordsMicrophone)
        return allowed
    }

    /// Records from `id`, or the system input when nil, and turns the microphone on.
    @MainActor
    @discardableResult
    static func choose(_ id: String?) async -> Bool {
        UserDefaults.standard.set(id ?? "", forKey: PreferenceKey.microphoneID)
        return await setRecording(true)
    }

    /// "System Default (MacBook Pro Microphone)", for pickers.
    static var systemDefaultTitle: String {
        systemDefaultName.map { "System Default (\($0))" } ?? "System Default"
    }
}
