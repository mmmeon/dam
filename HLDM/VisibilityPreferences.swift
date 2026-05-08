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

    // MARK: - Virtual Display

    /// Distinguishes AirPlay destinations from wired external displays for
    /// per-context virtual-display settings.
    enum DisplayContext: String {
        case airPlay   = "airplay"
        case external  = "external"
    }

    /// Refresh rates (Hz) to expose on the virtual anchor display. Defaults to [60].
    static func virtualRefreshRates(for context: DisplayContext) -> Set<Int> {
        let key = "hldm.virtual.\(context.rawValue).refreshRates"
        return Set((UserDefaults.standard.array(forKey: key) as? [Int]) ?? [60])
    }

    static func setVirtualRefreshRates(_ rates: Set<Int>, for context: DisplayContext) {
        let key = "hldm.virtual.\(context.rawValue).refreshRates"
        UserDefaults.standard.set(Array(rates), forKey: key)
    }

    /// Default virtual resolution stored as "WIDTHxHEIGHT", e.g. "3840x2160". Nil means no default.
    static func defaultVirtualResolution(for context: DisplayContext) -> String? {
        UserDefaults.standard.string(forKey: "hldm.virtual.\(context.rawValue).defaultResolution")
    }

    static func setDefaultVirtualResolution(_ res: String?, for context: DisplayContext) {
        let key = "hldm.virtual.\(context.rawValue).defaultResolution"
        if let v = res { UserDefaults.standard.set(v, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// Aspect ratio used to decide whether to show compact "HEIGHTp" labels in the Touch Bar.
    /// Stored as "W:H", e.g. "16:9". Defaults to 16:9.
    static var defaultAspectRatio: (w: Int, h: Int) {
        get {
            let stored = UserDefaults.standard.string(forKey: "hldm.display.aspectRatio") ?? "16:9"
            let parts = stored.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return (16, 9) }
            return (parts[0], parts[1])
        }
        set { UserDefaults.standard.set("\(newValue.w):\(newValue.h)", forKey: "hldm.display.aspectRatio") }
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
