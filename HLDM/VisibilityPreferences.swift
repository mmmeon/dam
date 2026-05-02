//
//  VisibilityPreferences.swift
//  boar
//
//  Persists the user's choice to hide specific audio/video devices from
//  the menu and Touch Bar. Uses device names as stable keys.
//

import Foundation

enum VisibilityPreferences {

    // MARK: - Audio

    private static let audioKey     = "hldm.hidden.audio"
    private static let audioSeenKey = "hldm.seen.audio"

    static var hiddenAudioDevices: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: audioKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: audioKey) }
    }

    /// Every audio device name ever observed. Used to auto-hide virtual devices
    /// only on their first discovery, without re-hiding them if the user later
    /// enables them manually.
    static var seenAudioDevices: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: audioSeenKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: audioSeenKey) }
    }

    static func isVisible(audioDevice name: String) -> Bool {
        !hiddenAudioDevices.contains(name)
    }

    static func setVisible(_ visible: Bool, audioDevice name: String) {
        var s = hiddenAudioDevices
        if visible { s.remove(name) } else { s.insert(name) }
        hiddenAudioDevices = s
    }

    // MARK: - AirPlay displays

    private static let airPlayKey = "hldm.hidden.airplay"

    static var hiddenAirPlayDevices: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: airPlayKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: airPlayKey) }
    }

    static func isVisible(airPlayDevice name: String) -> Bool {
        !hiddenAirPlayDevices.contains(name)
    }

    static func setVisible(_ visible: Bool, airPlayDevice name: String) {
        var s = hiddenAirPlayDevices
        if visible { s.remove(name) } else { s.insert(name) }
        hiddenAirPlayDevices = s
    }

    // MARK: - Behaviour

    private static let autoConnectKey = "hldm.behaviour.autoConnectSingle"

    /// When true (default), pressing the AirPlay Connect hotkey with exactly one
    /// visible AirPlay display skips the selection list and goes straight to the
    /// confirmation / TTS step. When false the selection list is always shown.
    static var autoConnectSingleDisplay: Bool {
        get {
            let val = UserDefaults.standard.object(forKey: autoConnectKey)
            return val == nil ? true : UserDefaults.standard.bool(forKey: autoConnectKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoConnectKey) }
    }

    // MARK: - Connected (physical) displays

    private static let displayKey = "hldm.hidden.displays"

    static var hiddenDisplays: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: displayKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: displayKey) }
    }

    static func isVisible(display name: String) -> Bool {
        !hiddenDisplays.contains(name)
    }

    static func setVisible(_ visible: Bool, display name: String) {
        var s = hiddenDisplays
        if visible { s.remove(name) } else { s.insert(name) }
        hiddenDisplays = s
    }
}
