//
//  HotkeyPreference.swift
//

import AppKit
import Carbon.HIToolbox

/// The app's shortcuts: what each is called in Settings, where it is stored and what it
/// starts as. Settings lists them in this order.
enum HotkeyAction: CaseIterable {
    case switcher, airPlayConnect, mirrorToggle, audioCycle, mainDisplay, resolution, rotation

    /// The shortcut set for this action, or its default when none is.
    var shortcut: HotkeyPreference {
        get {
            guard let data = UserDefaults.dam.data(forKey: defaultsKey),
                  let pref = try? JSONDecoder().decode(HotkeyPreference.self, from: data)
            else { return defaultShortcut }
            return pref
        }
        nonmutating set { UserDefaults.dam.set(try? JSONEncoder().encode(newValue), forKey: defaultsKey) }
    }

    /// Where the shortcut is stored; the keys predate this enum, so they stay as they were.
    var defaultsKey: String {
        switch self {
        case .switcher:       return "\(AppIdentity.bundleID).hotkey"
        case .airPlayConnect: return "\(AppIdentity.bundleID).hotkeyAirPlayConnect"
        case .mirrorToggle:   return "\(AppIdentity.bundleID).hotkeyMirrorToggle"
        case .audioCycle:     return "\(AppIdentity.bundleID).hotkeyAudioCycle"
        case .mainDisplay:    return "\(AppIdentity.bundleID).hotkeyMainDisplay"
        case .resolution:     return "\(AppIdentity.bundleID).hotkeyResolution"
        case .rotation:       return "\(AppIdentity.bundleID).hotkeyRotation"
        }
    }

    /// ⌃⌥⌘ and a letter: B, A, M, O, D, R and T.
    var defaultShortcut: HotkeyPreference {
        let key: Int
        switch self {
        case .switcher:       key = kVK_ANSI_B
        case .airPlayConnect: key = kVK_ANSI_A
        case .mirrorToggle:   key = kVK_ANSI_M
        case .audioCycle:     key = kVK_ANSI_O
        case .mainDisplay:    key = kVK_ANSI_D
        case .resolution:     key = kVK_ANSI_R
        case .rotation:       key = kVK_ANSI_T
        }
        return HotkeyPreference(keyCode: UInt32(key), modifiers: UInt32(controlKey | optionKey | cmdKey))
    }

    /// Its name in Settings, and in another's clash.
    var title: String {
        switch self {
        case .switcher:       return "Switcher"
        case .airPlayConnect: return "Quick Connect"
        case .mirrorToggle:   return "Mirror / Extend"
        case .audioCycle:     return "Cycle Audio"
        case .mainDisplay:    return "Main Display"
        case .resolution:     return "Resolution"
        case .rotation:       return "Rotation"
        }
    }

    /// What it does, as Settings tells it.
    var help: String {
        switch self {
        case .switcher:
            return "Opens the Touch Bar switcher for the audio output and AirPlay display. " +
                   "Without a Touch Bar (or with the lid closed) it opens the menu bar menu."
        case .airPlayConnect:
            return "Connects to an AirPlay display or an iPad (Sidecar) from any " +
                   "application, even with no display attached."
        case .mirrorToggle:
            return "Picks where the connected AirPlay display is mirrored: nowhere, " +
                   "on one of the other displays, or on all of them."
        case .audioCycle:
            return "Picks an audio output among those checked on the Devices tab."
        case .mainDisplay:
            return "Picks the display that has the menu bar."
        case .resolution:
            return "Picks a resolution for the display under the pointer."
        case .rotation:
            return "Turns the display under the pointer, where macOS allows it, or a " +
                   "streaming display, whose streams keep their shape."
        }
    }
}

struct HotkeyPreference: Codable, Equatable {

    var keyCode:  UInt32   // Carbon virtual key code
    var modifiers: UInt32  // Carbon modifier mask

    // MARK: - Clashes

    /// For each of `shortcuts`, the indices of the others set to the same keys. Only one of
    /// those can be registered.
    static func clashes(among shortcuts: [HotkeyPreference]) -> [[Int]] {
        shortcuts.indices.map { i in shortcuts.indices.filter { $0 != i && shortcuts[$0] == shortcuts[i] } }
    }

    // MARK: - Display

    /// e.g. "⌃⌥⌘B"
    var displayString: String { modifierString + keyString }

    /// Modifier symbols in standard macOS order: ⌃ ⌥ ⇧ ⌘
    var modifierString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s
    }

    /// Localized key name via UCKeyTranslate (respects current keyboard layout).
    var keyString: String {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let rawPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return fallbackKeyName
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawPtr).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { buf -> String in
            guard let layout = buf.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return fallbackKeyName
            }
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var len = 0
            let err = UCKeyTranslate(layout, UInt16(keyCode),
                                     UInt16(kUCKeyActionDisplay), 0,
                                     UInt32(LMGetKbdType()),
                                     OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                     &dead, 4, &len, &chars)
            guard err == noErr, len > 0 else { return fallbackKeyName }
            return String(utf16CodeUnits: Array(chars.prefix(len)), count: len).uppercased()
        }
    }

    private var fallbackKeyName: String { "(\(keyCode))" }
}

// MARK: - NSEvent helper

extension NSEvent.ModifierFlags {
    /// Converts AppKit modifier flags to a Carbon modifier mask.
    var carbonFlags: UInt32 {
        var result: UInt32 = 0
        if contains(.control) { result |= UInt32(controlKey) }
        if contains(.option)  { result |= UInt32(optionKey)  }
        if contains(.shift)   { result |= UInt32(shiftKey)   }
        if contains(.command) { result |= UInt32(cmdKey)     }
        return result
    }
}
