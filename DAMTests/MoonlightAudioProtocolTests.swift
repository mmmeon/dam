import XCTest
@testable import DAM

final class MoonlightAudioProtocolTests: XCTestCase {

    private func hex(_ text: String) -> Data { MoonlightCrypto.data(hex: text.replacingOccurrences(of: " ", with: ""))! }

    func testEncryptsAudioAsMoonlightDecryptsIt() throws {
        // AES-128-CBC with PKCS#7, worked out with openssl enc -aes-128-cbc.
        let key = hex("000102030405060708090a0b0c0d0e0f")
        let iv = hex("12345 67d") + Data(count: 12)
        let plain = Data((0..<60).map { UInt8($0) })
        XCTAssertEqual(MoonlightCrypto.hex(try MoonlightCrypto.aesCBC(plain, key: key, iv: iv)).lowercased(),
                       "b5ad90d1800ce5c01e882ead138391d9" + "7b6a044939bc783a24546868621afedd" +
                       "544e82c9826f4b6d1f6fedb2bf79399c" + "e8ddddeea7dcd03db8f51a73bb7e26a0")
    }

    func testAudioParityUsesItsFixedMatrix() {
        let shards = [hex("01020304"), hex("05060708"), hex("090a0b0c"), hex("0d0e0f10")]
        XCTAssertEqual(MoonlightFEC.parity(of: shards, rows: MoonlightFEC.audioRows), [hex("898a8b26"), hex("252627b8")])
    }

    func testPacketsCarryTheHeaderAndAParityPairAfterEveryFourth() throws {
        var packetizer = MoonlightAudioPacketizer(packetDuration: 5, key: Data(count: 16), keyID: 0x1234_5678)
        var sent: [[Data]] = []
        for _ in 0..<8 { sent.append(try XCTUnwrap(packetizer.packets(for: Data(repeating: 7, count: 60)))) }
        XCTAssertEqual(sent.map(\.count), [1, 1, 1, 4 - 1, 1, 1, 1, 3], "parity after the 4th and 8th")
        let seventh = sent[7][0]
        XCTAssertEqual([UInt8](seventh.prefix(12)), [0x80, 0x61, 0, 7, 0, 0, 0, 35, 0, 0, 0, 0])
        XCTAssertEqual(seventh.count, 12 + 64, "60 bytes encrypted, padded to 64")
        // The IV is the key ID plus the sequence number: 12 34 56 7F for packet 7.
        XCTAssertEqual(seventh.dropFirst(12),
                       try MoonlightCrypto.aesCBC(Data(repeating: 7, count: 60), key: Data(count: 16),
                                                  iv: hex("1234567f") + Data(count: 12)))
        XCTAssertEqual([UInt8](sent[7][1].prefix(24)),
                       [0x80, 0x7F, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x61, 0, 4, 0, 0, 0, 20, 0, 0, 0, 0])
        XCTAssertEqual([UInt8](sent[7][2].prefix(14)), [0x80, 0x7F, 0, 9, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0x61])
        let payloads = (4...7).map { sent[$0][0].dropFirst(12) }.map { Data($0) }
        XCTAssertEqual(sent[7][1].dropFirst(24), MoonlightFEC.parity(of: payloads, rows: MoonlightFEC.audioRows)[0])
    }

    func testSendsInTheClearWhenNotAskedToEncrypt() throws {
        var packetizer = MoonlightAudioPacketizer(packetDuration: 10, key: nil, keyID: 0)
        let packet = try XCTUnwrap(packetizer.packets(for: Data([1, 2, 3]))?.first)
        XCTAssertEqual(packet, Data([0x80, 0x61, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3]))
        XCTAssertEqual(packetizer.timestamp, 10)
    }

    func testReadsAudioSettingsFromAnnounce() throws {
        let base = "a=x-nv-video[0].clientViewportWd:1280 \r\na=x-nv-video[0].clientViewportHt:720 \r\n" +
                   "a=x-nv-video[0].maxFPS:60 \r\na=x-nv-video[0].packetSize:1392 \r\n" +
                   "a=x-nv-vqos[0].bw.maximumBitrateKbps:8000 \r\n"
        let legacy = try XCTUnwrap(MoonlightStreamConfig.parse(sdp: base + "a=x-nv-general.featureFlags:167 \r\na=x-nv-aqos.packetDuration:10 \r\n"))
        XCTAssertTrue(legacy.audioEncrypted)
        XCTAssertEqual(legacy.audioPacketDuration, 10)
        XCTAssertTrue(try XCTUnwrap(MoonlightStreamConfig.parse(sdp: base + "a=x-ss-general.encryptionEnabled:5 \r\n")).audioEncrypted)
        let plain = try XCTUnwrap(MoonlightStreamConfig.parse(sdp: base + "a=x-nv-general.featureFlags:135 \r\n"))
        XCTAssertFalse(plain.audioEncrypted)
        XCTAssertEqual(plain.audioPacketDuration, 5)
    }

    func testEncoderMakesPacketsOfOneSize() throws {
        var sizes = Set<Int>()
        let encoder = try MoonlightAudioEncoder(packetDuration: 5, bitrate: 96_000) { sizes.insert($0.count) }
        // Sound, then silence: a varying encoder would shrink the silent packets.
        var samples = [Float](repeating: 0, count: 48_000)
        for i in 0..<24_000 { samples[i] = Float(sin(Double(i) * 0.07)) * 0.4 }
        samples.withUnsafeBufferPointer { encoder.encode(interleaved: $0) }
        XCTAssertEqual(sizes, [60], "96 kbit/s for 5 ms")
    }
}
