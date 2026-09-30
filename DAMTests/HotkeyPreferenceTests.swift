import AppKit
import Carbon.HIToolbox
import XCTest
@testable import DAM

final class HotkeyPreferenceTests: XCTestCase {

    private let key1 = "\(AppIdentity.bundleID).hotkey"
    private let key2 = "\(AppIdentity.bundleID).hotkeyAirPlayConnect"
    private let key3 = "\(AppIdentity.bundleID).hotkeyMirrorToggle"
    private let key4 = "\(AppIdentity.bundleID).hotkeyAudioCycle"
    private let key5 = "\(AppIdentity.bundleID).hotkeyMainDisplay"

    override func tearDown() {
        super.tearDown()
        [key1, key2, key3, key4, key5].forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    // MARK: - modifierString

    func testModifierString_allModifiers_correctOrder() {
        let pref = HotkeyPreference(
            keyCode: UInt32(kVK_ANSI_B),
            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)
        )
        // macOS standard order: ⌃ ⌥ ⇧ ⌘
        XCTAssertEqual(pref.modifierString, "⌃⌥⇧⌘")
    }

    func testModifierString_controlOnly() {
        let pref = HotkeyPreference(keyCode: 0, modifiers: UInt32(controlKey))
        XCTAssertEqual(pref.modifierString, "⌃")
    }

    func testModifierString_optionOnly() {
        let pref = HotkeyPreference(keyCode: 0, modifiers: UInt32(optionKey))
        XCTAssertEqual(pref.modifierString, "⌥")
    }

    func testModifierString_shiftOnly() {
        let pref = HotkeyPreference(keyCode: 0, modifiers: UInt32(shiftKey))
        XCTAssertEqual(pref.modifierString, "⇧")
    }

    func testModifierString_commandOnly() {
        let pref = HotkeyPreference(keyCode: 0, modifiers: UInt32(cmdKey))
        XCTAssertEqual(pref.modifierString, "⌘")
    }

    func testModifierString_noModifiers_emptyString() {
        let pref = HotkeyPreference(keyCode: 0, modifiers: 0)
        XCTAssertEqual(pref.modifierString, "")
    }

    func testModifierString_ctrlCmd_noOptShift() {
        let pref = HotkeyPreference(keyCode: 0, modifiers: UInt32(controlKey | cmdKey))
        XCTAssertEqual(pref.modifierString, "⌃⌘")
    }

    func testModifierString_ctrlOptCmd_matchesDefaultHotkey() {
        XCTAssertEqual(HotkeyPreference.default.modifierString, "⌃⌥⌘")
    }

    func testModifierString_controlNotContainedInOptionBits() {
        // Ensure no bit-bleed between modifier flags
        let pref = HotkeyPreference(keyCode: 0, modifiers: UInt32(optionKey))
        XCTAssertFalse(pref.modifierString.contains("⌃"))
    }

    // MARK: - NSEvent.ModifierFlags.carbonFlags

    func testCarbonFlags_controlKey() {
        let flags: NSEvent.ModifierFlags = [.control]
        XCTAssertEqual(flags.carbonFlags & UInt32(controlKey), UInt32(controlKey))
    }

    func testCarbonFlags_optionKey() {
        let flags: NSEvent.ModifierFlags = [.option]
        XCTAssertEqual(flags.carbonFlags & UInt32(optionKey), UInt32(optionKey))
    }

    func testCarbonFlags_shiftKey() {
        let flags: NSEvent.ModifierFlags = [.shift]
        XCTAssertEqual(flags.carbonFlags & UInt32(shiftKey), UInt32(shiftKey))
    }

    func testCarbonFlags_commandKey() {
        let flags: NSEvent.ModifierFlags = [.command]
        XCTAssertEqual(flags.carbonFlags & UInt32(cmdKey), UInt32(cmdKey))
    }

    func testCarbonFlags_combinedCtrlOptCmd() {
        let flags: NSEvent.ModifierFlags = [.control, .option, .command]
        let carbon = flags.carbonFlags
        XCTAssertEqual(carbon & UInt32(controlKey), UInt32(controlKey))
        XCTAssertEqual(carbon & UInt32(optionKey),  UInt32(optionKey))
        XCTAssertEqual(carbon & UInt32(cmdKey),     UInt32(cmdKey))
        XCTAssertEqual(carbon & UInt32(shiftKey),   0)
    }

