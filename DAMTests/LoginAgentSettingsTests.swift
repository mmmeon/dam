import XCTest
@testable import DAM

final class LoginAgentSettingsTests: XCTestCase {

    func testOnlyReceiversAtStartupGoToTheAgentWithWhatWasLearnedOfThem() {
        let entries = [AutoConnectEntry(target: .openDisplay(key: "a"), mode: .startup),
                       AutoConnectEntry(target: .openDisplay(key: "b"), mode: .login),
                       AutoConnectEntry(target: .airPlay(name: "Den")),
                       AutoConnectEntry(target: .openDisplay(key: "c"), onlyWithoutOwnDisplay: true, mode: .startup)]
        let settings = LoginAgentSettings.make(entries: entries, names: ["a": "iPad", "b": "iPhone", "c": "Mac"],
                                               usbIDs: ["udid-a": "a", "udid-b": "b"],
                                               bonjourIDs: ["iPad._od": "a", "iPhone._od": "b"], bitrateKbps: 30_000)
        XCTAssertEqual(settings.entries.map(\.target), [.openDisplay(key: "a"), .openDisplay(key: "c")])
        XCTAssertEqual(settings.names, ["a": "iPad", "c": "Mac"])
        XCTAssertEqual(settings.usbIDs, ["udid-a": "a"])
        XCTAssertEqual(settings.bonjourIDs, ["iPad._od": "a"])
        XCTAssertEqual(settings.bitrateKbps, 30_000)
    }

    func testTheFileReadsBackAsWritten() throws {
        let settings = LoginAgentSettings(entries: [AutoConnectEntry(target: .openDisplay(key: "a"), mode: .startup)],
                                          names: ["a": "iPad"], usbIDs: ["udid": "a"], bitrateKbps: 15_000)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        try settings.data.write(to: url)
        XCTAssertEqual(try LoginAgentSettings.read(from: url), settings)
        XCTAssertThrowsError(try LoginAgentSettings.read(from: url.appendingPathExtension("missing")))
    }

    func testTheAgentsStoreDialsByCableOnly() {
        let store = LoginAgentSettings(entries: [AutoConnectEntry(target: .openDisplay(key: "a"), mode: .startup)]).store()
        XCTAssertTrue(store.usbOnly)
        XCTAssertFalse(store.pointerOverUDP)
        XCTAssertEqual(store.toDial(hasOwnDisplay: true), ["a"])
        XCTAssertFalse(DefaultsOpenDisplayStore().usbOnly)
    }

    func testTheAgentsDisplaysAreDAMsDisplays() {
        XCTAssertEqual(StreamingDisplayIdentity.vendorID, VideoManager.anchorVendorID)
        XCTAssertEqual(StreamingDisplayIdentity.productID, VideoManager.streamingProductID)
        let identity = StreamingDisplayIdentity(name: "iPad", seed: "opendisplay:C29C")
        XCTAssertEqual(identity.serial, VideoManager.streamingSerial(seed: "opendisplay:C29C"))
        XCTAssertNotEqual(identity.serial & 0x8000_0000, 0, "never a slot's serial")
    }
}
