import AppKit
import SwiftUI
import TinycapCore

/// The annotation editor: toolbar, zoomable canvas, export bar.
struct ScreenshotEditorView: View {
    @Bindable var model: ScreenshotEditorModel
    /// nil = fit to window.
    @State private var zoom: Double?

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(model: model, zoom: $zoom)
            Divider()
            GeometryReader { geometry in
                let fit = fitZoom(in: geometry.size)
                let effective = zoom ?? fit
                ScrollView([.horizontal, .vertical]) {
                    EditorCanvas(model: model, viewScale: effective / model.pixelsPerPoint)
                        .frame(width: pointSize.width * effective, height: pointSize.height * effective)
                        .padding(16)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
                .simultaneousGesture(MagnifyGesture().onChanged { value in
                    zoom = min(8, max(0.1, (zoom ?? fit) * value.magnification))
                })
            }
            Divider()
            ExportBar(model: model)
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    private var pointSize: CGSize {
        CGSize(width: Double(model.image.width) / model.pixelsPerPoint, height: Double(model.image.height) / model.pixelsPerPoint)
    }

    private func fitZoom(in size: CGSize) -> Double {
        let available = CGSize(width: max(1, size.width - 32), height: max(1, size.height - 32))
        return min(1, available.width / pointSize.width, available.height / pointSize.height)
    }
}

// MARK: - Toolbar

private struct EditorToolbar: View {
    @Bindable var model: ScreenshotEditorModel
    @Binding var zoom: Double?

    private enum SizeControl { case thickness, text, badge }

    /// Which size control to show: the selected mark's kind, else the current tool's.
    private var sizeControl: SizeControl {
        switch model.selected?.kind {
        case .text?: return .text
        case .badge?: return .badge
        case .arrow?, .shape?, .stroke?: return .thickness
        default: return model.tool == .text ? .text : model.tool == .badge ? .badge : .thickness
        }
    }

