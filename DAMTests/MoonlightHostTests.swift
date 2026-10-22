import XCTest
import CommonCrypto
import CryptoKit
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
                             rtspPort: NWEndpoint.Port(rawValue: base + 2)!,
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
            let certificate = try MoonlightCrypto.certificate(key: key, subject: "NVIDIA GameStream Client", days: 20 * 365)
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
        try body(of: open(target, secure: secure, identity: identity), timeout: timeout)
    }

    /// The body of the response on `connection`, read to its end.
    private func body(of connection: NWConnection, timeout: TimeInterval = 10) throws -> String {
        let done = expectation(description: "response")
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

    /// HEVC only when turned on, and only in hardware: Moonlight takes it whenever it is offered.
    func testHEVCIsOfferedOnlyWhenTurnedOnAndInHardware() {
        let none = VideoCodec.Support(hardware: false, lowLatency: false)
        let plain = VideoCodec.Support(hardware: true, lowLatency: false)
        XCTAssertEqual(MoonlightHost.codecs(offersHEVC: false, support: [.h264: plain, .hevc: plain]), [.h264])
        XCTAssertEqual(MoonlightHost.codecs(offersHEVC: true, support: [.h264: plain, .hevc: plain]), [.h264, .hevc])
        XCTAssertEqual(MoonlightHost.codecs(offersHEVC: true, support: [.h264: plain, .hevc: none]), [.h264],
                       "not in software")
        XCTAssertEqual(MoonlightHost.codecs(offersHEVC: true, support: [:]), [.h264])
    }

    func testServerInfoOffersTheDevicesCodecs() throws {
        host.requestPIN = { _, answer in answer("4821") }
        startHost()
        let client = try Client.make()
        XCTAssertTrue(try pair(client, pin: "4821"))
        func offered() throws -> (modes: Int?, luma: String?) {
            let info = try get("/serverinfo", secure: true, identity: client.identity)
            return (field("ServerCodecModeSupport", in: info).flatMap { Int($0) }, field("MaxLumaPixelsHEVC", in: info))
        }
        let key = "\(AppIdentity.shortID).moonlight.offersHEVC"
        let saved = UserDefaults.dam.object(forKey: key)
        defer { UserDefaults.dam.set(saved, forKey: key) }
        for offers in [false, true] {
            MoonlightHost.offersHEVC = offers
            let hevc = offers && VideoCodec.support[.hevc]?.hardware == true
            let (modes, luma) = try offered()
            XCTAssertEqual(modes, hevc ? 0x0101 : 0x0001, "offers HEVC \(offers)")
            XCTAssertEqual(luma, hevc ? "1869449984" : "0", "Moonlight takes HEVC only with a maximum")
        }
    }

    func testPairsWithTheRightPIN() throws {
        host.requestPIN = { _, answer in answer("4821") }
        host.apps = [MoonlightApp(id: 1, title: "DAM Streaming", displayID: 0)]
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

    func testTurnsAwayNewDevicesWithoutAskingWhenPairingIsOff() throws {
        MoonlightHost.allowsPairing = false
        defer { MoonlightHost.allowsPairing = true }
        var asked = false
        host.requestPIN = { _, answer in asked = true; answer("4821") }
        startHost()
        XCTAssertFalse(try pair(try Client.make(), pin: "4821"))
        XCTAssertFalse(asked)
        XCTAssertTrue(host.clients.isEmpty)
    }

    func testTurnsAwayUnpairedDevicesOverHTTPS() throws {
        startHost()
        let xml = try get("/serverinfo", secure: true, identity: try Client.make().identity)
        XCTAssertEqual(status(xml), "401")
    }

    func testLowLatencyIsSetPerDeviceAndKept() throws {
        host.requestPIN = { _, answer in answer("1234") }
        startHost()
        let client = try Client.make()
        XCTAssertTrue(try pair(client, pin: "1234"))
        XCTAssertTrue(try XCTUnwrap(host.clients.first).lowLatency)
        host.setLowLatency(false, for: try XCTUnwrap(host.clients.first))
        XCTAssertFalse(try XCTUnwrap(host.clients.first).lowLatency)
        let saved = try Data(contentsOf: directory.appendingPathComponent("paired-clients.json"))
        XCTAssertEqual(try JSONDecoder().decode([MoonlightClient].self, from: saved).map(\.lowLatency), [false])
    }

    func testInputIsAllowedPerDeviceAndKept() throws {
        host.requestPIN = { _, answer in answer("1234") }
        startHost()
        let client = try Client.make()
        XCTAssertTrue(try pair(client, pin: "1234"))
        XCTAssertTrue(try XCTUnwrap(host.clients.first).allowsInput)
        host.setAllowsInput(false, for: try XCTUnwrap(host.clients.first))
        XCTAssertFalse(try XCTUnwrap(host.clients.first).allowsInput)
        let saved = try Data(contentsOf: directory.appendingPathComponent("paired-clients.json"))
        XCTAssertEqual(try JSONDecoder().decode([MoonlightClient].self, from: saved).map(\.allowsInput), [false])
    }

    func testDevicesSavedBeforeInputAllowItOn() throws {
        let saved = try JSONEncoder().encode([MoonlightClient(name: "10.0.0.2", certificate: Data([1]), paired: Date())])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [[String: Any]])
        object[0].removeValue(forKey: "allowsInput")
        let clients = try JSONDecoder().decode([MoonlightClient].self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(clients.map(\.allowsInput), [true])
    }

    func testDevicesSavedBeforeLowLatencyWasTheDefaultHaveItOn() throws {
        let saved = try JSONEncoder().encode([MoonlightClient(name: "10.0.0.2", certificate: Data([1]), paired: Date())])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [[String: Any]])
        object[0].removeValue(forKey: "lowLatencyEncoding")
        let older = try JSONSerialization.data(withJSONObject: object)
        object[0]["lowLatency"] = false
        let old = try JSONSerialization.data(withJSONObject: object)
        for data in [older, old] {
            let clients = try JSONDecoder().decode([MoonlightClient].self, from: data)
            XCTAssertEqual(clients.map(\.name), ["10.0.0.2"])
            XCTAssertEqual(clients.map(\.lowLatency), [true])
        }
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

    // MARK: - Displays made on demand

    func testNewDisplayIsListedAndLaunchingItMakesADisplayThatCancelRemoves() throws {
        var made: [Int] = []
        var removed: [CGDirectDisplayID] = []
        host.requestPIN = { _, answer in answer("1234") }
        host.makeDisplay = { width, height, fps, done in
            made = [width, height, fps]
            // Placing a display takes a while; the launch waits for it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { done(42) }
        }
        host.removeDisplay = { removed.append($0) }
        startHost()
        let client = try Client.make()
        XCTAssertTrue(try pair(client, pin: "1234"))

        let apps = try get("/applist", secure: true, identity: client.identity)
        XCTAssertEqual(field("AppTitle", in: apps), "New Display")
        XCTAssertEqual(field("ID", in: apps), "\(MoonlightHost.newDisplayAppID)")

        let key = MoonlightCrypto.hex(MoonlightPairing.randomBytes(16))
        let launch = try get("/launch?appid=\(MoonlightHost.newDisplayAppID)&mode=2880x1800x120&rikey=\(key)&rikeyid=1",
                             secure: true, identity: client.identity)
        XCTAssertEqual(field("gamesession", in: launch), "1")
        XCTAssertEqual(made, [2880, 1800, 120])
        XCTAssertEqual(host.launches.first?.displayID, 42)
        XCTAssertEqual(field("currentgame", in: try get("/serverinfo", secure: true, identity: client.identity)),
                       "\(MoonlightHost.newDisplayAppID)")

        XCTAssertEqual(field("cancel", in: try get("/cancel", secure: true, identity: client.identity)), "1")
        XCTAssertEqual(removed, [42])
    }

    func testAnAppWhoseDisplayIsGoneGetsANewOne() throws {
        var made = false
        host.requestPIN = { _, answer in answer("1234") }
        host.makeDisplay = { _, _, _, done in made = true; done(7) }
        startHost()
        let client = try Client.make()
        XCTAssertTrue(try pair(client, pin: "1234"))
        let key = MoonlightCrypto.hex(MoonlightPairing.randomBytes(16))
        let launch = try get("/launch?appid=1&mode=1920x1080x60&rikey=\(key)&rikeyid=1", secure: true, identity: client.identity)
        XCTAssertEqual(field("gamesession", in: launch), "1")
        XCTAssertTrue(made)
    }

    // A launch reuses the display only while it is online, so these hand out the main
    // display's ID; every display change goes through the closures here, none for real.

    private func launchAndResume(appID: Int, resized: Bool, apps: [MoonlightApp] = [])
        throws -> (made: [[Int]], resizes: [[Int]], removed: [CGDirectDisplayID]) {
        let online = CGMainDisplayID()
        var made: [[Int]] = [], resizes: [[Int]] = [], removed: [CGDirectDisplayID] = []
        host.requestPIN = { _, answer in answer("1234") }
        host.apps = apps
        host.makeDisplay = { width, height, fps, done in
            made.append([width, height, fps])
            done(made.count == 1 ? online : 43)
        }
        host.resizeDisplay = { id, width, height, fps, done in
            resizes.append([Int(id), width, height, fps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { done(resized) }
        }
        host.removeDisplay = { removed.append($0) }
        startHost()
        let client = try Client.make()
        XCTAssertTrue(try pair(client, pin: "1234"))
        let key = MoonlightCrypto.hex(MoonlightPairing.randomBytes(16))
        XCTAssertEqual(field("gamesession", in: try get("/launch?appid=\(appID)&mode=1920x1080x60&rikey=\(key)&rikeyid=1",
                                                        secure: true, identity: client.identity)), "1")
        XCTAssertEqual(field("resume", in: try get("/resume?appid=\(appID)&mode=2532x1170x60&rikey=\(key)&rikeyid=2",
                                                   secure: true, identity: client.identity)), "1")
        return (made, resizes, removed)
    }

    func testResumingAtAnotherSizeResizesTheDisplayMadeForTheStream() throws {
        let (made, resizes, removed) = try launchAndResume(appID: MoonlightHost.newDisplayAppID, resized: true)
        XCTAssertEqual(made, [[1920, 1080, 60]])
        XCTAssertEqual(resizes, [[Int(CGMainDisplayID()), 2532, 1170, 60]])
        XCTAssertEqual(removed, [])
        XCTAssertEqual(host.launches.first?.displayID, CGMainDisplayID())
        XCTAssertEqual(host.launches.first?.ownsDisplay, true)
    }

    func testMakesAnotherDisplayWhenTheOneMadeCannotBeResized() throws {
        let (made, _, removed) = try launchAndResume(appID: MoonlightHost.newDisplayAppID, resized: false)
        XCTAssertEqual(made, [[1920, 1080, 60], [2532, 1170, 60]])
        XCTAssertEqual(removed, [CGMainDisplayID()])
        XCTAssertEqual(host.launches.first?.displayID, 43)
    }

    func testLeavesTheSizeOfADisplayTheUserMade() throws {
        let apps = [MoonlightApp(id: 1, title: "DAM Streaming", displayID: CGMainDisplayID())]
        let (made, resizes, removed) = try launchAndResume(appID: 1, resized: true, apps: apps)
        XCTAssertEqual(made, [])
        XCTAssertEqual(resizes, [])
        XCTAssertEqual(removed, [])
        XCTAssertEqual(host.launches.first?.displayID, CGMainDisplayID())
    }

    func testSaysSoWhenNoDisplayCanBeMade() throws {
        host.requestPIN = { _, answer in answer("1234") }
        host.makeDisplay = { _, _, _, done in done(nil) }
        startHost()
        let client = try Client.make()
        XCTAssertTrue(try pair(client, pin: "1234"))
        let key = MoonlightCrypto.hex(MoonlightPairing.randomBytes(16))
        let launch = try get("/launch?appid=100&mode=1920x1080x60&rikey=\(key)&rikeyid=1", secure: true, identity: client.identity)
        XCTAssertEqual(status(launch), "503")
        XCTAssertTrue(host.launches.isEmpty)
    }

    func testTwoLaunchesAtOnceLeaveNoDisplayBehind() throws {
        var removed: [CGDirectDisplayID] = []
        var made = 0
        host.requestPIN = { _, answer in answer("1234") }
        host.makeDisplay = { _, _, _, done in
            made += 1
            let id = CGDirectDisplayID(89 + made)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 * Double(made)) { done(id) }
        }
        host.removeDisplay = { removed.append($0) }
        startHost()
        let client = try Client.make()
        XCTAssertTrue(try pair(client, pin: "1234"))
        func launch() -> NWConnection {
            let key = MoonlightCrypto.hex(MoonlightPairing.randomBytes(16))
            return open("/launch?appid=\(MoonlightHost.newDisplayAppID)&mode=1920x1080x60&rikey=\(key)&rikeyid=1",
                        secure: true, identity: client.identity)
        }
        let first = launch(), second = launch()
        XCTAssertEqual(field("gamesession", in: try body(of: first)), "1")
        XCTAssertEqual(field("gamesession", in: try body(of: second)), "1")
        XCTAssertEqual(made, 2)
        XCTAssertEqual(host.launches.map(\.displayID), [91])
        XCTAssertEqual(removed, [90], "the display of the launch replaced")
    }

    /// A display that is ready only after hosting stopped, or the device was unpaired, goes
    /// again, and no launch is left.
    func testALaunchOutlivingTheHostOrThePairingLeavesNothing() throws {
        var removed: [CGDirectDisplayID] = []
        var asked: XCTestExpectation?
        host.requestPIN = { _, answer in answer("1234") }
        host.makeDisplay = { _, _, _, done in
            asked?.fulfill()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { done(96) }
        }
        host.removeDisplay = { removed.append($0) }
        startHost()
        for ending in ["unpaired", "stopped"] {
            let client = try Client.make()
            XCTAssertTrue(try pair(client, pin: "1234"))
            asked = expectation(description: "display asked for")
            let key = MoonlightCrypto.hex(MoonlightPairing.randomBytes(16))
            let connection = open("/launch?appid=\(MoonlightHost.newDisplayAppID)&mode=1920x1080x60&rikey=\(key)&rikeyid=1",
                                  secure: true, identity: client.identity)
            wait(for: [asked!], timeout: 5)
            if ending == "unpaired" {
                host.forget(try XCTUnwrap(host.clients.first { $0.certificate == client.certificate }))
            } else {
                host.stop()
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            connection.cancel()
            XCTAssertTrue(host.launches.isEmpty, ending)
            XCTAssertEqual(removed, [96], ending)
            removed = []
        }
    }

    func testConnectionsAreCappedAndMustAskInTime() throws {
        host = MoonlightHost(httpPort: host.httpPort, httpsPort: host.httpsPort, rtspPort: host.rtspPort, directory: directory,
                             advertises: false, limits: MoonlightConnectionLimits(maxPerAddress: 2, deadline: 1))
        startHost()
        func idle() -> NWConnection {
            let connection = NWConnection(host: "127.0.0.1", port: host.httpPort, using: .tcp)
            connection.start(queue: .global())
            return connection
        }
        /// How long until the host closes `connection`.
        func closing(_ connection: NWConnection) -> TimeInterval {
            let start = Date()
            let closed = expectation(description: "closed")
            func read() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, isComplete, error in
                    if isComplete || error != nil { closed.fulfill() } else { read() }
                }
            }
            read()
            wait(for: [closed], timeout: 5)
            connection.cancel()
            return Date().timeIntervalSince(start)
        }
        let waiting = [idle(), idle()]
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertLessThan(closing(idle()), 0.5, "a third from the same address is turned away")
        for connection in waiting {
            XCTAssertLessThan(closing(connection), 2, "closed for asking nothing")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(status(try get("/serverinfo")), "200", "served again once they have gone")
    }

    // MARK: - Several devices

    private func launchNewDisplay(_ client: Client, mode: String = "1920x1080x60") throws -> String {
        let key = MoonlightCrypto.hex(MoonlightPairing.randomBytes(16))
        return try get("/launch?appid=\(MoonlightHost.newDisplayAppID)&mode=\(mode)&rikey=\(key)&rikeyid=1",
                       secure: true, identity: client.identity)
    }

    func testEachDeviceHasASessionOfItsOwnAndSeesOnlyItsOwn() throws {
        var made: [CGDirectDisplayID] = [], removed: [CGDirectDisplayID] = []
        host.requestPIN = { _, answer in answer("1234") }
        host.makeDisplay = { _, _, _, done in made.append(CGDirectDisplayID(50 + made.count)); done(made.last) }
        host.removeDisplay = { removed.append($0) }
        startHost()
        let a = try Client.make(), b = try Client.make(), idle = try Client.make()
        for client in [a, b, idle] { XCTAssertTrue(try pair(client, pin: "1234")) }

        let first = try launchNewDisplay(a)
        let second = try launchNewDisplay(b, mode: "2560x1600x120")
        XCTAssertEqual(field("sessionUrl0", in: first), "rtsp://127.0.0.1:\(host.rtspPort.rawValue)")
        XCTAssertEqual(field("sessionUrl0", in: second), "rtsp://127.0.0.1:\(host.rtspPort.rawValue + 1)")
        XCTAssertEqual(made, [50, 51], "a display each")
        XCTAssertEqual(host.launches.map(\.displayID), [50, 51])
        XCTAssertEqual(host.streamingClients.map(\.certificate), [a.certificate, b.certificate])

        // Each sees its own launch; one that launched nothing sees the host free, so
        // Moonlight doesn't ask it to quit another device's app.
        for client in [a, b] {
            let info = try get("/serverinfo", secure: true, identity: client.identity)
            XCTAssertEqual(field("state", in: info), "SUNSHINE_SERVER_BUSY")
            XCTAssertEqual(field("currentgame", in: info), "\(MoonlightHost.newDisplayAppID)")
        }
        XCTAssertEqual(field("state", in: try get("/serverinfo", secure: true, identity: idle.identity)), "SUNSHINE_SERVER_FREE")
        XCTAssertEqual(field("state", in: try get("/serverinfo")), "SUNSHINE_SERVER_FREE")

        // Cancelling ends only that device's launch, and its session's port is free again.
        XCTAssertEqual(field("cancel", in: try get("/cancel", secure: true, identity: a.identity)), "1")
        XCTAssertEqual(removed, [50])
        XCTAssertEqual(host.launches.map(\.displayID), [51])
        XCTAssertEqual(field("state", in: try get("/serverinfo", secure: true, identity: b.identity)), "SUNSHINE_SERVER_BUSY")
        XCTAssertEqual(field("sessionUrl0", in: try launchNewDisplay(idle)), "rtsp://127.0.0.1:\(host.rtspPort.rawValue)")
    }

    func testTurnsAwayADeviceBeyondTheMostSessions() throws {
        var made = 0
        host.requestPIN = { _, answer in answer("1234") }
        host.makeDisplay = { _, _, _, done in made += 1; done(CGDirectDisplayID(60 + made)) }
        startHost()
        for _ in 0..<MoonlightHost.maxSessions {
            let client = try Client.make()
            XCTAssertTrue(try pair(client, pin: "1234"))
            XCTAssertEqual(field("gamesession", in: try launchNewDisplay(client)), "1")
        }
        let late = try Client.make()
        XCTAssertTrue(try pair(late, pin: "1234"))
        XCTAssertEqual(status(try launchNewDisplay(late)), "503")
        XCTAssertEqual(made, MoonlightHost.maxSessions, "no display made for it")
    }

    func testADisplayTwoDevicesStreamGoesOnlyWhenBothAreDone() throws {
        var removed: [CGDirectDisplayID] = []
        host.requestPIN = { _, answer in answer("1234") }
        host.makeDisplay = { _, _, _, done in done(70) }
        host.removeDisplay = { removed.append($0) }
        startHost()
        let a = try Client.make(), b = try Client.make()
        XCTAssertTrue(try pair(a, pin: "1234"))
        XCTAssertTrue(try pair(b, pin: "1234"))
        XCTAssertEqual(field("gamesession", in: try launchNewDisplay(a)), "1")
        // The display made for A is listed, as streaming displays are, and B picks it.
        host.apps = [MoonlightApp(id: 1, title: "Streaming Display 1", displayID: 70)]
        let key = MoonlightCrypto.hex(MoonlightPairing.randomBytes(16))
        XCTAssertEqual(field("gamesession", in: try get("/launch?appid=1&mode=1280x720x60&rikey=\(key)&rikeyid=1",
                                                        secure: true, identity: b.identity)), "1")
        _ = try get("/cancel", secure: true, identity: a.identity)
        XCTAssertEqual(removed, [], "B still streams it")
        XCTAssertEqual(host.launches.first?.ownsDisplay, true, "handed on")
        _ = try get("/cancel", secure: true, identity: b.identity)
        XCTAssertEqual(removed, [70])
    }

    /// Two devices shake hands at once, each on its own RTSP port, and each connects to
    /// the control stream on its session's ports.
    func testTwoDevicesConnectSideBySide() throws {
        host.requestPIN = { _, answer in answer("1234") }
        host.makeDisplay = { _, _, _, done in done(80) }
        startHost()
        var controls: [(UnsafeMutablePointer<ENetHost>, Bool)] = []
        defer { controls.forEach { enet_host_destroy($0.0) } }
        let sdp = "v=0\r\na=x-ss-general.encryptionEnabled:1 \r\na=x-nv-video[0].clientViewportWd:1280 \r\n" +
                  "a=x-nv-video[0].clientViewportHt:720 \r\na=x-nv-video[0].maxFPS:60 \r\n" +
                  "a=x-nv-video[0].packetSize:1392 \r\na=x-nv-vqos[0].bw.maximumBitrateKbps:8000 \r\n"
        for slot in 0..<2 {
            let client = try Client.make()
            XCTAssertTrue(try pair(client, pin: "1234"))
            XCTAssertEqual(field("gamesession", in: try launchNewDisplay(client)), "1")
            let common = "X-GS-ClientVersion: 14\r\nHost: 127.0.0.1\r\n"
            let video = rtsp("SETUP streamid=video/0/0 RTSP/1.0\r\nCSeq: 4\r\n\(common)\r\n", slot: slot)
            XCTAssertTrue(video.contains("Transport: server_port=\(MoonlightStream.videoPort + UInt16(slot * 100))\r\n"), video)
            let control = rtsp("SETUP streamid=control/13/0 RTSP/1.0\r\nCSeq: 5\r\n\(common)\r\n", slot: slot)
            let port = MoonlightStream.controlPort + UInt16(slot * 100)
            XCTAssertTrue(control.contains("Transport: server_port=\(port)\r\n"), control)
            let connectData = try XCTUnwrap(header("X-SS-Connect-Data", in: control).flatMap { UInt32($0) })
            let announce = rtsp("ANNOUNCE streamid=control/13/0 RTSP/1.0\r\nCSeq: 6\r\n\(common)" +
                                "Content-length: \(sdp.utf8.count)\r\n\r\n\(sdp)", slot: slot)
            XCTAssertTrue(announce.hasPrefix("RTSP/1.0 200 OK"), announce)
            XCTAssertTrue(rtsp("ANNOUNCE streamid=control/13/0 RTSP/1.0\r\nCSeq: 7\r\n\(common)" +
                               "Content-length: \(sdp.utf8.count)\r\n\r\n\(sdp)", slot: slot).hasPrefix("RTSP/1.0 455"),
                          "a launch's stream starts once")
            let enet = try XCTUnwrap(enet_host_create(nil, 1, 48, 0, 0))
            var address = ENetAddress(host: 0, port: port)
            enet_address_set_host_ip(&address, "127.0.0.1")
            XCTAssertNotNil(enet_host_connect(enet, &address, 48, connectData))
            controls.append((enet, false))
        }
        var event = ENetEvent()
        let deadline = Date().addingTimeInterval(5)
        while controls.contains(where: { !$0.1 }), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            for index in controls.indices where enet_host_service(controls[index].0, &event, 5) > 0 {
                if event.type == ENET_EVENT_TYPE_CONNECT { controls[index].1 = true }
            }
        }
        XCTAssertEqual(controls.map(\.1), [true, true], "both control streams connected")
        XCTAssertEqual(host.launches.count, 2)
    }

    /// Another device can't shake hands on a launch; the device that launched can start its
    /// stream once, and again after a resume, which is a launch of its own with a new key.
    func testOnlyTheLaunchingDeviceShakesHandsAndAResumeStreamsAgain() throws {
        host.requestPIN = { _, answer in answer("1234") }
        host.makeDisplay = { _, _, _, done in done(81) }
        startHost()
        let client = try Client.make()
        XCTAssertTrue(try pair(client, pin: "1234"))
        XCTAssertEqual(field("gamesession", in: try launchNewDisplay(client)), "1")
        let common = "X-GS-ClientVersion: 14\r\nHost: 127.0.0.1\r\n"
        // From another of the Mac's own addresses, as Moonlight on this Mac may come: answered,
        // as no other device can send from them (others are turned away, see MoonlightRTSPTests).
        if let other = LocalNetwork.interfaceSubnets().first(where: { $0.address.count == 4 && ![127, 169].contains($0.address[0]) }) {
            let reply = rtsp("OPTIONS rtsp://127.0.0.1:48010 RTSP/1.0\r\nCSeq: 4\r\n\(common)\r\n",
                             to: other.address.map(String.init).joined(separator: "."))
            XCTAssertTrue(reply.hasPrefix("RTSP/1.0 200"), reply)
        }
        let sdp = "v=0\r\na=x-ss-general.encryptionEnabled:1 \r\na=x-nv-video[0].clientViewportWd:1280 \r\n" +
                  "a=x-nv-video[0].clientViewportHt:720 \r\na=x-nv-video[0].maxFPS:60 \r\n" +
                  "a=x-nv-video[0].packetSize:1392 \r\na=x-nv-vqos[0].bw.maximumBitrateKbps:8000 \r\n"
        func announce() -> String {
            rtsp("ANNOUNCE streamid=control/13/0 RTSP/1.0\r\nCSeq: 6\r\n\(common)Content-length: \(sdp.utf8.count)\r\n\r\n\(sdp)")
        }
        XCTAssertTrue(announce().hasPrefix("RTSP/1.0 200 OK"))
        XCTAssertTrue(announce().hasPrefix("RTSP/1.0 455"), "not again under the same key")
        let key = MoonlightCrypto.hex(MoonlightPairing.randomBytes(16))
        XCTAssertEqual(field("resume", in: try get("/resume?appid=\(MoonlightHost.newDisplayAppID)&mode=1920x1080x60&rikey=\(key)&rikeyid=2",
                                                   secure: true, identity: client.identity)), "1")
        // The last stream's ports close within a quarter second.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let resumed = announce()
        XCTAssertTrue(resumed.hasPrefix("RTSP/1.0 200 OK"), resumed)
    }

    // MARK: - Streaming, end to end

    /// Sends `text` as one RTSP request on a connection of its own and reads to the end, as
    /// Moonlight does.
    private func rtsp(_ text: String, slot: Int = 0, to address: String = "127.0.0.1") -> String {
        let connection = NWConnection(host: NWEndpoint.Host(address), port: host.rtspPort(slot: slot), using: .tcp)
        connection.start(queue: .global())
        connection.send(content: Data(text.utf8), completion: .idempotent)
        let done = expectation(description: "rtsp")
        var response = Data()
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data { response.append(data) }
                if isComplete || error != nil { done.fulfill() } else { read() }
            }
        }
        read()
        wait(for: [done], timeout: 10)
        connection.cancel()
        return String(decoding: response, as: UTF8.self)
    }

    private func header(_ name: String, in reply: String) -> String? {
        reply.components(separatedBy: "\r\n").first { $0.hasPrefix("\(name): ") }.map { String($0.dropFirst(name.count + 2)) }
    }

    private func streamingDisplay() -> CGDirectDisplayID? {
        DisplayArrangement.onlineDisplayIDs().first {
            CGDisplayVendorNumber($0) == VideoManager.anchorVendorID && CGDisplayModelNumber($0) == VideoManager.streamingProductID
        }
    }

    private func localhost(_ port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    /// Pairs, launches, shakes hands over RTSP, connects to the control stream and pings for
    /// video, as Moonlight does; checks the first frame when DAM may record the screen, else
    /// that the stream ends saying why; then cancels.
    func testLaunchesAndStreamsAsMoonlightExpects() throws {
        let display = try XCTUnwrap(streamingDisplay() ?? Optional(0))
        host.requestPIN = { _, answer in answer("1234") }
        host.apps = [MoonlightApp(id: 1, title: "DAM Streaming", displayID: display)]
        startHost()
        let client = try Client.make()
        XCTAssertTrue(try pair(client, pin: "1234"))

        // /launch
        let key = MoonlightPairing.randomBytes(16)
        let launch = try get("/launch?appid=1&mode=1280x720x60&additionalStates=1&sops=0&rikey=\(MoonlightCrypto.hex(key).lowercased())&rikeyid=-1294967296&localAudioPlayMode=0&surroundAudioInfo=196610",
                             secure: true, identity: client.identity)
        XCTAssertEqual(field("gamesession", in: launch), "1")
        XCTAssertEqual(field("sessionUrl0", in: launch), "rtsp://127.0.0.1:\(host.rtspPort.rawValue)")
        let busy = try get("/serverinfo", secure: true, identity: client.identity)
        XCTAssertEqual(field("state", in: busy), "SUNSHINE_SERVER_BUSY")
        XCTAssertEqual(field("currentgame", in: busy), "1")

        // RTSP
        let common = "X-GS-ClientVersion: 14\r\nHost: 127.0.0.1\r\n"
        XCTAssertTrue(rtsp("OPTIONS rtsp://127.0.0.1:48010 RTSP/1.0\r\nCSeq: 1\r\n\(common)\r\n").hasPrefix("RTSP/1.0 200 OK\r\nCSeq: 1\r\n"))
        let describe = rtsp("DESCRIBE rtsp://127.0.0.1:48010 RTSP/1.0\r\nCSeq: 2\r\n\(common)Accept: application/sdp\r\n\r\n")
        XCTAssertTrue(describe.contains("a=x-ss-general.encryptionSupported:5"))
        let audio = rtsp("SETUP streamid=audio/0/0 RTSP/1.0\r\nCSeq: 3\r\n\(common)Transport: unicast;X-GS-ClientPort=50000-50001\r\n\r\n")
        let session = try XCTUnwrap(header("Session", in: audio)?.components(separatedBy: ";").first)
        let audioPing = try XCTUnwrap(header("X-SS-Ping-Payload", in: audio))
        let video = rtsp("SETUP streamid=video/0/0 RTSP/1.0\r\nCSeq: 4\r\n\(common)Session: \(session)\r\n\r\n")
        let pingPayload = try XCTUnwrap(header("X-SS-Ping-Payload", in: video))
        XCTAssertEqual(pingPayload.count, 16)
        let control = rtsp("SETUP streamid=control/13/0 RTSP/1.0\r\nCSeq: 5\r\n\(common)Session: \(session)\r\n\r\n")
        let connectData = try XCTUnwrap(header("X-SS-Connect-Data", in: control).flatMap { UInt32($0) })
        let sdp = "v=0\r\na=x-ss-general.encryptionEnabled:1 \r\na=x-nv-video[0].clientViewportWd:1280 \r\n" +
                  "a=x-nv-video[0].clientViewportHt:720 \r\na=x-nv-video[0].maxFPS:60 \r\n" +
                  "a=x-nv-video[0].packetSize:1392 \r\na=x-nv-vqos[0].bw.maximumBitrateKbps:8000 \r\n" +
                  "a=x-nv-vqos[0].bitStreamFormat:0 \r\na=x-nv-general.featureFlags:167 \r\n" +
                  "a=x-nv-aqos.packetDuration:5 \r\n"
        let announce = rtsp("ANNOUNCE streamid=control/13/0 RTSP/1.0\r\nCSeq: 6\r\n\(common)Session: \(session)\r\n" +
                            "Content-type: application/sdp\r\nContent-length: \(sdp.utf8.count)\r\n\r\n\(sdp)")
        XCTAssertTrue(announce.hasPrefix("RTSP/1.0 200 OK"), announce)
        XCTAssertTrue(rtsp("PLAY / RTSP/1.0\r\nCSeq: 7\r\n\(common)Session: \(session)\r\n\r\n").hasPrefix("RTSP/1.0 200 OK"))

        // Control: connect with the token, then ask for a keyframe as Moonlight's Start A does.
        let enet = try XCTUnwrap(enet_host_create(nil, 1, 48, 0, 0))
        defer { enet_host_destroy(enet) }
        var address = ENetAddress(host: 0, port: MoonlightStream.controlPort)
        enet_address_set_host_ip(&address, "127.0.0.1")
        let peer = try XCTUnwrap(enet_host_connect(enet, &address, 48, connectData))
        var event = ENetEvent()
        var connected = false
        let deadline = Date().addingTimeInterval(5)
        while !connected, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            if enet_host_service(enet, &event, 10) > 0, event.type == ENET_EVENT_TYPE_CONNECT { connected = true }
        }
        XCTAssertTrue(connected, "control stream connected")
        let sessionKey = SymmetricKey(data: key)
        let start = try MoonlightControlCrypto.seal(type: 0x0302, payload: Data([0, 0]), sequence: 0, key: sessionKey,
                                                    direction: .clientToHost)
        _ = start.withUnsafeBytes { enet_peer_send(peer, 1, enet_packet_create($0.baseAddress, start.count, ENET_PACKET_FLAG_RELIABLE.rawValue)) }
        enet_host_flush(enet)

        // Audio: ping as Moonlight does after SETUP; silence comes until sound is captured,
        // encrypted with the session key and an IV of the key ID plus the sequence number.
        let audioSocket = try MoonlightUDPSocket(port: 0)
        var audioPingData = Data(audioPing.utf8)
        audioPingData.append(bigEndian: UInt32(1))
        audioSocket.send(audioPingData, to: localhost(MoonlightStream.audioPort))
        var audioPackets: [Data] = []
        let audioDeadline = Date().addingTimeInterval(3)
        while audioPackets.count < 12, Date() < audioDeadline {
            _ = enet_host_service(enet, &event, 0)
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            if let (packet, _) = audioSocket.receive(timeout: 0.02) { audioPackets.append(packet) }
        }
        let data = audioPackets.filter { $0[1] == 97 }
        XCTAssertGreaterThanOrEqual(data.count, 8, "audio flowing")
        XCTAssertTrue(audioPackets.contains { $0[1] == 127 }, "parity after every fourth")
        let first = try XCTUnwrap(data.first)
        // Host names the address, as Moonlight does when stereo may be high quality: 512 kbit/s.
        XCTAssertEqual(first.count, 12 + 336, "320 bytes of Opus, encrypted and padded")
        let sequence = UInt32(first[2]) << 8 | UInt32(first[3])
        var iv = Data()
        iv.append(bigEndian: UInt32(bitPattern: -1_294_967_296) &+ sequence)
        iv.append(Data(count: 12))
        var plain = [UInt8](repeating: 0, count: 400)
        var moved = 0
        let cipher = [UInt8](first.dropFirst(12))
        let status = key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    k.baseAddress, 16, v.baseAddress, cipher, cipher.count, &plain, plain.count, &moved) } }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        XCTAssertEqual(moved, 320, "one 5 ms Opus packet at 512 kbit/s")
        audioSocket.close()

        // Video: the ping starts screen capture, which this test leaves to a process that may
        // record (DAM_TEST_CAPTURE=1). Under xcodebuild capture gets no frames, and a test
        // process killed mid-capture can leave macOS's capture service (replayd) refusing
        // every app afterwards, DAM included.
        let checkFrames = ProcessInfo.processInfo.environment["DAM_TEST_CAPTURE"] == "1" && display != 0
        let socket = try MoonlightUDPSocket(port: 0)
        if checkFrames {
            var ping = Data(pingPayload.utf8)
            ping.append(bigEndian: UInt32(1))
            socket.send(ping, to: localhost(MoonlightStream.videoPort))
            var firstFrame: [Data] = []
            let videoDeadline = Date().addingTimeInterval(5)
            while Date() < videoDeadline {
                _ = enet_host_service(enet, &event, 0)
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))
                guard let (packet, _) = socket.receive(timeout: 0.05) else { continue }
                XCTAssertEqual(packet.count, 1392 + 16)
                let bytes = [UInt8](packet)
                let frameIndex = UInt32(bytes[20]) | UInt32(bytes[21]) << 8 | UInt32(bytes[22]) << 16 | UInt32(bytes[23]) << 24
                guard frameIndex == 1 else { continue }
                firstFrame.append(packet)
                if bytes[24] & 0x02 != 0 { break }
            }
            let payload = firstFrame.reduce(Data()) { $0 + $1.dropFirst(32) }
            XCTAssertGreaterThan(firstFrame.count, 0, "video arrived; stream end: \(host.lastStreamEnd ?? "none")")
            XCTAssertEqual(payload.prefix(1), Data([0x01]), "8-byte frame header")
            XCTAssertEqual([UInt8](payload)[3], 2, "an IDR first")
            let unit = [UInt8](payload.dropFirst(8))
            XCTAssertEqual(Array(unit.prefix(4)), [0, 0, 0, 1])
            XCTAssertEqual(unit[4] & 0x1F, 7, "SPS first")
        }

        // /cancel frees the host, and Moonlight hears the stream ended.
        XCTAssertEqual(field("cancel", in: try get("/cancel", secure: true, identity: client.identity)), "1")
        let free = try get("/serverinfo", secure: true, identity: client.identity)
        XCTAssertEqual(field("state", in: free), "SUNSHINE_SERVER_FREE")
        XCTAssertEqual(field("currentgame", in: free), "0")
        if host.lastStreamEnd == nil {
            var termination: (type: UInt16, payload: Data)?
            let endDeadline = Date().addingTimeInterval(3)
            while termination == nil, Date() < endDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                guard enet_host_service(enet, &event, 10) > 0, event.type == ENET_EVENT_TYPE_RECEIVE else { continue }
                let data = Data(bytes: event.packet.pointee.data, count: Int(event.packet.pointee.dataLength))
                enet_packet_destroy(event.packet)
                termination = MoonlightControlCrypto.open(data, key: sessionKey, direction: .hostToClient)
            }
            XCTAssertEqual(termination?.type, 0x0109)
            XCTAssertEqual(termination?.payload, Data([0x80, 0x03, 0x00, 0x23]))
        }
        socket.close()
    }
}
