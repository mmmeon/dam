import XCTest
import CoreGraphics
@testable import DAM

/// The rules the Arrange Displays window and the "Position" menu move displays by.
final class DisplayLayoutTests: XCTestCase {

    private let a: CGDirectDisplayID = 1
    private let b: CGDirectDisplayID = 2
    private let c: CGDirectDisplayID = 3

    private func placement(_ id: CGDirectDisplayID, _ x: CGFloat, _ y: CGFloat,
                           _ w: CGFloat = 1920, _ h: CGFloat = 1080, main: Bool = false) -> DisplayPlacement {
        DisplayPlacement(id: id, frame: CGRect(x: x, y: y, width: w, height: h),
                         names: ["Display \(id)"], isMain: main)
    }

    /// The main display with another to its left, as on the dev Mac.
    private var sideBySide: DisplayLayout {
        DisplayLayout(placements: [placement(a, 0, 0, main: true), placement(b, -1920, 0)])
    }

    // MARK: - displaysUnder

    func testDisplaysUnder_heldSquarelyOverAnother_findsIt() {
        let held = CGRect(x: -1700, y: 100, width: 1920, height: 1080)
        XCTAssertEqual(sideBySide.displaysUnder(a, at: held), [b])
    }

    func testDisplaysUnder_justOverlappingTheEdge_findsNothing() {
        let held = CGRect(x: -300, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(sideBySide.displaysUnder(a, at: held), [])
    }

    func testDisplaysUnder_smallDisplayInsideLargeOne_findsIt() {
        let layout = DisplayLayout(placements: [placement(a, 0, 0, 3840, 2160, main: true),
                                                placement(b, 3840, 0, 1280, 800)])
        XCTAssertEqual(layout.displaysUnder(b, at: CGRect(x: 500, y: 500, width: 1280, height: 800)), [a])
    }

    func testDisplaysUnder_straddlingTwo_findsBoth() {
        let layout = DisplayLayout(placements: [placement(a, 0, 0, main: true), placement(b, 1920, 0),
                                                placement(c, 0, 1080, 1920, 1080)])
        let held = CGRect(x: 960, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(layout.displaysUnder(c, at: held), [a, b])
    }

    // MARK: - displayCount

    func testDisplayCount_countsEveryMemberOfAMirrorSet() {
        let set = DisplayPlacement(id: a, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                   names: ["A", "B"], isMain: true, memberIDs: [a, b])
        XCTAssertEqual(DisplayLayout(placements: [set]).displayCount, 2)
    }

    // MARK: - snap

    func testSnap_dropNearRightEdge_landsOnIt() {
        let landed = DisplayLayout.snap(CGRect(x: 2000, y: 100, width: 1920, height: 1080),
                                        to: [CGRect(x: 0, y: 0, width: 1920, height: 1080)])
        XCTAssertEqual(landed, CGRect(x: 1920, y: 100, width: 1920, height: 1080))
    }

    func testSnap_dropOverlapping_movesToTheNearestEdge() {
        let landed = DisplayLayout.snap(CGRect(x: 1500, y: 0, width: 1920, height: 1080),
                                        to: [CGRect(x: 0, y: 0, width: 1920, height: 1080)])
        XCTAssertEqual(landed?.origin, CGPoint(x: 1920, y: 0))
    }

    func testSnap_dropBelow_keepsHorizontalPosition() {
        let landed = DisplayLayout.snap(CGRect(x: 300, y: 1300, width: 1440, height: 900),
                                        to: [CGRect(x: 0, y: 0, width: 1920, height: 1080)])
        XCTAssertEqual(landed?.origin, CGPoint(x: 300, y: 1080))
    }

    func testSnap_dropFarAlongTheEdge_keepsAMinimumOfSharedEdge() {
        // Far below and just past the right corner: below is nearer, and it slides back
        // until enough of the top edge touches.
        let landed = DisplayLayout.snap(CGRect(x: 1920, y: 3000, width: 1920, height: 1080),
                                        to: [CGRect(x: 0, y: 0, width: 1920, height: 1080)])
        XCTAssertEqual(landed?.origin, CGPoint(x: 1920 - DisplayLayout.minimumSharedEdge, y: 1080))
    }

    func testSnap_neverLandsOnAnotherDisplay() {
        let others = [CGRect(x: 0, y: 0, width: 1920, height: 1080),
                      CGRect(x: 1920, y: 0, width: 1920, height: 1080)]
        let landed = DisplayLayout.snap(CGRect(x: 1900, y: 50, width: 1000, height: 800), to: others)!
        XCTAssertFalse(others.contains { DisplayLayout.overlaps(landed, $0) })
        XCTAssertTrue(others.contains { DisplayLayout.attached(landed, $0) })
    }

    // MARK: - moving

    func testMoving_toTheOtherSide_swapsTheArrangement() {
        let moved = sideBySide.moving(b, to: CGPoint(x: 2100, y: 40))
        XCTAssertEqual(moved[b]?.frame.origin, CGPoint(x: 1920, y: 40))
        XCTAssertEqual(moved[a]?.frame.origin, .zero)
        XCTAssertTrue(moved.isConnected)
    }

    func testMoving_theBridgeDisplay_pullsTheStrandedOneAlong() {
        // b — a — c in a row; a moves far below, and c must follow.
        let row = DisplayLayout(placements: [placement(a, 0, 0, main: true),
                                             placement(b, -1920, 0), placement(c, 1920, 0)])
        let moved = row.moving(a, to: CGPoint(x: -1920, y: 1080))
        XCTAssertEqual(moved[a]?.frame.origin, CGPoint(x: -1920, y: 1080))
        XCTAssertTrue(moved.isConnected)
        XCTAssertFalse(DisplayLayout.overlaps(moved[b]!.frame, moved[c]!.frame))
    }

    func testMoving_unknownDisplay_changesNothing() {
        XCTAssertEqual(sideBySide.moving(99, to: CGPoint(x: 5, y: 5)), sideBySide)
    }

    // MARK: - placing

    func testPlacing_rightOf_centresAlongTheEdge() {
        let moved = sideBySide.placing(b, .right, of: a)
        XCTAssertEqual(moved[b]?.frame.origin, CGPoint(x: 1920, y: 0))
        XCTAssertEqual(moved.side(of: b, relativeTo: a), .right)
    }

    func testPlacing_aboveASmallerDisplay_centresIt() {
        let layout = DisplayLayout(placements: [placement(a, 0, 0, 1440, 900, main: true),
                                                placement(b, 1440, 0)])
        let moved = layout.placing(b, .above, of: a)
        XCTAssertEqual(moved[b]?.frame.origin, CGPoint(x: -240, y: -1080))
        XCTAssertEqual(moved.side(of: b, relativeTo: a), .above)
    }

    func testPlacing_below_thenSide_reportsBelow() {
        let moved = sideBySide.placing(b, .below, of: a)
        XCTAssertEqual(moved[b]?.frame.origin, CGPoint(x: 0, y: 1080))
        XCTAssertEqual(moved.side(of: b, relativeTo: a), .below)
        XCTAssertEqual(moved.side(of: a, relativeTo: b), .above)
    }

    func testSide_detached_isNil() {
        let apart = DisplayLayout(placements: [placement(a, 0, 0, main: true), placement(b, 3000, 0)])
        XCTAssertNil(apart.side(of: b, relativeTo: a))
        XCTAssertFalse(apart.isConnected)
    }

    // MARK: - origins

    func testOrigins_keepTheMainDisplayAtTheOrigin() {
        let moved = sideBySide.moving(a, to: CGPoint(x: -3800, y: 100))
        let origins = moved.origins()
        XCTAssertEqual(origins[a], .zero)
        XCTAssertEqual(origins[b], CGPoint(x: 1920, y: -100))
    }

    func testOrigins_makingAnotherDisplayMain_shiftsEverything() {
        let origins = sideBySide.origins(makingMain: b)
        XCTAssertEqual(origins[b], .zero)
        XCTAssertEqual(origins[a], CGPoint(x: 1920, y: 0))
    }

    // MARK: - placement

    func testPlacement_nameJoinsAMirrorSet() {
        let set = DisplayPlacement(id: a, frame: .zero, names: ["LEN T24i-20", "tv"], isMain: true,
                                   memberIDs: [a, b])
        XCTAssertEqual(set.name, "LEN T24i-20 + tv")
        XCTAssertEqual(placement(a, 0, 0).memberIDs, [a])
    }
}
