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

    // MARK: - Pausing

    /// Keys no one is likely to have: ⌃⌥⇧⌘F19.
    private let unlikely = HotkeyPreference(keyCode: UInt32(kVK_F19),
                                            modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))

    func testPausing_unregistersUntilResumed() {
        let hotkey = GlobalHotkey(preference: unlikely) {}
        XCTAssertTrue(hotkey.isRegistered)
        GlobalHotkey.pauseAll()
        XCTAssertFalse(hotkey.isRegistered)
        // A shortcut changed meanwhile waits for the resume too.
        hotkey.update(preference: unlikely)
        XCTAssertFalse(hotkey.isRegistered)
        GlobalHotkey.resumeAll()
        XCTAssertTrue(hotkey.isRegistered)
    }

    func testPausing_twiceNeedsTwoResumes() {
        let hotkey = GlobalHotkey(preference: unlikely) {}
        GlobalHotkey.pauseAll()
        GlobalHotkey.pauseAll()
        GlobalHotkey.resumeAll()
        XCTAssertFalse(hotkey.isRegistered)
        GlobalHotkey.resumeAll()
        XCTAssertTrue(hotkey.isRegistered)
        // An extra resume changes nothing.
        GlobalHotkey.resumeAll()
        XCTAssertTrue(hotkey.isRegistered)
    }

    func testPausing_theFirstMadeKeepsSharedKeys() {
        let first = GlobalHotkey(preference: unlikely) {}
        let second = GlobalHotkey(preference: unlikely) {}
        GlobalHotkey.pauseAll()
        GlobalHotkey.resumeAll()
        XCTAssertTrue(first.isRegistered)
        XCTAssertFalse(second.isRegistered)
    }

    // MARK: - Rebinding

    func testRebinding_freesTheKeysForAnotherShortcut() {
        // As AppDelegate's rebind: one shortcut moves, then the others try their keys again.
        let other = HotkeyPreference(keyCode: UInt32(kVK_F18),
                                     modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        let first = GlobalHotkey(preference: unlikely) {}
        let second = GlobalHotkey(preference: unlikely) {}
        XCTAssertFalse(second.isRegistered)
        first.update(preference: other)
        second.registerIfNeeded()
        XCTAssertTrue(first.isRegistered)
        XCTAssertTrue(second.isRegistered)
    }

    func testRegisterIfNeeded_leavesARegisteredShortcutBe() {
        let hotkey = GlobalHotkey(preference: unlikely) {}
        hotkey.registerIfNeeded()
        XCTAssertTrue(hotkey.isRegistered)
    }

    // MARK: - Key names

    func testKeyString_namesKeysThatTypeNothingVisible() {
        let names: [Int: String] = [
            kVK_F1: "F1", kVK_F5: "F5", kVK_F12: "F12", kVK_F19: "F19", kVK_F20: "F20",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
        ]
        for (key, name) in names {
            XCTAssertEqual(HotkeyPreference(keyCode: UInt32(key), modifiers: UInt32(cmdKey)).keyString, name, "\(key)")
        }
    }

    func testKeyString_everyCharacterKeyHasAName() {
        // In whatever layout the Mac has, dead keys (^ on a German or French one) among them.
        let keys = [kVK_ANSI_A, kVK_ANSI_Z, kVK_ANSI_1, kVK_ANSI_0, kVK_ANSI_Grave, kVK_ANSI_Equal,
                    kVK_ANSI_LeftBracket, kVK_ANSI_Quote, kVK_ANSI_Semicolon, kVK_ANSI_Backslash,
                    kVK_ANSI_Comma, kVK_ANSI_Slash]
        for key in keys {
            let name = HotkeyPreference(keyCode: UInt32(key), modifiers: UInt32(cmdKey)).keyString
            XCTAssertFalse(name.hasPrefix("("), "\(key) is \(name)")
        }
    }
}

// MARK: - KeyRecorderView

final class KeyRecorderViewTests: XCTestCase {

    private var window: NSWindow!
    private var recorder: KeyRecorderView!
    private let start = HotkeyAction.switcher.defaultShortcut

    // A window never put on screen, so the recorder can be first responder.
    override func setUp() {
        super.setUp()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                          styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        recorder = KeyRecorderView(preference: start)
        window.contentView?.addSubview(recorder)
    }

    override func tearDown() {
        recorder.cancel()
        recorder = nil
        window = nil
        super.tearDown()
    }

    private func key(_ code: Int, _ modifiers: NSEvent.ModifierFlags, _ characters: String = "q") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code))!
    }

    func testRecording_takesTheAppsOwnShortcuts() {
        var recorded: [HotkeyPreference] = []
        recorder.onChanged = { recorded.append($0) }
        let shortcuts: [(code: Int, flags: NSEvent.ModifierFlags, carbon: Int)] = [
            (kVK_ANSI_Q, [.command], cmdKey),
            (kVK_ANSI_H, [.command], cmdKey),
            (kVK_ANSI_H, [.option, .command], optionKey | cmdKey),
            (kVK_ANSI_W, [.command], cmdKey),
        ]
        for shortcut in shortcuts {
            recorder.startRecording()
            XCTAssertTrue(recorder.performKeyEquivalent(with: key(shortcut.code, shortcut.flags)), "\(shortcut.code)")
        }
        XCTAssertEqual(recorded, shortcuts.map { HotkeyPreference(keyCode: UInt32($0.code), modifiers: UInt32($0.carbon)) })
        XCTAssertEqual(recorder.preference, recorded.last)
    }

    func testNotRecording_leavesKeyEquivalentsToTheApp() {
        recorder.onChanged = { _ in XCTFail("recorded") }
        XCTAssertFalse(recorder.performKeyEquivalent(with: key(kVK_ANSI_Q, [.command])))
        XCTAssertEqual(recorder.preference, start)
    }

    func testBareKeyIsNotRecorded_escapeCancels() {
        recorder.onChanged = { _ in XCTFail("recorded") }
        recorder.startRecording()
        recorder.keyDown(with: key(kVK_ANSI_Q, []))
        XCTAssertEqual(recorder.accessibilityValue() as? String, "Type shortcut")
        recorder.keyDown(with: key(kVK_Escape, [], "\u{1b}"))
        XCTAssertEqual(recorder.preference, start)
        XCTAssertEqual(recorder.accessibilityValue() as? String, start.displayString)
    }

    func testRecording_pausesTheAppsHotkeys() {
        let hotkey = GlobalHotkey(preference: HotkeyPreference(
            keyCode: UInt32(kVK_F17), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))) {}
        XCTAssertTrue(hotkey.isRegistered)
        recorder.startRecording()
        XCTAssertFalse(hotkey.isRegistered)
        recorder.cancel()
        XCTAssertTrue(hotkey.isRegistered)
    }

    func testAccessibility_aButtonNamedForItsShortcut() {
        recorder.setAccessibilityLabel(HotkeyAction.switcher.title)
        XCTAssertTrue(recorder.isAccessibilityElement())
        XCTAssertEqual(recorder.accessibilityRole(), .button)
        XCTAssertEqual(recorder.accessibilityLabel(), "Switcher")
        XCTAssertEqual(recorder.accessibilityValue() as? String, start.displayString)
        // Pressed as VoiceOver presses it, it starts recording; pressed again, it cancels.
        XCTAssertTrue(recorder.accessibilityPerformPress())
        XCTAssertEqual(recorder.accessibilityValue() as? String, "Type shortcut")
        XCTAssertTrue(recorder.accessibilityPerformPress())
        XCTAssertEqual(recorder.accessibilityValue() as? String, start.displayString)
    }
}
