import XCTest
import CryptoKit
@testable import DAM

final class MoonlightProtocolTests: XCTestCase {

    // MARK: - ANNOUNCE

    /// The attributes moonlight-common-c sends to a 7.1.431 host, trimmed, with its
    /// trailing space on each line.
    private let announce = """
        v=0\r
        o=android 0 14 IN IPv4 10.10.1.5\r
        s=NVIDIA Streaming Client\r
        a=x-ml-general.featureFlags:3 \r
        a=x-ss-general.encryptionEnabled:1 \r
        a=x-nv-video[0].clientViewportWd:2560 \r
        a=x-nv-video[0].clientViewportHt:1600 \r
        a=x-nv-video[0].maxFPS:60 \r
        a=x-nv-video[0].packetSize:1392 \r
        a=x-nv-vqos[0].bw.maximumBitrateKbps:16000 \r
        a=x-nv-vqos[0].bitStreamFormat:0 \r
        t=0 0\r
        m=video 47998  \r

        """

    func testReadsTheStreamSettingsFromAnnounce() throws {
        let config = try XCTUnwrap(MoonlightStreamConfig.parse(sdp: announce))
        XCTAssertEqual(config, MoonlightStreamConfig(width: 2560, height: 1600, fps: 60, packetSize: 1392,
                                                     bitrateKbps: 16000, videoFormat: 0, encryptionEnabled: 1))
    }

    func testRefusesAnAnnounceWithoutTheSize() {
        XCTAssertNil(MoonlightStreamConfig.parse(sdp: announce.replacingOccurrences(of: "clientViewportWd", with: "x")))
    }

    // MARK: - Video packets

    private func le32(_ packet: Data, _ offset: Int) -> UInt32 {
        let b = [UInt8](packet)
        return UInt32(b[offset]) | UInt32(b[offset + 1]) << 8 | UInt32(b[offset + 2]) << 16 | UInt32(b[offset + 3]) << 24
    }

    private func be16(_ packet: Data, _ offset: Int) -> UInt16 {
        let b = [UInt8](packet)
        return UInt16(b[offset]) << 8 | UInt16(b[offset + 1])
    }

    func testEveryPacketIsPacketSizePlusTheRTPHeader() throws {
        var packetizer = MoonlightPacketizer(packetSize: 1392)
        let packets = try XCTUnwrap(packetizer.packets(for: Data(count: 5000), isKeyFrame: true, timestamp: 0, latency: 0))
        // 8 + 5000 bytes in slices of 1376.
        XCTAssertEqual(packets.count, 4)
        XCTAssertTrue(packets.allSatisfy { $0.count == 1392 + 16 })
    }

    func testHeadersFollowTheLayout() throws {
        var packetizer = MoonlightPacketizer(packetSize: 1392)
        let unit = Data([0, 0, 0, 1, 0x67]) + Data(count: 3000)
        let packets = try XCTUnwrap(packetizer.packets(for: unit, isKeyFrame: true, timestamp: 0x01020304, latency: 25))
        let first = [UInt8](packets[0])
        XCTAssertEqual(first[0], 0x90, "RTP version 2 with the extension bit")
        XCTAssertEqual(be16(packets[0], 2), 0)
        XCTAssertEqual(Array(first[4...7]), [1, 2, 3, 4], "timestamp big-endian")
        XCTAssertEqual(le32(packets[0], 20), 1, "first frame index is 1")
        XCTAssertEqual(first[24], 0x05, "picture data, start of frame")
        XCTAssertEqual(first[26], 0x10)
        XCTAssertEqual(first[27], 0)
        XCTAssertEqual(le32(packets[0], 28), 3 << 22 | 0 << 12, "3 data packets, this one first, no FEC")
        // The frame header, then the access unit.
        let last = (unit.count + 8) % 1376
        XCTAssertEqual(Array(first[32...39]), [0x01, 25, 0, 2, UInt8(last & 0xFF), UInt8(last >> 8), 0, 0])
        XCTAssertEqual(Array(first[40...44]), [0, 0, 0, 1, 0x67])

        XCTAssertEqual(packets[1][24], 0x01, "picture data only in the middle")
        XCTAssertEqual(packets[2][24], 0x03, "picture data, end of frame")
        XCTAssertEqual(le32(packets[2], 28) >> 12 & 0x3FF, 2)
    }

