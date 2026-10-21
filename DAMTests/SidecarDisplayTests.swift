import XCTest
import CoreGraphics
@testable import DAM

final class SidecarDisplayTests: XCTestCase {
    private let iPadName = "Sidecar Test iPad"

    override func tearDown() {
        VisibilityPreferences.setNickname(nil, .sidecar, for: iPadName)
        VisibilityPreferences.setNickname(nil, .display, for: iPadName)
        super.tearDown()
    }

    // MARK: - Recognising a Sidecar display

    func testSidecarVendorAndModelAreRecognised() {
        XCTAssertTrue(VideoManager.isSidecarDisplay(vendor: 0x6161706c, model: 0x69506164))
    }

    func testAirPlayVirtualDisplayIsNotSidecar() {
        // "aapl" / "airp"
        XCTAssertFalse(VideoManager.isSidecarDisplay(vendor: 0x6161706c, model: 0x61697270))
    }

    func testOrdinaryDisplayIsNotSidecar() {
        XCTAssertFalse(VideoManager.isSidecarDisplay(vendor: 0x30ae, model: 0x61f7))
    }

    func testAirPlayVendorAndModelAreRecognised() {
        XCTAssertTrue(VideoManager.isAirPlayDisplay(vendor: 0x6161706c, model: 0x61697270))
    }

    func testSidecarAndOrdinaryDisplaysAreNotAirPlay() {
        XCTAssertFalse(VideoManager.isAirPlayDisplay(vendor: 0x6161706c, model: 0x69506164))
        XCTAssertFalse(VideoManager.isAirPlayDisplay(vendor: 0x30ae, model: 0x61f7))
    }

    // MARK: - Matching AirPlay names to displays

    private func resolve(_ discovered: [String], screenNames: [CGDirectDisplayID: String] = [:],
                         systemNames: [CGDirectDisplayID: String] = [:],
                         cached: [String: CGDirectDisplayID] = [:], online: [CGDirectDisplayID],
                         airPlay: Set<CGDirectDisplayID>, named: Set<CGDirectDisplayID>? = nil)
        -> (resolved: [String: CGDirectDisplayID], unmatched: [CGDirectDisplayID]) {
        VideoManager.resolveAirPlay(discovered: discovered, screenNames: screenNames,
                                    systemNames: systemNames, cached: cached,
                                    online: online, airPlayIDs: airPlay,
                                    namedIDs: named ?? Set(screenNames.keys).union(systemNames.keys))
    }

    func testAirPlayNameMatchesItsScreenName() {
        let r = resolve(["Living Room"], screenNames: [1: "Built-in", 7: "Living Room"],
                        online: [1, 7], airPlay: [7])
        XCTAssertEqual(r.resolved, ["Living Room": 7])
        XCTAssertEqual(r.unmatched, [])
    }

    func testCachedIDKeepsAMirroredAirPlayDisplay() {
        let r = resolve(["Living Room"], cached: ["Living Room": 7], online: [1, 7], airPlay: [7])
        XCTAssertEqual(r.resolved, ["Living Room": 7])
    }

    func testCachedIDNowOnAnotherKindOfDisplayIsDropped() {
        // tv's display went away and WindowServer gave its ID to a streaming display.
        let r = resolve(["Den", "tv"], screenNames: [4128835: "DAM Streaming"], cached: ["tv": 4128835],
                        online: [4128835, 731413954], airPlay: [])
        XCTAssertEqual(r.resolved, [:])
        XCTAssertEqual(r.unmatched, [])
    }

    func testAirPlayDisplayNamedDifferentlyFromBonjourIsMatched() {
        // macOS names the screen otherwise than the receiver advertises itself.
        let r = resolve(["Living Room"], screenNames: [1: "Built-in", 7: "Samsung 4K TV"],
                        online: [1, 7], airPlay: [7])
        XCTAssertEqual(r.resolved, ["Living Room": 7])
        XCTAssertEqual(r.unmatched, [])
    }

