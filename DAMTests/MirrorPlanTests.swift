import XCTest
import CoreGraphics
@testable import DAM

/// The decisions behind the mirror / extend toggle, which `VideoManager.toggleMirroring`
/// reads from the live display configuration.
final class MirrorPlanTests: XCTestCase {

    private let builtIn: CGDirectDisplayID = 1
    private let external: CGDirectDisplayID = 2
    private let airPlay: CGDirectDisplayID = 3
    private let anchor: CGDirectDisplayID = 900

    private func display(_ name: String, cgID: CGDirectDisplayID, builtIn: Bool = false) -> DisplayInfo {
        DisplayInfo(id: name, name: name, isConnected: true, cgDisplayID: cgID,
                    isMirroring: false, isBuiltIn: builtIn)
    }

    private var candidates: [DisplayInfo] {
        [display("__builtin__", cgID: builtIn, builtIn: true),
         display("LEN T24i-20", cgID: external),
         display("tv", cgID: airPlay)]
    }

    // MARK: - userMirrorMaster

    func testUserMirrorMaster_nothing_isNil() {
        XCTAssertNil(VideoManager.userMirrorMaster(0, anchorIDs: [anchor]))
    }

    func testUserMirrorMaster_userDisplay_isReported() {
        XCTAssertEqual(VideoManager.userMirrorMaster(builtIn, anchorIDs: [anchor]), builtIn)
    }

    func testUserMirrorMaster_virtualAnchor_doesNotCount() {
        XCTAssertNil(VideoManager.userMirrorMaster(anchor, anchorIDs: [anchor]))
    }

    // MARK: - mirrorPlan

    func testPlan_slaveOfUserDisplay_extendsItself() {
        let plan = VideoManager.mirrorPlan(for: airPlay, master: builtIn, slaves: [],
                                           anchorIDs: [], candidates: candidates)
        XCTAssertEqual(plan, .extendSelf)
    }

    func testPlan_masterOfSet_extendsEverySlave() {
        let plan = VideoManager.mirrorPlan(for: airPlay, master: 0, slaves: [builtIn, external],
                                           anchorIDs: [], candidates: candidates)
        XCTAssertEqual(plan, .extendSlaves([builtIn, external]))
    }

    func testPlan_extended_mirrorsFirstOtherDisplayOntoIt() {
        let plan = VideoManager.mirrorPlan(for: airPlay, master: 0, slaves: [],
                                           anchorIDs: [], candidates: candidates)
        XCTAssertEqual(plan, .mirror(target: candidates[0]))
    }

    func testPlan_skipsItselfAndDisconnectedCandidates() {
        let offline = DisplayInfo(id: "Office TV", name: "Office TV", isConnected: false,
                                  cgDisplayID: 0, isMirroring: false, isBuiltIn: false)
        let tv = display("tv", cgID: airPlay)
        let plan = VideoManager.mirrorPlan(for: builtIn, master: 0, slaves: [],
                                           anchorIDs: [], candidates: [offline, candidates[0], tv])
        XCTAssertEqual(plan, .mirror(target: tv))
    }

    func testPlan_anchoredDisplay_countsAsExtended() {
        // The AirPlay display mirrors DAM's anchor: the toggle offers to mirror, not extend.
        let plan = VideoManager.mirrorPlan(for: airPlay, master: anchor, slaves: [],
                                           anchorIDs: [anchor], candidates: candidates)
        XCTAssertEqual(plan, .mirror(target: candidates[0]))
    }

    func testPlan_singleDisplay_hasNothingToMirror() {
        let plan = VideoManager.mirrorPlan(for: builtIn, master: 0, slaves: [],
                                           anchorIDs: [], candidates: [candidates[0]])
        XCTAssertEqual(plan, .noOtherDisplay)
    }

    // MARK: - displaysToExtend