    func testCountersRunOnAcrossFrames() throws {
        var packetizer = MoonlightPacketizer(packetSize: 1024)
        let one = try XCTUnwrap(packetizer.packets(for: Data(count: 2000), isKeyFrame: true, timestamp: 0, latency: 0))
        let two = try XCTUnwrap(packetizer.packets(for: Data(count: 100), isKeyFrame: false, timestamp: 0, latency: 0))
        let all = one + two
        XCTAssertEqual(all.map { be16($0, 2) }, Array(0..<UInt16(all.count)))
        XCTAssertEqual(all.map { le32($0, 16) >> 8 }, Array(0..<UInt32(all.count)), "packet index = sequence, shifted")
        XCTAssertEqual(le32(two[0], 20), 2)
        XCTAssertEqual(two[0][24], 0x07, "a one-packet frame starts and ends it")
        XCTAssertEqual(two[0][35], 1, "P-frame type")
    }

    func testSplitsALargeFrameIntoBlocks() throws {
        var packetizer = MoonlightPacketizer(packetSize: 1024)
        // 1500 packets' worth: two blocks of 750.
        let packets = try XCTUnwrap(packetizer.packets(for: Data(count: 1500 * 1008 - 8), isKeyFrame: true,
                                                       timestamp: 0, latency: 0))
        XCTAssertEqual(packets.count, 1500)
        XCTAssertEqual(packets[0][27], 0 << 4 | 1 << 6)
        XCTAssertEqual(packets[750][27], 1 << 4 | 1 << 6)
        XCTAssertEqual(packets[749][24], 0x03, "end of block 0")
        XCTAssertEqual(packets[750][24], 0x05, "start of block 1")
        XCTAssertEqual(le32(packets[750], 28) >> 22, 750)
        XCTAssertEqual(le32(packets[750], 28) >> 12 & 0x3FF, 0)
    }

    func testRefusesAFrameTooLargeForFourBlocks() {
        var packetizer = MoonlightPacketizer(packetSize: 1024)
        XCTAssertNil(packetizer.packets(for: Data(count: 4093 * 1008), isKeyFrame: true, timestamp: 0, latency: 0))
    }

    // MARK: - Control messages

    func testNonceIsTheCounterThenTheDirection() {
        XCTAssertEqual([UInt8](MoonlightControlCrypto.nonce(sequence: 0x0403_0201, direction: .clientToHost)),
                       [1, 2, 3, 4, 0, 0, 0, 0, 0, 0, 0x43, 0x43])
        XCTAssertEqual([UInt8](MoonlightControlCrypto.nonce(sequence: 7, direction: .hostToClient)),
                       [7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x48, 0x43])
    }

    func testSealedMessagesOpenWithTheSameKeyAndDirection() throws {
        let key = SymmetricKey(size: .bits128)
        let sealed = try MoonlightControlCrypto.seal(type: 0x0302, payload: Data([0, 0]), sequence: 5, key: key,
                                                     direction: .clientToHost)
        XCTAssertEqual([UInt8](sealed.prefix(8)), [1, 0, 26, 0, 5, 0, 0, 0], "type, length 4+16+6, counter")
        let opened = try XCTUnwrap(MoonlightControlCrypto.open(sealed, key: key, direction: .clientToHost))
        XCTAssertEqual(opened.type, 0x0302)
        XCTAssertEqual(opened.payload, Data([0, 0]))
        XCTAssertNil(MoonlightControlCrypto.open(sealed, key: key, direction: .hostToClient))
        XCTAssertNil(MoonlightControlCrypto.open(sealed, key: SymmetricKey(size: .bits128)))
    }

