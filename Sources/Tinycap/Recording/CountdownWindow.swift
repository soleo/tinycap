import AppKit

/// A 3-2-1 countdown shown over the capture target before recording starts.
/// Esc cancels. The panel is gone before capture begins, so it never shows in the video.
@MainActor
final class CountdownController {
    private var panel: CountdownPanel?
    private var continuation: CheckedContinuation<Bool, Never>?

    /// Counts down from `seconds`, centered on `rect` (AppKit global coordinates).
    /// Returns false if the user cancelled.
    func run(over rect: CGRect, seconds: Int = 3) async -> Bool {
        let size = CGSize(width: 160, height: 160)
        let frame = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        let panel = CountdownPanel(frame: frame)
        panel.onCancel = { [weak self] in self?.finish(false) }
        self.panel = panel

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            Task { [weak self] in
                for n in stride(from: seconds, through: 1, by: -1) {
                    guard let self, self.continuation != nil else { return }
                    panel.show(n)
                    try? await Task.sleep(for: .seconds(1))
                }
                self?.finish(true)
            }
        }
    }

    private func finish(_ completed: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        panel?.orderOut(nil)
        panel = nil
        continuation.resume(returning: completed)
    }
}

private final class CountdownPanel: NSPanel {
    var onCancel: (() -> Void)?
    private let label = NSTextField(labelWithString: "")

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSVisualEffectView(frame: CGRect(origin: .zero, size: frame.size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 28
        background.layer?.masksToBounds = true

        label.font = .monospacedDigitSystemFont(ofSize: 88, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "Esc to cancel")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(label)
        background.addSubview(hint)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor, constant: 6),
            hint.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
        ])
        contentView = background
    }

    override var canBecomeKey: Bool { true }

    func show(_ n: Int) {
        label.stringValue = "\(n)"
        setAccessibilityLabel("Recording starts in \(n)")
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: "\(n)", .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == OverlayKey.escape { onCancel?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
