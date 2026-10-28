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
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
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
    @AppStorage(PreferenceKey.highlightsClicks) private var highlightsClicks = false
    @AppStorage(PreferenceKey.countdown) private var countdown = false

    var body: some View {
        Form {
            Picker("Frame rate", selection: $frameRate) {
                ForEach(FrameRate.allCases) { rate in
                    Text("\(rate.rawValue) fps").tag(rate.rawValue)
                }
            }
            Toggle("Show cursor", isOn: $showsCursor)
            Toggle("Highlight clicks", isOn: $highlightsClicks)
            Toggle("Count down 3-2-1 before recording", isOn: $countdown)
            Toggle("Record at Retina resolution", isOn: $nativeScale)
            Text("Turn off Retina resolution to record at 1×, which makes smaller files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettingsView: View {
    @State private var copied = false
    private let info = Diagnostics.current

    var body: some View {
        Form {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tinycap").font(.title2.weight(.semibold))
                    Text("Version \(info.appVersion) (\(info.build))")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 4)

            Section {
                if let date = info.buildDate {
                    LabeledContent("Built", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                if let commit = info.commit {
                    LabeledContent("Commit") {
                        if let url = Diagnostics.commitURL {
                            Link(commit, destination: url).font(.body.monospaced())
                        } else {
                            Text(commit).font(.body.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                LabeledContent("Installed from", value: info.channel == .appStore ? "App Store" : "Direct download")
            }

            Section("Links") {
                links
            }

            Section {
                HStack {
                    Button("Report a Bug…") { Diagnostics.open(.bug) }
                    Button("Send Feedback…") { Diagnostics.open(.feature) }
                    Spacer()
                    Button(copied ? "Copied" : "Copy Diagnostics") {
                        Diagnostics.copyToPasteboard()
                        copied = true
                    }
                }
                .disabled(Diagnostics.repositoryURL == nil)
            } footer: {
                Text("Report and feedback open GitHub in your browser with your Tinycap and macOS versions filled in. Tinycap sends nothing itself. Copy Diagnostics adds the last error, for pasting into an issue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Tinycap is open source under the MIT license.") {
                    Button("Acknowledgements…") { AcknowledgementsWindowController.shared.show() }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var links: some View {
        let items: [(String, URL?)] = [
            ("Xinjiang Shao", Diagnostics.authorURL),
            ("@soleo on GitHub", Diagnostics.authorGitHubURL),
            ("Source code", Diagnostics.repositoryURL),
            ("Release notes", Diagnostics.releaseNotesURL),
        ]
        ForEach(items.compactMap { title, url in url.map { (title, $0) } }, id: \.0) { title, url in
            LabeledContent(title) {
                Link(url.host().map { $0 + url.path() } ?? url.absoluteString, destination: url)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

private struct ExportSettingsView: View {
    @AppStorage(PreferenceKey.exportFormat) private var format = ExportFormat.mp4.rawValue
    @AppStorage(PreferenceKey.exportCodec) private var codec = VideoCodec.h264.rawValue
    @AppStorage(PreferenceKey.exportQuality) private var quality = ExportSettings.defaultQuality
    @AppStorage(PreferenceKey.exportScale) private var scale = OutputScale.full.storageValue
    @AppStorage(PreferenceKey.gifFitTargetMB) private var fitTargetMB = 10
    @AppStorage(PreferenceKey.webmQuality) private var webmQuality = WebMSettings.defaultQuality
    @AppStorage(PreferenceKey.webmScale) private var webmScale = OutputScale.full.storageValue
    @State private var gif = GIFSettings(defaults: .standard)

    var body: some View {
        Form {
            Picker("Default format", selection: $format) {
                ForEach(ExportFormat.allCases) { Text($0.displayName).tag($0.rawValue) }
            }

            Section("MP4") {
                Picker("Codec", selection: $codec) {
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
            }

            Section("WebM") {
                LabeledContent("Quality") {
                    HStack {
                        Text("Smaller").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $webmQuality, in: 0...1).accessibilityLabel("WebM quality")
                        Text("Better").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("Size", selection: $webmScale) {
                    Text("Full (1×)").tag(OutputScale.full.storageValue)
                    Text("Half (0.5×)").tag(OutputScale.half.storageValue)
                    Text("1280 px wide").tag(OutputScale.width(1280).storageValue)
                    if case .width(let w) = OutputScale(storageValue: webmScale), w != 1280 {
                        Text("\(w) px wide").tag(webmScale)
                    }
                }
                Text("VP9. Plays inline in Chrome, Firefox, Edge, Safari 14.1+ and Slack.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("GIF") {
                Picker("Preset", selection: presetBinding) {
                    ForEach(GIFPreset.allCases) { preset in
                        Text("\(preset.displayName) — \(describe(preset.settings))").tag(Optional(preset))
                    }
                    if gif.preset == nil { Text("Custom — \(describe(gif))").tag(GIFPreset?.none) }
                }
                Toggle("Loop", isOn: Binding(get: { gif.loop }, set: { gif.loop = $0; gif.save(to: .standard) }))
                Stepper("Fit under \(fitTargetMB) MB", value: $fitTargetMB, in: 1...100)
            }

            Text("These are the starting values in the preview window. Changes made there are remembered here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { gif = GIFSettings(defaults: .standard) }
    }

    private var presetBinding: Binding<GIFPreset?> {
        Binding { gif.preset } set: { preset in
            guard let preset else { return }
            var s = preset.settings
            s.loop = gif.loop
            gif = s
            gif.save(to: .standard)
        }
    }

    private func describe(_ s: GIFSettings) -> String {
        let size: String
        switch s.scale {
        case .full: size = "full size"
        case .half: size = "half size"
        case .width(let w): size = "\(w) px"
        }
        return "\(s.fps) fps, \(size), \(s.colors) colors\(s.dither ? ", dithered" : "")"
    }
}
