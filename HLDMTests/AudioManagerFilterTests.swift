import XCTest
import CoreAudio
@testable import HLDM

final class AudioManagerFilterTests: XCTestCase {

    private let audioKey     = "hldm.hidden.audio"
    private let audioSeenKey = "hldm.seen.audio"

    override func tearDown() {
        super.tearDown()
        [audioKey, audioSeenKey].forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    // Convenience factory — AudioDeviceID is UInt32; use arbitrary values for tests.
    private func device(_ name: String, id: AudioDeviceID = 1) -> AudioDevice {
        AudioDevice(id: id, name: name)
    }

    // MARK: - AudioManager.filter(devices:hidden:)

    func testFilter_emptyDevices_returnsEmpty() {
        let result = AudioManager.filter(devices: [], hidden: ["Speaker"])
        XCTAssertTrue(result.isEmpty)
    }

    func testFilter_noHiddenDevices_returnsAll() {
        let devices = [device("Speakers", id: 1), device("Headphones", id: 2)]
        let result = AudioManager.filter(devices: devices, hidden: [])
        XCTAssertEqual(result.map(\.name), ["Speakers", "Headphones"])
    }

    func testFilter_allDevicesHidden_returnsEmpty() {
        let devices = [device("A", id: 1), device("B", id: 2)]
        let result = AudioManager.filter(devices: devices, hidden: ["A", "B"])
        XCTAssertTrue(result.isEmpty)
    }

    func testFilter_oneDeviceHidden_returnsRest() {
        let devices = [device("Speakers", id: 1), device("ZoomAudioDevice", id: 2), device("Headphones", id: 3)]
        let result = AudioManager.filter(devices: devices, hidden: ["ZoomAudioDevice"])
        XCTAssertEqual(result.map(\.name), ["Speakers", "Headphones"])
    }

    func testFilter_preservesOrder() {
        let names = ["C", "A", "B"]
        let devices = names.enumerated().map { device($0.element, id: AudioDeviceID($0.offset + 1)) }
        let result = AudioManager.filter(devices: devices, hidden: [])
        XCTAssertEqual(result.map(\.name), names)
    }

    func testFilter_hiddenSetContainsNonexistentName_noEffect() {
        let devices = [device("MacBook Pro Speakers", id: 1)]
        let result = AudioManager.filter(devices: devices, hidden: ["BlackHole 2ch"])
        XCTAssertEqual(result.map(\.name), ["MacBook Pro Speakers"])
    }

    func testFilter_duplicateNamesInInput_bothExcludedWhenHidden() {
        let devices = [device("Zoom", id: 1), device("Zoom", id: 2)]
        let result = AudioManager.filter(devices: devices, hidden: ["Zoom"])
        XCTAssertTrue(result.isEmpty)
    }

    func testFilter_largeDeviceList_onlyHiddenRemoved() {
        let names = (1...10).map { "Device \($0)" }
        let devices = names.enumerated().map { device($0.element, id: AudioDeviceID($0.offset + 1)) }
        let result = AudioManager.filter(devices: devices, hidden: ["Device 3", "Device 7"])
        let resultNames = result.map(\.name)
        XCTAssertFalse(resultNames.contains("Device 3"))
        XCTAssertFalse(resultNames.contains("Device 7"))
        XCTAssertEqual(result.count, 8)
    }

    func testFilter_preservesDeviceIDs() {
        let devices = [device("Speakers", id: 42), device("Headphones", id: 99)]
        let result = AudioManager.filter(devices: devices, hidden: [])
        XCTAssertEqual(result.first?.id, 42)
        XCTAssertEqual(result.last?.id, 99)
    }

    // MARK: - Auto-hide path (VisibilityPreferences side-effects)
    //
    // These tests replicate the UserDefaults portion of autoHideNewVirtualDevices
    // without calling CoreAudio (isHardwareDevice is excluded). They verify the
    // seen-set and hide semantics that the method relies on.

    func testAutoHidePath_unseenDeviceMarkedHiddenViaPreferences() {
        // Simulates: device not in seen set → mark hidden, add to seen
        let name = "BlackHole 2ch"
        XCTAssertFalse(VisibilityPreferences.seenAudioDevices.contains(name))
        // Replicate the autoHide path manually
        var seen = VisibilityPreferences.seenAudioDevices
        if !seen.contains(name) {
            VisibilityPreferences.setVisible(false, audioDevice: name)
            seen.insert(name)
        }
        VisibilityPreferences.seenAudioDevices = seen
        XCTAssertFalse(VisibilityPreferences.isVisible(audioDevice: name))
        XCTAssertTrue(VisibilityPreferences.seenAudioDevices.contains(name))
    }

    func testAutoHidePath_seenDeviceNotReHidden() {
        // Simulates: device already in seen set → do not re-hide if user re-enabled it
        let name = "BlackHole 2ch"
        VisibilityPreferences.seenAudioDevices = [name]   // mark as previously seen
        VisibilityPreferences.setVisible(true, audioDevice: name) // user re-enabled it

        var seen = VisibilityPreferences.seenAudioDevices
        if !seen.contains(name) {
            VisibilityPreferences.setVisible(false, audioDevice: name)
            seen.insert(name)
        }
        VisibilityPreferences.seenAudioDevices = seen
        // Because it was already seen, the if-block above was skipped → still visible
        XCTAssertTrue(VisibilityPreferences.isVisible(audioDevice: name))
    }

    func testAutoHidePath_seenSetGrowsWithEachNewDevice() {
        let newDevices = ["Device A", "Device B", "Device C"]
        for name in newDevices {
            var seen = VisibilityPreferences.seenAudioDevices
            if !seen.contains(name) {
                seen.insert(name)
            }
            VisibilityPreferences.seenAudioDevices = seen
        }
        XCTAssertEqual(VisibilityPreferences.seenAudioDevices, Set(newDevices))
    }

    func testAutoHidePath_alreadySeenDeviceSkippedInSeenSet() {
        let name = "Speaker"
        VisibilityPreferences.seenAudioDevices = [name]
        var seen = VisibilityPreferences.seenAudioDevices
        let countBefore = seen.count
        seen.insert(name)   // inserting duplicate into a Set is a no-op
        VisibilityPreferences.seenAudioDevices = seen
        XCTAssertEqual(VisibilityPreferences.seenAudioDevices.count, countBefore)
    }

    // MARK: - AudioManager.device(after:in:)

    func testDeviceAfter_advancesToNext() {
        let devices = [device("Speakers", id: 1), device("Headphones", id: 2), device("TV", id: 3)]
        XCTAssertEqual(AudioManager.device(after: 1, in: devices)?.name, "Headphones")
    }

    func testDeviceAfter_wrapsFromLastToFirst() {
        let devices = [device("Speakers", id: 1), device("Headphones", id: 2)]
        XCTAssertEqual(AudioManager.device(after: 2, in: devices)?.name, "Speakers")
    }

    func testDeviceAfter_currentHidden_startsAtFirst() {
        let devices = [device("Speakers", id: 1), device("Headphones", id: 2)]
        XCTAssertEqual(AudioManager.device(after: 99, in: devices)?.name, "Speakers")
    }

    func testDeviceAfter_singleDevice_returnsItself() {
        XCTAssertEqual(AudioManager.device(after: 1, in: [device("Speakers", id: 1)])?.name, "Speakers")
    }

    func testDeviceAfter_noDevices_returnsNil() {
        XCTAssertNil(AudioManager.device(after: 1, in: []))
    }
}
