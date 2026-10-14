import XCTest
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