    func testMacOS27AirPlaySuffixStillMatchesTheBonjourName() {
        // macOS 27 lists the screen as "<receiver> (AirPlay)". It matches by name, even when
        // the display doesn't report AirPlay's vendor and model.
        let r = resolve(["No's Fire TV"], screenNames: [1: "Built-in Retina Display", 7: "No's Fire TV (AirPlay)"],
                        online: [1, 7], airPlay: [])
        XCTAssertEqual(r.resolved, ["No's Fire TV": 7])
    }

    func testAirPlayNameDropsOnlyTheMacOS27Suffix() {
        XCTAssertEqual(VideoManager.airPlayName(fromScreenName: "No's Fire TV (AirPlay)"), "No's Fire TV")
        XCTAssertEqual(VideoManager.airPlayName(fromScreenName: "Living Room"), "Living Room")
    }

    func testUnnamedAirPlayDisplayIsPairedBeforeANamedOne() {
        let r = resolve(["Living Room"], screenNames: [8: "Samsung 4K TV"],
                        online: [7, 8], airPlay: [7, 8])
        XCTAssertEqual(r.resolved, ["Living Room": 7])
        XCTAssertEqual(r.unmatched, [8])
    }

    func testMirroredAirPlayDisplayMatchesItsSystemName() {
        // "tv" mirrors, so it is out of NSScreen; "Den" is advertised but not connected.
        // Sorted order alone would hand tv's display to Den.
        let r = resolve(["Den", "tv"], screenNames: [1: "HISENSE"], systemNames: [7: "tv"],
                        online: [1, 7], airPlay: [7])
        XCTAssertEqual(r.resolved, ["tv": 7])
        XCTAssertEqual(r.unmatched, [])
    }

    func testSeveralUnresolvedNamesAreNotPairedByOrder() {
        let r = resolve(["Den", "tv"], screenNames: [1: "HISENSE"], online: [1, 7], airPlay: [7])
        XCTAssertEqual(r.resolved, [:])
        XCTAssertEqual(r.unmatched, [7])
    }

    func testNameMatchBeatsAnotherNamesStaleCache() {
        let r = resolve(["Den", "tv"], systemNames: [7: "tv"], cached: ["Den": 7],
                        online: [7], airPlay: [7])
        XCTAssertEqual(r.resolved, ["tv": 7])
    }

    func testAirPlayDisplayWithNoBonjourNameIsLeftOverAsAirPlay() {
        let r = resolve([], screenNames: [1: "Built-in", 7: "Samsung 4K TV"], online: [1, 7], airPlay: [7])
        XCTAssertEqual(r.resolved, [:])
        XCTAssertEqual(r.unmatched, [7])
    }

    func testMonitorIsNeverTakenForAnAirPlayDisplay() {
        let r = resolve(["Living Room"], screenNames: [2: "DELL U2720Q"], online: [2], airPlay: [])
        XCTAssertEqual(r.resolved, [:])
        XCTAssertEqual(r.unmatched, [])
    }

    // MARK: - Naming after the iPad

    func testOneDisplayTakesTheOneName() {
        let names = VideoManager.sidecarNames(displayIDs: [4128835], deviceNames: ["pad"])
        XCTAssertEqual(names, [4128835: "pad"])
    }

    func testDisplaysPairWithNamesInOrder() {
        let names = VideoManager.sidecarNames(displayIDs: [9, 3], deviceNames: ["Zed", "Alpha"])
        XCTAssertEqual(names, [3: "Alpha", 9: "Zed"])
    }

    func testDisplayWithoutAnIPadIsLeftUnnamed() {
        let names = VideoManager.sidecarNames(displayIDs: [3, 9], deviceNames: ["pad"])
        XCTAssertEqual(names, [3: "pad"])
    }

    func testNoDisplaysGivesNoNames() {
        XCTAssertTrue(VideoManager.sidecarNames(displayIDs: [], deviceNames: ["pad"]).isEmpty)
    }

    // MARK: - Live display list (skips unless an iPad is connected over Sidecar)

