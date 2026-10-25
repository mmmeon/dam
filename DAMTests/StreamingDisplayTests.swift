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
        XCTAssertEqual(VideoManager.StreamingRequest.remove(display: NSObject()).countChange, -1)
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

    func testArrangementKeepsAMirrorSetOrMainMadeMeanwhile() {
        let arrangement = DisplayArrangement(origins: [1: .zero, 2: CGPoint(x: 1440, y: 0)],
                                             mirrorMasters: [1: 0, 2: 0])
        XCTAssertEqual(arrangement.mirroring([1], on: 2).mirrorMasters, [1: 2, 2: 0])
        XCTAssertEqual(arrangement.mirroring([1], on: 2).mirroring([1], on: 0).mirrorMasters, [1: 0, 2: 0])
        XCTAssertEqual(arrangement.makingMain(2).origins, [1: CGPoint(x: -1440, y: 0), 2: .zero])
    }

    func testOnlyAModeADisplayCanBeMadeInIsValid() {
        XCTAssertTrue(StreamingDisplayModes.start.isValid)
        XCTAssertTrue(StreamingDisplayModes.forStream(width: 7680, height: 4320, fps: 120).isValid)
        XCTAssertFalse(StreamingDisplayModes.Mode(width: -1920, height: 1080, refreshRate: 60).isValid)
        XCTAssertFalse(StreamingDisplayModes.Mode(width: 1920, height: 0, refreshRate: 60).isValid)
        XCTAssertFalse(StreamingDisplayModes.Mode(width: 1920, height: 1080, refreshRate: 0).isValid)
        XCTAssertFalse(StreamingDisplayModes.Mode(width: 1920, height: 1080, refreshRate: 100_000).isValid)
        XCTAssertFalse(StreamingDisplayModes.Mode(width: 5000, height: 2000, refreshRate: 60, hiDPI: true).isValid)
        // Asked without working out its pixels, which would overflow.
        XCTAssertFalse(StreamingDisplayModes.Mode(width: .max, height: 1080, refreshRate: 60, hiDPI: true).isValid)
        XCTAssertFalse(StreamingDisplayModes.forStream(width: .max, height: 1080, fps: 60).isValid)
    }

    func testAnInvalidModeMakesNoDisplay() {
        let manager = VideoManager()
        var result: CGDirectDisplayID?? = .none
        manager.createStreamingDisplay(mode: .init(width: -5, height: 1080, refreshRate: 60)) { result = $0 }
        XCTAssertEqual(result, .some(nil))
        XCTAssertTrue(manager.streamingDisplays.isEmpty)
    }

    func testArrangementPutsBackOnlyMirrorsOntoMastersStillOnline() {
        let arrangement = DisplayArrangement(origins: [1: .zero], mirrorMasters: [1: 0, 2: 1, 3: 9, 4: 0, 5: 1])
        // 2 and 3 have since been extended, 4 mirrored onto 1; 9 has gone; 5 is left out.
        let live: [CGDirectDisplayID: CGDirectDisplayID] = [1: 0, 2: 0, 3: 0, 4: 1, 5: 0]
        let changes = arrangement.mirrorChanges(online: [1, 2, 3, 4, 5], excluding: [5], mirrorOf: { live[$0] ?? 0 })
        XCTAssertEqual(changes, [2: 1, 4: 0])
    }

    func testArrangementMovesOnlyDisplaysShowingTheirOwnDesktop() {
        let arrangement = DisplayArrangement(origins: [1: .zero, 2: CGPoint(x: 1440, y: 0), 3: CGPoint(x: -1920, y: 0),
                                                       4: CGPoint(x: 0, y: 900), 5: CGPoint(x: 0, y: -900)],
                                             mirrorMasters: [1: 0, 2: 0, 3: 0, 4: 0, 5: 1])
        // All moved since; 3 has been mirrored onto 1, 4 is left out, 5 was a mirror slave.
        let live: [CGDirectDisplayID: CGDirectDisplayID] = [3: 1, 5: 1]
        let changes = arrangement.originChanges(online: [1, 2, 3, 4, 5], excluding: [4], mirrorOf: { live[$0] ?? 0 },
                                                originOf: { _ in CGPoint(x: 5000, y: 0) })
        XCTAssertEqual(changes, [1: .zero, 2: CGPoint(x: 1440, y: 0)])
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

    // MARK: - Mirrors WindowServer makes when a display joins

    /// 1 the Mac, 2 a TV, 10 and 11 streaming displays, 20 an anchor.
    private func release(masters: [CGDirectDisplayID: CGDirectDisplayID],
                         mirroringByChoice: Set<CGDirectDisplayID> = [],
                         mirroredByChoice: Set<CGDirectDisplayID> = [],
                         anchorManaged: Set<CGDirectDisplayID> = []) -> [CGDirectDisplayID] {
        VideoManager.mirrorsToRelease(streaming: [10, 11], online: [1, 2, 10, 11, 20],
                                      masterOf: { masters[$0] ?? 0 },
                                      mirroringByChoice: mirroringByChoice, mirroredByChoice: mirroredByChoice,
                                      anchorManaged: anchorManaged)
    }

    func testAStreamingDisplayMirroringTheTVIsFreed() {
        XCTAssertEqual(release(masters: [10: 2]), [10])
    }

    func testTheTVMirroringAStreamingDisplayIsFreed() {
        XCTAssertEqual(release(masters: [2: 10, 1: 10]), [1, 2])
    }

    func testMirrorsMadeThroughDAMStay() {
        XCTAssertEqual(release(masters: [10: 2], mirroringByChoice: [10]), [])
        XCTAssertEqual(release(masters: [2: 11], mirroredByChoice: [11]), [])
    }

    /// The Lenovo (1) main with the iPad's display (11) and Moonlight's (10) right of it, before
    /// the TV came.
    private let settled: [CGDirectDisplayID: CGRect] = [
        1: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        11: CGRect(x: 1920, y: 0, width: 1024, height: 768),
        10: CGRect(x: 2944, y: 0, width: 1920, height: 1080),
    ]

    func testStreamingDisplaysGoBackWhereTheyWereOnceTheTVLeaves() {
        // As seen: after the TV left, Moonlight's display took the iPad's place, and the iPad's
        // went left of the Lenovo.
        let now: [CGDirectDisplayID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            10: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            11: CGRect(x: -1024, y: 533, width: 1024, height: 768),
        ]
        let moves = VideoManager.originsBack(before: settled, now: now, streaming: [10, 11], mirroring: [], main: 1)
        XCTAssertEqual(moves, [10: CGPoint(x: 2944, y: 0), 11: CGPoint(x: 1920, y: 0)])
    }

    func testStreamingDisplaysFollowTheMainDisplayWhenItMoved() {
        var now = settled
        now[1] = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        now[2] = CGRect(x: -1920, y: 0, width: 1920, height: 1080)  // the TV, left of it
        XCTAssertEqual(VideoManager.originsBack(before: settled, now: now, streaming: [10, 11], mirroring: [], main: 1), [:])
        // Main went to the TV, which the Lenovo mirrors: placed by the Lenovo, as before.
        now = [2: CGRect(x: 0, y: 0, width: 1920, height: 1080), 1: CGRect(x: 0, y: 0, width: 1920, height: 1080),
               10: CGRect(x: 1920, y: 0, width: 1920, height: 1080), 11: CGRect(x: 3840, y: 0, width: 1024, height: 768)]
        XCTAssertEqual(VideoManager.originsBack(before: settled, now: now, streaming: [10, 11], mirroring: [1], main: 2), [:],
                       "no display both settled and fixed now, but the TV, which was not there")
    }

    func testNoMoveThatWouldOverlapAnotherDisplay() {
        let now: [CGDirectDisplayID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            2: CGRect(x: 1920, y: 0, width: 1920, height: 1080),  // the TV, where the iPad's was
            10: CGRect(x: 3840, y: 0, width: 1920, height: 1080),
            11: CGRect(x: -1024, y: 0, width: 1024, height: 768),
        ]
        XCTAssertEqual(VideoManager.originsBack(before: settled, now: now, streaming: [10, 11], mirroring: [], main: 1), [:])
    }

    func testMirrorsWithoutStreamingDisplaysAndAnchorSetsAreLeftAlone() {
        XCTAssertEqual(release(masters: [2: 1]), [])
        XCTAssertEqual(release(masters: [10: 20], anchorManaged: [10, 20]), [])
    }
}

