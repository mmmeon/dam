//
//  VisibilityPreferences.swift
//
//  Persists the user's choice to hide specific audio/video devices from
//  the menu and Touch Bar. Uses device names as stable keys.
//

import Foundation
import ServiceManagement

extension UserDefaults {
    /// Where DAM keeps its preferences. Under tests it's a store of their own, so tests
    /// neither see nor change the user's settings. Each test process gets its own, as tests
    /// run in parallel processes; it starts empty.
    static let dam: UserDefaults = {
        guard NSClassFromString("XCTestCase") != nil else { return .standard }
        removeStaleTestSuites()
        UserDefaults.standard.removePersistentDomain(forName: testSuite)
        return UserDefaults(suiteName: testSuite)!
    }()

    private static let testSuitePrefix = "\(AppIdentity.shortID).tests."
    private static let testSuite = testSuitePrefix + "\(getpid())"

    /// Test processes are killed rather than exiting, so a later run removes their stores
    /// once the process that made each is gone.
    private static func removeStaleTestSuites() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for file in files where file.hasPrefix(testSuitePrefix) && file.hasSuffix(".plist") {
            let suite = String(file.dropLast(".plist".count))
            guard let pid = pid_t(suite.dropFirst(testSuitePrefix.count)),
                  kill(pid, 0) != 0, errno == ESRCH else { continue }
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
        }
    }
}

enum VisibilityPreferences {

    // MARK: - Storage

    /// A set of names stored as an array under `key`.
    private static func names(_ key: String) -> Set<String> {
        Set(UserDefaults.dam.stringArray(forKey: key) ?? [])
    }

    private static func setNames(_ names: Set<String>, _ key: String) {
        UserDefaults.dam.set(Array(names), forKey: key)
    }

    /// Adds `name` to, or takes it from, the hidden names under `key`.
    private static func setVisible(_ visible: Bool, _ name: String, hiddenKey key: String) {
        var hidden = names(key)
        if visible { hidden.remove(name) } else { hidden.insert(name) }
        setNames(hidden, key)
    }

    /// A switch stored under `key`, on until set.
    private static func isOn(_ key: String) -> Bool {
        UserDefaults.dam.object(forKey: key) == nil ? true : UserDefaults.dam.bool(forKey: key)
    }

    // MARK: - Audio

    private static let audioKey     = "\(AppIdentity.shortID).hidden.audio"
    private static let audioSeenKey = "\(AppIdentity.shortID).seen.audio"

    static var hiddenAudioDevices: Set<String> {
        get { names(audioKey) }
        set { setNames(newValue, audioKey) }
    }

    /// Every audio device name ever observed. Used to auto-hide virtual devices
    /// only on their first discovery, without re-hiding them if the user later
    /// enables them manually.
    static var seenAudioDevices: Set<String> {
        get { names(audioSeenKey) }
        set { setNames(newValue, audioSeenKey) }
    }

    static func isVisible(audioDevice name: String) -> Bool {
        !hiddenAudioDevices.contains(name)
    }

    static func setVisible(_ visible: Bool, audioDevice name: String) {
        setVisible(visible, name, hiddenKey: audioKey)
    }

    // MARK: - AirPlay displays

    private static let airPlayKey = "\(AppIdentity.shortID).hidden.airplay"

    static var hiddenAirPlayDevices: Set<String> {
        get { names(airPlayKey) }
        set { setNames(newValue, airPlayKey) }
    }

    static func isVisible(airPlayDevice name: String) -> Bool {
        !hiddenAirPlayDevices.contains(name)
    }

    static func setVisible(_ visible: Bool, airPlayDevice name: String) {
        setVisible(visible, name, hiddenKey: airPlayKey)
    }

    // MARK: - Behaviour

    private static let autoConnectKey = "\(AppIdentity.shortID).behaviour.autoConnectSingle"

    /// When true (default), pressing the AirPlay Connect hotkey with exactly one
    /// visible AirPlay display skips the selection list and goes straight to the
    /// confirmation / TTS step. When false the selection list is always shown.
    static var autoConnectSingleDisplay: Bool {
        get { isOn(autoConnectKey) }
        set { UserDefaults.dam.set(newValue, forKey: autoConnectKey) }
    }

    private static let speechEnabledKey = "\(AppIdentity.shortID).behaviour.speechEnabled"

    /// When true (default), actions such as connecting AirPlay and toggling
    /// mirror/extend are announced via TTS. Set to false to silence all speech.
    static var speechEnabled: Bool {
        get { isOn(speechEnabledKey) }
        set { UserDefaults.dam.set(newValue, forKey: speechEnabledKey) }
    }

    private static let speechOutputUIDKey  = "\(AppIdentity.shortID).behaviour.speechOutputUID"
    private static let speechOutputNameKey = "\(AppIdentity.shortID).behaviour.speechOutputName"

