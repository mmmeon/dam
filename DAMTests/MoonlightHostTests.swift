import XCTest
import Network
import Security
@testable import DAM

/// Runs the host on its own ports and folder, and pairs with it over real connections as
/// Moonlight does. The PIN prompt is a closure here, so no window opens.
final class MoonlightHostTests: XCTestCase {

    private var directory: URL!
    private var host: MoonlightHost!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let base = UInt16.random(in: 40000...59000)
        host = MoonlightHost(httpPort: NWEndpoint.Port(rawValue: base)!,
                             httpsPort: NWEndpoint.Port(rawValue: base + 1)!,
                             directory: directory, advertises: false)
    }

    override func tearDownWithError() throws {
        host.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    private func startHost() {
        host.start()
        let deadline = Date().addingTimeInterval(5)
        while !host.isListening, host.lastError == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(host.isListening, host.lastError ?? "not listening")
    }

    // MARK: - A client

    private struct Client {
        let key: SecKey
        let certificate: Data
        let identity: SecIdentity

        static func make() throws -> Client {
            let key = try MoonlightCrypto.generatePrivateKey()
            let certificate = try MoonlightCrypto.selfSignedCertificate(key: key, commonName: "NVIDIA GameStream Client")
            let identity = try XCTUnwrap(MoonlightHost.makeIdentity(
                try XCTUnwrap(SecCertificateCreateWithData(nil, certificate as CFData)), key))
            return Client(key: key, certificate: certificate, identity: identity)
        }
    }

    /// Opens a connection and sends a GET for `target`; over TLS as `identity` when given.
    private func open(_ target: String, secure: Bool, identity: SecIdentity? = nil) -> NWConnection {
        let parameters: NWParameters
        if secure {
            let tls = NWProtocolTLS.Options()
            if let identity, let local = sec_identity_create(identity) {
                sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
            }
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, done in done(true) },
                                                  .global())
            parameters = NWParameters(tls: tls)
        } else {
            parameters = .tcp
        }
        let port = secure ? host.httpsPort : host.httpPort
        let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
        connection.start(queue: .global())
        let separator = target.contains("?") ? "&" : "?"
        let request = "GET \(target)\(separator)uniqueid=0123456789ABCDEF HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        connection.send(content: Data(request.utf8), completion: .idempotent)
        return connection
    }

    /// The body of the response to a GET for `target`.
    private func get(_ target: String, secure: Bool = false, identity: SecIdentity? = nil,
                     timeout: TimeInterval = 10) throws -> String {
        let connection = open(target, secure: secure, identity: identity)
        let done = expectation(description: target)
        var response = Data()
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data { response.append(data) }
                if isComplete || error != nil { done.fulfill() } else { read() }
            }
        }
        read()
        wait(for: [done], timeout: timeout)
        connection.cancel()
        let text = String(decoding: response, as: UTF8.self)
        return try XCTUnwrap(text.components(separatedBy: "\r\n\r\n").dropFirst().first, "no body: \(text)")
    }

    private func field(_ name: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(name)>"),
              let end = xml.range(of: "</\(name)>", range: start.upperBound..<xml.endIndex) else { return nil }
        return String(xml[start.upperBound..<end.lowerBound])
    }

    private func status(_ xml: String) -> String? {
        xml.range(of: #"status_code="\d+""#, options: .regularExpression)
            .map { String(xml[$0].dropFirst(13).dropLast()) }
    }

    /// Pairs as moonlight-qt's NvPairingManager does: four steps over HTTP, the last over
    /// HTTPS. Returns whether the host said paired at the last step it reached.
    @discardableResult
    private func pair(_ client: Client, pin: String) throws -> Bool {
        let hex = MoonlightCrypto.hex
        let salt = MoonlightPairing.randomBytes(16)
        let key = MoonlightCrypto.pairingKey(salt: salt, pin: pin)
        let pem = Data(MoonlightCrypto.pem(certificate: client.certificate).utf8)

        var xml = try get("/pair?devicename=roth&updateState=1&phrase=getservercert&salt=\(hex(salt))&clientcert=\(hex(pem))")
        guard field("paired", in: xml) == "1" else { return false }
        let serverPEM = String(decoding: try XCTUnwrap(field("plaincert", in: xml).flatMap(MoonlightCrypto.data(hex:))),
                               as: UTF8.self)
        let serverCertificate = try MoonlightCrypto.der(certificatePEM: serverPEM)

        let challenge = MoonlightPairing.randomBytes(16)
        xml = try get("/pair?devicename=roth&updateState=1&clientchallenge=\(hex(try MoonlightCrypto.aesECB(challenge, key: key, encrypt: true)))")
        let response = try MoonlightCrypto.aesECB(
            try XCTUnwrap(field("challengeresponse", in: xml).flatMap(MoonlightCrypto.data(hex:))), key: key, encrypt: false)

        let clientSecret = MoonlightPairing.randomBytes(16)
        let clientHash = MoonlightCrypto.sha256(Data(response.dropFirst(32).prefix(16))
            + (try MoonlightCrypto.signature(ofCertificate: client.certificate)) + clientSecret)
        xml = try get("/pair?devicename=roth&updateState=1&serverchallengeresp=\(hex(try MoonlightCrypto.aesECB(clientHash, key: key, encrypt: true)))")
        let secret = try XCTUnwrap(field("pairingsecret", in: xml).flatMap(MoonlightCrypto.data(hex:)))
        XCTAssertTrue(MoonlightCrypto.verify(Data(secret.dropFirst(16)), of: Data(secret.prefix(16)),
                                             certificateDER: serverCertificate))
        let hostKnewPIN = MoonlightCrypto.sha256(challenge + (try MoonlightCrypto.signature(ofCertificate: serverCertificate))
            + secret.prefix(16)) == response.prefix(32)

        let signed = clientSecret + (try MoonlightCrypto.sign(clientSecret, with: client.key))
        xml = try get("/pair?devicename=roth&updateState=1&clientpairingsecret=\(hex(signed))")
        guard field("paired", in: xml) == "1" else { return false }
        XCTAssertTrue(hostKnewPIN)

        xml = try get("/pair?devicename=roth&updateState=1&phrase=pairchallenge", secure: true, identity: client.identity)
        return field("paired", in: xml) == "1"
    }

    // MARK: - Tests

    func testServerInfoOverHTTPSaysUnpaired() throws {
        startHost()
        let xml = try get("/serverinfo")
        XCTAssertEqual(status(xml), "200")
        XCTAssertEqual(field("PairStatus", in: xml), "0")
        XCTAssertEqual(field("appversion", in: xml), MoonlightHost.appVersion)
        XCTAssertEqual(field("HttpsPort", in: xml), "\(host.httpsPort.rawValue)")
    }

    func testPairsWithTheRightPIN() throws {
        host.requestPIN = { _, answer in answer("4821") }
        host.apps = [MoonlightApp(id: 1, title: "DAM Streaming")]
        startHost()
        let client = try Client.make()
        XCTAssertTrue(try pair(client, pin: "4821"))
        XCTAssertEqual(host.clients.map(\.certificate), [client.certificate])

        let info = try get("/serverinfo", secure: true, identity: client.identity)
        XCTAssertEqual(field("PairStatus", in: info), "1")
        let apps = try get("/applist", secure: true, identity: client.identity)
        XCTAssertEqual(field("AppTitle", in: apps), "DAM Streaming")
        XCTAssertEqual(field("ID", in: apps), "1")
    }

    func testRefusesAWrongPIN() throws {
        host.requestPIN = { _, answer in answer("4812") }
        startHost()
        XCTAssertFalse(try pair(try Client.make(), pin: "4821"))
        XCTAssertTrue(host.clients.isEmpty)
    }

    func testRefusesWhenTheUserDeclines() throws {
        host.requestPIN = { _, answer in answer(nil) }
        startHost()
        XCTAssertFalse(try pair(try Client.make(), pin: "4821"))
        XCTAssertTrue(host.clients.isEmpty)
    }

    func testTurnsAwayUnpairedDevicesOverHTTPS() throws {
        startHost()
        let xml = try get("/serverinfo", secure: true, identity: try Client.make().identity)
        XCTAssertEqual(status(xml), "401")
    }

    func testForgottenDeviceMustPairAgain() throws {
        host.requestPIN = { _, answer in answer("1234") }
        startHost()
        let client = try Client.make()
        XCTAssertTrue(try pair(client, pin: "1234"))
        host.forget(try XCTUnwrap(host.clients.first))
        XCTAssertEqual(status(try get("/applist", secure: true, identity: client.identity)), "401")
    }

    func testKeepsItsCertificateAndPairingsAcrossRestarts() throws {
        host.requestPIN = { _, answer in answer("1234") }
        startHost()
        let client = try Client.make()
        XCTAssertTrue(try pair(client, pin: "1234"))
        host.stop()
        startHost()
        XCTAssertEqual(field("PairStatus", in: try get("/serverinfo", secure: true, identity: client.identity)), "1")
    }

    func testGivesUpWhenTheDeviceHangsUpDuringThePrompt() throws {
        let asked = expectation(description: "PIN asked")
        let abandoned = expectation(description: "pairing abandoned")
        host.requestPIN = { _, _ in asked.fulfill() }
        host.pairingAbandoned = { abandoned.fulfill() }
        startHost()
        let client = try Client.make()
        let pem = MoonlightCrypto.hex(Data(MoonlightCrypto.pem(certificate: client.certificate).utf8))
        let connection = open("/pair?devicename=roth&updateState=1&phrase=getservercert&salt=00112233445566778899AABBCCDDEEFF&clientcert=\(pem)",
                              secure: false)
        wait(for: [asked], timeout: 5)
        connection.cancel()
        wait(for: [abandoned], timeout: 5)
    }
}
