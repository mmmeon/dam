//
//  HotkeyPreference.swift
//  boar
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

    // MARK: - Persistence

    private static let defaultsKey               = "mmmeon.hldm.hotkey"
    private static let airPlayConnectDefaultsKey  = "mmmeon.hldm.hotkeyAirPlayConnect"
    private static let mirrorToggleDefaultsKey    = "mmmeon.hldm.hotkeyMirrorToggle"

    static var current: HotkeyPreference {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let pref = try? JSONDecoder().decode(HotkeyPreference.self, from: data)
            else { return .default }
            return pref
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue),
                                      forKey: defaultsKey)
        }
    }

    static var currentAirPlayConnect: HotkeyPreference {
        get {
            guard let data = UserDefaults.standard.data(forKey: airPlayConnectDefaultsKey),
                  let pref = try? JSONDecoder().decode(HotkeyPreference.self, from: data)
            else { return .defaultAirPlayConnect }
            return pref
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue),
                                      forKey: airPlayConnectDefaultsKey)
        }
    }

    static var currentMirrorToggle: HotkeyPreference {
        get {
            guard let data = UserDefaults.standard.data(forKey: mirrorToggleDefaultsKey),
                  let pref = try? JSONDecoder().decode(HotkeyPreference.self, from: data)
            else { return .defaultMirrorToggle }
            return pref
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue),
                                      forKey: mirrorToggleDefaultsKey)
        }
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
