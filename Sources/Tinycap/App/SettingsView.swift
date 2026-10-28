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
            ExportSettingsView()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
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

            Section {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(action: action)
                    }
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                HStack {
                    Text("Click a shortcut, then press new keys. Delete clears it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Defaults") { ShortcutManager.shared.resetAll() }
                        .controlSize(.small)
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

private struct ExportSettingsView: View {
    @AppStorage(PreferenceKey.exportCodec) private var codec = VideoCodec.h264.rawValue
    @AppStorage(PreferenceKey.exportQuality) private var quality = ExportSettings.defaultQuality
    @AppStorage(PreferenceKey.exportScale) private var scale = OutputScale.full.storageValue

    var body: some View {
        Form {
            LabeledContent("Format", value: "MP4")
            Picker("MP4 codec", selection: $codec) {
                ForEach(VideoCodec.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            Text("H.264 plays inline almost everywhere. HEVC makes smaller files, but some apps won't play it inline.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Quality") {
                HStack {
                    Text("Smaller").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $quality, in: 0...1).accessibilityLabel("Quality")
                    Text("Better").font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("Size", selection: $scale) {
                Text("Full (1×)").tag(OutputScale.full.storageValue)
                Text("Half (0.5×)").tag(OutputScale.half.storageValue)
                Text("1280 px wide").tag(OutputScale.width(1280).storageValue)
                if case .width(let w) = OutputScale(storageValue: scale), w != 1280 {
                    Text("\(w) px wide").tag(scale)
                }
            }
            Text("These are the starting values in the preview window. Changes made there are remembered here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
