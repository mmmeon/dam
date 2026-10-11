import XCTest
import CoreGraphics
@testable import DAM

final class StreamingDisplayTests: XCTestCase {

    // MARK: - Modes

    func testComesUpAt1080p60() {
        let first = StreamingDisplayModes.advertised.first
        XCTAssertEqual(first?.width, 1920)
        XCTAssertEqual(first?.height, 1080)
        XCTAssertEqual(first?.refreshRate, 60)
    }

    func testOffersEverySizeAtEveryRateOnce() {
        let modes = StreamingDisplayModes.advertised
        XCTAssertEqual(modes.count, StreamingDisplayModes.sizes.count * StreamingDisplayModes.refreshRates.count)
        XCTAssertEqual(Set(modes.map { "\($0.width)x\($0.height)@\($0.refreshRate)" }).count, modes.count)
    }

    func testOffers1080pAtHiDPI() {
        // HiDPI 1920 × 1080 needs 3840 × 2160 listed too.
        XCTAssertTrue(StreamingDisplayModes.sizes.contains { $0 == (3840, 2160) })
        XCTAssertEqual(StreamingDisplayModes.maxPixelsWide, 3840)
        XCTAssertEqual(StreamingDisplayModes.maxPixelsHigh, 2160)
    }

    func testStreamingProductDiffersFromAnchorAndStandIn() {
        XCTAssertNotEqual(VideoManager.streamingProductID, VideoManager.anchorProductID)
        XCTAssertNotEqual(VideoManager.streamingProductID, VideoManager.bootstrapProductID)
    }

    func testStreamingDisplayIsNotOneOfTheMacsOwn() {
        XCTAssertFalse(VideoManager.hasOwnDisplay([(VideoManager.anchorVendorID, VideoManager.streamingProductID)]))
    }

    func testListsEveryShapeAndBothScales() {
        let m = { (w: Int, h: Int, hz: Int, scale: Int) in
            VideoManager.virtualMode(width: w, height: h, refreshRate: hz, pixelWidth: w * scale, pixelHeight: h * scale)
        }
        let modes = [m(1920, 1080, 60, 1), m(1920, 1080, 30, 1), m(1920, 1080, 60, 2),
                     m(1024, 768, 60, 1), m(1440, 900, 60, 1)]
        let listed = VideoManager.everyResolution(modes).map { "\($0.width)x\($0.height)\($0.isHiDPI ? "@2x" : "")" }
        XCTAssertEqual(listed, ["1920x1080@2x", "1920x1080", "1440x900", "1024x768"])
    }

    func testListsOnlyHiDPIModesWithinItsLargestSize() {
        let m = { (w: Int, h: Int, scale: Int) in
            VideoManager.virtualMode(width: w, height: h, refreshRate: 60, pixelWidth: w * scale, pixelHeight: h * scale)
        }
        XCTAssertTrue(StreamingDisplayModes.fits(m(1920, 1080, 2)))
        XCTAssertTrue(StreamingDisplayModes.fits(m(1440, 900, 2)))
        XCTAssertTrue(StreamingDisplayModes.fits(m(3840, 2160, 1)))
        // macOS offers these at 2x too: 5120 × 2880 and 3840 × 2400.
        XCTAssertFalse(StreamingDisplayModes.fits(m(2560, 1440, 2)))
        XCTAssertFalse(StreamingDisplayModes.fits(m(1920, 1200, 2)))
    }

    // MARK: - Main display

    func testHandsMainBackToTheDisplayThatHadIt() {
        XCTAssertEqual(VideoManager.displayToMakeMain(candidates: [7, 3], previousMain: 3), 3)
    }

    func testHandsMainToAnotherDisplayWhenThatOneIsGone() {
        XCTAssertEqual(VideoManager.displayToMakeMain(candidates: [7, 3], previousMain: 5), 7)
        XCTAssertEqual(VideoManager.displayToMakeMain(candidates: [7], previousMain: nil), 7)
    }

    func testKeepsMainWithNoOtherDisplay() {
        XCTAssertNil(VideoManager.displayToMakeMain(candidates: [], previousMain: 3))
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