    func testDissolve_freeDisplays_needNothing() {
        let result = VideoManager.displaysToExtend(freeing: [builtIn, airPlay],
                                                   masterOf: { _ in 0 }, slavesOf: { _ in [] },
                                                   anchorIDs: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testDissolve_targetIsSlave_extendsTarget() {
        let result = VideoManager.displaysToExtend(freeing: [airPlay, external],
                                                   masterOf: { $0 == self.external ? self.builtIn : 0 },
                                                   slavesOf: { _ in [] }, anchorIDs: [])
        XCTAssertEqual(result, [external])
    }

    func testDissolve_targetIsMaster_extendsItsSlaves() {
        let result = VideoManager.displaysToExtend(freeing: [airPlay, builtIn],
                                                   masterOf: { _ in 0 },
                                                   slavesOf: { $0 == self.builtIn ? [self.external] : [] },
                                                   anchorIDs: [])
        XCTAssertEqual(result, [external])
    }

    func testDissolve_anchorMirror_isNotAUserSet() {
        let result = VideoManager.displaysToExtend(freeing: [airPlay],
                                                   masterOf: { $0 == self.airPlay ? self.anchor : 0 },
                                                   slavesOf: { _ in [] }, anchorIDs: [anchor])
        XCTAssertTrue(result.isEmpty)
    }
}

/// The arrangement a change of main display produces.
final class MainDisplayTests: XCTestCase {

    private let a: CGDirectDisplayID = 1, b: CGDirectDisplayID = 2, c: CGDirectDisplayID = 3

    func testOrigins_slideEveryDisplaySoTheMainOneIsAtTheOrigin() {
        let bounds: [CGDirectDisplayID: CGRect] = [
            a: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            b: CGRect(x: 1920, y: -200, width: 2560, height: 1440),
        ]
        let origins = VideoManager.origins(makingMain: b, bounds: bounds, slaves: [])
        XCTAssertEqual(origins[b], .zero)
        XCTAssertEqual(origins[a], CGPoint(x: -1920, y: 200))
    }

    func testOrigins_leaveMirrorSlavesToTheirMaster() {
        let bounds: [CGDirectDisplayID: CGRect] = [
            a: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            b: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            c: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
        ]
        let origins = VideoManager.origins(makingMain: b, bounds: bounds, slaves: [c])
        XCTAssertEqual(Set(origins.keys), [a, b])
        XCTAssertEqual(origins[a], CGPoint(x: -1920, y: 0))
    }

    func testOrigins_unknownMain_changesNothing() {
        let bounds: [CGDirectDisplayID: CGRect] = [a: CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        XCTAssertTrue(VideoManager.origins(makingMain: c, bounds: bounds, slaves: []).isEmpty)
    }
}

/// Re-basing a captured arrangement on a new main display.
final class ArrangementMainTests: XCTestCase {

    func testMakingMain_rebasesOnTheDisplaysCapturedOrigin() {
        let captured = DisplayArrangement(origins: [1: .zero, 2: CGPoint(x: 1920, y: 0)],
                                          mirrorMasters: [1: 0, 2: 0])
        let rebased = captured.makingMain(2)
        XCTAssertEqual(rebased.origins[2], .zero)
        XCTAssertEqual(rebased.origins[1], CGPoint(x: -1920, y: 0))
    }

    func testMakingMain_slaveUsesItsMastersOrigin() {
        let captured = DisplayArrangement(origins: [1: .zero, 2: CGPoint(x: 1920, y: 0), 3: CGPoint(x: 1920, y: 0)],
                                          mirrorMasters: [1: 0, 2: 0, 3: 2])
        XCTAssertEqual(captured.makingMain(3).origins[1], CGPoint(x: -1920, y: 0))
    }

    func testMakingMain_unknownDisplay_isUnchanged() {
        let captured = DisplayArrangement(origins: [1: .zero], mirrorMasters: [1: 0])
        XCTAssertEqual(captured.makingMain(9).origins, captured.origins)
    }
}
