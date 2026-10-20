import XCTest
import Network
@testable import DAM

final class MoonlightRTSPTests: XCTestCase {

    private let launch = MoonlightLaunch(appID: 1, displayID: 0, key: Data(count: 16))

    private func request(_ method: String, _ target: String, headers: [String: String] = [:], body: String = "") -> MoonlightRTSP.Request {
        MoonlightRTSP.Request(method: method, target: target, headers: headers.merging(["CSeq": "3"]) { $1 }, body: body)
    }

    private func respond(_ request: MoonlightRTSP.Request, announce: @escaping (MoonlightLaunch, MoonlightStreamConfig) -> String? = { _, _ in nil }) -> String {
        MoonlightRTSP.response(to: request, launch: launch, announce: announce)
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
        let reply = MoonlightRTSP.response(to: request("DESCRIBE", "rtsp://10.0.0.2:48010"), launch: encrypting,
                                           announce: { _, _ in nil })
        XCTAssertTrue(reply.contains("a=x-ss-general.encryptionSupported:7\r\n"), "control, video and audio")
        XCTAssertTrue(reply.contains("a=x-ss-general.encryptionRequested:0\r\n"), "never required")

        var started: MoonlightStreamConfig?
        let sdp = "a=x-nv-video[0].clientViewportWd:1280 \r\na=x-nv-video[0].clientViewportHt:720 \r\n" +
                  "a=x-nv-video[0].maxFPS:60 \r\na=x-nv-video[0].packetSize:1392 \r\n" +
                  "a=x-nv-vqos[0].bw.maximumBitrateKbps:8000 \r\na=x-ss-general.encryptionEnabled:7 \r\n"
        let announced = MoonlightRTSP.response(to: request("ANNOUNCE", "streamid=control/13/0", body: sdp),
                                               launch: encrypting) { _, config in started = config; return nil }
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

    func testRefusesAHandshakeWithoutALaunch() {
        XCTAssertTrue(MoonlightRTSP.response(to: request("OPTIONS", "/"), launch: nil, announce: { _, _ in nil })
            .hasPrefix("RTSP/1.0 503"))
    }

    func testParsesARequestOnlyOnceItsBodyHasCome() throws {
        let head = "ANNOUNCE streamid=control/13/0 RTSP/1.0\r\nCSeq: 6\r\nContent-length: 5\r\n\r\n"
        XCTAssertNil(MoonlightRTSP.parse(Data((head + "abc").utf8)))
        let request = try XCTUnwrap(MoonlightRTSP.parse(Data((head + "abcde").utf8)))
        XCTAssertEqual(request.method, "ANNOUNCE")
        XCTAssertEqual(request.headers["CSeq"], "6")
        XCTAssertEqual(request.body, "abcde")
    }
}