    func testCarbonFlags_emptyFlags_returnsZero() {
        let flags: NSEvent.ModifierFlags = []
        XCTAssertEqual(flags.carbonFlags, 0)
    }

    func testCarbonFlags_roundTripWithModifierString() {
        // AppKit flags → carbonFlags → HotkeyPreference.modifierString
        let flags: NSEvent.ModifierFlags = [.control, .option, .command]
        let pref = HotkeyPreference(keyCode: UInt32(kVK_ANSI_B), modifiers: flags.carbonFlags)
        XCTAssertEqual(pref.modifierString, "⌃⌥⌘")
    }

    // MARK: - Codable

    func testCodable_roundTrip() throws {
        let original = HotkeyPreference(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | cmdKey))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HotkeyPreference.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCodable_defaultValue_roundTrip() throws {
        let data = try JSONEncoder().encode(HotkeyPreference.default)
        let decoded = try JSONDecoder().decode(HotkeyPreference.self, from: data)
        XCTAssertEqual(decoded, HotkeyPreference.default)
    }

    // MARK: - Persistence

    func testPersistence_current_defaultWhenNeverSet() {
        XCTAssertEqual(HotkeyPreference.current, HotkeyPreference.default)
    }

    func testPersistence_current_roundTrip() {
        let custom = HotkeyPreference(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(shiftKey | cmdKey))
        HotkeyPreference.current = custom
        XCTAssertEqual(HotkeyPreference.current, custom)
    }

    func testPersistence_currentAirPlayConnect_defaultWhenNeverSet() {
        XCTAssertEqual(HotkeyPreference.currentAirPlayConnect, HotkeyPreference.defaultAirPlayConnect)
    }

    func testPersistence_currentAirPlayConnect_roundTrip() {
        let custom = HotkeyPreference(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(controlKey | optionKey))
        HotkeyPreference.currentAirPlayConnect = custom
        XCTAssertEqual(HotkeyPreference.currentAirPlayConnect, custom)
    }

    func testPersistence_currentMirrorToggle_defaultWhenNeverSet() {
        XCTAssertEqual(HotkeyPreference.currentMirrorToggle, HotkeyPreference.defaultMirrorToggle)
    }

    func testPersistence_currentMirrorToggle_roundTrip() {
        let custom = HotkeyPreference(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey))
        HotkeyPreference.currentMirrorToggle = custom
        XCTAssertEqual(HotkeyPreference.currentMirrorToggle, custom)
    }

    func testPersistence_currentAudioCycle_defaultWhenNeverSet() {
        XCTAssertEqual(HotkeyPreference.currentAudioCycle, HotkeyPreference.defaultAudioCycle)
    }

    func testPersistence_currentAudioCycle_roundTrip() {
        let custom = HotkeyPreference(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey | cmdKey))
        HotkeyPreference.currentAudioCycle = custom
        XCTAssertEqual(HotkeyPreference.currentAudioCycle, custom)
    }

    func testPersistence_currentMainDisplay_defaultWhenNeverSet() {
        XCTAssertEqual(HotkeyPreference.currentMainDisplay, HotkeyPreference.defaultMainDisplay)
    }

    func testPersistence_currentMainDisplay_roundTrip() {
        let custom = HotkeyPreference(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(optionKey | cmdKey))
        HotkeyPreference.currentMainDisplay = custom
        XCTAssertEqual(HotkeyPreference.currentMainDisplay, custom)
    }

    func testPersistence_writeOneKey_doesNotAffectOthers() {
        let customMain = HotkeyPreference(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey))
        HotkeyPreference.current = customMain
        // The other two should still return their defaults
        XCTAssertEqual(HotkeyPreference.currentAirPlayConnect, HotkeyPreference.defaultAirPlayConnect)
        XCTAssertEqual(HotkeyPreference.currentMirrorToggle,   HotkeyPreference.defaultMirrorToggle)
        XCTAssertEqual(HotkeyPreference.currentAudioCycle,     HotkeyPreference.defaultAudioCycle)
        XCTAssertEqual(HotkeyPreference.currentMainDisplay,    HotkeyPreference.defaultMainDisplay)
    }
}
