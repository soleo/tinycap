import AppKit
import ServiceManagement
import SwiftUI
import TinycapCore

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Tinycap Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            RecordingSettingsView()
                .tabItem { Label("Recording", systemImage: "record.circle") }
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var folderPath = SaveLocation.shared.folderURL.path
    @State private var isCustomFolder = SaveLocation.shared.isCustom
    @AppStorage(PreferenceKey.filenamePattern) private var filenamePattern = FilenamePattern.defaultPattern

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }

            LabeledContent("Save recordings to") {
                HStack {
                    Text((folderPath as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Choose…") {
                        SaveLocation.shared.chooseFolder()
                        refreshFolder()
                    }
                    if isCustomFolder {
                        Button("Reset") {
                            SaveLocation.shared.resetToDefault()
                            refreshFolder()
                        }
                    }
                }
            }

            LabeledContent("File name") {
                VStack(alignment: .trailing, spacing: 4) {
                    TextField("File name", text: $filenamePattern, prompt: Text(FilenamePattern.defaultPattern))
                        .labelsHidden()
                    Text("Example: \(FilenamePattern(filenamePattern).baseName(for: Date())).mp4")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Shortcuts") {
                ForEach(Shortcut.allCases, id: \.self) { shortcut in
                    LabeledContent(shortcut.title) {
                        Text(shortcut.hotKey.displayString).monospaced()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func refreshFolder() {
        folderPath = SaveLocation.shared.folderURL.path
        isCustomFolder = SaveLocation.shared.isCustom
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            NSAlert(error: error).runModal()
        }
    }
}

private struct RecordingSettingsView: View {
    @AppStorage(PreferenceKey.frameRate) private var frameRate = FrameRate.default.rawValue
    @AppStorage(PreferenceKey.showsCursor) private var showsCursor = true
    @AppStorage(PreferenceKey.captureAtNativeScale) private var nativeScale = true

    var body: some View {
        Form {
            Picker("Frame rate", selection: $frameRate) {
                ForEach(FrameRate.allCases) { rate in
                    Text("\(rate.rawValue) fps").tag(rate.rawValue)
                }
            }
            Toggle("Show cursor", isOn: $showsCursor)
            Toggle("Record at Retina resolution", isOn: $nativeScale)
            Text("Turn off Retina resolution to record at 1×, which makes smaller files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
