import XCTest
import CoreAudio
@testable import DAM

final class AudioManagerFilterTests: XCTestCase {

    private let audioKey     = "\(AppIdentity.shortID).hidden.audio"
    private let audioSeenKey = "\(AppIdentity.shortID).seen.audio"
    private let speechUIDKey  = "\(AppIdentity.shortID).behaviour.speechOutputUID"
    private let speechNameKey = "\(AppIdentity.shortID).behaviour.speechOutputName"
    private let autoHideKey   = "\(AppIdentity.shortID).behaviour.autoHideVirtualAudio"
    private let oldRuleKey    = "\(AppIdentity.shortID).hidden.audio.oldVirtualRule"

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
        [audioKey, audioSeenKey, speechUIDKey, speechNameKey, autoHideKey, oldRuleKey].forEach { UserDefaults.dam.removeObject(forKey: $0) }
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

    // MARK: - AudioManager.isVirtual(transport:)

    func testIsVirtual_onlyVirtualAndAggregateTransports() {
        for transport in [kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
                          kAudioDeviceTransportTypeAutoAggregate] {
            XCTAssertTrue(AudioManager.isVirtual(transport: transport), "\(transport)")
        }
        // A device's own, those the list once left out (PCI, AVB, unknown) among them.
        for transport in [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB,
                          kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeAirPlay,
                          kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeAVB,
                          kAudioDeviceTransportTypeUnknown] {
            XCTAssertFalse(AudioManager.isVirtual(transport: transport), "\(transport)")
        }
        XCTAssertFalse(AudioManager.isVirtual(transport: nil))
    }

    // MARK: - AudioManager.undoOldVirtualRule

    func testOldRuleHid_everyReadableTransportButTheHardwareItListed() {
        for transport in [kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeAVB,
                          kAudioDeviceTransportTypeUnknown, kAudioDeviceTransportTypeVirtual] {
            XCTAssertTrue(AudioManager.oldRuleHid(transport: transport), "\(transport)")
        }
        for transport in [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB,
                          kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeHDMI,
                          kAudioDeviceTransportTypeAirPlay, kAudioDeviceTransportTypeThunderbolt] {
            XCTAssertFalse(AudioManager.oldRuleHid(transport: transport), "\(transport)")
        }
        XCTAssertFalse(AudioManager.oldRuleHid(transport: nil), "an unreadable one was shown")
    }

    /// Hidden before, a PCI or AVB output shows again; a virtual one, or a USB one (which the
    /// old rule didn't hide, so the user did), stays hidden.
    func testUndoOldVirtualRule_showsOnlyWhatTheOldRuleAloneHid() {
        let names = ["PCI Card", "AVB Box", "BlackHole", "USB DAC"]
        VisibilityPreferences.seenAudioDevices = Set(names)
        VisibilityPreferences.hiddenAudioDevices = Set(names)
        let transports: [AudioDeviceID: UInt32] = [
            1: kAudioDeviceTransportTypePCI, 2: kAudioDeviceTransportTypeAVB,
            3: kAudioDeviceTransportTypeVirtual, 4: kAudioDeviceTransportTypeUSB,
        ]
        let devices = names.enumerated().map { device($0.element, id: AudioDeviceID($0.offset + 1)) }
        AudioManager.undoOldVirtualRule(devices) { transports[$0] }
        XCTAssertEqual(VisibilityPreferences.hiddenAudioDevices, ["BlackHole", "USB DAC"])
        XCTAssertEqual(VisibilityPreferences.audioHiddenByOldRule, [])
    }

    /// Once only: hidden again by the user afterwards, a device stays hidden.
    func testUndoOldVirtualRule_onceOnly() {
        VisibilityPreferences.seenAudioDevices = ["PCI Card"]
        VisibilityPreferences.hiddenAudioDevices = ["PCI Card"]
        let pci = [device("PCI Card", id: 1)]
        AudioManager.undoOldVirtualRule(pci) { _ in kAudioDeviceTransportTypePCI }
        XCTAssertEqual(VisibilityPreferences.hiddenAudioDevices, [])
        VisibilityPreferences.setVisible(false, audioDevice: "PCI Card")
        AudioManager.undoOldVirtualRule(pci) { _ in kAudioDeviceTransportTypePCI }
        XCTAssertEqual(VisibilityPreferences.hiddenAudioDevices, ["PCI Card"])
    }

    /// A device not connected when it first runs is checked when it next is; one hidden after
    /// that is the user's.
    func testUndoOldVirtualRule_checksADeviceWhenItComes() {
        VisibilityPreferences.seenAudioDevices = ["AVB Box"]
        VisibilityPreferences.hiddenAudioDevices = ["AVB Box"]
        AudioManager.undoOldVirtualRule([]) { _ in nil }
        XCTAssertEqual(VisibilityPreferences.audioHiddenByOldRule, ["AVB Box"])
        VisibilityPreferences.seenAudioDevices.insert("PCI Card")
        VisibilityPreferences.setVisible(false, audioDevice: "PCI Card")
        AudioManager.undoOldVirtualRule([device("AVB Box", id: 2), device("PCI Card", id: 1)]) { _ in
            kAudioDeviceTransportTypeAVB
        }
        XCTAssertEqual(VisibilityPreferences.hiddenAudioDevices, ["PCI Card"])
    }

    /// With hiding new virtual devices off, the old rule hid nothing: all that is hidden is the user's.
    func testUndoOldVirtualRule_autoHideOff_leavesAllHidden() {
        VisibilityPreferences.autoHideVirtualAudio = false
        VisibilityPreferences.seenAudioDevices = ["PCI Card"]
        VisibilityPreferences.hiddenAudioDevices = ["PCI Card"]
        AudioManager.undoOldVirtualRule([device("PCI Card")]) { _ in kAudioDeviceTransportTypePCI }
        XCTAssertEqual(VisibilityPreferences.hiddenAudioDevices, ["PCI Card"])
    }

    // MARK: - AudioManager.undoesSwitch
    //
    // Device 1 played before; device 5 is a display's audio that has just appeared.

    private let display: (AudioDeviceID) -> Bool = { $0 == 5 }

    private func undoes(to current: AudioDeviceID = 5, from previous: AudioDeviceID = 1,
                        devices: Set<AudioDeviceID> = [1, 5], added: [AudioDeviceID] = [5],
                        follows: Bool = false) -> Bool {
        AudioManager.undoesSwitch(to: current, from: previous, devices: devices,
                                  recentlyAdded: Dictionary(uniqueKeysWithValues: added.map { ($0, Date()) }),
                                  follows: follows, isDisplay: display)
    }

    func testUndoesSwitch_toANewDisplaysAudio() {
        XCTAssertTrue(undoes())
    }

    func testUndoesSwitch_notWhenFollowingTheDisplay() {
        XCTAssertFalse(undoes(follows: true))
    }

    func testUndoesSwitch_notToADeviceThatWasAlreadyThere() {
        XCTAssertFalse(undoes(added: []))
    }

    func testUndoesSwitch_notToAnotherKindOfDevice() {
        XCTAssertFalse(undoes(to: 6, devices: [1, 6], added: [6]))
    }

    func testUndoesSwitch_notWhenThePreviousOutputHasGone() {
        XCTAssertFalse(undoes(devices: [5]))
    }

    func testUndoesSwitch_notWhenNothingSwitched() {
        XCTAssertFalse(undoes(to: 5, from: 5))
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
