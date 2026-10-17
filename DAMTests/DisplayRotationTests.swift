import XCTest
import CoreGraphics
import CoreVideo
import IOKit.graphics
@testable import DAM

final class DisplayRotationTests: XCTestCase {

    // MARK: - Rotation

    func testReadsCoreGraphicsDegrees() {
        XCTAssertEqual(DisplayRotation(degrees: 0), .standard)
        XCTAssertEqual(DisplayRotation(degrees: 90), .quarter)
        XCTAssertEqual(DisplayRotation(degrees: 180), .half)
        XCTAssertEqual(DisplayRotation(degrees: 270), .threeQuarters)
        XCTAssertEqual(DisplayRotation(degrees: 360), .standard)
        XCTAssertEqual(DisplayRotation(degrees: -90), .threeQuarters)
        XCTAssertEqual(DisplayRotation(degrees: 89.9), .quarter)
    }

    func testOnlyQuarterTurnsSwapTheSides() {
        XCTAssertEqual(DisplayRotation.allCases.filter(\.swapsAxes), [.quarter, .threeQuarters])
        XCTAssertTrue(DisplayRotation.quarter.size(width: 1920, height: 1080) == (1080, 1920))
        XCTAssertTrue(DisplayRotation.half.size(width: 1920, height: 1080) == (1920, 1080))
    }

    func testInverseUndoesTheTurn() {
        XCTAssertEqual(DisplayRotation.standard.inverse, .standard)
        XCTAssertEqual(DisplayRotation.quarter.inverse, .threeQuarters)
        XCTAssertEqual(DisplayRotation.half.inverse, .half)
        XCTAssertEqual(DisplayRotation.threeQuarters.inverse, .quarter)
    }

    func testIOKitTransforms() {
        XCTAssertEqual(SystemRotation.transform(for: .standard), 0)
        XCTAssertEqual(SystemRotation.transform(for: .quarter), UInt32(kIOScaleSwapAxes | kIOScaleInvertX))
        XCTAssertEqual(SystemRotation.transform(for: .half), UInt32(kIOScaleInvertX | kIOScaleInvertY))
        XCTAssertEqual(SystemRotation.transform(for: .threeQuarters), UInt32(kIOScaleSwapAxes | kIOScaleInvertY))
    }

    func testEveryRotationHasAName() {
        XCTAssertEqual(Set(DisplayRotation.allCases.map(\.label)).count, 4)
        XCTAssertEqual(DisplayRotation.standard.label, "Standard")
        XCTAssertEqual(DisplayRotation.quarter.label, "90°")
    }

    // MARK: - Streaming display modes

    func testTurnedModeTradesItsSides() {
        let mode = StreamingDisplayModes.Mode(width: 1920, height: 1080, refreshRate: 60, hiDPI: true)
        XCTAssertEqual(mode.rotated(.quarter), .init(width: 1080, height: 1920, refreshRate: 60, hiDPI: true))
        XCTAssertEqual(mode.rotated(.half), mode)
        XCTAssertEqual(mode.rotated(.threeQuarters).rotated(.quarter), mode)
    }

    func testPortraitStreamGetsAPortraitMode() {
        XCTAssertEqual(StreamingDisplayModes.forStream(width: 1080, height: 1920, fps: 60),
                       .init(width: 1080, height: 1920, refreshRate: 60))
        // As sharp as a 2560-wide screen, so HiDPI, whichever way up.
        XCTAssertEqual(StreamingDisplayModes.forStream(width: 1600, height: 2560, fps: 60),
                       .init(width: 800, height: 1280, refreshRate: 60, hiDPI: true))
    }

    func testPortraitDisplayListsPortraitSizes() {
        let start = StreamingDisplayModes.Mode(width: 1080, height: 1920, refreshRate: 60)
        let modes = StreamingDisplayModes.advertised(startingIn: start)
        XCTAssertEqual(modes.first?.width, 1080)
        XCTAssertEqual(modes.first?.height, 1920)
        XCTAssertTrue(modes.allSatisfy { $0.height >= $0.width })
        XCTAssertEqual(modes.count, StreamingDisplayModes.advertised.count, "1080 × 1920 is a listed size turned")
    }

    func testPortraitModesFit() {
        func m(_ w: Int, _ h: Int, _ scale: Int) -> DisplayMode {
            DisplayMode(id: "", ioModeID: 0, width: w, height: h, pixelWidth: w * scale,
                        pixelHeight: h * scale, refreshRate: 60, isHiDPI: scale == 2)
        }
        XCTAssertTrue(StreamingDisplayModes.fits(m(1080, 1920, 2)))
        XCTAssertTrue(StreamingDisplayModes.fits(m(2160, 3840, 1)))
        XCTAssertFalse(StreamingDisplayModes.fits(m(1440, 2560, 2)))
    }

