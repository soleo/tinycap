import AppKit
import SwiftUI
import TinycapCore

/// Click, then press the new shortcut. Esc cancels; Delete clears the shortcut.
struct ShortcutRecorder: View {
    let action: ShortcutAction
    var manager = ShortcutManager.shared

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 6) {
                if manager.unavailable.contains(action) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Another app is using this shortcut. Pick a different one.")
                        .accessibilityLabel("Unavailable: another app uses this shortcut")
                }
                Button(action: toggle) {
                    Text(label)
                        .monospaced(!isRecording && manager.combo(for: action) != nil)
                        .frame(minWidth: 110)
                }
                .accessibilityLabel("\(action.title) shortcut")
                .accessibilityValue(manager.combo(for: action)?.displayString ?? "None")
                .accessibilityHint("Activate, then press the new key combination")
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stop)
    }

    private var label: String {
        if isRecording { return "Press shortcut…" }
        return manager.combo(for: action)?.displayString ?? "None"
    }

    private func toggle() {
        isRecording ? stop() : start()
    }

    private func start() {
        message = nil
        isRecording = true
        manager.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording {
            isRecording = false
            manager.resume()
        }
    }

    private func handle(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: // Esc
            stop()
            return
        case 51, 117: // Delete, Forward Delete
            manager.set(nil, for: action)
            stop()
            return
        default:
            break
        }
        let combo = KeyCombo(event: event)
        guard combo.isValidGlobalShortcut else {
            message = "Include ⌘, ⌃ or ⌥"
            return
        }
        if let other = manager.store.conflict(for: combo, excluding: action) {
            message = "Already used by \(other.title)"
            return
        }
        message = nil
        stop()
        manager.set(combo, for: action)
    }
}
