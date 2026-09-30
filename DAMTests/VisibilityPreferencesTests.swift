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

    override func tearDown() {
        super.tearDown()
        [audioKey, audioSeenKey, airPlayKey, displayKey, autoConnKey, touchBarKey, screenKey,
         startKey, delayKey].forEach {
            UserDefaults.standard.removeObject(forKey: $0)
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
}
