import AppKit
import SwiftUI
import TinycapCore

/// Shown when Tinycap is opened again while running (e.g. from Finder or `open`), so
/// the app is reachable even when its menu-bar icon is hidden behind the notch.
@MainActor
final class ControlWindowController {
    private var window: NSWindow?
    private let coordinator: RecordingCoordinator
    private let openSettings: () -> Void

    init(coordinator: RecordingCoordinator, openSettings: @escaping () -> Void) {
        self.coordinator = coordinator
        self.openSettings = openSettings
    }

    func show() {
        if window == nil {
            let view = ControlView(
                record: { [weak self] mode in
                    self?.window?.orderOut(nil)
                    self?.coordinator.begin(mode)
                },
                openSettings: { [weak self] in
                    self?.window?.orderOut(nil)
                    self?.openSettings()
                }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Tinycap"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct ControlView: View {
    let record: (CaptureMode) -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tinycap is running").font(.headline)
                    Text("It lives in the menu bar. If you can't see its icon, use these buttons or the shortcuts.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                button(.recordArea, mode: .area)
                button(.recordWindow, mode: .window)
                button(.recordScreen, mode: .screen)
            }
            HStack {
                Text("Stop: \(ShortcutManager.shared.combo(for: .stop)?.displayString ?? "click the menu-bar timer")")
                    .monospaced().font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Settings…", action: openSettings)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func button(_ action: ShortcutAction, mode: CaptureMode) -> some View {
        Button {
            record(mode)
        } label: {
            VStack(spacing: 2) {
                Text(action.title)
                Text(ShortcutManager.shared.combo(for: action)?.displayString ?? " ")
                    .font(.caption).monospaced().foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
    }
}
