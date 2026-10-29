import AppKit
import Observation
import TinycapCore

/// One screenshot being marked up: the captured image plus an editable list of
/// annotations in image pixels (AN-3). Every change goes through `undoManager` (AN-4).
@MainActor
@Observable
final class ScreenshotEditorModel {
    enum Tool: String, CaseIterable, Identifiable {
        case select, arrow, text, redact, crop
        var id: String { rawValue }
        var title: String {
            switch self {
            case .select: return "Select"
            case .arrow: return "Arrow"
            case .text: return "Text"
            case .redact: return "Pixelate"
            case .crop: return "Crop"
            }
        }
        var symbol: String {
            switch self {
            case .select: return "cursorarrow"
            case .arrow: return "arrow.up.right"
            case .text: return "textformat"
            case .redact: return "checkerboard.rectangle"
            case .crop: return "crop"
            }
        }
        /// V, A, T, P, C, as in most image editors.
        var key: Character {
            switch self {
            case .select: return "v"
            case .arrow: return "a"
            case .text: return "t"
            case .redact: return "p"
            case .crop: return "c"
            }
        }
    }

    let image: CGImage
    let pixelsPerPoint: Double
    @ObservationIgnored let undoManager = UndoManager()

    private(set) var annotations: [Annotation] = []
    /// Bumped on every committed change (including undo and redo), so views that show
    /// undo state refresh.
    private(set) var revision = 0
    var selectedID: UUID?
    var tool: Tool = .arrow
    /// The text label being typed into, drawn by a text field instead of the canvas.
    var editingID: UUID?
    /// Live state while a drag is in progress; committed with one undo step on release.
    var draft: [Annotation]?

    var style: AnnotationStyle {
        didSet { ScreenshotSettings.saveStyle(style, to: .standard) } // AN-5: remember last-used
    }

    // Export settings start from Settings → Screenshot and are remembered when changed.
    var format: ScreenshotFormat { didSet { persistExport(); scheduleEstimate() } }
    var jpegQuality: Double { didSet { persistExport(); scheduleEstimate() } }
    var scale: ScreenshotScale { didSet { persistExport(); scheduleEstimate() } }
    private(set) var estimatedBytes: Int?
    var savedURL: URL?
    var message: String?

    @ObservationIgnored private var estimateTask: Task<Void, Never>?

    init(_ shot: Screenshot) {
        image = shot.image
        pixelsPerPoint = shot.pixelsPerPoint
        let settings = ScreenshotSettings(defaults: .standard)
        style = settings.style
        format = settings.format
        jpegQuality = settings.jpegQuality
        scale = settings.scale
        undoManager.levelsOfUndo = 200
        scheduleEstimate()
    }

    /// What the canvas draws: the drag in progress, or the committed list.
    var visible: [Annotation] { draft ?? annotations }

    var selected: Annotation? { visible.first { $0.id == selectedID } }

    // MARK: - Edits

    /// Replaces the annotation list as one undoable step.
    func commit(_ new: [Annotation], name: String, select: UUID? = nil) {
        let old = annotations
        let oldSelection = selectedID
        draft = nil
        guard new != old else { selectedID = select ?? selectedID; return }
        annotations = new
        revision += 1
        selectedID = select ?? (new.contains { $0.id == selectedID } ? selectedID : nil)
        undoManager.registerUndo(withTarget: self) { model in
            model.commit(old, name: name, select: oldSelection)
        }
        undoManager.setActionName(name)
        scheduleEstimate()
    }

    func add(_ annotation: Annotation, name: String) {
        commit(annotations + [annotation], name: name, select: annotation.id)
    }

    func replace(_ annotation: Annotation, name: String) {
        commit(annotations.map { $0.id == annotation.id ? annotation : $0 }, name: name, select: annotation.id)
    }

    func deleteSelected() {
        guard let id = selectedID, editingID == nil else { return }
        commit(annotations.filter { $0.id != id }, name: "Delete")
        selectedID = nil
    }

    /// Style controls change the default and, if something is selected, that mark too.
    func applyStyle(_ change: (inout AnnotationStyle) -> Void) {
        change(&style)
        if let selected = annotations.first(where: { $0.id == selectedID }) {
            replace(selected.restyled(style), name: "Change Style")
        }
    }

    /// Picks up the selected mark's style, so the controls show what it uses.
    func adoptStyle(of annotation: Annotation) {
        var s = style
        switch annotation.kind {
        case .arrow(let a):
            s.color = a.color
            s.lineWidth = a.lineWidth
        case .text(let t):
            s.color = t.color
            s.fontSize = t.fontSize
            s.textBackground = t.hasBackground
        case .redaction, .crop:
            return
        }
        if s != style { style = s }
    }

    // MARK: - Crop (AN-8) and redaction (AN-7)

    var imageSize: CGSize { CGSize(width: image.width, height: image.height) }

    var cropAnnotation: Annotation? {
        visible.first { if case .crop = $0.kind { return true } else { return false } }
    }

