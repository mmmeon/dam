import XCTest
import CoreGraphics
@testable import DAM

/// The Touch Bar arrange flow's pages and preview.
final class ArrangeTouchBarTests: XCTestCase {

    func testSteps_goBackOnePageAtATime() {
        let last = ArrangeTouchBar.Step.confirm(moving: 1, side: .left, other: 2)
        XCTAssertEqual(last.previous, .pickOther(moving: 1, side: .left))
        XCTAssertEqual(last.previous?.previous, .pickSide(moving: 1))
        XCTAssertEqual(last.previous?.previous?.previous, .pickDisplay)
        XCTAssertNil(ArrangeTouchBar.Step.pickDisplay.previous)
    }

    func testSentence_readsNaturally() {
        XCTAssertEqual(ArrangeTouchBar.sentence(moving: "tv", side: .left, other: "LEN T24i-20"),
                       "tv left of LEN T24i-20")
        XCTAssertEqual(ArrangeTouchBar.sentence(moving: "tv", side: .above, other: "LEN T24i-20"),
                       "tv above LEN T24i-20")
    }

    func testSides_offerAllFour() {
        XCTAssertEqual(ArrangeTouchBar.sides.map(\.side), [.left, .right, .above, .below])
        XCTAssertEqual(ArrangeTouchBar.sides.map(\.label), ["Left", "Right", "Top", "Bottom"])
    }

    func testPreviewImage_fitsTheTouchBar() {
        let layout = DisplayLayout(placements: [
            DisplayPlacement(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), names: ["a"], isMain: true),
            DisplayPlacement(id: 2, frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080), names: ["b"], isMain: false),
        ])
        let image = ArrangeTouchBar.previewImage(of: layout, moving: 2)
        XCTAssertNotNil(image)
        XCTAssertLessThanOrEqual(image!.size.height, 26)
        XCTAssertLessThanOrEqual(image!.size.width, 96)
        XCTAssertNil(ArrangeTouchBar.previewImage(of: DisplayLayout(placements: []), moving: 1))
    }
}
