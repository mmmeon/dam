import XCTest
import Network
import Security
@testable import DAM

final class WebStreamAccessTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Reach

    func testReachGoesFromThisMacToAnywhere() {
        let loopback = NWEndpoint.hostPort(host: "127.0.0.1", port: 1)
        let mapped = NWEndpoint.hostPort(host: "::ffff:127.0.0.1", port: 1)
        let cable = NWEndpoint.hostPort(host: "169.254.3.4", port: 1)
        let far = NWEndpoint.hostPort(host: "8.8.8.8", port: 1)
        XCTAssertTrue(WebStreamReach.thisMac.allows(loopback))
        XCTAssertTrue(WebStreamReach.thisMac.allows(mapped))
        XCTAssertFalse(WebStreamReach.thisMac.allows(cable))
        XCTAssertTrue(WebStreamReach.thisNetwork.allows(cable))
        XCTAssertFalse(WebStreamReach.thisNetwork.allows(far))
        XCTAssertTrue(WebStreamReach.anywhere.allows(far))
    }

    // MARK: - Pairing

    func testACodeTypedRightPairsTheBrowser() throws {
        let pairing = WebStreamPairing()
        let request = try XCTUnwrap(pairing.begin(address: "10.0.0.5", name: "Safari on iPhone (10.0.0.5)"))
        XCTAssertEqual(request.code.count, 4)
        XCTAssertNil(pairing.begin(address: "10.0.0.6", name: "other"), "one at a time")
        var added: [WebStreamDevice] = []
        XCTAssertTrue(pairing.answer(id: request.id, code: " \(request.code) ") { added.append($0) })
        XCTAssertEqual(added.map(\.name), ["Safari on iPhone (10.0.0.5)"])
        XCTAssertEqual(added.first?.kind, .browser)
        XCTAssertEqual(pairing.request(id: request.id)?.device, added.first)
        XCTAssertNotNil(pairing.begin(address: "10.0.0.6", name: "other"), "free again")
    }

    func testAWrongCodeOrNoneDeclinesAndTheCodeRunsOut() throws {
        let pairing = WebStreamPairing()
        let start = Date()
        var request = try XCTUnwrap(pairing.begin(address: "a", name: "a", now: start))
        let wrong = request.code == "0000" ? "1111" : "0000"
        XCTAssertFalse(pairing.answer(id: request.id, code: wrong) { _ in XCTFail() })
        XCTAssertEqual(pairing.request(id: request.id)?.declined, true)
        XCTAssertFalse(pairing.answer(id: request.id, code: request.code) { _ in XCTFail() }, "no second try")

        request = try XCTUnwrap(pairing.begin(address: "b", name: "b", now: start))
        XCTAssertFalse(pairing.answer(id: request.id, code: nil) { _ in XCTFail() }, "the user said no")
        request = try XCTUnwrap(pairing.begin(address: "c", name: "c", now: start))
        let late = start.addingTimeInterval(WebStreamPairing.lifetime + 1)
        XCTAssertNil(pairing.request(id: request.id, now: late))
        XCTAssertFalse(pairing.answer(id: request.id, code: request.code, now: late) { _ in XCTFail() })
        XCTAssertNotNil(pairing.begin(address: "d", name: "d", now: late), "an old request holds nothing up")
    }

    func testAQRKeyWorksOnceAndNotForLong() {
        let pairing = WebStreamPairing()
        let start = Date()
        let key = pairing.makeKey(now: start)
        XCTAssertTrue(pairing.use(key: key, now: start.addingTimeInterval(10)))
        XCTAssertFalse(pairing.use(key: key, now: start.addingTimeInterval(11)), "once")
        let old = pairing.makeKey(now: start)
        XCTAssertFalse(pairing.use(key: old, now: start.addingTimeInterval(WebStreamPairing.lifetime + 1)))
        XCTAssertFalse(pairing.use(key: "nonsense"))
        XCTAssertFalse(pairing.use(key: nil))
    }

    func testBrowsersAreNamedFromTheirUserAgent() {
        let iphone = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        let chrome = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
        XCTAssertEqual(WebStreamPairing.name(userAgent: iphone, address: "10.0.0.5"), "Safari on iPhone (10.0.0.5)")
        XCTAssertEqual(WebStreamPairing.name(userAgent: chrome, address: ""), "Chrome on Windows")
        XCTAssertEqual(WebStreamPairing.name(userAgent: nil, address: "::1"), "Browser (::1)")
    }

    // MARK: - Devices

    func testDevicesAreKeptAndTheOldLinkGoesOnWorking() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = String(repeating: "a", count: 32)
        try Data(old.utf8).write(to: directory.appendingPathComponent("token"))
        let devices = WebStreamDevices(directory: directory)
        XCTAssertEqual(devices.device(token: old)?.name, "Link from Before")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("token").path))
        let phone = devices.add(WebStreamDevice(name: "Phone", kind: .browser))
        let thisMac = devices.thisMac
        XCTAssertEqual(devices.thisMac, thisMac, "made once")

        let again = WebStreamDevices(directory: directory)
        XCTAssertEqual(again.all.map(\.name), ["Link from Before", "Phone", WebStreamDevices.thisMacName])
        XCTAssertEqual(again.device(token: phone.token), phone)
        again.remove(id: phone.id)
        XCTAssertNil(WebStreamDevices(directory: directory).device(token: phone.token))
        XCTAssertNil(again.device(token: ""))
        XCTAssertNil(again.device(token: nil))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("devices.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // MARK: - Certificates

    private func trusts(_ server: Data, name: String, authority: Data) -> Bool {
        guard let leaf = SecCertificateCreateWithData(nil, server as CFData),
              let root = SecCertificateCreateWithData(nil, authority as CFData) else { return false }
        var trust: SecTrust?
        SecTrustCreateWithCertificates([leaf] as CFArray, SecPolicyCreateSSL(true, name as CFString), &trust)
        guard let trust else { return false }
        SecTrustSetAnchorCertificates(trust, [root] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &error)
        if let error { print("trust: \(error)") }
        return trusted
    }

    /// The server certificate passes Apple's checks for a TLS server under the authority,
    /// for each of its names; the authority is kept, and the server certificate made again
    /// when the names change.
    func testTheServerCertificateIsTrustedUnderTheAuthorityForItsNames() throws {
        let names = ["test-mac.local", "localhost"]
        let first = try WebStreamCertificates(directory: directory, names: names, addresses: [[127, 0, 0, 1]])
        XCTAssertTrue(trusts(first.server, name: "test-mac.local", authority: first.authority))
        XCTAssertTrue(trusts(first.server, name: "localhost", authority: first.authority))
        XCTAssertTrue(trusts(first.server, name: "127.0.0.1", authority: first.authority))
        XCTAssertFalse(trusts(first.server, name: "other.local", authority: first.authority))
        XCTAssertTrue(first.authorityPEM.hasPrefix("-----BEGIN CERTIFICATE-----"))
        XCTAssertEqual(first.fingerprint.count, 32 * 3 - 1)

        let kept = try WebStreamCertificates(directory: directory, names: names, addresses: [[127, 0, 0, 1]])
        XCTAssertEqual(kept.server, first.server)
        XCTAssertEqual(kept.authority, first.authority)

        let renamed = try WebStreamCertificates(directory: directory, names: ["new-name.local"], addresses: [[127, 0, 0, 1]])
        XCTAssertEqual(renamed.authority, first.authority, "trusted once")
        XCTAssertNotEqual(renamed.server, first.server)
        XCTAssertTrue(trusts(renamed.server, name: "new-name.local", authority: first.authority))
    }
}
