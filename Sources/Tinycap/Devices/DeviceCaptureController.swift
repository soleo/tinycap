import AppKit
import AVFoundation
import CoreMediaIO
import os
import TinycapCore

private let log = Logger(subsystem: "app.tinycap.Tinycap", category: "device")

/// A connected iPhone or iPad, as the menu lists it.
struct ConnectedDevice: Equatable {
    let id: String
    let name: String
}

/// iPhone and iPad capture (DV-1 to DV-5): keeps the list of devices connected by cable,
/// opens a window per device, and takes device screenshots.
@MainActor
final class DeviceCaptureController {
    private(set) var devices: [ConnectedDevice] = []
    private let recording: RecordingCoordinator
    private let screenshots: ScreenshotCoordinator
    private var windows: [DeviceWindowController] = []
    private var observers: [NSObjectProtocol] = []
    /// A screenshot without a window open runs its own short session.
    private var takingScreenshot = false

    init(recording: RecordingCoordinator, screenshots: ScreenshotCoordinator) {
        self.recording = recording
        self.screenshots = screenshots
        recording.observeState { [weak self] _ in self?.updateRecordingState() }
    }

    /// Lets connected devices show up as capture devices and starts following plugs
    /// and unplugs. Asks for nothing: camera access is asked on first use.
    func start() {
        Self.allowScreenCaptureDevices()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    /// macOS lists iPhones and iPads as capture devices only after an app opts in.
    private static func allowScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        let status = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                                               UInt32(MemoryLayout<UInt32>.size), &allow)
        if status != 0 { log.error("can't allow screen capture devices: \(status, privacy: .public)") }
    }

    private static func captureDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified).devices
    }

    private func refresh() {
        let found = Self.captureDevices().map { ConnectedDevice(id: $0.uniqueID, name: $0.localizedName) }
        if found != devices { log.notice("devices: \(found.map(\.name), privacy: .public)") }
        devices = found
        // An unplugged device: keep what was recorded, then close its window.
        for window in windows where !found.contains(where: { $0.id == window.session.deviceID }) {
            if recording.recordingDeviceID == window.session.deviceID { recording.stop() }
            window.close()
        }
    }

    // MARK: - Window (DV-2)

    /// Record <device>: opens the device's window, where recording starts.
    func open(_ device: ConnectedDevice) {
        if let window = windows.first(where: { $0.session.deviceID == device.id }) {
            window.show()
            return
        }
        Task { await openWindow(for: device) }
    }

    private func openWindow(for device: ConnectedDevice) async {
        guard await ensureCameraAccess(), !windows.contains(where: { $0.session.deviceID == device.id }) else { return }
        guard let session = makeSession(for: device, onSize: { [weak self] size in
            self?.sizeChanged(size, deviceID: device.id)
        }) else { return }
        let model = DeviceWindowModel(name: device.name)
        let window = DeviceWindowController(session: session, model: model) { [weak self] closed in
            self?.windowClosed(closed)
        }
        model.onRecord = { [weak self, weak window] in
            guard let self, let window else { return }
            self.recording.startRecording(device: window.session, sound: window.model.soundOn)
        }
        model.onStop = { [weak self] in self?.recording.stop() }
        model.onScreenshot = { [weak self, weak window] in
            guard let self, let window else { return }
            Task { await self.screenshot(from: window.session, name: device.name, model: window.model) }
        }
        windows.append(window)
        updateRecordingState()
        window.show()
        session.startRunning()
    }

    private func windowClosed(_ window: DeviceWindowController) {
        if recording.recordingDeviceID == window.session.deviceID { recording.stop() }
        window.session.stopRunning()
        windows.removeAll { $0 === window }
    }

    private func sizeChanged(_ size: CGSize, deviceID: String) {
        guard let window = windows.first(where: { $0.session.deviceID == deviceID }) else { return }
        window.model.pixelSize = size
        window.fit(to: size)
    }

    private func updateRecordingState() {
        let state = recording.state
        let recordingID = recording.recordingDeviceID
        for window in windows {
            let model = window.model
            let isThis = recordingID == window.session.deviceID
            if case .recording(let since) = state, isThis {
                if model.recordingSince == nil { model.recordingSize = model.pixelSize }
                model.recordingSince = since
            } else {
                model.recordingSince = nil
                model.recordingSize = nil
            }
            model.isBusy = (state == .selecting || state == .saving) && (isThis || recordingID == nil)
            model.otherRecording = state != .idle && !isThis
        }
    }

    // MARK: - Screenshots (DV-4)

    /// Screenshot <device>: from the open window's picture, or from a short session.
    func screenshot(_ device: ConnectedDevice) {
        if let window = windows.first(where: { $0.session.deviceID == device.id }) {
            Task { await screenshot(from: window.session, name: device.name, model: window.model) }
            return
        }
        guard !takingScreenshot else { return }
        takingScreenshot = true
        Task {
            defer { takingScreenshot = false }
            guard await ensureCameraAccess(), let session = makeSession(for: device, onSize: { _ in }) else { return }
            session.startRunning()
            await screenshot(from: session, name: device.name, model: nil)
            session.stopRunning()
        }
    }

    private func screenshot(from session: DeviceSession, name: String, model: DeviceWindowModel?) async {
        model?.isBusy = true
        defer { model?.isBusy = false }
        guard let image = await session.snapshot() else {
            present(DeviceCaptureError.noPicture, title: "Tinycap couldn't take the screenshot")
            return
        }
        let size = CGSize(width: image.width, height: image.height)
        NSSound(named: "Tink")?.play()
        screenshots.openEditor(Screenshot(image: image, pixelsPerPoint: DeviceKind.pointScale(for: size),
                                          source: .device(named: name)))
    }

    // MARK: - Helpers

    private func makeSession(for device: ConnectedDevice, onSize: @escaping @MainActor @Sendable (CGSize) -> Void) -> DeviceSession? {
        guard let captureDevice = Self.captureDevices().first(where: { $0.uniqueID == device.id }) else {
            present(DeviceCaptureError.cannotOpen(device.name), title: "\(device.name) isn't connected")
            refresh()
            return nil
        }
        do {
            return try DeviceSession(device: captureDevice, onSizeChange: onSize)
        } catch {
            present(error, title: "Tinycap couldn't open \(device.name)")
            return nil
        }
    }

    /// Connected devices are cameras to macOS, so capturing one needs camera access.
    private func ensureCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            NSApp.activate()
            if await AVCaptureDevice.requestAccess(for: .video) { return true }
        default:
            break
        }
        let alert = NSAlert()
        alert.messageText = "Tinycap can't see connected iPhones and iPads"
        alert.informativeText = "macOS lists them as cameras. Allow Tinycap in System Settings → Privacy & Security → Camera, then try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    private func present(_ error: Error, title: String) {
        Diagnostics.record(error, context: title)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate()
        alert.runModal()
    }
}
