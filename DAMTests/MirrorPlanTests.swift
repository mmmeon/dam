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