    /// UID of the audio device speech plays through. Nil (default) follows the
    /// system sound output; so does a chosen device that isn't connected.
    static var speechOutputUID: String? {
        get { UserDefaults.dam.string(forKey: speechOutputUIDKey) }
        set { UserDefaults.dam.set(newValue, forKey: speechOutputUIDKey) }
    }

    /// Name of the speech output device, so Settings can show it while it's disconnected.
    static var speechOutputName: String? {
        get { UserDefaults.dam.string(forKey: speechOutputNameKey) }
        set { UserDefaults.dam.set(newValue, forKey: speechOutputNameKey) }
    }

    private static let touchBarFeedbackKey = "\(AppIdentity.shortID).behaviour.touchBarFeedback"

    /// When true (default), hotkeys show their feedback on the Touch Bar when one is available.
    static var touchBarFeedback: Bool {
        get { isOn(touchBarFeedbackKey) }
        set { UserDefaults.dam.set(newValue, forKey: touchBarFeedbackKey) }
    }

    private static let screenFeedbackKey = "\(AppIdentity.shortID).behaviour.screenFeedback"

    /// When true (default), hotkeys show their feedback on screen.
    static var screenFeedback: Bool {
        get { isOn(screenFeedbackKey) }
        set { UserDefaults.dam.set(newValue, forKey: screenFeedbackKey) }
    }

    private static let pickerStartsOnCurrentKey = "\(AppIdentity.shortID).behaviour.pickerStartsOnCurrent"

    /// When true (default), a hotkey picker opens on the current choice. When false it opens
    /// on the one after it, so a single press followed by the pause moves on.
    static var pickerStartsOnCurrent: Bool {
        get { isOn(pickerStartsOnCurrentKey) }
        set { UserDefaults.dam.set(newValue, forKey: pickerStartsOnCurrentKey) }
    }

    private static let pickDelayKey = "\(AppIdentity.shortID).behaviour.pickDelay"
    static let pickDelayRange: ClosedRange<TimeInterval> = 0.5...10
    static let defaultPickDelay: TimeInterval = 2

    /// How long a hotkey picker waits after the last press before picking the tinted
    /// choice, in seconds, kept within `pickDelayRange`.
    static var pickDelay: TimeInterval {
        get {
            guard UserDefaults.dam.object(forKey: pickDelayKey) != nil else { return defaultPickDelay }
            return clampedPickDelay(UserDefaults.dam.double(forKey: pickDelayKey))
        }
        set { UserDefaults.dam.set(clampedPickDelay(newValue), forKey: pickDelayKey) }
    }