    func testConnectedIPadIsListedUnderItsOwnName() throws {
        let online = DisplayArrangement.onlineDisplayIDs().filter { VideoManager.isSidecarDisplay($0) }
        try XCTSkipIf(online.isEmpty, "no Sidecar display is online")
        let manager = VideoManager()
        manager.connectedSidecarNames = { ["Live iPad"] }
        manager.refresh()
        let entry = try XCTUnwrap(manager.allConnectedDisplays.first { $0.isSidecar })
        XCTAssertEqual(entry.name, "Live iPad")
        XCTAssertEqual(entry.cgDisplayID, online[0])
        XCTAssertTrue(entry.isConnected)
        XCTAssertFalse(entry.isBuiltIn)
        XCTAssertFalse(manager.allAirPlayDevices.contains { $0.cgDisplayID == online[0] })
    }

    // MARK: - Anchor state

    func testForgettingAnAnchorClearsWhatIsKeptForIt() {
        let manager = VideoManager()
        let vd = NSObject()
        manager.virtualAnchorStore = ["iPad": vd, "TV": NSObject()]
        manager.virtualAnchorCGIDs = ["iPad": 9, "TV": 8]
        manager.virtualAnchorTargets = ["iPad": 3, "TV": 4]
        manager.virtualAnchorArrangements = ["iPad": DisplayArrangement(origins: [1: .zero], mirrorMasters: [1: 0])]
        manager.virtualAnchorModes = ["iPad": VideoManager.virtualMode(width: 1280, height: 720, refreshRate: 60)]
        manager.virtualAnchorSettleDeadlines = ["iPad": Date()]
        manager.anchorSetSlaves = ["iPad": [5], "TV": [6]]
        manager.anchorPendingSlaves = ["iPad": [7]]
        manager.sidecarNativeModes = [3: VideoManager.virtualMode(width: 1180, height: 820, refreshRate: 60)]

        XCTAssertTrue(manager.forgetAnchor("iPad") === vd)
        XCTAssertEqual(Array(manager.virtualAnchorStore.keys), ["TV"])
        XCTAssertEqual(manager.virtualAnchorCGIDs, ["TV": 8])
        XCTAssertEqual(manager.virtualAnchorTargets, ["TV": 4])
        XCTAssertTrue(manager.virtualAnchorArrangements.isEmpty)
        XCTAssertTrue(manager.virtualAnchorModes.isEmpty)
        XCTAssertTrue(manager.virtualAnchorSettleDeadlines.isEmpty)
        XCTAssertEqual(manager.anchorSetSlaves, ["TV": [6]])
        XCTAssertTrue(manager.anchorPendingSlaves.isEmpty)
        XCTAssertTrue(manager.sidecarNativeModes.isEmpty)
    }

    func testAMirrorChangeIsKeptInEveryAnchorsArrangement() {
        let manager = VideoManager()
        let captured = DisplayArrangement(origins: [1: .zero, 2: CGPoint(x: 1440, y: 0)], mirrorMasters: [1: 0, 2: 0])
        manager.virtualAnchorArrangements = ["iPad": captured, "TV": captured.mirroring([2], on: 1)]
        manager.anchorSetSlaves = ["iPad": [2, 5]]
        manager.streamingSettle = (captured, Date.distantFuture)

        manager.keepUserMirror([2], on: 1)
        XCTAssertEqual(manager.virtualAnchorArrangements["iPad"]?.mirrorMasters, [1: 0, 2: 1])
        XCTAssertEqual(manager.streamingSettle?.arrangement.mirrorMasters, [1: 0, 2: 1])
        XCTAssertEqual(manager.anchorSetSlaves, ["iPad": [5]])

        manager.keepUserMirror([2], on: 0)
        XCTAssertEqual(manager.virtualAnchorArrangements["TV"]?.mirrorMasters, [1: 0, 2: 0])
        XCTAssertEqual(manager.virtualAnchorArrangements["TV"]?.origins, captured.origins)
    }

