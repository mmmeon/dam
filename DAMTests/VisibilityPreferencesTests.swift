import XCTest
@testable import DAM

final class VisibilityPreferencesTests: XCTestCase {

    private let audioKey     = "\(AppIdentity.shortID).hidden.audio"
    private let audioSeenKey = "\(AppIdentity.shortID).seen.audio"
    private let airPlayKey   = "\(AppIdentity.shortID).hidden.airplay"
    private let displayKey   = "\(AppIdentity.shortID).hidden.displays"
    private let autoConnKey  = "\(AppIdentity.shortID).behaviour.autoConnectSingle"
    private let touchBarKey  = "\(AppIdentity.shortID).behaviour.touchBarFeedback"
    private let screenKey    = "\(AppIdentity.shortID).behaviour.screenFeedback"
    private let startKey     = "\(AppIdentity.shortID).behaviour.pickerStartsOnCurrent"
    private let delayKey     = "\(AppIdentity.shortID).behaviour.pickDelay"
    private let splitKey     = "\(AppIdentity.shortID).split.displays"
    private let nicknameKey  = "\(AppIdentity.shortID).nicknames.displays"

    // The host app also writes preferences (seen audio devices, for one), so start each
    // test from a clean slate as well as cleaning up after it.
    override func setUp() {
        super.setUp()
        clearPreferences()
    }

    override func tearDown() {
        super.tearDown()
        clearPreferences()
    }

    private func clearPreferences() {
        [audioKey, audioSeenKey, airPlayKey, displayKey, autoConnKey, touchBarKey, screenKey,
         startKey, delayKey, splitKey, nicknameKey].forEach {
            UserDefaults.dam.removeObject(forKey: $0)
        }
    }

    // MARK: - Pickers

    func testPickerStartsOnCurrent_defaultsToTrue() {
        XCTAssertTrue(VisibilityPreferences.pickerStartsOnCurrent)
    }

    func testPickerStartsOnCurrent_roundTrip() {
        VisibilityPreferences.pickerStartsOnCurrent = false
        XCTAssertFalse(VisibilityPreferences.pickerStartsOnCurrent)
    }

    func testStartCursor_followsThePreference() {
        VisibilityPreferences.pickerStartsOnCurrent = true
        XCTAssertEqual(ChoicePicker.startCursor(current: 1, count: 3), 1)
        VisibilityPreferences.pickerStartsOnCurrent = false
        XCTAssertEqual(ChoicePicker.startCursor(current: 2, count: 3), 0)
    }

    func testStartCursor_noneCurrent_opensOnTheFirst() {
        // In both modes: the first is also the one after none.
        VisibilityPreferences.pickerStartsOnCurrent = true
        XCTAssertEqual(ChoicePicker.startCursor(current: nil, count: 3), 0)
        VisibilityPreferences.pickerStartsOnCurrent = false
        XCTAssertEqual(ChoicePicker.startCursor(current: nil, count: 3), 0)
        XCTAssertEqual(ChoicePicker.startCursor(current: 2, count: 0), 0)
    }

    func testPausePicksStart_notTheFirstForNoneCurrent() {
        VisibilityPreferences.pickerStartsOnCurrent = true
        XCTAssertTrue(ChoicePicker.pausePicksStart(current: 0))
        XCTAssertFalse(ChoicePicker.pausePicksStart(current: nil))
        // Opened on the next choice, a single press and the pause move on, to the first here.
        VisibilityPreferences.pickerStartsOnCurrent = false
        XCTAssertTrue(ChoicePicker.pausePicksStart(current: nil))
        XCTAssertTrue(ChoicePicker.pausePicksStart(current: 1))
    }

    /// Opened on the first with none current, the pause doesn't pick it, and the first press
    /// lands on it rather than skipping to the second; presses after that move on.
    func testCursorAdvancing_noneCurrent_firstPressLandsOnTheFirst() {
        XCTAssertEqual(ChoicePicker.cursor(advancingFrom: 0, count: 3, pausePicks: false), 0)
        XCTAssertEqual(ChoicePicker.cursor(advancingFrom: 0, count: 3, pausePicks: true), 1)
        XCTAssertEqual(ChoicePicker.cursor(advancingFrom: 2, count: 3, pausePicks: true), 0, "wraps round")
        XCTAssertEqual(ChoicePicker.cursor(advancingFrom: 0, count: 0, pausePicks: true), 0)
    }

