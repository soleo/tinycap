import AppKit

/// Borderless, transparent panel covering one display, used by all selection modes.
final class OverlayPanel: NSPanel {
    let screenFrame: CGRect

    init(screen: NSScreen) {
        screenFrame = screen.frame
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static var withMouse: NSScreen? {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) }
    }

    /// Height of the display that holds the menu bar; the reference for flipping
    /// Core Graphics coordinates into AppKit ones.
    static var primaryHeight: CGFloat { screens.first?.frame.height ?? 0 }
}

/// Esc / Return handling shared by the overlay views.
enum OverlayKey {
    static let escape: UInt16 = 53
    static let returnKey: UInt16 = 36
    static let enter: UInt16 = 76
}

/// Draws a small rounded label, used for sizes and hints on overlays.
enum OverlayLabel {
    static func draw(_ text: String, centeredAt center: CGPoint? = nil, origin: CGPoint? = nil, in bounds: CGRect, fontSize: CGFloat = 12) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attrs)
        let size = string.size()
        let pad = CGSize(width: 8, height: 4)
        var box = CGRect(x: 0, y: 0, width: size.width + pad.width * 2, height: size.height + pad.height * 2)
        if let center {
            box.origin = CGPoint(x: center.x - box.width / 2, y: center.y - box.height / 2)
        } else if let origin {
            box.origin = origin
        }
        box.origin.x = min(max(box.minX, bounds.minX + 4), bounds.maxX - box.width - 4)
        box.origin.y = min(max(box.minY, bounds.minY + 4), bounds.maxY - box.height - 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        string.draw(at: CGPoint(x: box.minX + pad.width, y: box.minY + pad.height))
    }
}
