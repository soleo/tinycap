import AppKit

/// Pixel-art menu-bar glyph derived from the app icon: capture corner brackets around
/// a window with a title bar and a dot. Drawn as a template so it follows the menu bar.
enum MenuBarIcon {
    private static let pixels = [
        "####..........####",
        "#................#",
        "#................#",
        "#..############..#",
        "...############...",
        "...############...",
        "...#..........#...",
        "...#..........#...",
        "...#....##....#...",
        "...#...####...#...",
        "...#...####...#...",
        "...#....##....#...",
        "...#..........#...",
        "...############...",
        "#................#",
        "#................#",
        "#................#",
        "####..........####",
    ]

    static let idle = glyph(badge: false)

    /// UP-2: the same glyph with a small dot at the top right when an update is available.
    static let idleWithUpdate = glyph(badge: true)

    private static func glyph(badge: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            for (y, row) in pixels.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    NSRect(x: x, y: y, width: 1, height: 1).fill()
                }
            }
            if badge {
                // Clear a ring around the dot so it reads apart from the corner bracket.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: 11, y: -1, width: 8, height: 8)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: NSRect(x: 12.5, y: 0.5, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = badge ? "Tinycap, update available" : "Tinycap"
        return image
    }

    /// Red square "record" dot shown next to the elapsed time while recording.
    static let recording: NSImage = {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
        image.accessibilityDescription = "Recording"
        return image
    }()
}