    func testPickDelay_defaultsToTwoSeconds() {
        XCTAssertEqual(VisibilityPreferences.pickDelay, 2)
    }

    func testPickDelay_roundTripAndClamping() {
        VisibilityPreferences.pickDelay = 3.5
        XCTAssertEqual(VisibilityPreferences.pickDelay, 3.5)
        VisibilityPreferences.pickDelay = 0
        XCTAssertEqual(VisibilityPreferences.pickDelay, VisibilityPreferences.pickDelayRange.lowerBound)
        VisibilityPreferences.pickDelay = 99
        XCTAssertEqual(VisibilityPreferences.pickDelay, VisibilityPreferences.pickDelayRange.upperBound)
        XCTAssertEqual(VisibilityPreferences.clampedPickDelay(.nan), VisibilityPreferences.defaultPickDelay)
    }

    // MARK: - Audio visibility

    func testHiddenAudioDevices_defaultsToEmpty() {
        XCTAssertTrue(VisibilityPreferences.hiddenAudioDevices.isEmpty)
    }

    func testSetVisible_false_audioDevice_addsToHiddenSet() {
        VisibilityPreferences.setVisible(false, audioDevice: "MacBook Pro Speakers")
        XCTAssertTrue(VisibilityPreferences.hiddenAudioDevices.contains("MacBook Pro Speakers"))
    }

    func testSetVisible_true_audioDevice_removesFromHiddenSet() {
        VisibilityPreferences.setVisible(false, audioDevice: "Headphones")
        VisibilityPreferences.setVisible(true, audioDevice: "Headphones")
        XCTAssertFalse(VisibilityPreferences.hiddenAudioDevices.contains("Headphones"))
    }

    func testIsVisible_audioDevice_trueWhenNotHidden() {
        XCTAssertTrue(VisibilityPreferences.isVisible(audioDevice: "Headphones"))
    }

    func testIsVisible_audioDevice_falseWhenHidden() {
        VisibilityPreferences.setVisible(false, audioDevice: "ZoomAudioDevice")
        XCTAssertFalse(VisibilityPreferences.isVisible(audioDevice: "ZoomAudioDevice"))
    }

    func testMultipleHiddenAudioDevices_allTrackedInSet() {
        VisibilityPreferences.setVisible(false, audioDevice: "Zoom")
        VisibilityPreferences.setVisible(false, audioDevice: "Teams")
        let hidden = VisibilityPreferences.hiddenAudioDevices
        XCTAssertTrue(hidden.contains("Zoom"))
        XCTAssertTrue(hidden.contains("Teams"))
    }

    func testRoundTrip_hideAndUnhide_audioDevice() {
        VisibilityPreferences.setVisible(false, audioDevice: "BlackHole")
        XCTAssertFalse(VisibilityPreferences.isVisible(audioDevice: "BlackHole"))
        VisibilityPreferences.setVisible(true, audioDevice: "BlackHole")
        XCTAssertTrue(VisibilityPreferences.isVisible(audioDevice: "BlackHole"))
    }

    // MARK: - Seen audio devices

    func testSeenAudioDevices_defaultsToEmpty() {
        XCTAssertTrue(VisibilityPreferences.seenAudioDevices.isEmpty)
    }

    func testSeenAudioDevices_persistsAndReads() {
        VisibilityPreferences.seenAudioDevices = ["MacBook Pro Speakers"]
        XCTAssertTrue(VisibilityPreferences.seenAudioDevices.contains("MacBook Pro Speakers"))
    }

    func testSeenAudioDevices_roundTrips_multipleNames() {
        let names: Set<String> = ["Device A", "Device B", "Device C"]
        VisibilityPreferences.seenAudioDevices = names
        XCTAssertEqual(VisibilityPreferences.seenAudioDevices, names)
    }

    func testSeenAudioDevices_canGrowIncrementally() {
        VisibilityPreferences.seenAudioDevices = ["A"]
        var seen = VisibilityPreferences.seenAudioDevices
        seen.insert("B")
        VisibilityPreferences.seenAudioDevices = seen
        XCTAssertEqual(VisibilityPreferences.seenAudioDevices, ["A", "B"])
    }

    // MARK: - AirPlay visibility

    func testHiddenAirPlayDevices_defaultsToEmpty() {
        XCTAssertTrue(VisibilityPreferences.hiddenAirPlayDevices.isEmpty)
    }

