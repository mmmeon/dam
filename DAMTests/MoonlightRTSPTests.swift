import XCTest
import Network
@testable import DAM

final class MoonlightRTSPTests: XCTestCase {

    private let launch: MoonlightLaunch = {
        var launch = MoonlightLaunch(appID: 1, displayID: 0, key: Data(count: 16))
        launch.clientAddress = "10.0.0.2"
        return launch
    }()

    private func request(_ method: String, _ target: String, headers: [String: String] = [:], body: String = "") -> MoonlightRTSP.Request {
        MoonlightRTSP.Request(method: method, target: target, headers: headers.merging(["CSeq": "3"]) { $1 }, body: body)
    }

    private func respond(_ request: MoonlightRTSP.Request, announce: @escaping (MoonlightLaunch, MoonlightStreamConfig) -> String? = { _, _ in nil }) -> String {
        MoonlightRTSP.response(to: request, from: "10.0.0.2", launch: launch, announce: announce)
    }

    func testEveryReplyStartsWithRTSP10AndEchoesTheSequence() {
        for method in ["OPTIONS", "DESCRIBE", "PLAY"] {
            let reply = respond(request(method, "rtsp://10.0.0.2:48010"))
            XCTAssertTrue(reply.hasPrefix("RTSP/1.0 200 OK\r\nCSeq: 3\r\n"), reply)
        }
    }

    func testDescribeOffersControlEncryptionOnlyAndNoOtherCodec() {
        let reply = respond(request("DESCRIBE", "rtsp://10.0.0.2:48010"))
        let body = reply.components(separatedBy: "\r\n\r\n")[1]
        XCTAssertTrue(body.contains("a=x-ss-general.encryptionSupported:5"), "control and audio")
        XCTAssertFalse(body.contains("sprop-parameter-sets=AAAAAU"), "would choose HEVC")
        XCTAssertFalse(body.contains("AV1/90000"))
        XCTAssertFalse(body.contains("refPicInvalidation"))
    }

    func testEncryptedVideoIsOfferedOnlyWhenTheLaunchIsToHaveIt() {
        var encrypting = launch
        encrypting.offersEncryptedVideo = true
        let reply = MoonlightRTSP.response(to: request("DESCRIBE", "rtsp://10.0.0.2:48010"), from: "10.0.0.2", launch: encrypting,
                                           announce: { _, _ in nil })
        XCTAssertTrue(reply.contains("a=x-ss-general.encryptionSupported:7\r\n"), "control, video and audio")
        XCTAssertTrue(reply.contains("a=x-ss-general.encryptionRequested:0\r\n"), "never required")

        var started: MoonlightStreamConfig?
        let sdp = "a=x-nv-video[0].clientViewportWd:1280 \r\na=x-nv-video[0].clientViewportHt:720 \r\n" +
                  "a=x-nv-video[0].maxFPS:60 \r\na=x-nv-video[0].packetSize:1392 \r\n" +
                  "a=x-nv-vqos[0].bw.maximumBitrateKbps:8000 \r\na=x-ss-general.encryptionEnabled:7 \r\n"
        let announced = MoonlightRTSP.response(to: request("ANNOUNCE", "streamid=control/13/0", body: sdp),
                                               from: "10.0.0.2", launch: encrypting) { _, config in started = config; return nil }
        XCTAssertTrue(announced.hasPrefix("RTSP/1.0 200 OK"), announced)
        XCTAssertEqual(started?.videoEncrypted, true)
    }

