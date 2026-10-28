import AppKit
import Carbon.HIToolbox
import Observation
import TinycapCore

extension KeyCombo {
    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    var eventModifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { f.insert(.control) }
        if modifiers.contains(.option) { f.insert(.option) }
        if modifiers.contains(.shift) { f.insert(.shift) }
        if modifiers.contains(.command) { f.insert(.command) }
        return f
    }

    /// Menu key equivalent, when the key is a single printable character.
    var menuKeyEquivalent: String? {
        keyName.count == 1 ? keyName.lowercased() : nil
    }

    /// Builds a combo from a key press in the shortcut recorder.
    init(event: NSEvent) {
        var mods: Modifiers = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.command) { mods.insert(.command) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods, keyName: KeyName.name(for: event))
    }
}

enum KeyName {
    private static let special: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    static func name(for event: NSEvent) -> String {
        if let name = special[Int(event.keyCode)] { return name }
        let chars = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return chars.isEmpty ? "Key \(event.keyCode)" : chars.uppercased()
    }
}

/// Registers the user's global shortcuts with Carbon's RegisterEventHotKey, which works
/// in the App Sandbox and needs no Accessibility permission.
@MainActor
@Observable
final class ShortcutManager {
    static let shared = ShortcutManager()

    /// Actions whose shortcut another app already holds.
    private(set) var unavailable: Set<ShortcutAction> = []
    /// Bumped on every change so views reading `combo(for:)` refresh.
    private(set) var revision = 0

    @ObservationIgnored var handler: ((ShortcutAction) -> Void)?
    @ObservationIgnored let store = ShortcutStore(defaults: .standard)
    @ObservationIgnored private let center = HotKeyCenter()
    @ObservationIgnored private var suspended = false

    func combo(for action: ShortcutAction) -> KeyCombo? {
        _ = revision
        return store.combo(for: action)
    }

    func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        store.set(combo, for: action)
        reload()
    }

    func resetAll() {
        store.resetAll()
        reload()
    }

    /// Stops global shortcuts while the recorder in Settings is listening, so pressing an
    /// existing combo records it instead of starting a capture.
    func suspend() {
        suspended = true
        center.unregisterAll()
    }

    func resume() {
        suspended = false
        reload()
    }

    func reload() {
        revision += 1
        center.unregisterAll()
        guard !suspended else { return }
        var failed: Set<ShortcutAction> = []
        for action in ShortcutAction.allCases {
            guard let combo = store.combo(for: action) else { continue }
            let ok = center.register(keyCode: combo.keyCode, modifiers: combo.carbonModifiers) { [weak self] in
                self?.handler?(action)
            }
            if !ok { failed.insert(action) }
        }
        unavailable = failed
    }
}

@MainActor
final class HotKeyCenter {
    private static let signature: OSType = 0x5443_4150 // "TCAP"

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            guard status == noErr else { return status }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers hotkey events on the main thread's event loop.
            MainActor.assumeIsolated { center.fire(id.id) }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &spec,
            Unmanaged.passUnretained(self).toOpaque(), &handler
        )
    }

    /// Returns false when the combo can't be registered (usually taken by another app).
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        actions[id] = action
        return true
    }

    func unregisterAll() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    private func fire(_ id: UInt32) {
        actions[id]?()
    }
}
