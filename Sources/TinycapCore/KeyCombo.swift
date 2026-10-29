import Foundation

/// A global shortcut as stored in preferences. Modifier bits are Tinycap's own, so this
/// type has no AppKit or Carbon dependency.
public struct KeyCombo: Codable, Sendable, Hashable {
    public struct Modifiers: OptionSet, Codable, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    /// Virtual key code (kVK_*).
    public let keyCode: UInt32
    public let modifiers: Modifiers
    /// What the key shows as, e.g. "A", "Space", "F5". Captured when recorded.
    public let keyName: String

    public init(keyCode: UInt32, modifiers: Modifiers, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    /// "⌃⌥⌘A" in Apple's modifier order.
    public var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + keyName
    }

    /// Global shortcuts need ⌘, ⌃ or ⌥; Shift alone would swallow normal typing.
    /// Function keys (F1–F20) may stand alone.
    public var isValidGlobalShortcut: Bool {
        !modifiers.intersection([.command, .control, .option]).isEmpty || Self.functionKeyCodes.contains(keyCode)
    }

    /// kVK_F1…kVK_F20.
    static let functionKeyCodes: Set<UInt32> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
        0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
    ]
}

public enum ShortcutAction: String, CaseIterable, Sendable, Codable {
    case screenshotArea, recordArea, recordWindow, recordScreen, stop

    public var title: String {
        switch self {
        case .screenshotArea: return "Screenshot Area"
        case .recordArea: return "Record Area"
        case .recordWindow: return "Record Window"
        case .recordScreen: return "Record Screen"
        case .stop: return "Stop Recording"
        }
    }

    public var defaultsKey: String { "shortcut.\(rawValue)" }

    /// ⌃⌥⌘4 for a screenshot (like ⇧⌘4), ⌃⌥⌘A / W / S / period for recording.
    public var defaultCombo: KeyCombo {
        let mods: KeyCombo.Modifiers = [.control, .option, .command]
        switch self {
        case .screenshotArea: return KeyCombo(keyCode: 0x15, modifiers: mods, keyName: "4")
        case .recordArea: return KeyCombo(keyCode: 0x00, modifiers: mods, keyName: "A")
        case .recordWindow: return KeyCombo(keyCode: 0x0D, modifiers: mods, keyName: "W")
        case .recordScreen: return KeyCombo(keyCode: 0x01, modifiers: mods, keyName: "S")
        case .stop: return KeyCombo(keyCode: 0x2F, modifiers: mods, keyName: ".")
        }
    }
}

/// Reads and writes shortcuts. A missing value means the default; an explicit
/// "none" entry means the user cleared it.
public struct ShortcutStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private static let clearedMarker = Data("none".utf8)

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func combo(for action: ShortcutAction) -> KeyCombo? {
        guard let data = defaults.data(forKey: action.defaultsKey) else { return action.defaultCombo }
        if data == Self.clearedMarker { return nil }
        return (try? JSONDecoder().decode(KeyCombo.self, from: data)) ?? action.defaultCombo
    }

    public func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        if let combo, let data = try? JSONEncoder().encode(combo) {
            defaults.set(data, forKey: action.defaultsKey)
        } else {
            defaults.set(Self.clearedMarker, forKey: action.defaultsKey)
        }
    }

    public func resetAll() {
        ShortcutAction.allCases.forEach { defaults.removeObject(forKey: $0.defaultsKey) }
    }

    /// Another action already using `combo`, if any.
    public func conflict(for combo: KeyCombo, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { other in
            other != action && self.combo(for: other).map { $0.keyCode == combo.keyCode && $0.modifiers == combo.modifiers } == true
        }
    }
}
