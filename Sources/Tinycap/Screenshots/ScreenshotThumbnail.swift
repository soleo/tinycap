import AppKit
import TinycapCore

/// SS-4: a floating thumbnail in the corner of the screen right after a capture.
/// Click it to edit, drag it out to drop the file anywhere, or use Copy, Save or ✕.
/// Hovering pauses it. Left alone, it saves the screenshot and slides away, as macOS does.
@MainActor
final class ScreenshotThumbnailController {
    enum Outcome { case edit, saved, copied, dragged, discarded }

    private let shot: Screenshot
    private let model: ScreenshotEditorModel
    private let panel: ThumbnailPanel
    private var timer: Timer?
    private var finished = false
    private let onFinish: (ScreenshotThumbnailController, Outcome) -> Void

    init(_ shot: Screenshot, onFinish: @escaping (ScreenshotThumbnailController, Outcome) -> Void) {
        self.shot = shot
        self.onFinish = onFinish
        model = ScreenshotEditorModel(shot)

        let screen = NSScreen.withMouse ?? NSScreen.main ?? NSScreen.screens[0]
        let size = Self.size(for: shot)
        let visible = screen.visibleFrame
        let frame = CGRect(x: visible.maxX - size.width - 20, y: visible.minY + 20, width: size.width, height: size.height)
        panel = ThumbnailPanel(frame: frame)

        let view = ThumbnailView(frame: CGRect(origin: .zero, size: size), image: shot.image)
        view.onClick = { [weak self] in self?.finish(.edit) }
        view.onCopy = { [weak self] in
            guard let self else { return }
            self.model.copyToPasteboard()
            self.finish(.copied)
        }
        view.onSave = { [weak self] in self?.saveAndFinish() }
        view.onDiscard = { [weak self] in self?.finish(.discarded) }
        view.onHover = { [weak self] hovering in
            if hovering { self?.pause() } else { self?.restartTimer() }
        }
        view.dragFile = { [weak self] in self?.model.dragFile() }
        view.onDragEnded = { [weak self] delivered in
            if delivered { self?.finish(.dragged) } else { self?.restartTimer() }
        }
        panel.contentView = view
    }

    func show() {
        // Slide in from just off the right edge.
        let target = panel.frame
        panel.setFrame(target.offsetBy(dx: target.width + 40, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        restartTimer()
    }

    /// Ends this thumbnail now, saving it (used when the next screenshot arrives).
    func saveNow() {
        saveAndFinish()
    }

    // MARK: - Timer

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: ScreenshotSettings.thumbnailSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveAndFinish() }
        }
    }

    private func pause() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Finish

    private func saveAndFinish() {
        guard !finished else { return }
        model.save()
        if model.savedURL == nil {
            // Couldn't write the file: open the editor rather than lose the shot.
            finish(.edit)
            return
        }
        finish(.saved)
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        let panel = self.panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            panel.animator().setFrame(panel.frame.offsetBy(dx: outcome == .saved ? panel.frame.width + 40 : 0, dy: 0), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
        onFinish(self, outcome)
    }

    var screenshot: Screenshot { shot }

    /// Fits the image in 240 × 170 points, keeping its shape.
    private static func size(for shot: Screenshot) -> CGSize {
        let w = Double(shot.image.width), h = Double(shot.image.height)
        let scale = min(240 / w, 170 / h, 1)
        return CGSize(width: max(90, (w * scale).rounded()), height: max(60, (h * scale).rounded()))
    }
}

/// Floats above normal windows on every Space; never takes focus.
private final class ThumbnailPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
}

/// The image with rounded corners; Copy, Save and ✕ appear on hover. A click edits, a
/// drag hands the file to wherever it's dropped.
private final class ThumbnailView: NSView, NSDraggingSource {
    var onClick: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var dragFile: (() -> URL?)?
    var onDragEnded: ((Bool) -> Void)?

    private let image: CGImage
    private let buttons = NSStackView()
    private let discard: NSButton
    private var mouseDownPoint: CGPoint?
    private var dragging = false

    init(frame: CGRect, image: CGImage) {
        self.image = image
        discard = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Discard")!, target: nil, action: nil)
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor

        let copy = Self.pill("Copy", action: #selector(copyClicked), target: self)
        let save = Self.pill("Save", action: #selector(saveClicked), target: self)
        buttons.setViews([copy, save], in: .center)
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.isHidden = true
        addSubview(buttons)

        discard.target = self
        discard.action = #selector(discardClicked)
        discard.bezelStyle = .circular
        discard.controlSize = .small
        discard.toolTip = "Discard"
        discard.translatesAutoresizingMaskIntoConstraints = false
        discard.isHidden = true
        addSubview(discard)

        NSLayoutConstraint.activate([
            buttons.centerXAnchor.constraint(equalTo: centerXAnchor),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            discard.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            discard.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Screenshot thumbnail. Click to edit, drag to move the file.")
        toolTip = "Click to edit · drag to drop the file"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func pill(_ title: String, action: Selector, target: AnyObject) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .push
        button.controlSize = .small
        return button
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        if !buttons.isHidden {
            NSColor.black.withAlphaComponent(0.25).setFill()
            bounds.fill(using: .sourceOver)
        }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { if !dragging { setHovering(false) } }

    private func setHovering(_ hovering: Bool) {
        buttons.isHidden = !hovering
        discard.isHidden = !hovering
        needsDisplay = true
        onHover?(hovering)
    }

    // MARK: Click and drag

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !dragging else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4, let url = dragFile?() else { return }
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let preview = NSImage(cgImage: image, size: bounds.size)
        item.setDraggingFrame(bounds, contents: preview)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard !dragging, mouseDownPoint != nil else { return }
        onClick?()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        mouseDownPoint = nil
        onDragEnded?(!operation.isEmpty)
    }

    @objc private func copyClicked() { onCopy?() }
    @objc private func saveClicked() { onSave?() }
    @objc private func discardClicked() { onDiscard?() }
}
