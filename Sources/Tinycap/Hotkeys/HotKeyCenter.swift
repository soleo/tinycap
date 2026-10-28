import AppKit
import Carbon.HIToolbox

struct HotKey: Equatable {
    let keyCode: UInt32
    let modifiers: NSEvent.ModifierFlags
    let keyEquivalent: String

    /// "⌃⌥⌘A"
    var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + keyEquivalent.uppercased()
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }
}

/// Global shortcuts. Fixed defaults for now; editing them in Settings comes with M2.
enum Shortcut: CaseIterable {
    case recordArea, recordWindow, recordScreen, stop

    var hotKey: HotKey {
        let mods: NSEvent.ModifierFlags = [.control, .option, .command]
        switch self {
        case .recordArea: return HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: mods, keyEquivalent: "a")
        case .recordWindow: return HotKey(keyCode: UInt32(kVK_ANSI_W), modifiers: mods, keyEquivalent: "w")
        case .recordScreen: return HotKey(keyCode: UInt32(kVK_ANSI_S), modifiers: mods, keyEquivalent: "s")
        case .stop: return HotKey(keyCode: UInt32(kVK_ANSI_Period), modifiers: mods, keyEquivalent: ".")
        }
    }

    var title: String {
        switch self {
        case .recordArea: return "Record Area"
        case .recordWindow: return "Record Window"
        case .recordScreen: return "Record Screen"
        case .stop: return "Stop Recording"
        }
    }
}

/// Registers system-wide hotkeys with Carbon's RegisterEventHotKey, which works in the
/// App Sandbox and needs no Accessibility permission.
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

    func register(_ hotKey: HotKey, action: @escaping () -> Void) {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotKey.keyCode, hotKey.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            NSLog("Tinycap: could not register hotkey %@ (status %d)", hotKey.displayString, status)
            return
        }
        refs[id] = ref
        actions[id] = action
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
