//
//  VisibilityPreferences.swift
//
//  Persists the user's choice to hide specific audio/video devices from
//  the menu and Touch Bar. Uses device names as stable keys.
//

import Foundation
import ServiceManagement

enum VisibilityPreferences {

    // MARK: - Audio

    private static let audioKey     = "\(AppIdentity.shortID).hidden.audio"
    private static let audioSeenKey = "\(AppIdentity.shortID).seen.audio"

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

    private static let airPlayKey = "\(AppIdentity.shortID).hidden.airplay"

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

    private static let autoConnectKey = "\(AppIdentity.shortID).behaviour.autoConnectSingle"

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

    private static let speechEnabledKey = "\(AppIdentity.shortID).behaviour.speechEnabled"

    /// When true (default), actions such as connecting AirPlay and toggling
    /// mirror/extend are announced via TTS. Set to false to silence all speech.
    static var speechEnabled: Bool {
        get {
            let val = UserDefaults.standard.object(forKey: speechEnabledKey)
            return val == nil ? true : UserDefaults.standard.bool(forKey: speechEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: speechEnabledKey) }
    }

    private static let touchBarFeedbackKey = "\(AppIdentity.shortID).behaviour.touchBarFeedback"

    /// When true (default), hotkeys show their feedback on the Touch Bar when one is available.
    static var touchBarFeedback: Bool {
        get {
            let val = UserDefaults.standard.object(forKey: touchBarFeedbackKey)
            return val == nil ? true : UserDefaults.standard.bool(forKey: touchBarFeedbackKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: touchBarFeedbackKey) }
    }

    private static let screenFeedbackKey = "\(AppIdentity.shortID).behaviour.screenFeedback"

    /// When true (default), hotkeys show their feedback on screen.
    static var screenFeedback: Bool {
        get {
            let val = UserDefaults.standard.object(forKey: screenFeedbackKey)
            return val == nil ? true : UserDefaults.standard.bool(forKey: screenFeedbackKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: screenFeedbackKey) }
    }

    private static let pickerStartsOnCurrentKey = "\(AppIdentity.shortID).behaviour.pickerStartsOnCurrent"

    /// When true (default), a hotkey picker opens on the current choice. When false it opens
    /// on the one after it, so a single press followed by the pause moves on.
    static var pickerStartsOnCurrent: Bool {
        get {
            let val = UserDefaults.standard.object(forKey: pickerStartsOnCurrentKey)
            return val == nil ? true : UserDefaults.standard.bool(forKey: pickerStartsOnCurrentKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: pickerStartsOnCurrentKey) }
    }

    private static let pickDelayKey = "\(AppIdentity.shortID).behaviour.pickDelay"
    static let pickDelayRange: ClosedRange<TimeInterval> = 0.5...10
    static let defaultPickDelay: TimeInterval = 2

    /// How long a hotkey picker waits after the last press before picking the tinted
    /// choice, in seconds, kept within `pickDelayRange`.
    static var pickDelay: TimeInterval {
        get {
            guard UserDefaults.standard.object(forKey: pickDelayKey) != nil else { return defaultPickDelay }
            return clampedPickDelay(UserDefaults.standard.double(forKey: pickDelayKey))
        }
        set { UserDefaults.standard.set(clampedPickDelay(newValue), forKey: pickDelayKey) }
    }

