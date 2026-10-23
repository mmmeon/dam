import XCTest
import CoreMedia
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

    func testReadsHDRFromTheDynamicRangeMode() throws {
        XCTAssertFalse(try XCTUnwrap(MoonlightStreamConfig.parse(sdp: announce)).hdr)
        let hdr = try XCTUnwrap(MoonlightStreamConfig.parse(sdp: announce + "a=x-nv-video[0].dynamicRangeMode:1 \r\n"))
        XCTAssertTrue(hdr.hdr)
        XCTAssertFalse(try XCTUnwrap(MoonlightStreamConfig.parse(sdp: announce + "a=x-nv-video[0].dynamicRangeMode:0 \r\n")).hdr)
    }

    // MARK: - HDR metadata

    /// As moonlight-common-c reads it: the enabled byte, then thirteen little-endian 16-bit
    /// fields, primaries in RGB order.
    func testTheHDRModeMessageIsLaidOutAsMoonlightReadsIt() {
        let payload = [UInt8](MoonlightHDRMetadata.canonical.controlPayload(enabled: true))
        XCTAssertEqual(payload.count, 27)
        XCTAssertEqual(payload[0], 1)
        func field(_ index: Int) -> UInt16 { UInt16(payload[1 + index * 2]) | UInt16(payload[2 + index * 2]) << 8 }
        XCTAssertEqual((0..<13).map(field), [35400, 14600, 8500, 39850, 6550, 2300, 15635, 16450, 1000, 50, 1000, 400, 0])
        XCTAssertEqual(MoonlightHDRMetadata.canonical.controlPayload(enabled: false).first, 0)
    }

    /// As ST 2086 and CTA-861.3 SEI carry them: big-endian, primaries green, blue, red.
    func testTheEncodersMetadataIsInSEIOrder() {
        let volume = [UInt8](MoonlightHDRMetadata.canonical.masteringDisplayColorVolume)
        XCTAssertEqual(volume.count, 24)
        func u16(_ at: Int) -> Int { Int(volume[at]) << 8 | Int(volume[at + 1]) }
        XCTAssertEqual((0..<8).map { u16($0 * 2) }, [8500, 39850, 6550, 2300, 35400, 14600, 15635, 16450])
        XCTAssertEqual(volume[16..<20].reduce(0) { $0 << 8 | Int($1) }, 10_000_000, "1000 nits in 0.0001")
        XCTAssertEqual(volume[20..<24].reduce(0) { $0 << 8 | Int($1) }, 50)
        XCTAssertEqual([UInt8](MoonlightHDRMetadata.canonical.contentLightLevel), [0x03, 0xE8, 0x01, 0x90])
    }

    func testRefusesAnAnnounceWithoutTheSize() {
        XCTAssertNil(MoonlightStreamConfig.parse(sdp: announce.replacingOccurrences(of: "clientViewportWd", with: "x")))
    }

    /// Values that would overflow or trap further on are refused, or brought into range.
    func testRefusesOrBoundsSettingsNoClientWouldAnnounce() throws {
        func parse(_ attribute: String, _ value: String) -> MoonlightStreamConfig? {
            let line = announce.components(separatedBy: "\n").first { $0.hasPrefix("a=\(attribute):") }
            return MoonlightStreamConfig.parse(sdp: line.map { announce.replacingOccurrences(of: $0, with: "a=\(attribute):\(value) \r") }
                                                    ?? announce + "a=\(attribute):\(value) \r\n")
        }
        for (attribute, value) in [("x-nv-video[0].clientViewportWd", "0"), ("x-nv-video[0].clientViewportHt", "-1"),
                                   ("x-nv-video[0].clientViewportWd", "100000"), ("x-nv-video[0].maxFPS", "0"),
                                   ("x-nv-video[0].maxFPS", "\(Int.max)"), ("x-nv-video[0].packetSize", "32"),
                                   ("x-nv-video[0].packetSize", "65552"), ("x-nv-vqos[0].bw.maximumBitrateKbps", "-5"),
                                   ("x-nv-vqos[0].bw.maximumBitrateKbps", "0")] {
            XCTAssertNil(parse(attribute, value), "\(attribute) \(value)")
        }
        XCTAssertEqual(parse("x-nv-vqos[0].bw.maximumBitrateKbps", "\(Int.max / 2)")?.bitrateKbps, 1_000_000)
        XCTAssertEqual(parse("x-nv-video[0].packetSize", "1024")?.packetSize, 1024)
        XCTAssertEqual(parse("x-nv-video[0].maxFPS", "120")?.fps, 120)
        XCTAssertEqual(parse("x-nv-aqos.packetDuration", "10")?.audioPacketDuration, 10)
        for duration in ["-5", "0", "7", "100000"] {
            XCTAssertEqual(parse("x-nv-aqos.packetDuration", duration)?.audioPacketDuration, 5, duration)
        }
        // The largest packet still makes frames whose last-packet length fits its field.
        var packetizer = MoonlightPacketizer(packetSize: MoonlightStreamConfig.packetSizes.upperBound)
        XCTAssertNotNil(packetizer.packets(for: Data(count: 70_000), isKeyFrame: true, timestamp: 0, latency: 0))
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

    func testRefusesAFrameTooLargeForFourBlocks() throws {
        var packetizer = MoonlightPacketizer(packetSize: 1024)
        XCTAssertNil(packetizer.packets(for: Data(count: 4093 * 1008), isKeyFrame: true, timestamp: 0, latency: 0))
        // Its index is passed over, so Moonlight sees a frame lost and asks for a keyframe.
        let next = try XCTUnwrap(packetizer.packets(for: Data(count: 100), isKeyFrame: false, timestamp: 0, latency: 0))
        XCTAssertEqual(le32(next[0], 20), 2)
        XCTAssertEqual(be16(next[0], 2), 0, "no packet was sent for it")
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

    // MARK: - Encrypted video

    func testEncryptedVideoIsBitTwoOfEncryptionEnabled() throws {
        XCTAssertFalse(try XCTUnwrap(MoonlightStreamConfig.parse(sdp: announce)).videoEncrypted)
        let asked = announce.replacingOccurrences(of: "encryptionEnabled:1", with: "encryptionEnabled:7")
        XCTAssertTrue(try XCTUnwrap(MoonlightStreamConfig.parse(sdp: asked)).videoEncrypted)
    }

    func testVideoNonceIsTheCounterThenV() {
        XCTAssertEqual([UInt8](MoonlightVideoCrypto.nonce(counter: 0x0807_0605_0403_0201)),
                       [1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 0x56])
        // Never one of the control stream's, under the same key.
        XCTAssertNotEqual(MoonlightVideoCrypto.nonce(counter: 7).last, MoonlightControlCrypto.nonce(sequence: 7, direction: .hostToClient).last)
    }

    /// Each packet, data and parity alike, opens as moonlight-common-c opens it: the nonce
    /// and tag from the 32-byte prefix, the frame index in the clear between them.
    func testSealedVideoPacketsOpenToThePlainOnesWithTheFrameIndexInTheClear() throws {
        let key = Data((0..<16).map { UInt8($0) })
        var packetizer = MoonlightPacketizer(packetSize: 1392, fecPercentage: 20)
        var crypto = MoonlightVideoCrypto(key: key)
        _ = packetizer.blocks(for: Data(count: 100), isKeyFrame: true, timestamp: 0, latency: 0)
        let blocks = try XCTUnwrap(packetizer.blocks(for: Data(count: 5000), isKeyFrame: false, timestamp: 9, latency: 0))
        let plain = blocks.flatMap { $0.packets + MoonlightPacketizer.parity(for: $0) }
        var nonces = Set<Data>()
        for packet in plain {
            let sealed = try XCTUnwrap(crypto.seal(packet))
            XCTAssertEqual(sealed.count, packet.count + MoonlightVideoCrypto.overhead)
            XCTAssertEqual(le32(sealed, 12), 2, "the second frame")
            XCTAssertEqual(MoonlightVideoCrypto.open(sealed, key: key), packet)
            XCTAssertNil(MoonlightVideoCrypto.open(sealed, key: Data(count: 16)))
            nonces.insert(sealed.prefix(12))
        }
        XCTAssertEqual(nonces.count, plain.count, "no nonce twice")
        XCTAssertEqual(crypto.counter, UInt64(plain.count))
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

    func testAKeyFrameTooLargeToSendIsAskedForAgain() {
        var requests = MoonlightKeyFrameRequests()
        XCTAssertEqual(requests.request(at: 0, roundTrip: 40 * ms), .now)
        requests.keyFrameDropped()
        XCTAssertEqual(requests.request(at: 30 * ms, roundTrip: nil), .later(220 * ms), "not covered")
        XCTAssertEqual(requests.retry(at: 250 * ms, roundTrip: nil), .now)
    }

    func testARequestHeldForLaterIsDroppedOnceAKeyFrameWentOut() {
        var requests = MoonlightKeyFrameRequests()
        XCTAssertEqual(requests.request(at: 0, roundTrip: nil), .now)
        requests.keyFrameSent(at: 10 * ms)
        XCTAssertEqual(requests.request(at: 50 * ms, roundTrip: nil), .later(200 * ms))
        XCTAssertEqual(requests.request(at: 80 * ms, roundTrip: nil), .alreadyDue)
        requests.keyFrameSent(at: 100 * ms)
        XCTAssertEqual(requests.retry(at: 250 * ms, roundTrip: nil), .covered, "the keyframe at 100 ms answered both")
        // Nothing is due any more: the next request within the interval is held again.
        XCTAssertEqual(requests.request(at: 260 * ms, roundTrip: nil), .now)
    }

    func testARequestHeldForLaterAfterTheLastKeyFrameIsMade() {
        var requests = MoonlightKeyFrameRequests()
        XCTAssertEqual(requests.request(at: 0, roundTrip: nil), .now)
        requests.keyFrameSent(at: 10 * ms)
        XCTAssertEqual(requests.request(at: 50 * ms, roundTrip: nil), .later(200 * ms))
        XCTAssertEqual(requests.request(at: 120 * ms, roundTrip: nil), .alreadyDue)
        requests.keyFrameSent(at: 100 * ms)
        XCTAssertEqual(requests.retry(at: 250 * ms, roundTrip: nil), .now, "one came after the keyframe")
    }

    func testAJoinAndTheFramesAlreadyOnTheirWayCostOneKeyFrame() {
        // A browser viewer asks with every frame until its keyframe comes.
        var requests = MoonlightKeyFrameRequests()
        XCTAssertEqual(requests.request(at: 0, roundTrip: nil), .now)
        XCTAssertEqual(requests.request(at: 16 * ms, roundTrip: nil), .covered)
        XCTAssertEqual(requests.request(at: 33 * ms, roundTrip: nil), .covered)
        requests.keyFrameSent(at: 50 * ms)
    }

    func testALongRoundTripCoversNoMoreThanItsLimit() {
        var requests = MoonlightKeyFrameRequests()
        XCTAssertEqual(requests.request(at: 0, roundTrip: 500 * ms), .now)
        requests.keyFrameSent(at: 0)
        XCTAssertEqual(requests.request(at: 299 * ms, roundTrip: 500 * ms), .covered)
        XCTAssertEqual(requests.request(at: 300 * ms, roundTrip: 500 * ms), .now)
    }

    // MARK: - Bitrate

    func testFrameFecStatusReadsMoonlightsBigEndianReport() throws {
        // frame 0x01020304; highest 9, contiguous 3, missing 2; 10 data, 3 parity; 7 and 2 received; 20%, block 0 of 1
        let payload = Data([1, 2, 3, 4, 0, 9, 0, 3, 0, 2, 0, 10, 0, 3, 0, 7, 0, 2, 20, 0, 1])
        let status = try XCTUnwrap(MoonlightFrameFecStatus(payload: payload))
        XCTAssertEqual(status, MoonlightFrameFecStatus(frameIndex: 0x0102_0304, dataPackets: 10, parityPackets: 3,
                                                       receivedData: 7, receivedParity: 2))
        XCTAssertTrue(status.isLost, "9 packets came of the 10 the data needs")
        XCTAssertNil(MoonlightFrameFecStatus(payload: payload.prefix(20)))
    }

    private func rebuilt() -> MoonlightFrameFecStatus {
        MoonlightFrameFecStatus(frameIndex: 0, dataPackets: 10, parityPackets: 2, receivedData: 9, receivedParity: 2)
    }

    /// A second in which `count` frames came five packets short, as a queue overflowing leaves them.
    private func lostInRuns(_ count: Int, _ governor: inout MoonlightBitrateGovernor) -> Int? {
        for _ in 0..<count {
            governor.frameStatus(MoonlightFrameFecStatus(frameIndex: 0, dataPackets: 10, parityPackets: 2,
                                                         receivedData: 3, receivedParity: 2))
        }
        return governor.second()
    }

    /// A second in which `count` frames came a packet short, as random loss leaves them.
    private func lostScattered(_ count: Int, _ governor: inout MoonlightBitrateGovernor) -> Int? {
        for _ in 0..<count {
            governor.frameStatus(MoonlightFrameFecStatus(frameIndex: 0, dataPackets: 10, parityPackets: 2,
                                                         receivedData: 8, receivedParity: 1))
        }
        return governor.second()
    }

    /// A second in which the client asked for `count` keyframes.
    private func lose(_ count: Int, _ governor: inout MoonlightBitrateGovernor) -> Int? {
        for _ in 0..<count { governor.keyFrameRequested() }
        return governor.second()
    }

    private func warmUp(_ governor: inout MoonlightBitrateGovernor) {
        for _ in 0..<MoonlightBitrateGovernor.warmUpSeconds { XCTAssertNil(lose(12, &governor)) }
    }

    func testAFrameLostInARunIsFourOrMorePacketsShort() {
        func status(_ received: Int) -> MoonlightFrameFecStatus {
            MoonlightFrameFecStatus(frameIndex: 0, dataPackets: 20, parityPackets: 4, receivedData: received, receivedParity: 0)
        }
        XCTAssertFalse(status(20).isLost)
        XCTAssertEqual(status(17).shortBy, 3)
        XCTAssertFalse(status(17).isLostInARun)
        XCTAssertTrue(status(16).isLostInARun)
    }

    func testFramesLostInRunsBringTheBitrateDownThenItWaits() {
        var governor = MoonlightBitrateGovernor(kbps: 16000)
        warmUp(&governor)
        XCTAssertNil(lostInRuns(1, &governor), "one is not enough")
        XCTAssertEqual(lostInRuns(2, &governor), 11200)
        for _ in 0..<2 { XCTAssertNil(lostInRuns(2, &governor), "waits while what was sent at the old rate arrives") }
        XCTAssertEqual(lostInRuns(2, &governor), 7840)
    }

    func testAfterAFrameLostInARunOtherLossesCutIt() {
        var governor = MoonlightBitrateGovernor(kbps: 10000)
        warmUp(&governor)
        XCTAssertNil(lostInRuns(1, &governor))
        XCTAssertEqual(lostScattered(2, &governor), 7000)
    }

    func testAFrameLostInARunCountsForTenSeconds() {
        var governor = MoonlightBitrateGovernor(kbps: 10000)
        warmUp(&governor)
        XCTAssertNil(lostInRuns(1, &governor))
        // No losses, though too many frames needing parity to raise it.
        for _ in 0..<10 {
            for _ in 0..<3 { governor.frameStatus(rebuilt()) }
            XCTAssertNil(governor.second())
        }
        XCTAssertNil(lostScattered(2, &governor), "10 s after the frame lost in a run")
    }

    func testFramesLostAPacketShortOrKeyFrameRequestsAloneDoNotCutIt() {
        var governor = MoonlightBitrateGovernor(kbps: 16000)
        warmUp(&governor)
        for _ in 0..<20 {
            XCTAssertNil(lostScattered(5, &governor))
            XCTAssertNil(lose(5, &governor))
        }
        XCTAssertEqual(governor.current, 16000)
    }

    func testTheFirstSecondsCountForNothing() {
        var governor = MoonlightBitrateGovernor(kbps: 16000)
        warmUp(&governor)
        XCTAssertEqual(governor.current, 16000, "losses while Moonlight starts")
        // Clean from here: a later cut is judged against these seconds alone.
        for _ in 0..<10 { XCTAssertNil(lose(0, &governor)) }
        XCTAssertEqual(lostInRuns(2, &governor), 11200)
    }

    func testHeavyLossHalvesTheBitrateDownToAQuarterOrTwoMegabits() {
        var governor = MoonlightBitrateGovernor(kbps: 16000)
        warmUp(&governor)
        XCTAssertEqual(lose(12, &governor), 8000, "ten or more of any kind")
        XCTAssertNil(lose(12, &governor))
        XCTAssertNil(lose(12, &governor))
        XCTAssertEqual(lostScattered(12, &governor), 4000)
        XCTAssertNil(lose(12, &governor))
        XCTAssertNil(lose(12, &governor))
        XCTAssertNil(lose(12, &governor), "no lower than a quarter")
        XCTAssertEqual(MoonlightBitrateGovernor(kbps: 6000).floor, 2000)
        XCTAssertEqual(MoonlightBitrateGovernor(kbps: 1500).floor, 1500, "never above what the client asked for")
    }

    func testACutThatDoesNotLowerTheLossesIsUndone() {
        var governor = MoonlightBitrateGovernor(kbps: 10000)
        warmUp(&governor)
        // A link losing about a frame a second whatever the bitrate.
        for _ in 0..<10 { XCTAssertNil(lostScattered(1, &governor)) }
        XCTAssertEqual(lostInRuns(2, &governor), 7000)
        XCTAssertNil(lostScattered(1, &governor)); XCTAssertNil(lostScattered(1, &governor))
        for _ in 0..<9 { XCTAssertNil(lostScattered(1, &governor)) }
        XCTAssertEqual(lostScattered(1, &governor), 10000, "as many losses at 7000 as at 10000: back to 10000")
        // Then frames lost in runs leave it alone for a while; heavy loss still cuts it.
        for _ in 0..<5 { XCTAssertNil(lostInRuns(3, &governor)) }
        XCTAssertEqual(lose(12, &governor), 5000)
    }

    func testCutsThatDoNotHelpAreUndoneEvenFromTheFloor() {
        var governor = MoonlightBitrateGovernor(kbps: 8000)
        warmUp(&governor)
        var changes: [Int] = []
        for _ in 0..<30 { if let kbps = lostInRuns(2, &governor) { changes.append(kbps) } }
        XCTAssertEqual(changes, [5600, 3920, 2744, 2000, 8000], "down to the floor, then back once judged")
    }

    func testCleanSecondsBringTheBitrateBackUpToTheClients() {
        var governor = MoonlightBitrateGovernor(kbps: 10000)
        warmUp(&governor)
        XCTAssertEqual(lostInRuns(2, &governor), 7000)
        var changes: [Int] = []
        for _ in 0..<40 { if let kbps = governor.second() { changes.append(kbps) } }
        XCTAssertEqual(changes, [8050, 9257, 10000], "after the hold, every 5 clean seconds; at most the client's")
    }

    func testFramesNeedingMuchParityHoldTheBitrateUp() {
        var governor = MoonlightBitrateGovernor(kbps: 10000)
        warmUp(&governor)
        XCTAssertEqual(lostInRuns(2, &governor), 7000)
        for _ in 0..<20 {
            for _ in 0..<3 { governor.frameStatus(rebuilt()) }
            XCTAssertNil(governor.second())
        }
    }

    func testReadsIntegersBackFromASliceOfData() {
        var data = Data([0xEE, 0xEE])
        data.append(littleEndian: UInt16(0x1234))
        data.append(bigEndian: UInt32(0xDEAD_BEEF))
        data.append(bigEndian: Int16(-2))
        // Its indices start at 2, not 0.
        let slice = data[2...]
        XCTAssertEqual(slice.read(littleEndian: UInt16.self, at: 0), 0x1234)
        XCTAssertEqual(slice.read(bigEndian: UInt32.self, at: 2), 0xDEAD_BEEF)
        XCTAssertEqual(slice.read(bigEndian: Int16.self, at: 6), -2)
        XCTAssertEqual([UInt8](slice).read(littleEndian: UInt32.self, at: 2), 0xEFBE_ADDE)
    }

    // MARK: - Packet marking

    /// The traffic class a datagram sent from a socket for `traffic` arrives with, over loopback.
    private func arrivingTOS(_ traffic: MoonlightUDPSocket.Traffic?) throws -> UInt8 {
        let receiver = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        XCTAssertGreaterThanOrEqual(receiver, 0)
        defer { Darwin.close(receiver) }
        var yes: Int32 = 1
        setsockopt(receiver, IPPROTO_IP, IP_RECVTOS, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(receiver, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                XCTAssertEqual(Darwin.bind(receiver, $0, length), 0)
                XCTAssertEqual(getsockname(receiver, $0, &length), 0)
            }
        }

        let sender = try MoonlightUDPSocket(port: 0, traffic: traffic)
        XCTAssertTrue(sender.send(Data("frame".utf8), to: address))

        var buffer = [UInt8](repeating: 0, count: 64)
        var control = [UInt8](repeating: 0, count: 64)
        let count = buffer.withUnsafeMutableBytes { data in
            control.withUnsafeMutableBytes { control in
                var vector = iovec(iov_base: data.baseAddress, iov_len: data.count)
                return withUnsafeMutablePointer(to: &vector) { vector in
                    var message = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: vector, msg_iovlen: 1,
                                         msg_control: control.baseAddress, msg_controllen: socklen_t(control.count),
                                         msg_flags: 0)
                    let count = recvmsg(receiver, &message, 0)
                    XCTAssertGreaterThan(message.msg_controllen, 0, "the TOS came with the datagram")
                    return count
                }
            }
        }
        XCTAssertEqual(count, 5)
        // One cmsghdr: length, level, type, then the TOS byte.
        let header = control.withUnsafeBytes { $0.load(as: cmsghdr.self) }
        XCTAssertEqual(header.cmsg_level, IPPROTO_IP)
        XCTAssertEqual(header.cmsg_type, IP_RECVTOS)
        return control[MemoryLayout<cmsghdr>.size]
    }

    /// Video goes out as AF41 and sound as EF, so an access point queues them as video and
    /// voice; other sockets are left unmarked.
    func testStreamPacketsAreMarkedForTheirQueues() throws {
        XCTAssertEqual(try arrivingTOS(.video) >> 2, 34)
        XCTAssertEqual(try arrivingTOS(.audio) >> 2, 46)
        XCTAssertEqual(try arrivingTOS(nil), 0)
    }

    // MARK: - Control stream

    /// Ports for this file's streams, away from GameStream's and the host tests'.
    private func testPorts(_ slot: Int) -> MoonlightStream.Ports { MoonlightStream.Ports(slot: 120 + slot) }

    /// Waits up to 2 s for UDP `port` to be free again, as a stopped stream's threads let go
    /// of theirs a moment later, so a test run again finds it free.
    private func waitUntilFree(_ port: UInt16) {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let probe = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            Darwin.close(probe)
            if bound == 0 { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// The events an ENet client sees in `seconds` of trying to connect to `port` with `token`,
    /// as Moonlight does; it stops at a disconnect.
    private func connect(_ client: UnsafeMutablePointer<ENetHost>, to port: UInt16, token: UInt32,
                         seconds: TimeInterval = 1) throws -> [ENetEventType] {
        var address = ENetAddress(host: 0, port: port)
        enet_address_set_host_ip(&address, "127.0.0.1")
        _ = try XCTUnwrap(enet_host_connect(client, &address, 48, token))
        var events: [ENetEventType] = []
        var event = ENetEvent()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !events.contains(ENET_EVENT_TYPE_DISCONNECT) {
            guard enet_host_service(client, &event, 10) > 0 else { continue }
            if event.type == ENET_EVENT_TYPE_RECEIVE { enet_packet_destroy(event.packet) }
            events.append(event.type)
        }
        return events
    }

    /// A wrong token is turned away, the session's is taken, and a second device with it is
    /// turned away while the first is connected.
    func testTheControlStreamTakesOneDeviceWithTheSessionsToken() throws {
        let port = testPorts(1).control
        let server = try MoonlightControlServer(port: port, key: Data(count: 16), connectData: 0x1234)
        let lock = NSLock()
        var connects = 0
        server.onConnect = { lock.lock(); connects += 1; lock.unlock() }
        server.start()
        defer { server.stop(); waitUntilFree(port) }
        let clients = try (0..<3).map { _ in try XCTUnwrap(enet_host_create(nil, 1, 48, 0, 0)) }
        defer { clients.forEach { enet_host_destroy($0) } }

        XCTAssertTrue(try connect(clients[0], to: port, token: 0x9999).contains(ENET_EVENT_TYPE_DISCONNECT),
                      "a wrong token is disconnected")
        let first = try connect(clients[1], to: port, token: 0x1234, seconds: 0.5)
        XCTAssertEqual(first, [ENET_EVENT_TYPE_CONNECT], "the session's token stays connected")
        XCTAssertTrue(try connect(clients[2], to: port, token: 0x1234).contains(ENET_EVENT_TYPE_DISCONNECT),
                      "a second device is disconnected")
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(connects, 1)
    }

    /// A CONNECT never followed up holds a peer until ENet gives up on it; one address holds
    /// at most two, so a host sending them can't take the peers a device needs.
    func testOneAddressHoldsAtMostTwoOfTheControlStreamsPeers() throws {
        let port = testPorts(2).control
        let server = try MoonlightControlServer(port: port, key: Data(count: 16), connectData: 0x1234)
        server.start()
        defer { server.stop(); waitUntilFree(port) }
        let clients = try (0..<3).map { _ in try XCTUnwrap(enet_host_create(nil, 1, 48, 0, 0)) }
        defer { clients.forEach { enet_host_destroy($0) } }
        // Two CONNECTs whose replies are never read.
        var address = ENetAddress(host: 0, port: port)
        enet_address_set_host_ip(&address, "127.0.0.1")
        for client in clients.prefix(2) {
            _ = try XCTUnwrap(enet_host_connect(client, &address, 48, 0x1234))
            enet_host_flush(client)
        }
        XCTAssertFalse(try connect(clients[2], to: port, token: 0x1234).contains(ENET_EVENT_TYPE_CONNECT),
                       "a third from the same address gets no peer")
        XCTAssertLessThanOrEqual(MoonlightControlServer.peersPerAddress * 8, MoonlightControlServer.peerCount,
                                 "room for many addresses")
    }

    /// A stream whose last port is taken binds none: its control port is free for the next
    /// ANNOUNCE.
    func testAStreamThatCannotBindItsPortsLeavesNoneBound() throws {
        let ports = testPorts(3)
        let taken = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = ports.audio.bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(taken, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        let config = MoonlightStreamConfig(width: 1280, height: 720, fps: 60, packetSize: 1392, bitrateKbps: 10_000,
                                           videoFormat: 0, encryptionEnabled: 0)
        func makeStream() throws -> MoonlightStream {
            try MoonlightStream(config: config, displayID: 1, key: Data(count: 16), keyID: 0, pingPayload: "",
                                connectData: 0, clientAddress: "127.0.0.1", ports: ports)
        }
        XCTAssertThrowsError(try makeStream())
        Darwin.close(taken)
        XCTAssertNoThrow(try MoonlightControlServer(port: ports.control, key: Data(count: 16), connectData: 0))
        XCTAssertNoThrow(try MoonlightUDPSocket(port: ports.video))
        XCTAssertNoThrow(try makeStream(), "every port free again")
    }

    // MARK: - Pacing

    /// A socket on loopback that reads datagrams with the time the kernel took each in.
    private final class TimedReceiver {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        private(set) var address = sockaddr_in()

        init() {
            var yes: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_TIMESTAMP, &yes, socklen_t(MemoryLayout<Int32>.size))
            var buffer: Int32 = 4 << 20
            setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = Darwin.bind(descriptor, $0, length)
                    _ = getsockname(descriptor, $0, &length)
                }
            }
        }

        deinit { Darwin.close(descriptor) }

        func send(_ data: Data, to port: UInt16) {
            var to = address
            to.sin_port = port.bigEndian
            _ = data.withUnsafeBytes { bytes in
                withUnsafePointer(to: &to) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(descriptor, bytes.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        /// The next datagram and when it arrived, in microseconds; nil after 3 s without one.
        func receive() -> (Data, Int64)? {
            var buffer = [UInt8](repeating: 0, count: 2048)
            var control = [UInt8](repeating: 0, count: 64)
            var arrived: Int64 = 0
            let count = buffer.withUnsafeMutableBytes { data in
                control.withUnsafeMutableBytes { control -> Int in
                    var vector = iovec(iov_base: data.baseAddress, iov_len: data.count)
                    return withUnsafeMutablePointer(to: &vector) { vector in
                        var message = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: vector, msg_iovlen: 1,
                                             msg_control: control.baseAddress, msg_controllen: socklen_t(control.count),
                                             msg_flags: 0)
                        let count = recvmsg(descriptor, &message, 0)
                        guard count > 0, message.msg_controllen > 0 else { return count }
                        let header = control.load(as: cmsghdr.self)
                        if header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_TIMESTAMP {
                            let time = control.loadUnaligned(fromByteOffset: MemoryLayout<cmsghdr>.size, as: timeval.self)
                            arrived = Int64(time.tv_sec) * 1_000_000 + Int64(time.tv_usec)
                        }
                        return count
                    }
                }
            }
            guard count > 0 else { return nil }
            return (Data(buffer[0..<count]), arrived)
        }
    }

    /// A frame for the video sender: `data` as an access unit, with an empty sample.
    private func frame(_ data: Data, keyFrame: Bool = true) throws -> MoonlightVideoEncoder.Frame {
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                             formatDescription: nil, sampleCount: 0, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                             sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        let now = DispatchTime.now().uptimeNanoseconds
        return MoonlightVideoEncoder.Frame(data: data, isKeyFrame: keyFrame, units: [data], sample: try XCTUnwrap(sample),
                                           time: .zero, submitted: now, encoded: now)
    }

    /// A block's parity goes out at the pace once it is worked out, not at once to make up
    /// for the time that took; and the sender says when it has caught up.
    func testVideoParityGoesOutAtThePace() throws {
        let port = testPorts(4).video
        // 60 Mbit/s, the slowest pace: 133 ns a byte. 100 data packets and 50 of parity, 544
        // bytes each: the parity takes 3.6 ms at the pace, and longer to work out unoptimised.
        let sender = try MoonlightVideoSender(port: port, pingPayload: "0123456789abcdef", client: "127.0.0.1",
                                              packetSize: 528, minimumParity: 50, bitrateKbps: 1000)
        let caughtUp = expectation(description: "caught up")
        sender.onCaughtUp = { caughtUp.fulfill() }
        sender.startListening()
        defer { sender.stop(); waitUntilFree(port) }
        let receiver = TimedReceiver()
        receiver.send(Data("0123456789abcdef".utf8) + Data([0, 0, 0, 1]), to: port)
        let deadline = Date().addingTimeInterval(2)
        while !sender.hasPeer, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(sender.hasPeer)

        sender.send(try frame(Data(count: 100 * 512 - 8)))
        var data: [Int64] = [], parity: [Int64] = []
        while data.count + parity.count < 150, let (packet, arrived) = receiver.receive() {
            let fec = [UInt8](packet[28..<32]).read(littleEndian: UInt32.self, at: 0)
            if (fec >> 12) & 0x3FF < fec >> 22 { data.append(arrived) } else { parity.append(arrived) }
        }
        XCTAssertEqual(data.count, 100)
        XCTAssertEqual(parity.count, 50)
        let paritySpan = Double((parity.last ?? 0) - (parity.first ?? 0)) / 1000
        XCTAssertGreaterThan(paritySpan, 2.5, "parity paced, less half a millisecond of catching up")
        let dataSpan = Double((data.last ?? 0) - (data.first ?? 0)) / 1000
        XCTAssertGreaterThan(dataSpan, 6, "data paced: 7.2 ms")
        wait(for: [caughtUp], timeout: 2)
    }

    /// Sound goes one packet a fire, one for each fire missed, and one more while the line is
    /// longer than a piece of captured sound leaves it.
    func testSoundIsPacedAndItsLineDrains() {
        let due = MoonlightAudioPacing.due
        XCTAssertEqual(due(1, 0, 5), 0)
        XCTAssertEqual(due(1, 4, 5), 1, "a piece of captured sound goes a packet a fire")
        XCTAssertEqual(due(1, 6, 5), 1)
        XCTAssertEqual(due(1, 7, 5), 2, "a line longer than a piece drains")
        XCTAssertEqual(due(3, 4, 5), 3, "fires missed are made up")
        XCTAssertEqual(due(3, 2, 5), 2)
        XCTAssertEqual(due(1, 3, 10), 1)
        XCTAssertEqual(due(1, 4, 10), 2)

        // A line of eight drains two a fire, down to a piece's length.
        var waiting = 8
        for _ in 0..<2 { waiting -= due(1, waiting, 5) }
        XCTAssertEqual(waiting, 5)
    }
}
