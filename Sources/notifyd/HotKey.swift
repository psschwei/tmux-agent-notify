import AppKit
import Carbon.HIToolbox
import NotifyCore

/// Translates a `Config.Hotkey` (strings) into Carbon's (keyCode, modifiers).
/// Returns nil for an unknown key name so the caller can fall back to default.
enum HotKeySpec {
    static func resolve(_ h: Config.Hotkey) -> (keyCode: UInt32, modifiers: UInt32)? {
        guard let code = keyCode(for: h.key) else { return nil }
        var mods: UInt32 = 0
        for m in h.modifiers {
            switch m.lowercased() {
            case "cmd", "command":        mods |= UInt32(cmdKey)
            case "option", "alt", "opt":  mods |= UInt32(optionKey)
            case "control", "ctrl":       mods |= UInt32(controlKey)
            case "shift":                 mods |= UInt32(shiftKey)
            default:                      break
            }
        }
        guard mods != 0 else { return nil }   // require at least one modifier
        return (code, mods)
    }

    /// Map a one-character key (or a few named keys) to a virtual key code.
    private static func keyCode(for key: String) -> UInt32? {
        let k = key.lowercased()
        switch k {
        case "space", " ": return UInt32(kVK_Space)
        case "return", "enter": return UInt32(kVK_Return)
        default: break
        }
        let letters: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
            "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        ]
        return letters[k].map(UInt32.init)
    }
}

/// A single system-wide hotkey via Carbon's `RegisterEventHotKey`.
///
/// Carbon hotkeys are the dependency-free path that works for an LSUIElement
/// agent and — crucially — needs NO Accessibility permission (unlike a
/// CGEventTap global monitor). NSApplication's run loop dispatches the events,
/// so no extra thread is required.
@MainActor
final class HotKey {
    // C pointers owned by Carbon; safe to release from a nonisolated deinit.
    private nonisolated(unsafe) var ref: EventHotKeyRef?
    private nonisolated(unsafe) var handler: EventHandlerRef?
    private let onPressed: @MainActor () -> Void
    private let id = EventHotKeyID(signature: OSType(0x544D5831 /* 'TMX1' */), id: 1)

    /// `keyCode` is a virtual key code (e.g. `kVK_ANSI_J`); `modifiers` are
    /// Carbon flags (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    init(keyCode: UInt32, modifiers: UInt32, onPressed: @escaping @MainActor () -> Void) {
        self.onPressed = onPressed
        install(keyCode: keyCode, modifiers: modifiers)
    }

    private func install(keyCode: UInt32, modifiers: UInt32) {
        // Install the handler for hotkey-pressed events on the app event target.
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            // Match our hotkey id, then fire on the main actor.
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard let userData else { return noErr }
            let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            if hkID.id == me.id.id {
                MainActor.assumeIsolated { me.onPressed() }
            }
            return noErr
        }, 1, &spec, selfPtr, &handler)

        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