    static func clampedPickDelay(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultPickDelay }
        return min(max(value, pickDelayRange.lowerBound), pickDelayRange.upperBound)
    }

    private static let extraOfferDismissedKey = "\(AppIdentity.shortID).behaviour.screenMirroringExtraOfferDismissed"

    /// True once the user has declined, for good, the offer to show Control Center's
    /// Screen Mirroring item in the menu bar.
    static var screenMirroringExtraOfferDismissed: Bool {
        get { UserDefaults.standard.bool(forKey: extraOfferDismissedKey) }
        set { UserDefaults.standard.set(newValue, forKey: extraOfferDismissedKey) }
    }

    private static let autoHideVirtualAudioKey = "\(AppIdentity.shortID).behaviour.autoHideVirtualAudio"

    /// When true (default), virtual audio devices (Teams, Zoom, BlackHole, etc.)
    /// are automatically hidden on first discovery. The user can re-enable them
    /// in Settings at any time.
    static var autoHideVirtualAudio: Bool {
        get {
            let val = UserDefaults.standard.object(forKey: autoHideVirtualAudioKey)
            return val == nil ? true : UserDefaults.standard.bool(forKey: autoHideVirtualAudioKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoHideVirtualAudioKey) }
    }

    // MARK: - System

    /// Launch the app at login. Backed by SMAppService; UserDefaults is not used.
    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else        { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("\(AppIdentity.name): launch-at-login toggle failed: \(error)")
            }
        }
    }

    // MARK: - Virtual Display

    /// Distinguishes AirPlay destinations from wired external displays for
    /// per-context virtual-display settings.
    enum DisplayContext: String {
        case airPlay   = "airplay"
        case external  = "external"
        case builtIn   = "builtin"
    }

    /// Refresh rates (Hz) to expose on the virtual anchor display. Defaults to [60].
    static func virtualRefreshRates(for context: DisplayContext) -> Set<Int> {
        let key = "\(AppIdentity.shortID).virtual.\(context.rawValue).refreshRates"
        return Set((UserDefaults.standard.array(forKey: key) as? [Int]) ?? [60])
    }

    static func setVirtualRefreshRates(_ rates: Set<Int>, for context: DisplayContext) {
        let key = "\(AppIdentity.shortID).virtual.\(context.rawValue).refreshRates"
        UserDefaults.standard.set(Array(rates), forKey: key)
    }

    /// Every rate the virtual anchor advertises for `context`, highest first: the configured
    /// rates plus 60 Hz, which is always included (System Settings only shows its Refresh Rate
    /// dropdown when a resolution has at least two rates).
    static func effectiveVirtualRefreshRates(for context: DisplayContext) -> [Int] {
        virtualRefreshRates(for: context).union([60]).sorted(by: >)
    }

    /// Default virtual resolution stored as "WIDTHxHEIGHT", e.g. "3840x2160". Nil means no default.
    static func defaultVirtualResolution(for context: DisplayContext) -> String? {
        UserDefaults.standard.string(forKey: "\(AppIdentity.shortID).virtual.\(context.rawValue).defaultResolution")
    }

    static func setDefaultVirtualResolution(_ res: String?, for context: DisplayContext) {
        let key = "\(AppIdentity.shortID).virtual.\(context.rawValue).defaultResolution"
        if let v = res { UserDefaults.standard.set(v, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: - Sidecar

    private static let sidecarAloneKey = "\(AppIdentity.shortID).sidecar.virtualDisplayBacking"

    /// Whether a connected iPad gets a virtual display behind it, mirrored, so that it can be
    /// the Mac's only display. On by default.
    static var backsSidecarWithVirtualDisplay: Bool {
        get { UserDefaults.standard.object(forKey: sidecarAloneKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: sidecarAloneKey) }
    }

    private static let sidecarAutoConnectKey = "\(AppIdentity.shortID).sidecar.autoConnectWithoutDisplay"

    /// Whether an iPad plugged in over USB is connected over Sidecar when the Mac has no
    /// display of its own, including at login. Off by default.
    static var autoConnectsSidecarWithoutDisplay: Bool {
        get { UserDefaults.standard.bool(forKey: sidecarAutoConnectKey) }
        set { UserDefaults.standard.set(newValue, forKey: sidecarAutoConnectKey) }
    }

    /// The resolution last picked for an iPad's virtual display, as "WIDTHxHEIGHT" (logical),
    /// applied again when it reconnects. Nil means the iPad's own.
    static func sidecarResolution(for name: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: sidecarResolutionsKey) as? [String: String])?[name]
    }

    static func setSidecarResolution(_ res: String?, for name: String) {
        var all = (UserDefaults.standard.dictionary(forKey: sidecarResolutionsKey) as? [String: String]) ?? [:]
        all[name] = res
        UserDefaults.standard.set(all, forKey: sidecarResolutionsKey)
    }

    private static let sidecarResolutionsKey = "\(AppIdentity.shortID).sidecar.resolutions"

    // MARK: - Nicknames

    /// The kinds of device a nickname can be given to. Each keeps its own list, so equal
    /// names of different kinds don't share a nickname.
    enum NicknameKind: String {
        case display, audio, sidecar

        fileprivate var key: String {
            self == .display ? "\(AppIdentity.shortID).nicknames.displays"
                             : "\(AppIdentity.shortID).nicknames.\(rawValue)"
        }
    }

    /// Nicknames the user gave devices of `kind`, keyed by the device's own name.
    static func nicknames(_ kind: NicknameKind) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: kind.key) as? [String: String] ?? [:]
    }

    static func nickname(_ kind: NicknameKind, for name: String) -> String? {
        nicknames(kind)[name]
    }

    /// Sets the nickname for `name`; blank text removes it.
    static func setNickname(_ nickname: String?, _ kind: NicknameKind, for name: String) {
        var all = nicknames(kind)
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { all.removeValue(forKey: name) } else { all[name] = trimmed }
        UserDefaults.standard.set(all, forKey: kind.key)
    }

    // MARK: - Connected (physical) displays

    private static let displayKey = "\(AppIdentity.shortID).hidden.displays"

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