    func testCanTurnOnItsSideWhereItIs() {
        XCTAssertEqual(StreamingDisplayModes.maxPixelsSide, 3840)
    }

    // MARK: - Preferences and the capture threads' copy

    func testKeepsEachStreamingDisplaysRotation() {
        StreamingRotationPreferences.setRotation(.quarter, for: "DAM Streaming")
        StreamingRotationPreferences.setRotation(.half, for: "DAM Streaming 2")
        XCTAssertEqual(StreamingRotationPreferences.rotation(for: "DAM Streaming"), .quarter)
        XCTAssertEqual(StreamingRotationPreferences.rotation(for: "DAM Streaming 2"), .half)
        XCTAssertEqual(StreamingRotationPreferences.rotation(for: "DAM Streaming 3"), .standard)
        StreamingRotationPreferences.setRotation(.standard, for: "DAM Streaming")
        XCTAssertEqual(StreamingRotationPreferences.rotation(for: "DAM Streaming"), .standard)
    }

    func testTellsCapturesOnlyOfChanges() {
        let rotations = StreamRotations()
        var posts = 0
        let observer = NotificationCenter.default.addObserver(forName: StreamRotations.didChange, object: rotations,
                                                              queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        rotations.update([5: .quarter, 6: .standard])
        XCTAssertEqual(rotations.rotation(of: 5), .quarter)
        XCTAssertEqual(rotations.rotation(of: 6), .standard)
        XCTAssertEqual(rotations.rotation(of: 7), .standard)
        rotations.update([5: .quarter])
        XCTAssertEqual(posts, 1, "a standard display is as good as none")
        rotations.update([:])
        XCTAssertEqual(posts, 2)
    }

    // MARK: - Turning frames

    func testTurnsFramesToTheStreamsShape() throws {
        let rotator = try XCTUnwrap(FrameRotator(rotation: .quarter, width: 64, height: 32))
        var source: CVPixelBuffer?
        CVPixelBufferCreate(nil, 32, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]] as CFDictionary, &source)
        let turned = try XCTUnwrap(rotator.rotate(try XCTUnwrap(source)))
        XCTAssertEqual(CVPixelBufferGetWidth(turned), 64)
        XCTAssertEqual(CVPixelBufferGetHeight(turned), 32)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(turned), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }

    func testTurnsFramesClockwise() throws {
        // A bright corner top left of a 32 × 64 display is top right of the 64 × 32 stream.
        let rotator = try XCTUnwrap(FrameRotator(rotation: .quarter, width: 64, height: 32))
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, 32, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]] as CFDictionary, &made)
        let source = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(source, [])
        for plane in 0..<2 {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(source, plane)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let rows = CVPixelBufferGetHeightOfPlane(source, plane)
            // Dark luma, grey chroma; then the corner bright.
            for y in 0..<rows { for x in 0..<stride { base[y * stride + x] = plane == 0 ? 16 : 128 } }
            if plane == 0 { for y in 0..<4 { for x in 0..<4 { base[y * stride + x] = 235 } } }
        }
        CVPixelBufferUnlockBaseAddress(source, [])

        let turned = try XCTUnwrap(rotator.rotate(source))
        CVPixelBufferLockBaseAddress(turned, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(turned, .readOnly) }
        let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(turned, 0)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(turned, 0)
        XCTAssertGreaterThan(luma[1 * stride + 62], 200, "top right is bright")
        XCTAssertLessThan(luma[1 * stride + 1], 50, "top left is dark")
        XCTAssertLessThan(luma[30 * stride + 62], 50, "bottom right is dark")
    }

    // MARK: - Shown through a stand-in

    func testPointerLeavesTheCoveredScreenByItsNearestEdge() {
        let covered = CGRect(x: 1080, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(PointerFence.nearestOutside(CGPoint(x: 1085, y: 500), of: covered), CGPoint(x: 1079, y: 500))
        XCTAssertEqual(PointerFence.nearestOutside(CGPoint(x: 2990, y: 500), of: covered), CGPoint(x: 3001, y: 500))
        XCTAssertEqual(PointerFence.nearestOutside(CGPoint(x: 2000, y: 1070), of: covered), CGPoint(x: 2000, y: 1081))
    }

    func testStandInComesUpAtTheScreensSize() {
        let presentation = RotatedPresentation(name: "tv", screenID: 1, rotation: .quarter, width: 1920, height: 1080, fps: 60)
        XCTAssertEqual(presentation.standInMode, .init(width: 1920, height: 1080, refreshRate: 60))
        // The stand-in turns it on its side when it is made.
        XCTAssertEqual(presentation.standInMode.rotated(.quarter), .init(width: 1080, height: 1920, refreshRate: 60))
    }

    func testKeepsTheRotationOfDisplaysShownTurned() {
        PresentedRotationPreferences.setRotation(.quarter, for: "tv")
        XCTAssertEqual(PresentedRotationPreferences.rotation(for: "tv"), .quarter)
        XCTAssertEqual(PresentedRotationPreferences.rotation(for: "Den"), .standard)
        PresentedRotationPreferences.setRotation(.standard, for: "tv")
        XCTAssertEqual(PresentedRotationPreferences.rotation(for: "tv"), .standard)
    }

    func testStandInIsNamedAfterItsDisplay() {
        XCTAssertEqual(VideoManager.standInDisplayName(for: "tv"), "tv (Rotated)")
    }

    func testCoveredScreensGoPastTheRest() {
        let video = VideoManager()
        let main = CGMainDisplayID()
        XCTAssertTrue(video.coveredScreenOrigins(besides: [main: .zero]).isEmpty, "nothing is covered")
    }

    // MARK: - Browser streams

    func testPortraitViewerAsksForAPortraitDisplay() {
        let request = WebStreamRequest.parse(["orientation": "portrait"], preferred: .interactive)
        XCTAssertEqual(request.portrait, true)
        XCTAssertTrue(request.newDisplay == (1080, 1920, 60))
    }

    func testLandscapeViewerKeepsALandscapeDisplay() {
        let request = WebStreamRequest.parse(["orientation": "landscape", "mode": "1280x800x30"], preferred: .interactive)
        XCTAssertEqual(request.portrait, false)
        XCTAssertTrue(request.newDisplay == (1280, 800, 30))
        XCTAssertNil(WebStreamRequest.parse([:], preferred: .interactive).portrait)
    }
}