final class DisplayModeRateMatchTests: XCTestCase {
    func testExactKeeps5994And60Apart() {
        XCTAssertFalse(DisplayArrangement.RateMatch.exact.matches(59.94, 60))
        XCTAssertTrue(DisplayArrangement.RateMatch.exact.matches(60, 60.001))
    }

    func testWholeHertzTakes5994For60() {
        XCTAssertTrue(DisplayArrangement.RateMatch.wholeHertz.matches(59.94, 60))
        XCTAssertFalse(DisplayArrangement.RateMatch.wholeHertz.matches(59.4, 60))
    }

    func testWithinOneHertzTakesAVirtualDisplaysRate() {
        XCTAssertTrue(DisplayArrangement.RateMatch.withinOneHertz.matches(119.88, 120))
        XCTAssertFalse(DisplayArrangement.RateMatch.withinOneHertz.matches(119, 120))
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

/// The queue of streaming display changes, and the layouts DAM keeps, on a VideoManager of
/// their own with displays of no real display.
final class StreamingRequestTests: XCTestCase {

    // MARK: - Requests

    /// A streaming display of no real display: nothing in these tests reaches WindowServer.
    private func fakeDisplay(_ display: AnyObject, index: Int, id: CGDirectDisplayID) -> VideoManager.StreamingDisplay {
        VideoManager.StreamingDisplay(display: display, index: index, name: "Test \(index)",
                                      serial: VideoManager.streamingSerial(index),
                                      start: StreamingDisplayModes.start, id: id)
    }

    func testAQueuedRemovalTakesItsOwnDisplayNotItsSlot() {
        let manager = VideoManager()
        let old = NSObject(), newer = NSObject()
        manager.streamingDisplays = [fakeDisplay(old, index: 0, id: 9001)]
        // Another change is under way, so the removal waits.
        manager.streamingChangeInFlight = true
        manager.removeStreamingDisplay(id: 9001)
        manager.removeStreamingDisplay(id: 9001)
        XCTAssertEqual(manager.streamingRequests.count, 1, "asked twice, removed once")
        XCTAssertEqual(manager.plannedStreamingDisplayCount, 0)
        // Meanwhile the system ended it, and a newer display took its slot.
        manager.streamingDisplays = [fakeDisplay(newer, index: 0, id: 9002)]
        manager.streamingChangeInFlight = false
        manager.processStreamingRequests()
        XCTAssertTrue(manager.streamingRequests.isEmpty)
        XCTAssertEqual(manager.streamingDisplays.count, 1)
        XCTAssertTrue(manager.streamingDisplays.first?.display === newer)
    }

    func testRemovingADisplayThatIsNoneQueuesNothing() {
        let manager = VideoManager()
        manager.streamingChangeInFlight = true
        manager.removeStreamingDisplay(id: 0)
        manager.removeStreamingDisplay(id: 9003)
        XCTAssertTrue(manager.streamingRequests.isEmpty)
    }

    func testAdditionsWaitingCountTowardsTheLimit() {
        let manager = VideoManager()
        manager.streamingChangeInFlight = true
        var refused = 0
        for _ in 0...VideoManager.maxStreamingDisplays {
            manager.createStreamingDisplay { if $0 == nil { refused += 1 } }
        }
        XCTAssertEqual(manager.streamingRequests.count, VideoManager.maxStreamingDisplays)
        XCTAssertEqual(refused, 1, "the one past the limit is refused at once")
        XCTAssertFalse(manager.canCreateStreamingDisplay)
        manager.streamingRequests.removeAll()
    }

    func testRequestsWaitForTheModesPutBackAfterWake() {
        let manager = VideoManager()
        manager.streamingDisplays = [fakeDisplay(NSObject(), index: 0, id: 9004)]
        manager.wakeRestoreInFlight = true
        XCTAssertTrue(manager.displayChangeInFlight)
        manager.removeStreamingDisplay(id: 9004)
        XCTAssertEqual(manager.streamingRequests.count, 1)
        manager.streamingRequests.removeAll()
    }

    // MARK: - Changes made through DAM reach the kept layouts

    private let twoSideBySide = DisplayArrangement(origins: [1: .zero, 2: CGPoint(x: 1440, y: 0)],
                                                   mirrorMasters: [1: 0, 2: 0])

    func testPositionsReachEveryKeptLayout() {
        let manager = VideoManager()
        let until = Date().addingTimeInterval(5)
        manager.streamingSettle = (twoSideBySide, until)
        manager.streamingArrangement = twoSideBySide
        manager.virtualAnchorArrangements["tv"] = twoSideBySide
        manager.framesBeforeSetChange = [1: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                         2: CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        let left = CGPoint(x: -1920, y: 0)
        let undo = manager.keepUserOrigins([2: left, 3: CGPoint(x: 9, y: 9)])
        XCTAssertEqual(manager.streamingSettle?.arrangement.origins, [1: .zero, 2: left])
        XCTAssertEqual(manager.streamingSettle?.until, until)
        XCTAssertEqual(manager.streamingArrangement?.origins, [1: .zero, 2: left])
        XCTAssertEqual(manager.virtualAnchorArrangements["tv"]?.origins, [1: .zero, 2: left])
        XCTAssertEqual(manager.framesBeforeSetChange[2], CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        XCTAssertNil(manager.framesBeforeSetChange[3], "only displays a layout already holds")
        // The change failed: each layout gets back what it had.
        undo()
        XCTAssertEqual(manager.streamingSettle?.arrangement.origins, twoSideBySide.origins)
        XCTAssertEqual(manager.streamingArrangement?.origins, twoSideBySide.origins)
        XCTAssertEqual(manager.virtualAnchorArrangements["tv"]?.origins, twoSideBySide.origins)
        XCTAssertEqual(manager.framesBeforeSetChange[2], CGRect(x: 1440, y: 0, width: 1920, height: 1080))
    }

    func testARemoteSessionHoldsTheLayoutFromBeforeTheStreams() {
        let manager = VideoManager()
        manager.streamingArrangement = twoSideBySide
        manager.holdsStreamingArrangement = true
        manager.keepUserOrigins([2: CGPoint(x: -1920, y: 0)])
        XCTAssertEqual(manager.streamingArrangement?.origins, twoSideBySide.origins)
    }

    func testAnUndoLeavesALayoutKeptSinceAlone() {
        let manager = VideoManager()
        manager.streamingSettle = (twoSideBySide, Date().addingTimeInterval(5))
        let undo = manager.keepUserOrigins([2: CGPoint(x: -1920, y: 0)])
        // A streaming display came meanwhile and keeps a layout of its own.
        let placed = twoSideBySide.adding(3, origin: CGPoint(x: 3360, y: 0), mode: nil)
        manager.beginStreamingSettle(placed, for: 6)
        undo()
        XCTAssertEqual(manager.streamingSettle?.arrangement.origins, placed.origins)
    }

    func testAnUndoReachesALayoutWhoseTimeStartedAgain() {
        let manager = VideoManager()
        manager.beginStreamingSettle(twoSideBySide, for: 15)
        // A display removed, that WindowServer takes off meanwhile; none has this ID.
        manager.streamingSettleAwaitsRemoval = 0xDEAD
        let undo = manager.keepUserOrigins([2: CGPoint(x: -1920, y: 0)])
        manager.startSettleOnceRemoved()
        XCTAssertNil(manager.streamingSettleAwaitsRemoval)
        XCTAssertLessThan(manager.streamingSettle?.until ?? .distantFuture, Date().addingTimeInterval(6))
        undo()
        XCTAssertEqual(manager.streamingSettle?.arrangement.origins, twoSideBySide.origins)
    }

    func testModesReachEveryKeptLayoutAndTheStreamingDisplay() throws {
        let manager = VideoManager()
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else { throw XCTSkip("no display to read a mode of") }
        let display = NSObject()
        manager.streamingDisplays = [fakeDisplay(display, index: 0, id: 2)]
        manager.streamingSettle = (twoSideBySide, Date().addingTimeInterval(5))
        manager.streamingArrangement = twoSideBySide
        manager.virtualAnchorArrangements["tv"] = twoSideBySide
        let undo = manager.keepUserMode(mode, for: 2)
        XCTAssertTrue(manager.streamingSettle?.arrangement.modes[2] === mode)
        XCTAssertTrue(manager.streamingArrangement?.modes[2] === mode)
        XCTAssertTrue(manager.virtualAnchorArrangements["tv"]?.modes[2] === mode)
        XCTAssertEqual(manager.streamingDisplays.first?.start, StreamingDisplayModes.Mode(mode))
        undo()
        XCTAssertNil(manager.streamingSettle?.arrangement.modes[2])
        XCTAssertNil(manager.streamingArrangement?.modes[2])
        XCTAssertNil(manager.virtualAnchorArrangements["tv"]?.modes[2])
        XCTAssertEqual(manager.streamingDisplays.first?.start, StreamingDisplayModes.start)
    }

    // MARK: - Changes made through DAM while a streaming display is placed or resized

    func testPositionsReachTheLayoutAChangeUnderWayPlaces() {
        let manager = VideoManager()
        manager.streamingChangesBegun = 1
        manager.streamingChangeLayout = twoSideBySide
        let left = CGPoint(x: -1920, y: 0)
        let undo = manager.keepUserOrigins([2: left])
        XCTAssertEqual(manager.streamingChangeLayout?.origins, [1: .zero, 2: left])
        undo()
        XCTAssertEqual(manager.streamingChangeLayout?.origins, twoSideBySide.origins)
    }

    func testAMirrorReachesTheLayoutAChangeUnderWayPlaces() {
        let manager = VideoManager()
        manager.streamingChangeLayout = twoSideBySide
        manager.keepUserMirror([2], on: 1)
        XCTAssertEqual(manager.streamingChangeLayout?.mirrorMasters[2], 1)
    }

    func testModesReachTheLayoutAChangeUnderWayPlaces() throws {
        let manager = VideoManager()
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else { throw XCTSkip("no display to read a mode of") }
        manager.streamingChangesBegun = 1
        manager.streamingChangeLayout = twoSideBySide
        let undo = manager.keepUserMode(mode, for: 2)
        XCTAssertTrue(manager.streamingChangeLayout?.modes[2] === mode)
        undo()
        XCTAssertNil(manager.streamingChangeLayout?.modes[2])
    }

    func testAnUndoLeavesTheLayoutOfALaterChangeAlone() {
        let manager = VideoManager()
        manager.streamingChangesBegun = 1
        manager.streamingChangeLayout = twoSideBySide
        let undo = manager.keepUserOrigins([2: CGPoint(x: -1920, y: 0)])
        // That change ended and another began, from a layout of its own.
        let placed = twoSideBySide.adding(3, origin: CGPoint(x: 3360, y: 0), mode: nil)
        manager.streamingChangesBegun = 2
        manager.streamingChangeLayout = placed
        undo()
        XCTAssertEqual(manager.streamingChangeLayout?.origins, placed.origins)
    }

    func testAMainMadeMeanwhileReachesTheLayoutAChangeUnderWayPlaces() {
        let manager = VideoManager()
        manager.streamingChangeLayout = twoSideBySide
        let display = DisplayInfo(id: "x", name: "x", isConnected: true, cgDisplayID: 2,
                                  isMirroring: false, isBuiltIn: false, isMain: false)
        // Display 2 is no real display: nothing is committed, the layouts are re-based only
        // once it is main, which it isn't. Re-base the way setMainDisplay's choice does.
        _ = display
        let rebased = twoSideBySide.makingMain(2)
        XCTAssertEqual(rebased.origins[2], .zero)
        XCTAssertEqual(rebased.origins[1], CGPoint(x: -1440, y: 0))
    }

    // MARK: - The wake restore

    func testTheWakeRestoreKeepsTheModeSleptInForItsSecondPass() throws {
        let manager = VideoManager()
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else { throw XCTSkip("no display to read a mode of") }
        manager.virtualAnchorArrangements["ipad"] = twoSideBySide
        manager.modesBeforeSleep = [2: VideoManager.ModeShape(mode)]
        let undo = manager.keepUserMode(mode, for: 2, keepingSleepMode: true)
        // An anchor made after wake would otherwise put the mode the screens woke in back.
        XCTAssertTrue(manager.virtualAnchorArrangements["ipad"]?.modes[2] === mode)
        XCTAssertEqual(manager.modesBeforeSleep[2], VideoManager.ModeShape(mode))
        undo()
        XCTAssertNil(manager.virtualAnchorArrangements["ipad"]?.modes[2])
        // A mode picked replaces the one slept in.
        manager.keepUserMode(mode, for: 2)
        XCTAssertNil(manager.modesBeforeSleep[2])
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