    func testOnlyMacsOwnNetworksCountAsLocal() throws {
        let home = LocalNetwork.Subnet(address: [192, 168, 1, 20], mask: [255, 255, 255, 0])
        let v6 = LocalNetwork.Subnet(address: [0xFD, 0, 0, 0, 0, 0, 0, 1] + [UInt8](repeating: 0, count: 8),
                                     mask: [UInt8](repeating: 0xFF, count: 8) + [UInt8](repeating: 0, count: 8))
        func local(_ text: String) -> Bool {
            LocalNetwork.contains(.hostPort(host: NWEndpoint.Host(text), port: 1), subnets: [home, v6])
        }
        XCTAssertTrue(local("192.168.1.77"))
        XCTAssertTrue(local("::ffff:192.168.1.77"), "IPv4 written as IPv6")
        XCTAssertFalse(local("192.168.2.77"), "another private network, as over a VPN")
        XCTAssertFalse(local("8.8.8.8"))
        XCTAssertFalse(local("100.101.102.103"), "Tailscale")
        XCTAssertTrue(local("127.0.0.1"))
        XCTAssertTrue(local("169.254.3.4"), "link-local, as over a cable")
        XCTAssertTrue(local("::1"))
        XCTAssertTrue(local("fe80::1"))
        XCTAssertTrue(local("fd00:0:0:1::9"))
        XCTAssertFalse(local("2001:db8::1"))
        XCTAssertFalse(MoonlightVideoEncryption.offLocalNetwork.offers(to: .hostPort(host: "127.0.0.1", port: 1)))
        XCTAssertTrue(MoonlightVideoEncryption.offLocalNetwork.offers(to: .hostPort(host: "8.8.8.8", port: 1)))
        XCTAssertTrue(MoonlightVideoEncryption.always.offers(to: .hostPort(host: "127.0.0.1", port: 1)))
        XCTAssertFalse(MoonlightVideoEncryption.never.offers(to: .hostPort(host: "8.8.8.8", port: 1)))
        // The Mac's own interfaces are listed, loopback among them.
        XCTAssertTrue(LocalNetwork.interfaceSubnets().contains { $0.address == [127, 0, 0, 1] })
    }

    func testEachSessionHasPortsOfItsOwn() {
        var second = launch
        second.slot = 1
        func reply(_ stream: String) -> String {
            MoonlightRTSP.response(to: request("SETUP", "streamid=\(stream)/0/0"), from: "10.0.0.2", launch: second,
                                   announce: { _, _ in nil })
        }
        XCTAssertTrue(reply("audio").contains("Transport: server_port=48100\r\n"))
        XCTAssertTrue(reply("video").contains("Transport: server_port=48098\r\n"))
        XCTAssertTrue(reply("control").contains("Transport: server_port=48099\r\n"))
    }

    func testSetupGivesEachStreamItsPortAndTokens() {
        let audio = respond(request("SETUP", "streamid=audio/0/0"))
        XCTAssertTrue(audio.contains("Session: \(launch.sessionID);timeout = 90\r\n"))
        XCTAssertTrue(audio.contains("Transport: server_port=48000\r\n"))
        XCTAssertTrue(audio.contains("X-SS-Ping-Payload: \(launch.pingPayload)\r\n"))
        XCTAssertEqual(launch.pingPayload.count, 16)
        XCTAssertTrue(respond(request("SETUP", "streamid=video/0/0")).contains("Transport: server_port=47998\r\n"))
        let control = respond(request("SETUP", "streamid=control/13/0"))
        XCTAssertTrue(control.contains("X-SS-Connect-Data: \(launch.connectData)\r\n"))
        XCTAssertTrue(respond(request("SETUP", "streamid=other/0/0")).hasPrefix("RTSP/1.0 404"))
    }

    func testAnnounceStartsTheStreamItDescribes() {
        var started: MoonlightStreamConfig?
        let sdp = "a=x-nv-video[0].clientViewportWd:1280 \r\na=x-nv-video[0].clientViewportHt:720 \r\n" +
                  "a=x-nv-video[0].maxFPS:60 \r\na=x-nv-video[0].packetSize:1392 \r\n" +
                  "a=x-nv-vqos[0].bw.maximumBitrateKbps:8000 \r\n"
        let reply = respond(request("ANNOUNCE", "streamid=control/13/0", body: sdp)) { _, config in started = config; return nil }
        XCTAssertTrue(reply.hasPrefix("RTSP/1.0 200 OK"))
        XCTAssertEqual(started?.width, 1280)
        XCTAssertTrue(respond(request("ANNOUNCE", "streamid=control/13/0", body: sdp + "a=x-ss-general.encryptionEnabled:3 \r\n"))
            .hasPrefix("RTSP/1.0 400"), "encrypted video is not offered")
    }