    static func clampedPickDelay(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultPickDelay }
        return min(max(value, pickDelayRange.lowerBound), pickDelayRange.upperBound)
    }

    private static let extraOfferDismissedKey = "\(AppIdentity.shortID).behaviour.screenMirroringExtraOfferDismissed"

    /// True once the user has declined, for good, the offer to show Control Center's
    /// Screen Mirroring item in the menu bar.
    static var screenMirroringExtraOfferDismissed: Bool {
        get { UserDefaults.dam.bool(forKey: extraOfferDismissedKey) }
        set { UserDefaults.dam.set(newValue, forKey: extraOfferDismissedKey) }
    }

    private static let autoHideVirtualAudioKey = "\(AppIdentity.shortID).behaviour.autoHideVirtualAudio"

    /// When true (default), virtual audio devices (Teams, Zoom, BlackHole, etc.)
    /// are automatically hidden on first discovery. The user can re-enable them
    /// in Settings at any time.
    static var autoHideVirtualAudio: Bool {
        get { isOn(autoHideVirtualAudioKey) }
        set { UserDefaults.dam.set(newValue, forKey: autoHideVirtualAudioKey) }
    }

    // MARK: - System

    private static let followNewDisplayAudioKey = "\(AppIdentity.shortID).behaviour.followNewDisplayAudio"

    /// When true (default), macOS's switch of the sound output to a newly connected
    /// display (HDMI / DisplayPort) is left alone. When false, the app switches the
    /// output back to the device that was playing before.
    static var followNewDisplayAudio: Bool {
        get { isOn(followNewDisplayAudioKey) }
        set { UserDefaults.dam.set(newValue, forKey: followNewDisplayAudioKey) }
    }

    /// Whether the app launches at login, as SMAppService has it; UserDefaults is not used.
    /// Not while the login item waits for approval in System Settings: macOS reports a login
    /// item the user turned off there the same way, and neither launches.
    static var launchAtLogin: Bool { isLaunchAtLogin(SMAppService.mainApp.status) }

    static func isLaunchAtLogin(_ status: SMAppService.Status) -> Bool {
        status == .enabled
    }

    /// Whether the login item is registered but waits for the user's approval.
    static var launchAtLoginNeedsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Registers or unregisters the app as a login item, throwing what SMAppService throws.
    static func setLaunchAtLogin(_ on: Bool) throws {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("\(AppIdentity.name): launch-at-login toggle failed: \(error)")
            throw error
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
        return Set((UserDefaults.dam.array(forKey: key) as? [Int]) ?? [60])
    }

    static func setVirtualRefreshRates(_ rates: Set<Int>, for context: DisplayContext) {
        let key = "\(AppIdentity.shortID).virtual.\(context.rawValue).refreshRates"
        UserDefaults.dam.set(Array(rates), forKey: key)
    }

    /// Every rate the virtual anchor advertises for `context`, highest first: the configured
    /// rates plus 60 Hz, which is always included (System Settings only shows its Refresh Rate
    /// dropdown when a resolution has at least two rates).
    static func effectiveVirtualRefreshRates(for context: DisplayContext) -> [Int] {
        virtualRefreshRates(for: context).union([60]).sorted(by: >)
    }

    /// Default virtual resolution stored as "WIDTHxHEIGHT", e.g. "3840x2160". Nil means no default.
    static func defaultVirtualResolution(for context: DisplayContext) -> String? {
        UserDefaults.dam.string(forKey: "\(AppIdentity.shortID).virtual.\(context.rawValue).defaultResolution")
    }

    static func setDefaultVirtualResolution(_ res: String?, for context: DisplayContext) {
        let key = "\(AppIdentity.shortID).virtual.\(context.rawValue).defaultResolution"
        if let v = res { UserDefaults.dam.set(v, forKey: key) }
        else { UserDefaults.dam.removeObject(forKey: key) }
    }

    // MARK: - Sidecar

    private static let sidecarAloneKey = "\(AppIdentity.shortID).sidecar.virtualDisplayBacking"

    /// Whether a connected iPad gets a virtual display behind it, mirrored, so that it can be
    /// the Mac's only display. On by default.
    static var backsSidecarWithVirtualDisplay: Bool {
        get { isOn(sidecarAloneKey) }
        set { UserDefaults.dam.set(newValue, forKey: sidecarAloneKey) }
    }

    private static let sidecarAutoConnectKey = "\(AppIdentity.shortID).sidecar.autoConnectWithoutDisplay"

    /// Whether an iPad plugged in over USB is connected over Sidecar when the Mac has no
    /// display of its own, including at login. Off by default.
    static var autoConnectsSidecarWithoutDisplay: Bool {
        get { UserDefaults.dam.bool(forKey: sidecarAutoConnectKey) }
        set { UserDefaults.dam.set(newValue, forKey: sidecarAutoConnectKey) }
    }

    /// The resolution last picked for an iPad's virtual display, as "WIDTHxHEIGHT" (logical),
    /// applied again when it reconnects. Nil means the iPad's own.
    static func sidecarResolution(for name: String) -> String? {
        (UserDefaults.dam.dictionary(forKey: sidecarResolutionsKey) as? [String: String])?[name]
    }

    static func setSidecarResolution(_ res: String?, for name: String) {
        var all = (UserDefaults.dam.dictionary(forKey: sidecarResolutionsKey) as? [String: String]) ?? [:]
        all[name] = res
        UserDefaults.dam.set(all, forKey: sidecarResolutionsKey)
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
        UserDefaults.dam.dictionary(forKey: kind.key) as? [String: String] ?? [:]
    }

    static func nickname(_ kind: NicknameKind, for name: String) -> String? {
        nicknames(kind)[name]
    }

    /// Sets the nickname for `name`; blank text removes it.
    static func setNickname(_ nickname: String?, _ kind: NicknameKind, for name: String) {
        var all = nicknames(kind)
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { all.removeValue(forKey: name) } else { all[name] = trimmed }
        UserDefaults.dam.set(all, forKey: kind.key)
    }

    // MARK: - Connected (physical) displays

    private static let displayKey = "\(AppIdentity.shortID).hidden.displays"

    static var hiddenDisplays: Set<String> {
        get { names(displayKey) }
        set { setNames(newValue, displayKey) }
    }

    static func isVisible(display name: String) -> Bool {
        !hiddenDisplays.contains(name)
    }

    static func setVisible(_ visible: Bool, display name: String) {
        setVisible(visible, name, hiddenKey: displayKey)
    }

    private static let splitDisplaysKey = "\(AppIdentity.shortID).split.displays"

    /// Gives `name`, a monitor told apart from another of its model, whether it is hidden as
    /// `base` was while both went by it. Not the nickname, which names the one monitor that
    /// keeps `base`. Once per name, so what is changed for it afterwards stays.
    static func inheritDisplaySettings(from base: String, to name: String) {
        var split = names(splitDisplaysKey)
        guard !split.contains(name) else { return }
        split.insert(name)
        setNames(split, splitDisplaysKey)
        if !isVisible(display: base) { setVisible(false, display: name) }
    }
}
