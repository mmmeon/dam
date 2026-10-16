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

    // MARK: - Displays made for a stream

    func testAStreamUpTo2560WideGetsADisplayOfItsSize() {
        XCTAssertEqual(StreamingDisplayModes.forStream(width: 1920, height: 1200, fps: 60),
                       .init(width: 1920, height: 1200, refreshRate: 60))
        XCTAssertEqual(StreamingDisplayModes.forStream(width: 1366, height: 768, fps: 30),
                       .init(width: 1366, height: 768, refreshRate: 30))
    }

    func testASharperStreamGetsAHiDPIDisplayOfHalfItsSize() {
        let mode = StreamingDisplayModes.forStream(width: 2880, height: 1800, fps: 120)
        XCTAssertEqual(mode, .init(width: 1440, height: 900, refreshRate: 120, hiDPI: true))
        XCTAssertEqual(mode.pixelWidth, 2880)
        XCTAssertEqual(mode.pixelHeight, 1800)
    }

    func testOffersTheStreamsModeFirstAndOnce() {
        let start = StreamingDisplayModes.Mode(width: 1366, height: 768, refreshRate: 60)
        let modes = StreamingDisplayModes.advertised(startingIn: start)
        XCTAssertEqual(modes.first?.width, 1366)
        XCTAssertEqual(modes.first?.refreshRate, 60)
        XCTAssertEqual(modes.count, StreamingDisplayModes.advertised.count + 1)
        let standard = StreamingDisplayModes.advertised(startingIn: StreamingDisplayModes.start)
        XCTAssertEqual(standard.count, StreamingDisplayModes.advertised.count, "a listed mode is not listed twice")
    }

    func testAResizeWaitingLeavesTheCountAlone() {
        let mode = StreamingDisplayModes.start
        XCTAssertEqual(VideoManager.StreamingRequest.add(mode, completion: nil).countChange, 1)
        XCTAssertEqual(VideoManager.StreamingRequest.remove(index: 0).countChange, -1)
        XCTAssertEqual(VideoManager.StreamingRequest.resize(id: 1, mode, completion: { _ in }).countChange, 0)
    }

    // MARK: - Several displays

    func testEachDisplayHasItsOwnSerialAndName() {
        let indices = 0..<VideoManager.maxStreamingDisplays
        XCTAssertEqual(Set(indices.map(VideoManager.streamingSerial)).count, indices.count)
        XCTAssertEqual(Set(indices.map(VideoManager.streamingDisplayName)).count, indices.count)
    }

    func testFirstDisplayKeepsItsSerialAndName() {
        // macOS keys the place and resolution it saved for the display on these.
        XCTAssertEqual(VideoManager.streamingSerial(0), 0x0004)
        XCTAssertEqual(VideoManager.streamingDisplayName(0), "\(AppIdentity.name) Streaming")
        XCTAssertEqual(VideoManager.streamingDisplayName(1), "\(AppIdentity.name) Streaming 2")
    }

    func testSerialsDifferFromTheOtherVirtualDisplays() {
        // The anchors use 0x0002, the stand-in 0x0003.
        let serials = (0..<VideoManager.maxStreamingDisplays).map(VideoManager.streamingSerial)
        XCTAssertFalse(serials.contains(0x0002))
        XCTAssertFalse(serials.contains(0x0003))
    }

    func testArrangementWithoutARemovedDisplay() {
        let arrangement = DisplayArrangement(origins: [1: .zero, 2: CGPoint(x: 1440, y: 0)],
                                             mirrorMasters: [1: 0, 2: 0])
        let without = arrangement.excluding(2)
        XCTAssertEqual(without.origins, [1: .zero])
        XCTAssertEqual(without.mirrorMasters, [1: 0])
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

/// Makes and resizes a real streaming display through a VideoManager of its own. It changes
/// the Mac's display arrangement for a few seconds, so it runs only with DAM_TEST_DISPLAYS=1.
final class StreamingDisplayResizeTests: XCTestCase {

    func testResizesInPlaceKeepingTheDisplay() throws {
        guard ProcessInfo.processInfo.environment["DAM_TEST_DISPLAYS"] == "1" else {
            throw XCTSkip("real displays changed only with DAM_TEST_DISPLAYS=1")
        }
        let video = VideoManager()
        var id: CGDirectDisplayID?
        let made = expectation(description: "made")
        video.createStreamingDisplay(mode: .init(width: 1920, height: 1080, refreshRate: 60)) { id = $0; made.fulfill() }
        wait(for: [made], timeout: 30)
        let display = try XCTUnwrap(id)
        defer {
            video.removeStreamingDisplay(id: display)
            RunLoop.main.run(until: Date().addingTimeInterval(4))
        }
        var result: Bool?
        let resized = expectation(description: "resized")
        let began = Date()
        video.resizeStreamingDisplay(id: display, to: StreamingDisplayModes.forStream(width: 2532, height: 1170, fps: 60)) {
            result = $0; resized.fulfill()
        }
        wait(for: [resized], timeout: 10)
        NSLog("%@", "resize took \(String(format: "%.2f", Date().timeIntervalSince(began))) s")
        XCTAssertEqual(result, true)
        let mode = try XCTUnwrap(CGDisplayCopyDisplayMode(display))
        XCTAssertEqual([mode.width, mode.height, mode.pixelWidth], [2532, 1170, 2532])
        XCTAssertTrue(DisplayArrangement.onlineDisplayIDs().contains(display), "the same display, still online")
    }
}