/// Turns a real streaming display through a VideoManager of its own. It changes the Mac's
/// display arrangement for a few seconds, so it runs only with DAM_TEST_DISPLAYS=1.
final class StreamingDisplayRotationTests: XCTestCase {

    func testTurnsOnItsSideInPlace() throws {
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
            StreamingRotationPreferences.setRotation(.standard, for: VideoManager.streamingDisplayName(0))
            video.removeStreamingDisplay(id: display)
            RunLoop.main.run(until: Date().addingTimeInterval(4))
        }
        var result: Bool?
        let turned = expectation(description: "turned")
        video.rotateStreamingDisplay(id: display, to: .quarter) { result = $0; turned.fulfill() }
        // It waits for the layout commit after placing, which can take 10 s here.
        wait(for: [turned], timeout: 30)
        XCTAssertEqual(result, true)
        var mode = try XCTUnwrap(CGDisplayCopyDisplayMode(display))
        XCTAssertEqual([mode.width, mode.height], [1080, 1920])
        XCTAssertEqual(StreamRotations.shared.rotation(of: display), .quarter)
        XCTAssertEqual(StreamingRotationPreferences.rotation(for: VideoManager.streamingDisplayName(0)), .quarter)

        // A stream that comes back at another size is turned the same way.
        let resized = expectation(description: "resized")
        video.resizeStreamingDisplay(id: display, to: .init(width: 1280, height: 720, refreshRate: 60)) {
            result = $0; resized.fulfill()
        }
        wait(for: [resized], timeout: 30)
        XCTAssertEqual(result, true)
        mode = try XCTUnwrap(CGDisplayCopyDisplayMode(display))
        XCTAssertEqual([mode.width, mode.height], [720, 1280])
        XCTAssertTrue(DisplayArrangement.onlineDisplayIDs().contains(display), "the same display, still online")
    }
}

/// Turns the main display through macOS and back. It rotates the screen in front of the user
/// for a few seconds, so it runs only with DAM_TEST_ROTATE_MAIN=1.
final class SystemRotationTests: XCTestCase {

    func testTurnsTheMainDisplayAndBack() throws {
        guard ProcessInfo.processInfo.environment["DAM_TEST_ROTATE_MAIN"] == "1" else {
            throw XCTSkip("the main display is turned only with DAM_TEST_ROTATE_MAIN=1")
        }
        let id = CGMainDisplayID()
        guard SystemRotation.canRotate(id) else { throw XCTSkip("macOS can't turn the main display") }
        let before = SystemRotation.current(of: id)
        let size = CGDisplayBounds(id).size
        defer {
            SystemRotation.set(before, for: id)
            RunLoop.main.run(until: Date().addingTimeInterval(4))
        }
        XCTAssertTrue(SystemRotation.set(before == .quarter ? .standard : .quarter, for: id))
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        let turned = CGDisplayBounds(id).size
        XCTAssertNotEqual(SystemRotation.current(of: id), before)
        // On its side; macOS may pick another scaled size for it (1890 × 3360 for a 4K TV).
        XCTAssertEqual(turned.height > turned.width, size.width > size.height)
    }
}