    func testHEVCIsDescribedAndTakenOnlyWhenTheLaunchOffersIt() {
        let hevcSDP = sdp + "a=x-nv-vqos[0].bitStreamFormat:1 \r\n"
        XCTAssertTrue(respond(request("ANNOUNCE", "streamid=control/13/0", body: hevcSDP)) { _, _ in
            XCTFail("HEVC started"); return nil
        }.hasPrefix("RTSP/1.0 400"), "not offered")
        XCTAssertTrue(respond(request("ANNOUNCE", "streamid=control/13/0", body: sdp + "a=x-nv-vqos[0].bitStreamFormat:2 \r\n")) { _, _ in
            XCTFail("AV1 started"); return nil
        }.hasPrefix("RTSP/1.0 400"), "AV1 is never offered")

        var hevc = launch
        hevc.codecs = [.h264, .hevc]
        let describe = MoonlightRTSP.response(to: request("DESCRIBE", "rtsp://10.0.0.2:48010"), from: "10.0.0.2",
                                              launch: hevc, announce: { _, _ in nil })
        XCTAssertTrue(describe.contains("\r\nsprop-parameter-sets=AAAAAU\r\n"), describe)
        XCTAssertFalse(describe.contains("AV1/90000"))
        var started: MoonlightStreamConfig?
        let reply = MoonlightRTSP.response(to: request("ANNOUNCE", "streamid=control/13/0", body: hevcSDP), from: "10.0.0.2",
                                           launch: hevc) { _, config in started = config; return nil }
        XCTAssertTrue(reply.hasPrefix("RTSP/1.0 200 OK"), reply)
        XCTAssertEqual(started?.codec, .hevc)
        let plain = MoonlightRTSP.response(to: request("ANNOUNCE", "streamid=control/13/0", body: sdp), from: "10.0.0.2",
                                           launch: hevc) { _, config in started = config; return nil }
        XCTAssertTrue(plain.hasPrefix("RTSP/1.0 200 OK"), plain)
        XCTAssertEqual(started?.codec, .h264, "H.264 still, when the client chooses it")
    }

    func testHDRIsTakenOnlyForHEVCOnALaunchThatAskedForIt() {
        let hdrHEVC = sdp + "a=x-nv-vqos[0].bitStreamFormat:1 \r\na=x-nv-video[0].dynamicRangeMode:1 \r\n"
        let hdrH264 = sdp + "a=x-nv-video[0].dynamicRangeMode:1 \r\n"
        var hevc = launch
        hevc.codecs = [.h264, .hevc]
        XCTAssertTrue(MoonlightRTSP.response(to: request("ANNOUNCE", "streamid=control/13/0", body: hdrHEVC), from: "10.0.0.2",
                                             launch: hevc, announce: { _, _ in XCTFail("HDR started"); return nil })
            .hasPrefix("RTSP/1.0 400"), "the launch didn't ask for HDR")
        var hdr = hevc
        hdr.offersHDR = true
        XCTAssertTrue(MoonlightRTSP.response(to: request("ANNOUNCE", "streamid=control/13/0", body: hdrH264), from: "10.0.0.2",
                                             launch: hdr, announce: { _, _ in XCTFail("HDR H.264 started"); return nil })
            .hasPrefix("RTSP/1.0 400"), "HDR is HEVC's")
        var started: MoonlightStreamConfig?
        XCTAssertTrue(MoonlightRTSP.response(to: request("ANNOUNCE", "streamid=control/13/0", body: hdrHEVC), from: "10.0.0.2",
                                             launch: hdr, announce: { _, config in started = config; return nil })
            .hasPrefix("RTSP/1.0 200 OK"))
        XCTAssertEqual(started?.hdr, true)
        XCTAssertEqual(started?.codec, .hevc)
    }

