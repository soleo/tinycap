import SwiftUI
import TinycapCore
import UniformTypeIdentifiers

/// Preview window content (ED-1, ED-2, EX-1, EX-4, EX-6, EX-7).
struct PreviewView: View {
    @Bindable var model: PreviewModel
    let onDiscard: () -> Void

    @State private var widthText = ""

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
        .onAppear { syncWidthText() }
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
                Picker("Codec", selection: $model.codec) {
                    ForEach(VideoCodec.allCases) { Text("MP4 · \($0.displayName)").tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
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
                HStack {
                    Picker("Size", selection: scaleChoice) {
                        Text("Full (1×)").tag(ScaleChoice.full)
                        Text("Half (0.5×)").tag(ScaleChoice.half)
                        Text("Width…").tag(ScaleChoice.width)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    if case .width = model.scale {
                        TextField("Width", text: $widthText)
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                            .onSubmit(applyWidth)
                            .accessibilityLabel("Output width in pixels")
                        Text("px").foregroundStyle(.secondary)
                    }
                }
            }
            GridRow {
                Text("")
                summary
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 6) {
            if let size = model.outputSize {
                Text("\(size.width) × \(size.height) px")
            }
            if let bytes = model.estimatedBytes {
                Text("·").foregroundStyle(.tertiary)
                Text("about \(ByteSize.format(bytes))")
                    .help("Estimate for the kept range. Mostly static screens come out smaller.")
            }
        }
        .monospacedDigit()
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private enum ScaleChoice: Hashable { case full, half, width }

    private var scaleChoice: Binding<ScaleChoice> {
        Binding {
            switch model.scale {
            case .full: return .full
            case .half: return .half
            case .width: return .width
            }
        } set: { choice in
            switch choice {
            case .full: model.scale = .full
            case .half: model.scale = .half
            case .width:
                let current = model.outputSize?.width ?? 1280
                model.scale = .width(min(1280, current))
                syncWidthText()
            }
        }
    }

    private func syncWidthText() {
        if case .width(let w) = model.scale { widthText = String(w) }
    }

    private func applyWidth() {
        if let w = Int(widthText.trimmingCharacters(in: .whitespaces)), w >= 16 {
            model.scale = .width(w)
        }
        syncWidthText()
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
