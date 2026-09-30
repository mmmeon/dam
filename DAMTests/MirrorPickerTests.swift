import XCTest
import CoreGraphics
@testable import DAM

/// The choices the mirror hotkey's picker offers and which one reflects the current state.
final class MirrorPickerTests: XCTestCase {

    private func display(_ name: String, cgID: CGDirectDisplayID) -> DisplayInfo {
        DisplayInfo(id: name, name: name, isConnected: true, cgDisplayID: cgID,
                    isMirroring: false, isBuiltIn: false)
    }

    private lazy var builtIn  = display("Built-in Display", cgID: 1)
    private lazy var external = display("LEN T24i-20", cgID: 2)

    func testChoices_oneTarget_hasNoAllEntry() {
        XCTAssertEqual(MirrorPicker.choices(targets: [external]), [.separate, .display(external)])
    }

    func testChoices_severalTargets_endWithAll() {
        XCTAssertEqual(MirrorPicker.choices(targets: [builtIn, external]),
                       [.separate, .display(builtIn), .display(external), .all])
    }

    func testChoices_namesReadAsActions() {
        let names = MirrorPicker.choices(targets: [builtIn, external]).map(\.name)
        XCTAssertEqual(names, ["Separate Display", "Mirror on Built-in Display",
                               "Mirror on LEN T24i-20", "Mirror on All Displays"])
    }

    func testCurrent_extended_isSeparate() {
        let choices = MirrorPicker.choices(targets: [builtIn, external])
        XCTAssertEqual(MirrorPicker.currentChoice(in: choices, slaves: [], master: nil), 0)
    }

    func testCurrent_oneSlave_isThatDisplay() {
        let choices = MirrorPicker.choices(targets: [builtIn, external])
        XCTAssertEqual(MirrorPicker.currentChoice(in: choices, slaves: [external], master: nil), 2)
    }

    func testCurrent_everyTargetMirroring_isAll() {
        let choices = MirrorPicker.choices(targets: [builtIn, external])
        XCTAssertEqual(MirrorPicker.currentChoice(in: choices, slaves: [builtIn, external], master: nil), 3)
    }

    func testCurrent_singleTargetMirroring_isThatDisplay_notAll() {
        let choices = MirrorPicker.choices(targets: [external])
        XCTAssertEqual(MirrorPicker.currentChoice(in: choices, slaves: [external], master: nil), 1)
    }

    func testCurrent_subjectIsSlave_isItsMaster() {
        let choices = MirrorPicker.choices(targets: [builtIn, external])
        XCTAssertEqual(MirrorPicker.currentChoice(in: choices, slaves: [], master: builtIn), 1)
    }
}
