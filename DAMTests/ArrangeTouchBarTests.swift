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

    // MARK: - Applying to the arrangement as it is now

    private func placement(_ id: CGDirectDisplayID, x: CGFloat, y: CGFloat = 0) -> DisplayPlacement {
        DisplayPlacement(id: id, frame: CGRect(x: x, y: y, width: 1920, height: 1080), names: ["\(id)"], isMain: id == 1)
    }

    func testArrangement_appliesToTheLayoutAsItIsNow() {
        // When the flow began 3 was right of 2; it has since moved below 1.
        let now = DisplayLayout(placements: [placement(1, x: 0), placement(2, x: 1920), placement(3, x: 0, y: 1080)])
        let result = ArrangeTouchBar.arrangement(placing: 2, .left, of: 1, in: now)
        XCTAssertEqual(result?[3]?.frame.origin, CGPoint(x: 0, y: 1080), "Displays not moved stay where they are now")
        XCTAssertEqual(result?[2]?.frame.maxX, 0)
    }

    func testArrangement_displayGone_isNil() {
        let now = DisplayLayout(placements: [placement(1, x: 0), placement(2, x: 1920)])
        XCTAssertNil(ArrangeTouchBar.arrangement(placing: 3, .left, of: 1, in: now))
        XCTAssertNil(ArrangeTouchBar.arrangement(placing: 2, .left, of: 3, in: now))
    }

    func testMapDrop_appliesToTheLayoutGiven() {
        let now = DisplayLayout(placements: [placement(1, x: 0), placement(2, x: 1920), placement(3, x: 0, y: 1080)])
        let dropped = DisplayMapView.drop(2, at: CGPoint(x: -1920, y: 0), into: now)
        XCTAssertEqual(dropped?[2]?.frame.origin, CGPoint(x: -1920, y: 0))
        XCTAssertEqual(dropped?[3]?.frame.origin, CGPoint(x: 0, y: 1080))
    }

    func testMapDrop_displayGoneOrUnmoved_isNil() {
        let now = DisplayLayout(placements: [placement(1, x: 0), placement(2, x: 1920)])
        XCTAssertNil(DisplayMapView.drop(3, at: .zero, into: now))
        XCTAssertNil(DisplayMapView.drop(2, at: CGPoint(x: 1920, y: 0), into: now))
    }
}