    func testAReleasedAnchorLeavesTheKeptLayoutsAsItsReleaseLeavesTheDisplays() {
        // 5 is the anchor, 3 the iPad it drives, 7 set to mirror the iPad, 8 pulled in by WindowServer.
        let captured = DisplayArrangement(origins: [1: .zero, 5: CGPoint(x: 1440, y: 0)],
                                          mirrorMasters: [1: 0, 5: 0, 3: 5, 7: 5, 8: 5, 9: 1])
        let released = captured.releasing(5, target: 3, setSlaves: [7])
        XCTAssertEqual(released.mirrorMasters, [1: 0, 3: 0, 7: 3, 8: 0, 9: 1])
        XCTAssertEqual(released.origins, [1: .zero])

        let manager = VideoManager()
        manager.virtualAnchorCGIDs = ["iPad": 5, "TV": 6]
        manager.virtualAnchorTargets = ["iPad": 3, "TV": 4]
        manager.anchorSetSlaves = ["iPad": [7]]
        manager.virtualAnchorArrangements = ["TV": captured]
        manager.streamingArrangement = captured
        manager.forgetAnchor("iPad")
        XCTAssertEqual(manager.streamingArrangement?.mirrorMasters, released.mirrorMasters)
        XCTAssertEqual(manager.virtualAnchorArrangements["TV"]?.mirrorMasters, released.mirrorMasters)
    }

    func testAStreamingDisplayIsMirroredByChoiceOnlyWhileMirroredThroughDAM() {
        let manager = VideoManager()
        manager.streamingDisplays = [VideoManager.StreamingDisplay(display: NSObject(), index: 0, name: "S",
                                                                   serial: 4, start: StreamingDisplayModes.start,
                                                                   id: 42)]
        manager.keepUserMirror([2], on: 42)
        XCTAssertEqual(manager.streamingDisplaysMirroredByChoice, [42])
        // Nothing online mirrors it once 2 is extended again.
        manager.keepUserMirror([2], on: 0)
        XCTAssertTrue(manager.streamingDisplaysMirroredByChoice.isEmpty)

        // Set to mirror another display, which a resize keeps.
        manager.keepUserMirror([42, 2], on: 1)
        XCTAssertEqual(manager.streamingDisplaysMirroringByChoice, [42])
        manager.keepUserMirror([42], on: 0)
        XCTAssertTrue(manager.streamingDisplaysMirroringByChoice.isEmpty)
    }

    func testOnlyTheStandInAnAttemptMadeIsReleased() {
        let manager = VideoManager()
        let later = NSObject()
        manager.bootstrapDisplay = later
        manager.releaseBootstrapDisplay(NSObject())
        XCTAssertTrue(manager.bootstrapDisplay === later)
    }

    // MARK: - SidecarCore device identifiers

    /// Stands in for a SidecarCore device, whose identifier is an NSUUID.
    private final class FakeDevice: NSObject {
        @objc let identifier: Any?
        init(_ identifier: Any?) { self.identifier = identifier }
    }

    func testUUIDIdentifierBecomesItsString() {
        let uuid = UUID()
        XCTAssertEqual(SidecarManager.identifier(of: FakeDevice(uuid as NSUUID)), uuid.uuidString)
    }

    func testStringIdentifierIsKept() {
        XCTAssertEqual(SidecarManager.identifier(of: FakeDevice("abc")), "abc")
    }

    func testMissingIdentifierIsNil() {
        XCTAssertNil(SidecarManager.identifier(of: FakeDevice(nil)))
    }

    // MARK: - Link

    func testCableAttachedMeansUSB() {
        // Observed with the cable in: BLE, infrastructure Wi‑Fi, Owner, ApplePay, USB.
        XCTAssertEqual(SidecarDevice.link(fromStatus: 0x1880006), .usb)
    }

    func testPeerToPeerWiFiMeansWiFi() {
        // Observed with the cable out: BLE, WiFiP2P, Owner, ApplePay.
        XCTAssertEqual(SidecarDevice.link(fromStatus: 0x880202), .wifi)
    }

