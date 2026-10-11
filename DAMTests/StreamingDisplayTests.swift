import XCTest
import CoreGraphics
@testable import DAM

final class StreamingDisplayTests: XCTestCase {

    // MARK: - Preset

    func testIPadPresetLooksLikeHalfItsPanel() {
        let preset = StreamingDisplayPreset.iPadPro9_7
        XCTAssertEqual(preset.width, 1024)
        XCTAssertEqual(preset.height, 768)
        XCTAssertEqual(preset.refreshRate, 60)
    }

    func testPresetAdvertisesBackingThenLogicalSize() {
        let sizes = StreamingDisplayPreset.iPadPro9_7.advertisedSizes
        XCTAssertEqual(sizes.map(\.width), [2048, 1024])
        XCTAssertEqual(sizes.map(\.height), [1536, 768])
    }

    func testStreamingProductDiffersFromAnchorAndStandIn() {
        XCTAssertNotEqual(VideoManager.streamingProductID, VideoManager.anchorProductID)
        XCTAssertNotEqual(VideoManager.streamingProductID, VideoManager.bootstrapProductID)
    }

    func testStreamingDisplayIsNotOneOfTheMacsOwn() {
        XCTAssertFalse(VideoManager.hasOwnDisplay([(VideoManager.anchorVendorID, VideoManager.streamingProductID)]))
    }

    // MARK: - Placement

    func testGoesRightOfTheOnlyDisplay() {
        let origin = VideoManager.streamingDisplayOrigin(others: [CGRect(x: 0, y: 0, width: 1440, height: 900)])
        XCTAssertEqual(origin, CGPoint(x: 1440, y: 0))
    }

    func testGoesRightOfTheRightmostDisplay() {
        let origin = VideoManager.streamingDisplayOrigin(others: [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: 1440, y: -200, width: 1920, height: 1080),
            CGRect(x: -1280, y: 0, width: 1280, height: 800)
        ])
        XCTAssertEqual(origin, CGPoint(x: 3360, y: 0))
    }

    func testGoesAtTheOriginWithNoOtherDisplay() {
        XCTAssertEqual(VideoManager.streamingDisplayOrigin(others: []), .zero)
    }
}

final class DisplayArrangementSameSetTests: XCTestCase {
    func testSameDisplaysMirroredTheSameWayMatch() {
        XCTAssertTrue(DisplayArrangement.sameSet(captured: [1: 0, 2: 1], online: [2, 1],
                                                 mirrorOf: { [1: 0, 2: 1][$0] ?? 0 }))
    }

    func testADisplayThatJoinedDoesNotMatch() {
        XCTAssertFalse(DisplayArrangement.sameSet(captured: [1: 0], online: [1, 3], mirrorOf: { _ in 0 }))
    }

    func testADisplayNowMirroringDoesNotMatch() {
        XCTAssertFalse(DisplayArrangement.sameSet(captured: [1: 0, 3: 0], online: [1, 3],
                                                  mirrorOf: { $0 == 1 ? 3 : 0 }))
    }
}
