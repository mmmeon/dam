import XCTest
@testable import DAM

/// Reed-Solomon as nanors, which Moonlight decodes with, defines it. The vectors are worked
/// from that definition; the encoder was also checked against nanors itself, which recovered
/// lost packets from DAM's parity.
final class MoonlightFECTests: XCTestCase {

    func testCoefficientsFormTheCauchyMatrix() {
        let rows = (0..<2).map { row in (0..<3).map { MoonlightFEC.coefficient(row: row, column: $0, parityCount: 2) } }
        XCTAssertEqual(rows, [[142, 244, 71], [244, 142, 167]])
        XCTAssertEqual((0..<4).map { MoonlightFEC.coefficient(row: 0, column: $0, parityCount: 1) }, [1, 142, 244, 71])
    }

    func testParityOfTheWorkedExample() {
        let parity = MoonlightFEC.parity(of: [Data([0x01, 0x02]), Data([0x03, 0x04]), Data([0xFF, 0x10])], count: 2)
        XCTAssertEqual(parity, [Data([0x79, 0xF2]), Data([0x48, 0x55])])
    }

    func testOneParityShardRecoversAnyOneLostDataShard() {
        let data = (0..<5).map { seed in Data((0..<64).map { UInt8(truncatingIfNeeded: $0 * 31 + seed * 17) }) }
        let parity = MoonlightFEC.parity(of: data, count: 1)[0]
        for lost in 0..<data.count {
            // data[lost] = (parity − Σ others) / coefficient; minus is plus in GF(2^8).
            var rebuilt = parity
            for (column, shard) in data.enumerated() where column != lost {
                let c = MoonlightFEC.coefficient(row: 0, column: column, parityCount: 1)
                for i in 0..<rebuilt.count { rebuilt[i] ^= MoonlightFEC.multiply(c, shard[i]) }
            }
            let inverse = MoonlightFEC.inverse(MoonlightFEC.coefficient(row: 0, column: lost, parityCount: 1))
            for i in 0..<rebuilt.count { rebuilt[i] = MoonlightFEC.multiply(inverse, rebuilt[i]) }
            XCTAssertEqual(rebuilt, data[lost], "shard \(lost)")
        }
    }

    func testFieldArithmetic() {
        for a in 1...255 { XCTAssertEqual(MoonlightFEC.multiply(UInt8(a), MoonlightFEC.inverse(UInt8(a))), 1) }
        XCTAssertEqual(MoonlightFEC.multiply(0x80, 2), 0x1D, "x^8 reduces by 0x11D")
    }

    func testParityCountsRoundTripThroughThePercentage() {
        for data in 1...254 {
            let (count, percentage) = MoonlightFEC.parityCount(dataShards: data, percentage: 20, minimum: 2)
            XCTAssertEqual((data * percentage + 99) / 100, count, "Moonlight works out the same count for \(data)")
            XCTAssertLessThanOrEqual(data + count, 255)
            XCTAssertLessThanOrEqual(percentage, 255)
            if data <= 212 { XCTAssertGreaterThanOrEqual(count, 2) }
        }
        XCTAssertEqual(MoonlightFEC.parityCount(dataShards: 100, percentage: 20, minimum: 2).count, 20)
        XCTAssertEqual(MoonlightFEC.parityCount(dataShards: 1, percentage: 20, minimum: 2).count, 2)
        XCTAssertEqual(MoonlightFEC.parityCount(dataShards: 50, percentage: 0, minimum: 2).count, 0)
    }

    // MARK: - Packets

    private func le32(_ packet: Data, _ offset: Int) -> UInt32 {
        let b = [UInt8](packet)
        return UInt32(b[offset]) | UInt32(b[offset + 1]) << 8 | UInt32(b[offset + 2]) << 16 | UInt32(b[offset + 3]) << 24
    }

    private func be16(_ packet: Data, _ offset: Int) -> UInt16 { UInt16(packet[offset]) << 8 | UInt16(packet[offset + 1]) }

    func testParityPacketsFollowTheirDataInSequence() throws {
        var packetizer = MoonlightPacketizer(packetSize: 1392, fecPercentage: 20, minimumParity: 2)
        let blocks = try XCTUnwrap(packetizer.blocks(for: Data(count: 13_000), isKeyFrame: false, timestamp: 9, latency: 0))
        XCTAssertEqual(blocks.count, 1)
        let block = blocks[0]
        let parity = MoonlightPacketizer.parity(for: block)
        XCTAssertEqual(block.packets.count, 10)
        XCTAssertEqual(parity.count, 2)
        let all = block.packets + parity
        XCTAssertTrue(all.allSatisfy { $0.count == 1392 + 16 })
        XCTAssertEqual(all.map { be16($0, 2) }, Array(0..<12), "one run of sequence numbers")
        for (index, packet) in all.enumerated() {
            XCTAssertEqual(packet[0], 0x90)
            XCTAssertEqual(le32(packet, 20), 1, "frame index")
            XCTAssertEqual(le32(packet, 28), 10 << 22 | UInt32(index) << 12 | 20 << 4, "fecInfo of packet \(index)")
        }
        XCTAssertEqual(Array(parity[0][4...7]), [0, 0, 0, 9], "timestamp")

        let next = try XCTUnwrap(packetizer.packets(for: Data(count: 10), isKeyFrame: false, timestamp: 0, latency: 0))
        XCTAssertEqual(be16(next[0], 2), 12, "the next frame continues after the parity")
        XCTAssertEqual(le32(next[0], 16) >> 8, 12)
    }

    func testAFrameTooLargeForFourParityBlocksGoesWithout() throws {
        var packetizer = MoonlightPacketizer(packetSize: 1024, fecPercentage: 20, minimumParity: 2)
        // 900 packets: more than four blocks of 212, so no parity, in one block of 900.
        let blocks = try XCTUnwrap(packetizer.blocks(for: Data(count: 900 * 1008 - 8), isKeyFrame: true,
                                                     timestamp: 0, latency: 0))
        XCTAssertEqual(blocks.map(\.packets.count), [900])
        XCTAssertEqual(blocks[0].parityCount, 0)
    }

    func testReadsTheMinimumParityFromAnnounce() throws {
        let sdp = "a=x-nv-video[0].clientViewportWd:1280 \r\na=x-nv-video[0].clientViewportHt:720 \r\n" +
                  "a=x-nv-video[0].maxFPS:60 \r\na=x-nv-video[0].packetSize:1392 \r\n" +
                  "a=x-nv-vqos[0].bw.maximumBitrateKbps:8000 \r\na=x-nv-vqos[0].fec.minRequiredFecPackets:2 \r\n"
        XCTAssertEqual(try XCTUnwrap(MoonlightStreamConfig.parse(sdp: sdp)).minimumParity, 2)
    }
}