    func testSameNetworkWithoutCableMeansWiFi() {
        XCTAssertEqual(SidecarDevice.link(fromStatus: 0x4), .wifi)
    }

    func testBluetoothOnlyHasNoLink() {
        XCTAssertNil(SidecarDevice.link(fromStatus: 0x2))
        XCTAssertNil(SidecarDevice.link(fromStatus: 0))
    }

    // MARK: - Stand-in display

    func testNoDisplaysNeedsStandIn() {
        XCTAssertTrue(VideoManager.needsBootstrapDisplay(onlineIDs: [], virtualIDs: []))
    }

    func testOnlyVirtualDisplaysNeedsStandIn() {
        XCTAssertTrue(VideoManager.needsBootstrapDisplay(onlineIDs: [5, 6], virtualIDs: [5, 6]))
    }

    func testAnyRealDisplayNeedsNoStandIn() {
        XCTAssertFalse(VideoManager.needsBootstrapDisplay(onlineIDs: [5, 7], virtualIDs: [5]))
    }

    func testSidecarBackingIsOnByDefault() {
        let key = "\(AppIdentity.shortID).sidecar.virtualDisplayBacking"
        let saved = UserDefaults.dam.object(forKey: key)
        defer { UserDefaults.dam.set(saved, forKey: key) }
        UserDefaults.dam.removeObject(forKey: key)
        XCTAssertTrue(VisibilityPreferences.backsSidecarWithVirtualDisplay)
        VisibilityPreferences.backsSidecarWithVirtualDisplay = false
        XCTAssertFalse(VisibilityPreferences.backsSidecarWithVirtualDisplay)
    }

    // MARK: - Resolutions

    func testSidecarAnchorOffersSizesInTheIPadsShape() {
        let native = VideoManager.virtualMode(width: 960, height: 704, refreshRate: 60,
                                              pixelWidth: 1920, pixelHeight: 1408)
        let modes = VideoManager.sidecarVirtualModes(native: native)
        XCTAssertEqual(modes.map { "\($0.width)x\($0.height)" },
                       ["1600x1174", "1440x1056", "1280x938", "1120x822", "960x704", "800x586"])
        XCTAssertTrue(modes.allSatisfy { $0.isHiDPI && $0.isVirtual && $0.roundedRefreshRate == 60 })
        XCTAssertTrue(modes.allSatisfy { $0.pixelWidth == $0.width * 2 })
    }

    func testSidecarSizesStayWithin4KBacking() {
        let native = VideoManager.virtualMode(width: 1366, height: 1024, refreshRate: 60,
                                              pixelWidth: 2732, pixelHeight: 2048)
        let widths = VideoManager.sidecarVirtualModes(native: native).map(\.pixelWidth)
        XCTAssertTrue(widths.allSatisfy { $0 <= 3840 })
        XCTAssertTrue(widths.contains(2732))
    }

    func testSidecarResolutionIsRememberedPerIPad() {
        defer { VisibilityPreferences.setSidecarResolution(nil, for: iPadName) }
        VisibilityPreferences.setSidecarResolution("1280x938", for: iPadName)
        XCTAssertEqual(VisibilityPreferences.sidecarResolution(for: iPadName), "1280x938")
        XCTAssertNil(VisibilityPreferences.sidecarResolution(for: iPadName + " 2"))
    }

    // MARK: - Connecting

    func testConnectTargetNamesTheIPadsLink() {
        let usb = SidecarDevice(id: "x", name: iPadName, isConnected: false, status: 0x1000000)
        XCTAssertEqual(ConnectTarget.sidecar(usb).connectingAnnouncement, "Connecting to \(iPadName) over USB")
        let bleOnly = SidecarDevice(id: "x", name: iPadName, isConnected: false, status: 0x2)
        XCTAssertEqual(ConnectTarget.sidecar(bleOnly).connectingAnnouncement, "Connecting to \(iPadName)")
        XCTAssertFalse(ConnectTarget.sidecar(usb).isConnected)
    }

