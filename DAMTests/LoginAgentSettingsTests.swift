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

    func testRefreshRatesReadBackAndDefaultWhenMissingOrOutOfRange() {
        let settings = LoginAgentSettings(refreshRates: [120, 60])
        XCTAssertEqual(LoginAgentSettings(dictionary: settings.dictionary).refreshRates, [120, 60])
        XCTAssertEqual(LoginAgentSettings(dictionary: [:]).refreshRates, StreamingDisplayModes.refreshRates)
        XCTAssertEqual(LoginAgentSettings(dictionary: ["refreshRates": [0, 9_999]]).refreshRates,
                       StreamingDisplayModes.refreshRates)
    }

    func testOnlyDevicesAllowedGoToTheAgentAndWithoutInput() throws {
        let clients = [MoonlightClient(name: "iPad", certificate: Data([1]), paired: Date(), allowsInput: true,
                                       showsLoginWindow: true),
                       MoonlightClient(name: "Phone", certificate: Data([2]), paired: Date())]
        let defaults: [String: Any] = ["dam.moonlight.videoEncryption": "always", "dam.moonlight.hevc": "off",
                                       "dam.moonlight.enabled": true, "dam.moonlight.allowsPairing": true,
                                       "dam.moonlight.uniqueID": "A", "dam.other": 1]
        let moonlight = try XCTUnwrap(LoginAgentSettings.Moonlight.make(uniqueID: "A", certificate: Data([9]),
                                                                        clients: clients, defaults: defaults))
        XCTAssertEqual(moonlight.clients.map(\.name), ["iPad"])
        XCTAssertEqual(moonlight.clients.map(\.allowsInput), [false])
        XCTAssertEqual(moonlight.defaults, ["dam.moonlight.videoEncryption": "always", "dam.moonlight.hevc": "off"])
        XCTAssertNil(LoginAgentSettings.Moonlight.make(uniqueID: "A", certificate: Data([9]), clients: [clients[1]],
                                                       defaults: [:]), "none allowed")
    }

    func testTheAgentsDevicesHaveNoNamesOfDAMsSoRenamingNeedsNoUpdate() throws {
        var client = MoonlightClient(name: "10.0.0.2", certificate: Data([1]), paired: Date(), showsLoginWindow: true)
        let before = try XCTUnwrap(LoginAgentSettings.Moonlight.make(uniqueID: "A", certificate: Data([9]),
                                                                      clients: [client], defaults: [:]))
        client.autoName = "Robins-iPad"
        client.customName = "Living Room"
        let after = try XCTUnwrap(LoginAgentSettings.Moonlight.make(uniqueID: "A", certificate: Data([9]),
                                                                     clients: [client], defaults: [:]))
        XCTAssertEqual(after, before)
    }

    func testTheMoonlightHostReadsBackAsWrittenWithoutItsKey() throws {
        let iPad = MoonlightClient(name: "iPad", certificate: Data([1]), paired: Date(timeIntervalSince1970: 0),
                                   allowsInput: false, showsLoginWindow: true)
        let settings = LoginAgentSettings(moonlight: .init(uniqueID: "A", certificate: Data([9]), clients: [iPad],
                                                           defaults: ["dam.moonlight.hevc": "off"]))
        XCTAssertFalse(settings.isEmpty)
        XCTAssertTrue(LoginAgentSettings().isEmpty)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        try settings.data.write(to: url)
        XCTAssertEqual(try LoginAgentSettings.read(from: url), settings)
        let keys = try XCTUnwrap(settings.dictionary["moonlight"] as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["uniqueID", "certificate", "clients", "defaults"], "no key: anyone may read it")
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