    func testSetVisible_false_airPlayDevice_addsToHiddenSet() {
        VisibilityPreferences.setVisible(false, airPlayDevice: "Living Room TV")
        XCTAssertTrue(VisibilityPreferences.hiddenAirPlayDevices.contains("Living Room TV"))
    }

    func testSetVisible_true_airPlayDevice_removesFromHiddenSet() {
        VisibilityPreferences.setVisible(false, airPlayDevice: "Office ATV")
        VisibilityPreferences.setVisible(true, airPlayDevice: "Office ATV")
        XCTAssertFalse(VisibilityPreferences.hiddenAirPlayDevices.contains("Office ATV"))
    }

    func testIsVisible_airPlayDevice_trueWhenNotHidden() {
        XCTAssertTrue(VisibilityPreferences.isVisible(airPlayDevice: "Living Room TV"))
    }

    func testIsVisible_airPlayDevice_falseWhenHidden() {
        VisibilityPreferences.setVisible(false, airPlayDevice: "Bedroom ATV")
        XCTAssertFalse(VisibilityPreferences.isVisible(airPlayDevice: "Bedroom ATV"))
    }

    // MARK: - Display visibility

    func testHiddenDisplays_defaultsToEmpty() {
        XCTAssertTrue(VisibilityPreferences.hiddenDisplays.isEmpty)
    }

    func testSetVisible_false_display_addsToHiddenSet() {
        VisibilityPreferences.setVisible(false, display: "Dell U2723D")
        XCTAssertTrue(VisibilityPreferences.hiddenDisplays.contains("Dell U2723D"))
    }

    func testSetVisible_true_display_removesFromHiddenSet() {
        VisibilityPreferences.setVisible(false, display: "LG UltraFine")
        VisibilityPreferences.setVisible(true, display: "LG UltraFine")
        XCTAssertFalse(VisibilityPreferences.hiddenDisplays.contains("LG UltraFine"))
    }

    func testIsVisible_display_trueWhenNotHidden() {
        XCTAssertTrue(VisibilityPreferences.isVisible(display: "Dell U2723D"))
    }

    func testIsVisible_display_falseWhenHidden() {
        VisibilityPreferences.setVisible(false, display: "Studio Display")
        XCTAssertFalse(VisibilityPreferences.isVisible(display: "Studio Display"))
    }

    // MARK: - autoConnectSingleDisplay

    func testAutoConnectSingleDisplay_defaultsToTrue() {
        XCTAssertTrue(VisibilityPreferences.autoConnectSingleDisplay)
    }

    func testAutoConnectSingleDisplay_canBeSetFalse() {
        VisibilityPreferences.autoConnectSingleDisplay = false
        XCTAssertFalse(VisibilityPreferences.autoConnectSingleDisplay)
    }

    func testAutoConnectSingleDisplay_canBeSetTrueExplicitly() {
        VisibilityPreferences.autoConnectSingleDisplay = false
        VisibilityPreferences.autoConnectSingleDisplay = true
        XCTAssertTrue(VisibilityPreferences.autoConnectSingleDisplay)
    }

    // MARK: - Feedback surfaces

    func testTouchBarFeedback_defaultsToTrue() {
        XCTAssertTrue(VisibilityPreferences.touchBarFeedback)
    }

    func testTouchBarFeedback_canBeSetFalse() {
        VisibilityPreferences.touchBarFeedback = false
        XCTAssertFalse(VisibilityPreferences.touchBarFeedback)
    }

    func testScreenFeedback_defaultsToTrue() {
        XCTAssertTrue(VisibilityPreferences.screenFeedback)
    }

    func testScreenFeedback_canBeSetFalse() {
        VisibilityPreferences.screenFeedback = false
        XCTAssertFalse(VisibilityPreferences.screenFeedback)
    }

    // MARK: - Switches on until set

