import AppKit
import Carbon.HIToolbox
import XCTest
@testable import DAM

final class HotkeyPreferenceTests: XCTestCase {

    /// The keys users' shortcuts are saved under, which must not change.
    private let storedKeys: [HotkeyAction: String] = [
        .switcher:       "\(AppIdentity.bundleID).hotkey",
        .airPlayConnect: "\(AppIdentity.bundleID).hotkeyAirPlayConnect",
        .mirrorToggle:   "\(AppIdentity.bundleID).hotkeyMirrorToggle",
        .audioCycle:     "\(AppIdentity.bundleID).hotkeyAudioCycle",
        .mainDisplay:    "\(AppIdentity.bundleID).hotkeyMainDisplay",
        .resolution:     "\(AppIdentity.bundleID).hotkeyResolution",
        .rotation:       "\(AppIdentity.bundleID).hotkeyRotation",
    ]

    /// The default shortcuts, ⌃⌥⌘ and a letter each.
    private let defaultKeys: [HotkeyAction: Int] = [
        .switcher: kVK_ANSI_B, .airPlayConnect: kVK_ANSI_A, .mirrorToggle: kVK_ANSI_M,
        .audioCycle: kVK_ANSI_O, .mainDisplay: kVK_ANSI_D, .resolution: kVK_ANSI_R, .rotation: kVK_ANSI_T,
    ]

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
        HotkeyAction.allCases.forEach { UserDefaults.dam.removeObject(forKey: $0.defaultsKey) }
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
        XCTAssertEqual(HotkeyAction.switcher.defaultShortcut.modifierString, "⌃⌥⌘")
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
        let switcher = HotkeyAction.switcher.defaultShortcut
        let data = try JSONEncoder().encode(switcher)
        let decoded = try JSONDecoder().decode(HotkeyPreference.self, from: data)
        XCTAssertEqual(decoded, switcher)
    }

    // MARK: - Actions

    func testEveryActionKeepsItsStoredKey() {
        for action in HotkeyAction.allCases {
            XCTAssertEqual(action.defaultsKey, storedKeys[action], "\(action)")
        }
    }

    func testEveryActionKeepsItsDefaultShortcut() {
        for action in HotkeyAction.allCases {
            let expected = HotkeyPreference(keyCode: UInt32(defaultKeys[action] ?? 0),
                                            modifiers: UInt32(controlKey | optionKey | cmdKey))
            XCTAssertEqual(action.defaultShortcut, expected, "\(action)")
        }
    }

    func testEveryActionHasATitleAndHelp() {
        for action in HotkeyAction.allCases {
            XCTAssertFalse(action.title.isEmpty, "\(action)")
            XCTAssertFalse(action.help.isEmpty, "\(action)")
        }
        XCTAssertEqual(Set(HotkeyAction.allCases.map(\.title)).count, HotkeyAction.allCases.count)
    }

    // MARK: - Persistence

    func testPersistence_defaultWhenNeverSet() {
        for action in HotkeyAction.allCases {
            XCTAssertEqual(action.shortcut, action.defaultShortcut, "\(action)")
        }
    }

    func testPersistence_roundTrip() {
        for action in HotkeyAction.allCases {
            let custom = HotkeyPreference(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(shiftKey | cmdKey))
            action.shortcut = custom
            XCTAssertEqual(action.shortcut, custom, "\(action)")
        }
    }

    func testPersistence_readsAShortcutStoredAsBefore() throws {
        // As every version so far stored them: the struct as JSON under the action's key.
        let stored = HotkeyPreference(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(optionKey | cmdKey))
        for action in HotkeyAction.allCases {
            UserDefaults.dam.set(try JSONEncoder().encode(stored), forKey: storedKeys[action] ?? "")
            XCTAssertEqual(action.shortcut, stored, "\(action)")
        }
    }

    func testPersistence_writeOneKey_doesNotAffectOthers() {
        for action in HotkeyAction.allCases {
            clearPreferences()
            action.shortcut = HotkeyPreference(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey))
            for other in HotkeyAction.allCases where other != action {
                XCTAssertEqual(other.shortcut, other.defaultShortcut, "\(action) changed \(other)")
            }
        }
    }

    // MARK: - Clashes

    func testClashes_sameKeys_nameEachOther() {
        let a = HotkeyAction.airPlayConnect.defaultShortcut
        let clashes = HotkeyPreference.clashes(among: [HotkeyAction.switcher.defaultShortcut, a,
                                                       HotkeyAction.mirrorToggle.defaultShortcut, a])
        XCTAssertEqual(clashes, [[], [3], [], [1]])
    }

    func testClashes_sameKeyOtherModifiers_doNotClash() {
        let switcher = HotkeyAction.switcher.defaultShortcut
        let shifted = HotkeyPreference(keyCode: switcher.keyCode, modifiers: switcher.modifiers | UInt32(shiftKey))
        XCTAssertEqual(HotkeyPreference.clashes(among: [switcher, shifted]), [[], []])
    }

    func testClashes_defaults_none() {
        let defaults = HotkeyAction.allCases.map(\.defaultShortcut)
        XCTAssertTrue(HotkeyPreference.clashes(among: defaults).allSatisfy(\.isEmpty))
    }
}