    var body: some View {
        let _ = model.revision // refresh undo/redo state
        HStack(spacing: 12) {
            Picker("Tool", selection: $model.tool) {
                // Icons only: ten tools with titles would crowd out the style controls.
                ForEach(ScreenshotEditorModel.Tool.allCases) { tool in
                    Image(systemName: tool.symbol)
                        .accessibilityLabel(tool.title)
                        .help("\(tool.title) (\(String(tool.key).uppercased()))")
                        .tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Divider().frame(height: 20)

            if model.tool == .crop && !selectionIsMark {
                Text("Drag to choose what to keep; drag the corners to adjust.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Reset Crop") { model.resetCrop() }
                    .disabled(model.cropAnnotation == nil)
            } else if model.tool == .redact && !selectionIsMark {
                Text("Drag over anything private. It's pixelated in the exported image.")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                styleControls
            }

            Spacer()

            Button { model.undoManager.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .help("Undo (⌘Z)")
                .disabled(!model.undoManager.canUndo || model.editingID != nil)
            Button { model.undoManager.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .help("Redo (⇧⌘Z)")
                .disabled(!model.undoManager.canRedo || model.editingID != nil)

            Picker("Zoom", selection: Binding(get: { zoom ?? -1 }, set: { zoom = $0 < 0 ? nil : $0 })) {
                Text("Fit").tag(-1.0)
                Text("50%").tag(0.5)
                Text("100%").tag(1.0)
                Text("200%").tag(2.0)
                if let zoom, ![0.5, 1, 2].contains(zoom) { Text("\(Int(zoom * 100))%").tag(zoom) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// A mark with a color is selected, so its style controls apply.
    private var selectionIsMark: Bool {
        switch model.selected?.kind {
        case .arrow?, .text?, .shape?, .stroke?, .badge?: return true
        default: return false
        }
    }

    @ViewBuilder private var styleControls: some View {
        HStack(spacing: 6) {
            ForEach(Array(RGBAColor.presets.enumerated()), id: \.offset) { index, color in
                ColorSwatch(color: color, selected: model.style.color == color) {
                    model.applyStyle { $0.color = color }
                }
                .accessibilityLabel(["Pink", "Yellow", "Green", "Blue", "Black", "White"][index])
            }
            ColorPicker("Custom color", selection: customColor, supportsOpacity: false)
                .labelsHidden()
                .help("Custom color")
        }

        Divider().frame(height: 20)

        if sizeControl != .thickness {
            Picker("Size", selection: Binding(get: { model.style.fontSize }, set: { size in model.applyStyle { $0.fontSize = size } })) {
                ForEach(sizeOptions(AnnotationStyle.fontSizes, current: model.style.fontSize), id: \.self) { size in
                    Text(size == AnnotationStyle.fontSizes[0] ? "Small" : size == AnnotationStyle.fontSizes[1] ? "Medium"
                         : size == AnnotationStyle.fontSizes[2] ? "Large" : "\(Int(size)) px").tag(size)
                }
            }
            .fixedSize()
            if sizeControl == .text {
                Toggle("Background", isOn: Binding(get: { model.style.textBackground },
                                                   set: { on in model.applyStyle { $0.textBackground = on } }))
                    .help("Solid background behind the text")
            }
        } else {
            Picker("Thickness", selection: Binding(get: { model.style.lineWidth }, set: { width in model.applyStyle { $0.lineWidth = width } })) {
                ForEach(sizeOptions(AnnotationStyle.lineWidths, current: model.style.lineWidth), id: \.self) { width in
                    Text(width == AnnotationStyle.lineWidths[0] ? "Thin" : width == AnnotationStyle.lineWidths[1] ? "Medium"
                         : width == AnnotationStyle.lineWidths[2] ? "Thick" : "\(Int(width)) px").tag(width)
                }
            }
            .fixedSize()
        }
    }

    /// The presets, plus the current value if a mark was resized to something else.
    private func sizeOptions(_ presets: [Double], current: Double) -> [Double] {
        presets.contains(current) ? presets : (presets + [current]).sorted()
    }

    private var customColor: Binding<Color> {
        Binding {
            Color(cgColor: model.style.color.cgColor)
        } set: { color in
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
            let rgba = RGBAColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
            model.applyStyle { $0.color = rgba }
        }
    }
}

private struct ColorSwatch: View {
    let color: RGBAColor
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(cgColor: color.cgColor))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                .frame(width: 18, height: 18)
                .padding(2)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Canvas

private struct EditorCanvas: View {
    @Bindable var model: ScreenshotEditorModel
    /// View points per image pixel.
    let viewScale: Double

    @State private var drag: DragState = .idle
    @State private var lastTap: (id: UUID, time: Date)?
    @FocusState private var canvasFocused: Bool
    @FocusState private var textFocused: Bool

    private enum DragState {
        case idle
        case ignored
        case drawing(id: UUID, start: CGPoint)
        case moving(id: UUID, start: CGPoint, original: Annotation, moved: Bool)
        case arrowEnd(id: UUID, isStart: Bool, original: Arrow)
        case arrowBend(id: UUID, original: Arrow)
        case textSize(id: UUID, original: TextLabel)
        case placingText(at: CGPoint)
        /// A new redaction or crop rectangle being dragged out.
        case drawingRect(id: UUID, start: CGPoint, crop: Bool)
        case rectCorner(id: UUID, corner: Int, original: CGRect, crop: Bool)
        case movingCrop(start: CGPoint, original: CGRect)
        /// AN-6: a new rectangle or ellipse being dragged out.
        case drawingShape(id: UUID, start: CGPoint, form: ShapeMark.Form)
        /// AN-9 and AN-6: a pen or highlighter stroke in progress.
        case drawingStroke(id: UUID, points: [CGPoint], highlighter: Bool)
        /// AN-8: a click that drops the next numbered badge.
        case placingBadge(at: CGPoint)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                drawChecker(in: &context, size: size)
                context.draw(Image(decorative: model.image, scale: 1), in: CGRect(origin: .zero, size: size))
                let shown = model.visible.filter { $0.id != model.editingID }
                context.withCGContext { cg in
                    cg.scaleBy(x: viewScale, y: viewScale)
                    // Pixelated areas first, so arrows and text stay on top (as in the export).
                    for item in shown {
                        guard case .redaction(let rect) = item.kind,
                              let r = RectGeometry.clamp(rect, toImage: model.imageSize),
                              let patch = model.pixelatedPatch(for: r) else { continue }
                        AnnotationRenderer.drawImage(patch, in: r, context: cg)
                    }
                    AnnotationRenderer.draw(shown, in: cg)
                }
                drawCrop(in: &context, size: size)
                if let selected = model.selected, model.editingID == nil {
                    drawSelection(selected, in: &context)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .onContinuousHover { phase in
                if case .active = phase {
                    (model.tool == .select ? NSCursor.arrow : model.tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
                }
            }

            if let editing = editingLabel {
                textEditor(editing.label)
                    .offset(x: editing.frame.minX * viewScale, y: editing.frame.minY * viewScale)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($canvasFocused)
        .onAppear { canvasFocused = true }
        .onDeleteCommand {
            if model.selectedID == nil, model.tool == .crop { model.resetCrop() } else { model.deleteSelected() }
        }
        .onExitCommand {
            if model.editingID != nil { model.endEditing() } else { model.selectedID = nil }
        }
        .onKeyPress(characters: .letters) { press in
            guard model.editingID == nil, press.modifiers.isEmpty,
                  let tool = ScreenshotEditorModel.Tool.allCases.first(where: { press.characters == String($0.key) })
            else { return .ignored }
            model.tool = tool
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Screenshot. \(model.visible.count) annotations.")
    }

    // MARK: Coordinates

    private func imagePoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / viewScale, y: p.y / viewScale) }
    /// A grab radius of 7 view points, in image pixels.
    private var tolerance: Double { 7 / viewScale }
    private var shiftDown: Bool { NSEvent.modifierFlags.contains(.shift) }

    // MARK: Gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if case .idle = drag { begin(at: imagePoint(value.startLocation)) }
                update(to: imagePoint(value.location))
            }
            .onEnded { value in
                finish(at: imagePoint(value.location))
                drag = .idle
            }
    }

    private func begin(at p: CGPoint) {
        canvasFocused = true
        if model.editingID != nil {
            model.endEditing()
            drag = .ignored
            return
        }
        if let selected = model.selected, let handle = handle(of: selected, at: p) {
            drag = handle
            return
        }
        let hit = AnnotationHitTest.hit(p, in: model.annotations, tolerance: tolerance)
        switch model.tool {
        case .select:
            if let hit {
                model.selectedID = hit.id
                model.adoptStyle(of: hit)
                drag = .moving(id: hit.id, start: p, original: hit, moved: false)
            } else {
                model.selectedID = nil
                drag = .ignored
            }
        case .arrow:
            drag = .drawing(id: UUID(), start: p)
        case .rectangle, .ellipse:
            drag = .drawingShape(id: UUID(), start: p, form: model.tool == .rectangle ? .rectangle : .ellipse)
        case .pen, .highlighter:
            drag = .drawingStroke(id: UUID(), points: [p], highlighter: model.tool == .highlighter)
        case .badge:
            if let hit, case .badge = hit.kind {
                model.selectedID = hit.id
                model.adoptStyle(of: hit)
                drag = .moving(id: hit.id, start: p, original: hit, moved: false)
            } else {
                drag = .placingBadge(at: p)
            }
        case .text:
            if let hit, case .text = hit.kind {
                model.selectedID = hit.id
                model.adoptStyle(of: hit)
                drag = .moving(id: hit.id, start: p, original: hit, moved: false)
            } else {
                drag = .placingText(at: p)
            }
        case .redact:
            if let hit, case .redaction = hit.kind {
                model.selectedID = hit.id
                drag = .moving(id: hit.id, start: p, original: hit, moved: false)
            } else {
                model.selectedID = nil
                drag = .drawingRect(id: UUID(), start: p, crop: false)
            }
        case .crop:
            model.selectedID = nil
            if let crop = model.cropAnnotation, let r = crop.rect {
                if let corner = RectGeometry.corners(r).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) <= tolerance * 1.5 }) {
                    drag = .rectCorner(id: crop.id, corner: corner, original: r, crop: true)
                    return
                }
                if r.contains(p) {
                    drag = .movingCrop(start: p, original: r)
                    return
                }
            }
            drag = .drawingRect(id: model.cropAnnotation?.id ?? UUID(), start: p, crop: true)
        }
    }

    /// The annotations with `rect` set on the redaction, shape or crop `id`, or as a new
    /// redaction or crop.
    private func withRect(_ rect: CGRect, id: UUID, crop: Bool) -> [Annotation] {
        let item = Annotation(id: id, crop ? .crop(rect) : .redaction(rect))
        var list = model.annotations
        if let index = list.firstIndex(where: { $0.id == id }) {
            list[index] = list[index].withRect(rect)
        } else if crop {
            list.insert(item, at: 0)
        } else {
            list.append(item)
        }
        return list
    }

    private func update(to p: CGPoint) {
        switch drag {
        case .drawing(let id, let start):
            let end = shiftDown ? ArrowGeometry.snap45(from: start, to: p) : p
            let arrow = Annotation(id: id, .arrow(Arrow(start: start, end: end, color: model.style.color, lineWidth: model.style.lineWidth)))
            model.draft = model.annotations + [arrow]
        case .moving(let id, let start, let original, _):
            let delta = CGVector(dx: p.x - start.x, dy: p.y - start.y)
            let moved = hypot(delta.dx, delta.dy) > tolerance / 2
            drag = .moving(id: id, start: start, original: original, moved: moved)
            guard moved else { return }
            model.draft = model.annotations.map { $0.id == id ? original.moved(by: delta) : $0 }
        case .arrowEnd(let id, let isStart, let original):
            var arrow = original
            if isStart {
                arrow.start = shiftDown ? ArrowGeometry.snap45(from: original.end, to: p) : p
            } else {
                arrow.end = shiftDown ? ArrowGeometry.snap45(from: original.start, to: p) : p
            }
            model.draft = model.annotations.map { $0.id == id ? Annotation(id: id, .arrow(arrow)) : $0 }
        case .arrowBend(let id, let original):
            var arrow = original
            arrow.bend = ArrowGeometry.bend(original, through: p, snap: tolerance)
            model.draft = model.annotations.map { $0.id == id ? Annotation(id: id, .arrow(arrow)) : $0 }
        case .textSize(let id, let original):
            let frame = TextLayout.frame(original)
            let factor = max(0.2, (p.x - frame.minX) / max(1, frame.width))
            var label = original
            label.fontSize = min(400, max(8, (original.fontSize * factor).rounded()))
            model.draft = model.annotations.map { $0.id == id ? Annotation(id: id, .text(label)) : $0 }
        case .drawingRect(let id, let start, let crop):
            model.draft = withRect(Geometry.rect(from: start, to: p), id: id, crop: crop)
        case .rectCorner(let id, let corner, let original, let crop):
            model.draft = withRect(RectGeometry.drag(original, corner: corner, to: p, minimum: tolerance * 2), id: id, crop: crop)
        case .movingCrop(let start, let original):
            let moved = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            let kept = Geometry.keep(moved, inside: CGRect(origin: .zero, size: model.imageSize))
            model.draft = withRect(kept, id: model.cropAnnotation?.id ?? UUID(), crop: true)
        case .drawingShape(let id, let start, let form):
            let rect = shiftDown ? ShapeGeometry.square(from: start, to: p) : Geometry.rect(from: start, to: p)
            let shape = Annotation(id: id, .shape(ShapeMark(form: form, rect: rect, color: model.style.color, lineWidth: model.style.lineWidth)))
            model.draft = model.annotations + [shape]
        case .drawingStroke(let id, let points, let highlighter):
            // Shift draws a highlighter straight, for underlining a line of text.
            let next = highlighter && shiftDown ? [points[0], p] : StrokeGeometry.appending(p, to: points, spacing: max(1, tolerance / 4))
            drag = .drawingStroke(id: id, points: next, highlighter: highlighter)
            model.draft = model.annotations + [stroke(id: id, points: next, highlighter: highlighter)]
        case .idle, .ignored, .placingText, .placingBadge:
            break
        }
    }

    private func stroke(id: UUID, points: [CGPoint], highlighter: Bool) -> Annotation {
        Annotation(id: id, .stroke(Stroke(points: points, color: model.style.color, lineWidth: model.style.lineWidth, isHighlighter: highlighter)))
    }

    /// A click (no real drag) with a drawing tool selects whatever is under it.
    private func selectHit(at p: CGPoint) {
        model.draft = nil
        let hit = AnnotationHitTest.hit(p, in: model.annotations, tolerance: tolerance)
        model.selectedID = hit?.id
        if let hit { model.adoptStyle(of: hit) }
    }

    private func finish(at p: CGPoint) {
        switch drag {
        case .drawing(let id, _):
            guard let arrow = model.draft?.first(where: { $0.id == id }), case .arrow(let a) = arrow.kind,
                  hypot(a.end.x - a.start.x, a.end.y - a.start.y) >= tolerance * 1.5 else {
                selectHit(at: p)
                return
            }
            model.add(arrow, name: "Add Arrow")
        case .drawingShape(let id, _, let form):
            guard let shape = model.draft?.first(where: { $0.id == id }), let r = shape.rect,
                  max(r.width, r.height) >= tolerance * 1.5 else {
                selectHit(at: p)
                return
            }
            model.add(shape, name: form == .rectangle ? "Add Rectangle" : "Add Ellipse")
        case .drawingStroke(let id, var points, let highlighter):
            // Keep the release point, which the spacing filter may have skipped.
            if points.last != p, !(highlighter && shiftDown) { points.append(p) }
            guard StrokeGeometry.length(points) >= tolerance else {
                selectHit(at: p)
                return
            }
            model.add(stroke(id: id, points: points, highlighter: highlighter), name: highlighter ? "Highlight" : "Draw")
        case .placingBadge(let start):
            guard hypot(p.x - start.x, p.y - start.y) < tolerance * 2 else { return }
            let badge = Badge(center: p, number: Annotation.nextBadgeNumber(in: model.annotations),
                              color: model.style.color, fontSize: model.style.fontSize)
            model.add(Annotation(.badge(badge)), name: "Add Number")
        case .moving(let id, _, _, let moved):
            if moved, let draft = model.draft {
                model.commit(draft, name: "Move", select: id)
            } else {
                model.draft = nil
                // Text tool click, or a double click with Select, edits a label.
                let isDouble = lastTap.map { $0.id == id && Date().timeIntervalSince($0.time) < NSEvent.doubleClickInterval } ?? false
                lastTap = (id, Date())
                if case .text? = model.annotations.first(where: { $0.id == id })?.kind,
                   model.tool == .text || isDouble {
                    model.beginEditing(id)
                    textFocused = true
                }
            }
        case .arrowEnd(let id, _, _), .textSize(let id, _):
            if let draft = model.draft { model.commit(draft, name: "Resize", select: id) }
        case .arrowBend(let id, _):
            if let draft = model.draft { model.commit(draft, name: "Bend Arrow", select: id) }
        case .placingText(let start):
            guard hypot(p.x - start.x, p.y - start.y) < tolerance * 2 else { return }
            let pad = TextLayout.padding(fontSize: model.style.fontSize)
            let line = TextLayout.lineHeight(fontSize: model.style.fontSize)
            let label = TextLabel(origin: CGPoint(x: p.x - pad, y: p.y - pad - line / 2), text: "",
                                  fontSize: model.style.fontSize, color: model.style.color, hasBackground: model.style.textBackground)
            model.beginNewText(Annotation(.text(label)))
            textFocused = true
        case .drawingRect(let id, let start, let crop):
            let rect = Geometry.rect(from: start, to: p)
            guard rect.width >= tolerance * 2, rect.height >= tolerance * 2 else {
                model.draft = nil
                if !crop { model.selectedID = AnnotationHitTest.hit(p, in: model.annotations, tolerance: tolerance)?.id }
                return
            }
            if crop {
                model.setCrop(rect, name: "Crop")
            } else if let r = RectGeometry.clamp(rect, toImage: model.imageSize) {
                model.add(Annotation(id: id, .redaction(r)), name: "Pixelate")
            } else {
                model.draft = nil
            }
        case .rectCorner(let id, _, _, let crop):
            guard let draft = model.draft, let rect = draft.first(where: { $0.id == id })?.rect else { model.draft = nil; return }
            if crop { model.setCrop(rect, name: "Crop") } else { model.commit(draft, name: "Resize", select: id) }
        case .movingCrop:
            guard let rect = model.cropAnnotation?.rect else { return }
            model.setCrop(rect, name: "Move Crop")
        case .idle, .ignored:
            break
        }
    }

    // MARK: Handles

    private func handlePoints(_ annotation: Annotation) -> [CGPoint] {
        switch annotation.kind {
        case .arrow(let a): return [a.start, ArrowGeometry.midpoint(a), a.end]
        case .text: return [CGPoint(x: annotation.bounds.maxX, y: annotation.bounds.maxY)]
        case .redaction(let r), .crop(let r): return RectGeometry.corners(r)
        case .shape(let s): return RectGeometry.corners(s.rect.standardized)
        case .stroke, .badge: return []
        }
    }

    private func handle(of annotation: Annotation, at p: CGPoint) -> DragState? {
        let near = { (h: CGPoint) in hypot(h.x - p.x, h.y - p.y) <= tolerance * 1.3 }
        switch annotation.kind {
        case .arrow(let a):
            if near(a.end) { return .arrowEnd(id: annotation.id, isStart: false, original: a) }
            if near(a.start) { return .arrowEnd(id: annotation.id, isStart: true, original: a) }
            if near(ArrowGeometry.midpoint(a)) { return .arrowBend(id: annotation.id, original: a) }
        case .text(let t):
            if near(CGPoint(x: annotation.bounds.maxX, y: annotation.bounds.maxY)) { return .textSize(id: annotation.id, original: t) }
        case .redaction(let r):
            if let corner = RectGeometry.corners(r).firstIndex(where: near) {
                return .rectCorner(id: annotation.id, corner: corner, original: r, crop: false)
            }
        case .shape(let s):
            if let corner = RectGeometry.corners(s.rect.standardized).firstIndex(where: near) {
                return .rectCorner(id: annotation.id, corner: corner, original: s.rect.standardized, crop: false)
            }
        case .crop, .stroke, .badge:
            break
        }
        return nil
    }

    private func drawSelection(_ annotation: Annotation, in context: inout GraphicsContext) {
        let accent = Color.accentColor
        if case .arrow = annotation.kind {} else {
            let b = annotation.bounds
            let rect = CGRect(x: b.minX * viewScale, y: b.minY * viewScale, width: b.width * viewScale, height: b.height * viewScale)
            context.stroke(Path(rect.insetBy(dx: -2, dy: -2)), with: .color(accent), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        for (index, h) in handlePoints(annotation).enumerated() {
            let c = CGPoint(x: h.x * viewScale, y: h.y * viewScale)
            let dot = Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10))
            // The arrow's middle handle bends it; it's filled so it reads apart from the ends.
            let isBend = { if case .arrow = annotation.kind { return index == 1 } else { return false } }()
            context.fill(dot, with: .color(isBend ? accent : .white))
            context.stroke(dot, with: .color(isBend ? .white : accent), lineWidth: 2)
        }
    }

    /// Dims everything outside the crop and outlines it; corner handles with the Crop tool.
    private func drawCrop(in context: inout GraphicsContext, size: CGSize) {
        guard let rect = model.cropAnnotation?.rect.flatMap({ RectGeometry.clamp($0, toImage: model.imageSize) }) else { return }
        let r = CGRect(x: rect.minX * viewScale, y: rect.minY * viewScale, width: rect.width * viewScale, height: rect.height * viewScale)
        var outside = Path(CGRect(origin: .zero, size: size))
        outside.addRect(r)
        context.fill(outside, with: .color(.black.opacity(model.tool == .crop ? 0.5 : 0.65)), style: FillStyle(eoFill: true))
        context.stroke(Path(r), with: .color(.white), style: StrokeStyle(lineWidth: 1.5, dash: model.tool == .crop ? [] : [5, 4]))
        guard model.tool == .crop else { return }
        for c in RectGeometry.corners(rect) {
            let p = CGPoint(x: c.x * viewScale, y: c.y * viewScale)
            let dot = Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
            context.fill(dot, with: .color(.white))
            context.stroke(dot, with: .color(.accentColor), lineWidth: 2)
        }
    }

    /// Transparent areas (window corners) show a light checkerboard, as in image editors.
    private func drawChecker(in context: inout GraphicsContext, size: CGSize) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.96)))
        let cell: CGFloat = 8
        var path = Path()
        for row in 0..<Int((size.height / cell).rounded(.up)) {
            for col in 0..<Int((size.width / cell).rounded(.up)) where (row + col).isMultiple(of: 2) {
                path.addRect(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
            }
        }
        context.fill(path, with: .color(Color(white: 0.88)))
    }

    // MARK: Text editing (AN-2)

    private var editingLabel: (label: TextLabel, frame: CGRect)? {
        guard let id = model.editingID, let item = model.annotations.first(where: { $0.id == id }),
              case .text(let label) = item.kind else { return nil }
        return (label, item.bounds)
    }

    private func textEditor(_ label: TextLabel) -> some View {
        let pad = TextLayout.padding(fontSize: label.fontSize) * viewScale
        let textColor = label.hasBackground ? label.color.contrasting : label.color
        return TextField("Text", text: Binding(get: { label.text }, set: { model.updateEditingText($0) }), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: label.fontSize * viewScale, weight: .bold))
            .foregroundStyle(Color(cgColor: textColor.cgColor))
            .fixedSize()
            .frame(minWidth: max(40, label.fontSize * viewScale * 2), alignment: .leading)
            .padding(pad)
            .background(
                RoundedRectangle(cornerRadius: pad)
                    .fill(label.hasBackground ? Color(cgColor: label.color.cgColor) : Color.clear)
            )
            .overlay(RoundedRectangle(cornerRadius: pad).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .focused($textFocused)
            .onSubmit { model.endEditing(); canvasFocused = true }
            .onChange(of: textFocused) { _, focused in
                if !focused, model.editingID != nil { model.endEditing() }
            }
            .onAppear { textFocused = true }
    }
}

// MARK: - Export bar (SX-1 to SX-3)

private struct ExportBar: View {
    @Bindable var model: ScreenshotEditorModel

    var body: some View {
        HStack(spacing: 12) {
            Image(decorative: model.image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 32)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.2)))
                .onDrag {
                    model.dragFile().flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
                }
                .help("Drag the image into another app or Finder")
                .accessibilityLabel("Drag image")

            Picker("Format", selection: $model.format) {
                ForEach(ScreenshotFormat.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if model.format == .jpeg {
                Slider(value: $model.jpegQuality, in: 0.3...1) { Text("Quality") }
                    .frame(width: 110)
                    .help("JPEG quality")
            }

            if model.pixelsPerPoint > 1 {
                Picker("Scale", selection: $model.scale) {
                    ForEach(ScreenshotScale.allCases) { Text($0 == .retina ? "2×" : "1×").tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("2× keeps full Retina detail; 1× halves the width and height")
            }

            Text(summary)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if let url = model.savedURL {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button("Copy") { model.copyToPasteboard() }
                .help("Copy the image with annotations (⌘C)")
            Button("Save") { model.save() }
                .buttonStyle(.borderedProminent)
                .help("Save to the Tinycap folder (⌘S)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var summary: String {
        let size = model.exportPixelSize
        let bytes = model.estimatedBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "…"
        return "\(size.width) × \(size.height) px · \(bytes)"
    }
}