    /// Sets or replaces the crop; a crop covering the whole image is no crop.
    func setCrop(_ rect: CGRect, name: String) {
        var list = annotations.filter { if case .crop = $0.kind { return false } else { return true } }
        if let r = RectGeometry.clamp(rect, toImage: imageSize), r.size != imageSize {
            list.insert(Annotation(id: cropAnnotation?.id ?? UUID(), .crop(r)), at: 0)
        }
        commit(list, name: name)
    }

    func resetCrop() {
        guard cropAnnotation != nil else { return }
        commit(annotations.filter { if case .crop = $0.kind { return false } else { return true } }, name: "Reset Crop")
    }

    /// Pixelated patches for the canvas, cached by rectangle (the export recomputes them).
    @ObservationIgnored private var patches: [String: CGImage] = [:]

    func pixelatedPatch(for rect: CGRect) -> CGImage? {
        guard let r = RectGeometry.clamp(rect, toImage: imageSize) else { return nil }
        let key = "\(r.minX),\(r.minY),\(r.width),\(r.height)"
        if let cached = patches[key] { return cached }
        if patches.count > 64 { patches.removeAll() }
        let patch = AnnotationRenderer.pixelated(image, rect: r)
        patches[key] = patch
        return patch
    }

    // MARK: - Text editing

    func beginEditing(_ id: UUID) {
        selectedID = id
        editingID = id
        editingSnapshot = annotations
    }

    @ObservationIgnored private var editingSnapshot: [Annotation]?

    /// Places a new, empty label and starts typing into it. Nothing is added to the undo
    /// history until editing ends, and an empty label leaves no trace.
    func beginNewText(_ annotation: Annotation) {
        editingSnapshot = annotations
        annotations.append(annotation)
        selectedID = annotation.id
        editingID = annotation.id
    }

    /// Live text changes while typing; one undo step when editing ends.
    func updateEditingText(_ text: String) {
        guard let id = editingID, var item = annotations.first(where: { $0.id == id }),
              case .text(var label) = item.kind else { return }
        label.text = text
        item.kind = .text(label)
        annotations = annotations.map { $0.id == id ? item : $0 }
    }

    func endEditing() {
        guard let id = editingID else { return }
        editingID = nil
        let before = editingSnapshot ?? annotations
        editingSnapshot = nil
        var after = annotations
        if case .text(let label)? = after.first(where: { $0.id == id })?.kind,
           label.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            after.removeAll { $0.id == id } // an empty label is dropped
        }
        // Rewind to the snapshot, then commit the result as one step.
        annotations = before
        let existed = before.contains { $0.id == id }
        commit(after, name: existed ? "Edit Text" : "Add Text", select: after.contains { $0.id == id } ? id : nil)
    }

    // MARK: - Export (SX-1 to SX-4)

    var exportFactor: Double { scale.factor(pixelsPerPoint: pixelsPerPoint) }

    var exportPixelSize: (width: Int, height: Int) {
        AnnotationRenderer.outputSize(imageSize: imageSize, annotations: annotations, scale: exportFactor)
    }

    func renderedData(format: ScreenshotFormat? = nil) -> Data? {
        guard let flat = AnnotationRenderer.flatten(image, annotations: annotations, scale: exportFactor) else { return nil }
        return ScreenshotEncoder.encode(flat, format: format ?? self.format, jpegQuality: jpegQuality)
    }

    /// ⌘C: the flattened image. PNG on the clipboard, since pasting is lossless there.
    @discardableResult
    func copyToPasteboard() -> Bool {
        guard let png = renderedData(format: .png) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        message = "Copied"
        return true
    }

    /// ⌘S: writes to the save folder with the filename pattern.
    func save() {
        do {
            guard let data = renderedData() else { throw CocoaError(.fileWriteUnknown) }
            let url = try SaveLocation.shared.nextDestination(pathExtension: format.fileExtension, screenshot: true)
            try data.write(to: url, options: .atomic)
            RecentRecordings.add(url)
            savedURL = url
            message = "Saved \(url.lastPathComponent)"
        } catch {
            Diagnostics.record(error, context: "Save screenshot")
            message = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// A temporary file for dragging the image out of the editor.
    func dragFile() -> URL? {
        guard let data = renderedData() else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Tinycap Drag", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pattern = FilenamePattern(UserDefaults.standard.string(forKey: PreferenceKey.filenamePattern) ?? "").forScreenshots
        let url = folder.appendingPathComponent(pattern.baseName(for: Date())).appendingPathExtension(format.fileExtension)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func persistExport() {
        var settings = ScreenshotSettings(defaults: .standard)
        settings.format = format
        settings.jpegQuality = jpegQuality
        settings.scale = scale
        settings.save(to: .standard)
    }

    /// SX-3: the exact file size, from the same renderer, a moment after changes stop.
    private func scheduleEstimate() {
        estimateTask?.cancel()
        let image = self.image, annotations = self.annotations, factor = exportFactor
        let format = self.format, quality = jpegQuality
        estimateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            // Off the main thread: a 5K render and encode takes a noticeable moment.
            let bytes = await Task.detached(priority: .utility) {
                AnnotationRenderer.flatten(image, annotations: annotations, scale: factor)
                    .flatMap { ScreenshotEncoder.encode($0, format: format, jpegQuality: quality) }?.count
            }.value
            guard !Task.isCancelled else { return }
            self?.estimatedBytes = bytes
        }
    }
}
