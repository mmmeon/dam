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
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
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