    // MARK: - Connecting on plug-in

    private let usb: UInt64 = 0x1000000

    func testOnlyThePlaceholderIsNoDisplayOfTheMacsOwn() {
        XCTAssertFalse(VideoManager.hasOwnDisplay([]))
        XCTAssertFalse(VideoManager.hasOwnDisplay([(0x756e6b6e, 0x76697274)]))                 // placeholder
        XCTAssertFalse(VideoManager.hasOwnDisplay([(0x6161706c, 0x69506164), (0x3456, 0x1234)])) // iPad + anchor
        XCTAssertTrue(VideoManager.hasOwnDisplay([(0x30ae, 0x61f7)]))
    }

    func testPluggedInIPadIsConnectedWithoutADisplay() {
        let pad = SidecarDevice(id: "p", name: iPadName, isConnected: false, status: usb)
        let plan = SidecarAutoConnector.plan(devices: [pad], attempts: [:], hasOwnDisplay: false, now: Date())
        XCTAssertEqual(plan.connect?.id, "p")
        XCTAssertNil(SidecarAutoConnector.plan(devices: [pad], attempts: [:], hasOwnDisplay: true, now: Date()).connect)
    }

    func testWirelessIPadIsNotAutoConnected() {
        let pad = SidecarDevice(id: "p", name: iPadName, isConnected: false, status: 0x4)
        XCTAssertNil(SidecarAutoConnector.plan(devices: [pad], attempts: [:], hasOwnDisplay: false, now: Date()).connect)
    }

    func testIPadDisconnectedByHandStaysDisconnectedUntilReplugged() {
        let connected = SidecarDevice(id: "p", name: iPadName, isConnected: true, status: usb)
        var plan = SidecarAutoConnector.plan(devices: [connected], attempts: [:], hasOwnDisplay: false, now: Date())
        let disconnected = SidecarDevice(id: "p", name: iPadName, isConnected: false, status: usb)
        plan = SidecarAutoConnector.plan(devices: [disconnected], attempts: plan.attempts, hasOwnDisplay: false, now: Date())
        XCTAssertNil(plan.connect)
        // Unplugged (gone from USB), then plugged in again.
        plan = SidecarAutoConnector.plan(devices: [], attempts: plan.attempts, hasOwnDisplay: false, now: Date())
        plan = SidecarAutoConnector.plan(devices: [disconnected], attempts: plan.attempts, hasOwnDisplay: false, now: Date())
        XCTAssertEqual(plan.connect?.id, "p")
    }

    func testFailedAttemptsAreRetriedAfterADelayAndThenGivenUp() {
        let pad = SidecarDevice(id: "p", name: iPadName, isConnected: false, status: usb)
        let now = Date()
        var waiting = SidecarAutoConnector.Attempt(count: 1, nextTry: now + 5)
        XCTAssertNil(SidecarAutoConnector.plan(devices: [pad], attempts: ["p": waiting], hasOwnDisplay: false, now: now).connect)
        waiting.nextTry = now - 1
        XCTAssertNotNil(SidecarAutoConnector.plan(devices: [pad], attempts: ["p": waiting], hasOwnDisplay: false, now: now).connect)
        waiting.count = SidecarAutoConnector.maxAttempts
        XCTAssertNil(SidecarAutoConnector.plan(devices: [pad], attempts: ["p": waiting], hasOwnDisplay: false, now: now).connect)
    }

    // MARK: - Nickname

    func testSidecarDisplayUsesTheIPadNickname() {
        let display = DisplayInfo(id: iPadName, name: iPadName, isConnected: true, cgDisplayID: 7,
                                  isMirroring: false, isBuiltIn: false, isSidecar: true)
        VisibilityPreferences.setNickname("Tablet", .sidecar, for: iPadName)
        VisibilityPreferences.setNickname("Screen", .display, for: iPadName)
        XCTAssertEqual(display.label, "Tablet")
        XCTAssertEqual(SidecarDevice(id: "x", name: iPadName, isConnected: true).label, "Tablet")
    }
}