    // MARK: - Keyframe requests

    func testABurstOfKeyFrameRequestsCostsAtMostTwoKeyFrames() {
        var throttle = MoonlightKeyFrameThrottle(interval: 250)
        XCTAssertEqual(throttle.request(at: 1000), .now)
        XCTAssertEqual(throttle.request(at: 1050), .later(200), "answered once the interval is over")
        XCTAssertEqual(throttle.request(at: 1100), .alreadyDue)
        XCTAssertEqual(throttle.request(at: 1200), .alreadyDue)
        // The deferred one asks again when due, and goes out.
        XCTAssertEqual(throttle.request(at: 1250), .now)
        XCTAssertEqual(throttle.request(at: 1300), .later(200))
    }

    func testRequestsFarApartAreEachAnsweredAtOnce() {
        var throttle = MoonlightKeyFrameThrottle(interval: 250)
        XCTAssertEqual(throttle.request(at: 0), .now)
        XCTAssertEqual(throttle.request(at: 300), .now)
        XCTAssertEqual(throttle.request(at: 1000), .now)
    }

    private let ms: UInt64 = 1_000_000

    func testRequestsWhileTheKeyFrameIsOnItsWayAreCovered() {
        var requests = MoonlightKeyFrameRequests()
        XCTAssertEqual(requests.request(at: 0, roundTrip: 40 * ms), .now)
        XCTAssertEqual(requests.request(at: 20 * ms, roundTrip: 40 * ms), .covered, "not yet sent")
        requests.keyFrameSent(at: 30 * ms)
        XCTAssertEqual(requests.request(at: 60 * ms, roundTrip: 40 * ms), .covered,
                       "sent before the client could have had it")
        // One sent after the client had the keyframe means it lost something since.
        XCTAssertEqual(requests.request(at: 300 * ms, roundTrip: 40 * ms), .now)
    }

    func testAClientThatLostTheKeyFrameIsAnsweredAfterARoundTrip() {
        var requests = MoonlightKeyFrameRequests()
        XCTAssertEqual(requests.request(at: 0, roundTrip: 40 * ms), .now)
        requests.keyFrameSent(at: 10 * ms)
        XCTAssertEqual(requests.request(at: 70 * ms, roundTrip: 40 * ms), .later(180 * ms),
                       "past the round trip; within the quarter second, so answered at its end")
        XCTAssertEqual(requests.request(at: 250 * ms, roundTrip: 40 * ms), .now)
    }

    func testTheHostsOwnRequestsAreNotCoveredByAKeyFrameAlreadySent() {
        var requests = MoonlightKeyFrameRequests()
        XCTAssertEqual(requests.request(at: 0, roundTrip: 40 * ms), .now)
        requests.keyFrameSent(at: 10 * ms)
        XCTAssertEqual(requests.request(at: 20 * ms, roundTrip: nil), .later(230 * ms))
    }

    func testAKeyFrameNeverSentIsAskedForAgainAfterASecond() {
        var requests = MoonlightKeyFrameRequests()
        XCTAssertEqual(requests.request(at: 0, roundTrip: 40 * ms), .now)
        XCTAssertEqual(requests.request(at: 900 * ms, roundTrip: 40 * ms), .covered)
        XCTAssertEqual(requests.request(at: 1000 * ms, roundTrip: 40 * ms), .now)
    }

    func testALongRoundTripCoversNoMoreThanItsLimit() {
        var requests = MoonlightKeyFrameRequests()
        XCTAssertEqual(requests.request(at: 0, roundTrip: 500 * ms), .now)
        requests.keyFrameSent(at: 0)
        XCTAssertEqual(requests.request(at: 299 * ms, roundTrip: 500 * ms), .covered)
        XCTAssertEqual(requests.request(at: 300 * ms, roundTrip: 500 * ms), .now)
    }
}
