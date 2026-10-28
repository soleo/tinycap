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

    static let idle: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            for (y, row) in pixels.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    NSRect(x: x, y: y, width: 1, height: 1).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Tinycap"
        return image
    }()

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
