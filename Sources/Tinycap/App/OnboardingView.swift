import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let view = OnboardingView(onDone: { [weak self] in self?.close() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Welcome to Tinycap"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.close()
    }
}

/// First-run sheet: explains the Screen Recording permission and detects the grant
/// without a restart where macOS allows it.
struct OnboardingView: View {
    let onDone: () -> Void
    @State private var granted = Permissions.hasScreenRecordingAccess

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            Text("Welcome to Tinycap")
                .font(.title2.bold())

            Text("Tinycap records a window, a screen or an area to a file on this Mac. Nothing is uploaded.\n\nTo record, macOS needs you to allow Screen Recording for Tinycap.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if granted {
                Label("Screen Recording is allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Start Using Tinycap", action: onDone)
                    .keyboardShortcut(.defaultAction)
                Text("Click the Tinycap icon in the menu bar to record.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button("Open System Settings") {
                    Permissions.requestScreenRecordingAccess()
                    Permissions.openScreenRecordingSettings()
                }
                .keyboardShortcut(.defaultAction)
                Text("Turn on Tinycap under Privacy & Security → Screen & System Audio Recording.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Text("Already turned on? macOS may only notice after Tinycap restarts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Quit & Reopen Tinycap") { Permissions.relaunch() }
            }
        }
        .padding(28)
        .frame(width: 420)
        .task {
            while !Task.isCancelled && !granted {
                try? await Task.sleep(for: .seconds(1))
                granted = Permissions.hasScreenRecordingAccess
            }
        }
    }
}
