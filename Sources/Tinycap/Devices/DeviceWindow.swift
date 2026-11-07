import AppKit
import AVFoundation
import Observation
import SwiftUI
import TinycapCore

/// State behind one device window.
@MainActor
@Observable
final class DeviceWindowModel {
    let name: String
    /// The picture's pixel size; nil until the device sends its first frame.
    var pixelSize: CGSize?
    /// Set while this device is being recorded.
    var recordingSince: Date?
    /// The picture's size when recording started (DV-7).
    var recordingSize: CGSize?
    /// Starting or finishing a recording, or taking a screenshot.
    var isBusy = false
    /// Another recording is running, so this one can't start.
    var otherRecording = false
    var soundOn = UserDefaults.standard.bool(forKey: PreferenceKey.deviceSound) {
        didSet { UserDefaults.standard.set(soundOn, forKey: PreferenceKey.deviceSound) }
    }

    @ObservationIgnored var onRecord: () -> Void = {}
    @ObservationIgnored var onStop: () -> Void = {}
    @ObservationIgnored var onScreenshot: () -> Void = {}

    init(name: String) {
        self.name = name
    }

    var isRecording: Bool { recordingSince != nil }

    /// The device turned since recording started: the recording keeps its first
    /// orientation and letterboxes the new one (DV-7).
    var isRotated: Bool {
        guard isRecording, let start = recordingSize, let now = pixelSize else { return false }
        return (start.width > start.height) != (now.width > now.height)
    }
}

/// One window per connected device: the live screen, Record and Stop, Screenshot and
/// the Sound switch (DV-2).
@MainActor
final class DeviceWindowController: NSObject, NSWindowDelegate {
    let session: DeviceSession
    let model: DeviceWindowModel
    private let window: NSWindow
    private let onClose: (DeviceWindowController) -> Void
    private var sizedFor: CGSize?

    init(session: DeviceSession, model: DeviceWindowModel, onClose: @escaping (DeviceWindowController) -> Void) {
        self.session = session
        self.model = model
        self.onClose = onClose
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = session.name
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: DeviceView(model: model, session: session.session))
        window.contentMinSize = NSSize(width: 300, height: 360)
    }

    func show() {
        if window.frame.origin == .zero { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
    }

    /// Sizes the window to the device's shape the first time and when it rotates.
    func fit(to pixelSize: CGSize) {
        let landscape = pixelSize.width > pixelSize.height
        if let sizedFor, (sizedFor.width > sizedFor.height) == landscape { return }
        sizedFor = pixelSize
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let barHeight: CGFloat = 52
        let aspect = pixelSize.width / pixelSize.height
        var height = min(screen.height * 0.8, 760) - barHeight
        var width = height * aspect
        if width > screen.width * 0.8 {
            width = screen.width * 0.8
            height = width / aspect
        }
        let old = window.frame
        window.setContentSize(NSSize(width: max(width, 300), height: height + barHeight))
        // Keep the top edge where it was.
        window.setFrameTopLeftPoint(NSPoint(x: old.minX, y: old.maxY))
    }

    func windowWillClose(_ notification: Notification) {
        onClose(self)
    }
}

struct DeviceView: View {
    @Bindable var model: DeviceWindowModel
    let session: AVCaptureSession

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                CapturePreview(session: session)
                if model.pixelSize == nil {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for \(model.name)…")
                        Text("Unlock it, and tap Trust on it if it asks.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding()
                }
                if model.isRotated {
                    VStack {
                        Spacer()
                        Label("Rotated: the recording keeps its first orientation, with black bars.",
                              systemImage: "rotate.right")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(10)
                    }
                }
            }
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Toggle("Sound", isOn: $model.soundOn)
                .toggleStyle(.checkbox)
                .disabled(model.isRecording || model.isBusy)
                .help("Record the app's own sounds. While Tinycap is showing the device, its sound plays here instead of on the device.")
            Spacer()
            Button {
                model.onScreenshot()
            } label: {
                Image(systemName: "camera")
            }
            .help("Screenshot")
            .accessibilityLabel("Screenshot")
            .disabled(model.pixelSize == nil || model.isBusy)
            if let since = model.recordingSince {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(ElapsedTime.format(context.date.timeIntervalSince(since)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button {
                    model.onStop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button {
                    model.onRecord()
                } label: {
                    Label("Record", systemImage: "record.circle")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.pixelSize == nil || model.isBusy || model.otherRecording)
                .help(model.otherRecording ? "Another recording is running" : "Record the device's screen")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }
}

/// The live picture, letterboxed to the device's shape.
private struct CapturePreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