    func testRefusesAHandshakeWithoutALaunch() {
        XCTAssertTrue(MoonlightRTSP.response(to: request("OPTIONS", "/"), from: "10.0.0.2", launch: nil, announce: { _, _ in nil })
            .hasPrefix("RTSP/1.0 503"))
    }

    func testParsesARequestOnlyOnceItsBodyHasCome() throws {
        let head = "ANNOUNCE streamid=control/13/0 RTSP/1.0\r\nCSeq: 6\r\nContent-length: 5\r\n\r\n"
        XCTAssertNil(try MoonlightRTSP.parse(Data((head + "abc").utf8)))
        let request = try XCTUnwrap(MoonlightRTSP.parse(Data((head + "abcde").utf8)))
        XCTAssertEqual(request.method, "ANNOUNCE")
        XCTAssertEqual(request.headers["CSeq"], "6")
        XCTAssertEqual(request.body, "abcde")
    }

    func testRefusesARequestThatCanNeverBeRead() {
        let negative = "ANNOUNCE streamid=control/13/0 RTSP/1.0\r\nCSeq: 6\r\nContent-Length: -1\r\n\r\nabc"
        XCTAssertThrowsError(try MoonlightRTSP.parse(Data(negative.utf8)))
        XCTAssertThrowsError(try MoonlightRTSP.parse(Data("NONSENSE\r\n\r\n".utf8)))
    }

    func testAMoonlightOnThisMacMayComeThroughAnotherOfItsAddresses() {
        // As seen: launched through the cable's link-local address, RTSP from the Wi-Fi one.
        var local = launch
        local.clientAddress = "169.254.40.18"
        let own: Set<String> = ["127.0.0.1", "::1", "10.10.1.167", "169.254.40.18"]
        XCTAssertTrue(MoonlightRTSP.response(to: request("OPTIONS", "/"), from: "10.10.1.167", launch: local,
                                             ownAddresses: own, announce: { _, _ in nil }).hasPrefix("RTSP/1.0 200"))
        // Another device still can't, nor this Mac for a launch from another device.
        XCTAssertTrue(MoonlightRTSP.response(to: request("OPTIONS", "/"), from: "10.10.1.50", launch: local,
                                             ownAddresses: own, announce: { _, _ in nil }).hasPrefix("RTSP/1.0 403"))
        XCTAssertTrue(MoonlightRTSP.response(to: request("OPTIONS", "/"), from: "10.10.1.167", launch: launch,
                                             ownAddresses: own, announce: { _, _ in nil }).hasPrefix("RTSP/1.0 403"))
    }

    func testOwnAddressesAreWrittenAsConnectionsGiveThem() {
        let subnets = [LocalNetwork.Subnet(address: [10, 10, 1, 167], mask: [255, 255, 255, 0]),
                       LocalNetwork.Subnet(address: [0xFE, 0x80, 0, 4] + [UInt8](repeating: 0, count: 11) + [1],
                                           mask: [UInt8](repeating: 0xFF, count: 8) + [UInt8](repeating: 0, count: 8))]
        XCTAssertEqual(LocalNetwork.ownAddresses(subnets: subnets), ["10.10.1.167", "fe80::1"])
    }

    func testAnswersOnlyTheDeviceThatLaunched() {
        for method in ["OPTIONS", "DESCRIBE", "SETUP", "ANNOUNCE", "PLAY"] {
            let reply = MoonlightRTSP.response(to: request(method, "streamid=video/0/0"), from: "10.0.0.3", launch: launch,
                                               announce: { _, _ in XCTFail("announced"); return nil })
            XCTAssertTrue(reply.hasPrefix("RTSP/1.0 403"), "\(method): \(reply)")
            XCTAssertFalse(reply.contains(launch.pingPayload))
        }
        var unknown = launch
        unknown.clientAddress = ""
        XCTAssertTrue(MoonlightRTSP.response(to: request("SETUP", "streamid=video/0/0"), from: "", launch: unknown,
                                             announce: { _, _ in nil }).hasPrefix("RTSP/1.0 403"))
    }

