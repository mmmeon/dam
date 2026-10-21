import XCTest
import CoreAudio
@testable import DAM

final class AudioManagerFilterTests: XCTestCase {

    private let audioKey     = "\(AppIdentity.shortID).hidden.audio"
    private let audioSeenKey = "\(AppIdentity.shortID).seen.audio"
    private let speechUIDKey  = "\(AppIdentity.shortID).behaviour.speechOutputUID"
    private let speechNameKey = "\(AppIdentity.shortID).behaviour.speechOutputName"
    private let autoHideKey   = "\(AppIdentity.shortID).behaviour.autoHideVirtualAudio"

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
        [audioKey, audioSeenKey, speechUIDKey, speechNameKey, autoHideKey].forEach { UserDefaults.dam.removeObject(forKey: $0) }
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

    // MARK: - AudioManager.autoHideNewDevices(_:isVirtual:)
    //
    // The CoreAudio-free core of autoHideNewVirtualDevices; device 2 stands for a virtual one.

    private let virtual: (AudioDeviceID) -> Bool = { $0 == 2 }

    func testAutoHide_unseenVirtualDeviceIsHidden() {
        AudioManager.autoHideNewDevices([device("Speakers", id: 1), device("BlackHole 2ch", id: 2)],
                                        isVirtual: virtual)
        XCTAssertTrue(VisibilityPreferences.isVisible(audioDevice: "Speakers"))
        XCTAssertFalse(VisibilityPreferences.isVisible(audioDevice: "BlackHole 2ch"))
        XCTAssertEqual(VisibilityPreferences.seenAudioDevices, ["Speakers", "BlackHole 2ch"])
    }

    func testAutoHide_seenDeviceIsNotHiddenAgain() {
        // Seen before, and shown again by the user since.
        VisibilityPreferences.seenAudioDevices = ["BlackHole 2ch"]
        AudioManager.autoHideNewDevices([device("BlackHole 2ch", id: 2)], isVirtual: virtual)
        XCTAssertTrue(VisibilityPreferences.isVisible(audioDevice: "BlackHole 2ch"))
    }

    func testAutoHide_offStillRecordsTheDevicesSeen() {
        VisibilityPreferences.autoHideVirtualAudio = false
        AudioManager.autoHideNewDevices([device("BlackHole 2ch", id: 2)], isVirtual: virtual)
        XCTAssertTrue(VisibilityPreferences.isVisible(audioDevice: "BlackHole 2ch"))
        XCTAssertEqual(VisibilityPreferences.seenAudioDevices, ["BlackHole 2ch"])
    }

    func testAutoHide_seenSetGrowsWithEachNewDevice() {
        for name in ["Device A", "Device B", "Device C"] {
            AudioManager.autoHideNewDevices([device(name, id: 1)], isVirtual: virtual)
        }
        XCTAssertEqual(VisibilityPreferences.seenAudioDevices, ["Device A", "Device B", "Device C"])
    }

    // MARK: - AudioManager.uid(of:) / deviceID(forUID:)
    // These read live CoreAudio state (tests run inside the app process).

    func testUID_roundTripsForEveryOutputDevice() throws {
        let manager = AudioManager()
        manager.refresh()
        try XCTSkipIf(manager.allOutputDevices.isEmpty, "no audio output devices")
        for device in manager.allOutputDevices {
            let uid = try XCTUnwrap(AudioManager.uid(of: device.id), "\(device.name) has no UID")
            XCTAssertEqual(AudioManager.deviceID(forUID: uid), device.id, device.name)
        }
    }

    func testUID_unknownDevice_isNil() {
        XCTAssertNil(AudioManager.uid(of: kAudioObjectUnknown))
    }

    func testDeviceIDForUID_unknownUID_isNil() {
        XCTAssertNil(AudioManager.deviceID(forUID: "no-such-device-uid"))
    }

    func testDeviceIDForUID_emptyUID_isNil() {
        XCTAssertNil(AudioManager.deviceID(forUID: ""))
    }

    // MARK: - VisibilityPreferences.speechOutputUID / speechOutputName

    func testSpeechOutput_defaultsToSoundOutput() {
        XCTAssertNil(VisibilityPreferences.speechOutputUID)
        XCTAssertNil(VisibilityPreferences.speechOutputName)
    }

    func testSpeechOutput_roundTrip() {
        VisibilityPreferences.speechOutputUID  = "BuiltInSpeakerDevice"
        VisibilityPreferences.speechOutputName = "MacBook Pro Speakers"
        XCTAssertEqual(VisibilityPreferences.speechOutputUID, "BuiltInSpeakerDevice")
        XCTAssertEqual(VisibilityPreferences.speechOutputName, "MacBook Pro Speakers")
    }

    func testSpeechOutput_settingNil_returnsToSoundOutput() {
        VisibilityPreferences.speechOutputUID  = "BuiltInSpeakerDevice"
        VisibilityPreferences.speechOutputName = "MacBook Pro Speakers"
        VisibilityPreferences.speechOutputUID  = nil
        VisibilityPreferences.speechOutputName = nil
        XCTAssertNil(VisibilityPreferences.speechOutputUID)
        XCTAssertNil(VisibilityPreferences.speechOutputName)
    }
}
