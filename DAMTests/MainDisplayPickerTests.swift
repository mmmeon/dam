import XCTest
import CoreGraphics
@testable import DAM

/// The entries the main-display hotkey's picker offers and which one is current.
final class MainDisplayPickerTests: XCTestCase {

    private func display(_ name: String, cgID: CGDirectDisplayID, main: Bool = false) -> DisplayInfo {
        DisplayInfo(id: name, name: name, isConnected: true, cgDisplayID: cgID,
                    isMirroring: false, isBuiltIn: false, isMain: main)
    }

    func testChoices_listDisplayNamesInOrder() {
        let (names, _) = MainDisplayPicker.choices(from: [display("Built-in Display", cgID: 1),
                                                          display("LEN T24i-20", cgID: 2),
                                                          display("tv", cgID: 3)])
        XCTAssertEqual(names, ["Built-in Display", "LEN T24i-20", "tv"])
    }

    func testChoices_currentIsTheMainDisplay() {
        let (_, current) = MainDisplayPicker.choices(from: [display("Built-in Display", cgID: 1),
                                                            display("LEN T24i-20", cgID: 2, main: true)])
        XCTAssertEqual(current, 1)
    }

    func testChoices_noMainMarked_fallsBackToFirst() {
        let (_, current) = MainDisplayPicker.choices(from: [display("a", cgID: 1), display("b", cgID: 2)])
        XCTAssertEqual(current, 0)
    }
}