    func testALaunchIsAnnouncedOnce() {
        var started = launch
        started.announced = true
        let reply = MoonlightRTSP.response(to: request("ANNOUNCE", "streamid=control/13/0", body: sdp), from: "10.0.0.2",
                                           launch: started, announce: { _, _ in XCTFail("announced again"); return nil })
        XCTAssertTrue(reply.hasPrefix("RTSP/1.0 455"), reply)
    }

    func testVideoThatMustBeEncryptedIsAskedForAndPlainIsRefused() {
        var always = launch
        always.offersEncryptedVideo = true
        always.requiresEncryptedVideo = true
        let describe = MoonlightRTSP.response(to: request("DESCRIBE", "rtsp://10.0.0.2:48010"), from: "10.0.0.2",
                                              launch: always, announce: { _, _ in nil })
        XCTAssertTrue(describe.contains("a=x-ss-general.encryptionSupported:7\r\n"))
        XCTAssertTrue(describe.contains("a=x-ss-general.encryptionRequested:2\r\n"))
        let plain = MoonlightRTSP.response(to: request("ANNOUNCE", "streamid=control/13/0", body: sdp + "a=x-ss-general.encryptionEnabled:5 \r\n"),
                                           from: "10.0.0.2", launch: always,
                                           announce: { _, _ in XCTFail("plain video started"); return nil })
        XCTAssertTrue(plain.hasPrefix("RTSP/1.0 400"), plain)
        let sealed = MoonlightRTSP.response(to: request("ANNOUNCE", "streamid=control/13/0", body: sdp + "a=x-ss-general.encryptionEnabled:7 \r\n"),
                                            from: "10.0.0.2", launch: always, announce: { _, _ in nil })
        XCTAssertTrue(sealed.hasPrefix("RTSP/1.0 200 OK"), sealed)
    }

    func testABarePingIsTakenOnlyFromTheDeviceThatLaunched() throws {
        func from(_ text: String) -> sockaddr_in {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr = MoonlightVideoSender.ipv4(text)!
            return address
        }
        let payload = Data(launch.pingPayload.utf8)
        let client = MoonlightVideoSender.ipv4("10.0.0.2")
        var tagged = payload
        tagged.append(contentsOf: [0, 0, 0, 1])
        XCTAssertTrue(MoonlightVideoSender.isPing(tagged, from: from("10.0.0.9"), payload: payload, client: client),
                      "the payload is the proof, wherever it comes from")
        XCTAssertTrue(MoonlightVideoSender.isPing(Data("PING".utf8), from: from("10.0.0.2"), payload: payload, client: client))
        XCTAssertFalse(MoonlightVideoSender.isPing(Data("PING".utf8), from: from("10.0.0.9"), payload: payload, client: client))
        XCTAssertFalse(MoonlightVideoSender.isPing(Data("PING".utf8), from: from("10.0.0.2"), payload: payload, client: nil))
        XCTAssertFalse(MoonlightVideoSender.isPing(Data("PONG".utf8), from: from("10.0.0.2"), payload: payload, client: client))
        XCTAssertFalse(MoonlightVideoSender.isPing(payload.prefix(8), from: from("10.0.0.2"), payload: payload, client: client))
        XCTAssertNil(MoonlightVideoSender.ipv4("fe80::1"))
    }

    private let sdp = "a=x-nv-video[0].clientViewportWd:1280 \r\na=x-nv-video[0].clientViewportHt:720 \r\n" +
                      "a=x-nv-video[0].maxFPS:60 \r\na=x-nv-video[0].packetSize:1392 \r\n" +
                      "a=x-nv-vqos[0].bw.maximumBitrateKbps:8000 \r\n"
}
