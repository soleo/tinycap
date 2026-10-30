import SwiftUI
import TinycapCore
import UniformTypeIdentifiers

/// Preview window content (ED-1, ED-2, EX-1, EX-4, EX-6, EX-7).
struct PreviewView: View {
    @Bindable var model: PreviewModel
    let onDiscard: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PlayerView(player: model.player)
                .frame(minWidth: 480, minHeight: 240)
                .background(Color.black)

            VStack(alignment: .leading, spacing: 14) {
                timeline
                Divider()
                exportOptions
                Divider()
                footer
            }
            .padding(16)
            .disabled(model.info == nil && !isFailed)
        }
        .frame(minWidth: 560)
    }

    // MARK: - Timeline

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    model.togglePlay()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                .help("Play or pause (Space)")

                TrimScrubber(
                    duration: model.trim.duration,
                    start: model.trim.start,
                    end: model.trim.end,
                    playhead: model.playhead,
                    onSeek: model.seek(to:),
                    onStart: model.setTrimStart,
                    onEnd: model.setTrimEnd
                )

                Text(TimeText.precise(model.playhead))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 52, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Text("Keep \(TimeText.precise(model.trim.start)) – \(TimeText.precise(model.trim.end))")
                    .monospacedDigit()
                Text("(\(String(format: "%.1f", model.trim.length)) s)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Set Start") { model.setStartAtPlayhead() }
                    .keyboardShortcut("i", modifiers: [])
                    .help("Trim start to the playhead (I)")
                Button("Set End") { model.setEndAtPlayhead() }
                    .keyboardShortcut("o", modifiers: [])
                    .help("Trim end to the playhead (O)")
                Button("Reset") { model.resetTrim() }
                    .disabled(!model.trim.isTrimmed)
            }
            .controlSize(.small)
        }
    }

    // MARK: - Export options

    private var exportOptions: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Format").gridColumnAlignment(.trailing)
                Picker("Format", selection: $model.format) {
                    ForEach(ExportFormat.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            switch model.format {
            case .mp4: mp4Options
            case .webm: webmOptions
            case .gif: gifOptions
            }
            if !model.audioTracks.isEmpty {
                soundRow
            }
            GridRow {
                Text("")
                summary
            }
        }
    }

    /// One switch per recorded source; off mutes it here and leaves it out of the MP4.
    private var soundRow: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text("Sound")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 14) {
                    ForEach(model.audioTracks) { track in
                        Toggle(track.source == .system ? "System audio" : "Microphone", isOn: Binding {
                            !model.isMuted(track.source)
                        } set: { on in
                            model.setMuted(track.source, !on)
                        })
                        .toggleStyle(.checkbox)
                    }
                }
                if model.format != .mp4 {
                    Text("Sound is kept only in MP4.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var mp4Options: some View {
        GridRow {
            Text("Codec")
            Picker("Codec", selection: $model.codec) {
                ForEach(VideoCodec.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 180)
            .help("H.264 plays everywhere. HEVC makes smaller files but some apps can't play it inline.")
        }
        GridRow {
            Text("Quality")
            HStack {
                Text("Smaller").font(.caption).foregroundStyle(.secondary)
                Slider(value: $model.quality, in: 0...1)
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Quality")
                    .accessibilityValue("\(Int(model.quality * 100)) percent")
                Text("Better").font(.caption).foregroundStyle(.secondary)
            }
        }
        GridRow {
            Text("Size")
            ScalePicker(scale: $model.scale, sourceWidth: model.info.map { Int($0.pixelSize.width) })
        }
    }

    @ViewBuilder
    private var webmOptions: some View {
        GridRow {
            Text("Codec")
            Text("VP9")
                .foregroundStyle(.secondary)
                .help("Plays inline in Chrome, Firefox, Edge, Safari 14.1+ and Slack")
        }
        GridRow {
            Text("Quality")
            HStack {
                Text("Smaller").font(.caption).foregroundStyle(.secondary)
                Slider(value: $model.webm.quality, in: 0...1)
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Quality")
                    .accessibilityValue("\(Int(model.webm.quality * 100)) percent")
                Text("Better").font(.caption).foregroundStyle(.secondary)
            }
        }
        GridRow {
            Text("Size")
            ScalePicker(scale: $model.webm.scale, sourceWidth: model.info.map { Int($0.pixelSize.width) })
        }
    }

    @ViewBuilder
    private var gifOptions: some View {
        GridRow {
            Text("Preset")
            Picker("Preset", selection: presetChoice) {
                ForEach(GIFPreset.allCases) { Text($0.displayName).tag(Optional($0)) }
                if model.gif.preset == nil { Text("Custom").tag(GIFPreset?.none) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
        }
        GridRow {
            Text("Frame rate")
            HStack {
                Slider(value: fpsBinding, in: Double(GIFSettings.frameRates.lowerBound)...Double(GIFSettings.frameRates.upperBound), step: 1)
                    .frame(maxWidth: 180)
                    .accessibilityLabel("Frame rate")
                    .accessibilityValue("\(model.gif.fps) frames per second")
                Text("\(model.gif.fps) fps").monospacedDigit().frame(width: 48, alignment: .leading)
            }
        }
        GridRow {
            Text("Size")
            ScalePicker(scale: $model.gif.scale, sourceWidth: model.info.map { Int($0.pixelSize.width) })
        }
        GridRow {
            Text("Colors")
            Picker("Colors", selection: $model.gif.colors) {
                ForEach(GIFSettings.colorChoices, id: \.self) { Text("\($0)").tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 220)
        }
        GridRow {
            Text("")
            HStack(spacing: 14) {
                Toggle("Dither", isOn: $model.gif.dither)
                    .help("Smoother gradients and photos; larger files")
                Toggle("Loop", isOn: $model.gif.loop)
                Toggle("Drop duplicate frames", isOn: $model.gif.dropDuplicates)
                    .help("Merge frames where nothing changed into one longer frame")
            }
            .toggleStyle(.checkbox)
        }
        GridRow {
            Text("")
            fitRow
        }
    }

    private var fitRow: some View {
        HStack(spacing: 8) {
            Button("Fit under \(model.fitTargetMB) MB") { model.fitGIFUnderTarget() }
                .disabled(model.fit == .fitting || model.info == nil)
                .help("Lower dithering, colors, frame rate and size until the estimate fits")
            switch model.fit {
            case .idle:
                EmptyView()
            case .fitting:
                ProgressView().controlSize(.small)
                Text("Trying smaller settings…").foregroundStyle(.secondary)
            case .fitted(let bytes):
                Label("Fits: about \(ByteSize.format(bytes))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .cannotFit(let bytes):
                Label("Smallest settings are still about \(ByteSize.format(bytes)). Trim the clip to go lower.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .font(.callout)
    }

    private var presetChoice: Binding<GIFPreset?> {
        Binding { model.gif.preset } set: { preset in
            if let preset { model.applyGIFPreset(preset) }
        }
    }

    private var fpsBinding: Binding<Double> {
        Binding { Double(model.gif.fps) } set: { model.gif.fps = Int($0.rounded()) }
    }

    private var summary: some View {
        HStack(spacing: 6) {
            if let size = model.outputSize {
                Text("\(size.width) × \(size.height) px")
            }
            switch model.estimate {
            case .none, .unavailable:
                EmptyView()
            case .estimating(let previous):
                Text("·").foregroundStyle(.tertiary)
                if let previous {
                    Text("about \(ByteSize.format(previous))").opacity(0.5)
                } else {
                    Text("estimating size…")
                }
                ProgressView().controlSize(.mini)
            case .bytes(let bytes):
                Text("·").foregroundStyle(.tertiary)
                Text("about \(ByteSize.format(bytes))")
                    .help("Estimated by encoding a short sample of the kept range at these settings.")
            }
        }
        .monospacedDigit()
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Footer

    private var isFailed: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            Button("Discard", role: .destructive, action: onDiscard)
                .disabled(model.isExporting)

            Spacer()

            switch model.phase {
            case .loading:
                ProgressView().controlSize(.small)
            case .ready:
                exportButton
            case .exporting(let progress):
                ProgressView(value: progress)
                    .frame(width: 160)
                    .accessibilityLabel("Exporting")
                Text("\(Int(progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                Button("Cancel") { model.cancelExport() }
                    .keyboardShortcut(.cancelAction)
            case .exported(let url):
                exportedFile(url)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .help(message)
                if model.info != nil {
                    Button("Try Again") {
                        model.dismissError()
                        model.export()
                    }
                }
            }
        }
        .frame(minHeight: 28)
    }

    private var exportButton: some View {
        Button("Export") { model.export() }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canExport)
    }

    private func exportedFile(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 28, height: 28)
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                .help("Drag the file into another app")
                .accessibilityLabel("Exported file. Drag to share.")
            VStack(alignment: .leading, spacing: 0) {
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                if let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    Text(ByteSize.format(Int64(bytes))).font(.caption).foregroundStyle(.secondary)
                }
            }
            .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            .frame(maxWidth: 220, alignment: .leading)
            Button("Copy") { model.copyExportedFile() }
                .help("Copy the file to paste into Slack, Mail or Finder")
            Button("Show in Finder") { model.revealExportedFile() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// Full / Half / fixed width, shared by the MP4 and GIF options.
struct ScalePicker: View {
    @Binding var scale: OutputScale
    let sourceWidth: Int?
    @State private var widthText = ""

    private enum Choice: Hashable { case full, half, width }

    var body: some View {
        HStack {
            Picker("Size", selection: choice) {
                Text("Full (1×)").tag(Choice.full)
                Text("Half (0.5×)").tag(Choice.half)
                Text("Width…").tag(Choice.width)
            }
            .labelsHidden()
            .frame(width: 130)
            if case .width = scale {
                TextField("Width", text: $widthText)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(apply)
                    .accessibilityLabel("Output width in pixels")
                Text("px").foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: sync)
        .onChange(of: scale) { _, _ in sync() }
    }

    private var choice: Binding<Choice> {
        Binding {
            switch scale {
            case .full: return .full
            case .half: return .half
            case .width: return .width
            }
        } set: { newValue in
            switch newValue {
            case .full: scale = .full
            case .half: scale = .half
            case .width:
                if case .width = scale { return }
                scale = .width(min(1280, sourceWidth ?? 1280))
            }
        }
    }

    private func sync() {
        if case .width(let w) = scale { widthText = String(w) }
    }

    private func apply() {
        if let w = Int(widthText.trimmingCharacters(in: .whitespaces)), w >= 16 {
            scale = .width(w)
        }
        sync()
    }
}
