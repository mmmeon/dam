//
//  HotkeyPreference.swift
//

import AppKit
import Carbon.HIToolbox

struct HotkeyPreference: Codable, Equatable {

    var keyCode:  UInt32   // Carbon virtual key code
    var modifiers: UInt32  // Carbon modifier mask

    // MARK: - Defaults

    /// Default shortcut for opening the audio/display switcher (⌃⌥⌘B).
    static let `default` = HotkeyPreference(
        keyCode:   UInt32(kVK_ANSI_B),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    /// Default shortcut for AirPlay Quick Connect (⌃⌥⌘A).
    static let defaultAirPlayConnect = HotkeyPreference(
        keyCode:   UInt32(kVK_ANSI_A),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    /// Default shortcut for toggling mirror / extend on the AirPlay display (⌃⌥⌘M).
    static let defaultMirrorToggle = HotkeyPreference(
        keyCode:   UInt32(kVK_ANSI_M),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    /// Default shortcut for cycling through the enabled audio outputs (⌃⌥⌘O).
    static let defaultAudioCycle = HotkeyPreference(
        keyCode:   UInt32(kVK_ANSI_O),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    /// Default shortcut for choosing the main display (⌃⌥⌘D).
    static let defaultMainDisplay = HotkeyPreference(
        keyCode:   UInt32(kVK_ANSI_D),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    // MARK: - Persistence

    private static let defaultsKey               = "\(AppIdentity.bundleID).hotkey"
    private static let airPlayConnectDefaultsKey  = "\(AppIdentity.bundleID).hotkeyAirPlayConnect"
    private static let mirrorToggleDefaultsKey    = "\(AppIdentity.bundleID).hotkeyMirrorToggle"
    private static let audioCycleDefaultsKey      = "\(AppIdentity.bundleID).hotkeyAudioCycle"
    private static let mainDisplayDefaultsKey     = "\(AppIdentity.bundleID).hotkeyMainDisplay"

    static var current: HotkeyPreference {
        get { load(defaultsKey, fallback: .default) }
        set { store(newValue, defaultsKey) }
    }

    static var currentAirPlayConnect: HotkeyPreference {
        get { load(airPlayConnectDefaultsKey, fallback: .defaultAirPlayConnect) }
        set { store(newValue, airPlayConnectDefaultsKey) }
    }

    static var currentMirrorToggle: HotkeyPreference {
        get { load(mirrorToggleDefaultsKey, fallback: .defaultMirrorToggle) }
        set { store(newValue, mirrorToggleDefaultsKey) }
    }

    static var currentAudioCycle: HotkeyPreference {
        get { load(audioCycleDefaultsKey, fallback: .defaultAudioCycle) }
        set { store(newValue, audioCycleDefaultsKey) }
    }

    static var currentMainDisplay: HotkeyPreference {
        get { load(mainDisplayDefaultsKey, fallback: .defaultMainDisplay) }
        set { store(newValue, mainDisplayDefaultsKey) }
    }

    private static func load(_ key: String, fallback: HotkeyPreference) -> HotkeyPreference {
        guard let data = UserDefaults.standard.data(forKey: key),
              let pref = try? JSONDecoder().decode(HotkeyPreference.self, from: data)
        else { return fallback }
        return pref
    }

    private static func store(_ pref: HotkeyPreference, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(pref), forKey: key)
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