    func testEverySwitchOnByDefault_isOnUntilSetAndKeepsWhatIsSet() {
        let behaviour = "\(AppIdentity.shortID).behaviour."
        let switches: [(key: String, get: () -> Bool, set: (Bool) -> Void)] = [
            (behaviour + "autoConnectSingle", { VisibilityPreferences.autoConnectSingleDisplay },
             { VisibilityPreferences.autoConnectSingleDisplay = $0 }),
            (behaviour + "speechEnabled", { VisibilityPreferences.speechEnabled },
             { VisibilityPreferences.speechEnabled = $0 }),
            (behaviour + "touchBarFeedback", { VisibilityPreferences.touchBarFeedback },
             { VisibilityPreferences.touchBarFeedback = $0 }),
            (behaviour + "screenFeedback", { VisibilityPreferences.screenFeedback },
             { VisibilityPreferences.screenFeedback = $0 }),
            (behaviour + "pickerStartsOnCurrent", { VisibilityPreferences.pickerStartsOnCurrent },
             { VisibilityPreferences.pickerStartsOnCurrent = $0 }),
            (behaviour + "autoHideVirtualAudio", { VisibilityPreferences.autoHideVirtualAudio },
             { VisibilityPreferences.autoHideVirtualAudio = $0 }),
            (behaviour + "followNewDisplayAudio", { VisibilityPreferences.followNewDisplayAudio },
             { VisibilityPreferences.followNewDisplayAudio = $0 }),
            ("\(AppIdentity.shortID).sidecar.virtualDisplayBacking",
             { VisibilityPreferences.backsSidecarWithVirtualDisplay },
             { VisibilityPreferences.backsSidecarWithVirtualDisplay = $0 }),
        ]
        for entry in switches {
            UserDefaults.dam.removeObject(forKey: entry.key)
            defer { UserDefaults.dam.removeObject(forKey: entry.key) }
            XCTAssertTrue(entry.get(), entry.key)
            entry.set(false)
            XCTAssertFalse(entry.get(), entry.key)
            XCTAssertEqual(UserDefaults.dam.object(forKey: entry.key) as? Bool, false, entry.key)
            entry.set(true)
            XCTAssertTrue(entry.get(), entry.key)
        }
    }

    // MARK: - Launch at login

    /// Only an enabled login item launches. One waiting for approval, which is also how macOS
    /// reports one the user turned off in System Settings, shows unchecked.
    func testLaunchAtLogin_onlyWhenEnabled() {
        XCTAssertTrue(VisibilityPreferences.isLaunchAtLogin(.enabled))
        XCTAssertFalse(VisibilityPreferences.isLaunchAtLogin(.requiresApproval))
        XCTAssertFalse(VisibilityPreferences.isLaunchAtLogin(.notRegistered))
        XCTAssertFalse(VisibilityPreferences.isLaunchAtLogin(.notFound))
    }

    // MARK: - Monitors of one model

    func testInheritDisplaySettings_takesTheHiddenStateNotTheNickname() {
        VisibilityPreferences.setVisible(false, display: "DELL U2720Q")
        VisibilityPreferences.setNickname("Desk", .display, for: "DELL U2720Q")
        VisibilityPreferences.inheritDisplaySettings(from: "DELL U2720Q", to: "DELL U2720Q (2)")
        XCTAssertFalse(VisibilityPreferences.isVisible(display: "DELL U2720Q (2)"))
        // The nickname stays the first monitor's own.
        XCTAssertNil(VisibilityPreferences.nickname(.display, for: "DELL U2720Q (2)"))
        XCTAssertEqual(VisibilityPreferences.nickname(.display, for: "DELL U2720Q"), "Desk")
        XCTAssertFalse(VisibilityPreferences.isVisible(display: "DELL U2720Q"))
    }

    func testInheritDisplaySettings_onceOnly() {
        VisibilityPreferences.setVisible(false, display: "DELL U2720Q")
        VisibilityPreferences.inheritDisplaySettings(from: "DELL U2720Q", to: "DELL U2720Q (2)")
        // Shown again by the user, and kept so.
        VisibilityPreferences.setVisible(true, display: "DELL U2720Q (2)")
        VisibilityPreferences.inheritDisplaySettings(from: "DELL U2720Q", to: "DELL U2720Q (2)")
        XCTAssertTrue(VisibilityPreferences.isVisible(display: "DELL U2720Q (2)"))
    }

    func testInheritDisplaySettings_nothingSaved_staysShown() {
        VisibilityPreferences.inheritDisplaySettings(from: "LG UltraFine", to: "LG UltraFine (2)")
        XCTAssertTrue(VisibilityPreferences.isVisible(display: "LG UltraFine (2)"))
        XCTAssertNil(VisibilityPreferences.nickname(.display, for: "LG UltraFine (2)"))
    }
}
