//
//  MoonlightProtocol.swift
//
//  The parts of a Moonlight stream that are pure data: the stream settings Moonlight
//  announces over RTSP, the video packets a frame is cut into, and the encrypted messages
//  of the control stream. Layouts follow moonlight-common-c as it talks to a GameStream
//  7.1.431 host (as Sunshine reports itself).
//

import CryptoKit
import Foundation

/// What Moonlight asks of the stream in its RTSP ANNOUNCE.
struct MoonlightStreamConfig: Equatable {
    var width: Int
    var height: Int
    var fps: Int
    /// Bytes of each video packet after its 16-byte RTP header.
    var packetSize: Int
    var bitrateKbps: Int
    /// 0 is H.264, the only codec offered.
    var videoFormat: Int
    /// The x-ss-general.encryptionEnabled bits; 0x02 would be encrypted video.
    var encryptionEnabled: Int
    /// The fewest parity packets Moonlight asks for in each block.
    var minimumParity = 0

    /// The settings in an ANNOUNCE body, nil when one it needs is missing.
    static func parse(sdp: String) -> MoonlightStreamConfig? {
        var attributes: [String: String] = [:]
        for line in sdp.split(whereSeparator: \.isNewline) where line.hasPrefix("a=") {
            let body = line.dropFirst(2)
            guard let colon = body.firstIndex(of: ":") else { continue }
            attributes[String(body[..<colon])] = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        func int(_ name: String) -> Int? { attributes[name].flatMap { Int($0) } }
        guard let width = int("x-nv-video[0].clientViewportWd"), let height = int("x-nv-video[0].clientViewportHt"),
              let fps = int("x-nv-video[0].maxFPS"), let packetSize = int("x-nv-video[0].packetSize"),
              let bitrate = int("x-nv-vqos[0].bw.maximumBitrateKbps"),
              width > 0, height > 0, fps > 0, packetSize > 32 else { return nil }
        return MoonlightStreamConfig(width: width, height: height, fps: fps, packetSize: packetSize,
                                     bitrateKbps: bitrate, videoFormat: int("x-nv-vqos[0].bitStreamFormat") ?? 0,
                                     encryptionEnabled: int("x-ss-general.encryptionEnabled") ?? 0,
                                     minimumParity: int("x-nv-vqos[0].fec.minRequiredFecPackets") ?? 0)
    }
}

/// Cuts encoded frames into Moonlight's video packets. Each packet is exactly
/// `packetSize + 16` bytes: a 16-byte RTP header, a 16-byte video header, and a slice of
/// the frame, which starts with an 8-byte frame header. A frame goes in up to four blocks,
/// each followed by Reed-Solomon parity packets Moonlight rebuilds lost ones from. A
/// block's data packets can be sent before its parity is worked out: Moonlight takes a
/// block as soon as all its data has come, and only waits for parity when some is lost.
struct MoonlightPacketizer {

    /// One block's data packets, and what its parity packets need.
    struct Block {
        var packets: [Data]
        let parityCount: Int
        let percentage: Int
        /// The sequence number of its first data packet; its parity follows its data.
        let firstSequence: UInt32
        let multiFecBlocks: UInt8
        let frameIndex: UInt32
        let timestamp: UInt32
    }

    static let rtpHeaderSize = 16
    static let videoHeaderSize = 16
    static let frameHeaderSize = 8
    /// The most data packets a block can hold, and blocks a frame.
    static let maxPacketsPerBlock = 1023
    static let maxBlocks = 4

    let packetSize: Int
    /// How much parity each block gets, as a share of its data, and at least how many.
    let fecPercentage: Int
    let minimumParity: Int
    /// The next frame's index; Moonlight expects the first to be 1.
    private(set) var frameIndex: UInt32 = 1
    /// One counter for every packet of the session, as the RTP sequence and packet index.
    private(set) var sequence: UInt32 = 0

    init(packetSize: Int, fecPercentage: Int = 0, minimumParity: Int = 0) {
        self.packetSize = packetSize
        self.fecPercentage = fecPercentage
        self.minimumParity = minimumParity
    }

    private var payloadSize: Int { packetSize - Self.videoHeaderSize }

    /// Every packet for one Annex B access unit, each block's data then its parity, or nil
    /// when it is too large to send.
    mutating func packets(for accessUnit: Data, isKeyFrame: Bool, timestamp: UInt32, latency: UInt16) -> [Data]? {
        blocks(for: accessUnit, isKeyFrame: isKeyFrame, timestamp: timestamp, latency: latency)?
            .flatMap { $0.packets + Self.parity(for: $0) }
    }

    /// The blocks for one Annex B access unit, or nil when it is too large to send.
    /// `timestamp` is in 90 kHz units; `latency` is how long the frame took, in 0.1 ms.
    mutating func blocks(for accessUnit: Data, isKeyFrame: Bool, timestamp: UInt32, latency: UInt16) -> [Block]? {
        var stream = Data(capacity: Self.frameHeaderSize + accessUnit.count)
        let lastPayload = (accessUnit.count + Self.frameHeaderSize) % payloadSize
        stream.append(0x01)
        stream.append(littleEndian: latency)
        stream.append(isKeyFrame ? 2 : 1)
        stream.append(littleEndian: UInt16(lastPayload == 0 ? payloadSize : lastPayload))
        stream.append(contentsOf: [0, 0])
        stream.append(accessUnit)

        let total = (stream.count + payloadSize - 1) / payloadSize
        // Blocks small enough to leave room for their parity within 255 shards; a frame too
        // large for four of those goes without parity, in blocks of up to 1023 packets.
        var percentage = fecPercentage
        func blocksNeeded(_ perBlock: Int) -> Int { (total + perBlock - 1) / perBlock }
        var blocks = blocksNeeded(percentage > 0 ? MoonlightFEC.maxShards * 100 / (100 + percentage) : Self.maxPacketsPerBlock)
        if blocks > Self.maxBlocks {
            percentage = 0
            blocks = blocksNeeded(Self.maxPacketsPerBlock)
        }
        guard blocks <= Self.maxBlocks else { return nil }
        let perBlock = (total + blocks - 1) / blocks

        var result: [Block] = []
        var offset = 0
        for block in 0..<blocks {
            let count = min(perBlock, total - block * perBlock)
            let parity = MoonlightFEC.parityCount(dataShards: count, percentage: percentage, minimum: minimumParity)
            let multiFecBlocks = UInt8(block << 4 | (blocks - 1) << 6)
            let firstSequence = sequence
            var packets: [Data] = []
            packets.reserveCapacity(count)
            for index in 0..<count {
                var flags: UInt8 = 0x01
                if index == 0 { flags |= 0x04 }
                if index == count - 1 { flags |= 0x02 }
                var packet = Data(capacity: Self.rtpHeaderSize + packetSize)
                packet.append(contentsOf: [0x90, 0x00])
                packet.append(bigEndian: UInt16(truncatingIfNeeded: sequence))
                packet.append(bigEndian: timestamp)
                packet.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
                packet.append(littleEndian: (sequence & 0xFF_FFFF) << 8)
                packet.append(littleEndian: frameIndex)
                packet.append(contentsOf: [flags, 0, 0x10, multiFecBlocks])
                packet.append(littleEndian: Self.fecInfo(dataShards: count, index: index, percentage: parity.percentage))
                let end = min(offset + payloadSize, stream.count)
                packet.append(stream[offset..<end])
                packet.append(Data(count: payloadSize - (end - offset)))
                offset = end
                sequence &+= 1
                packets.append(packet)
            }
            // The parity's sequence numbers follow the data's, whenever it is sent.
            sequence &+= UInt32(parity.count)
            result.append(Block(packets: packets, parityCount: parity.count, percentage: parity.percentage,
                                firstSequence: firstSequence, multiFecBlocks: multiFecBlocks,
                                frameIndex: frameIndex, timestamp: timestamp))
        }
        frameIndex &+= 1
        return result
    }

    private static func fecInfo(dataShards: Int, index: Int, percentage: Int) -> UInt32 {
        UInt32(dataShards) << 22 | UInt32(index) << 12 | UInt32(percentage) << 4
    }

    /// `block`'s parity packets: Reed-Solomon over its whole data packets, then given the
    /// header fields Moonlight reads from parity (RTP version, sequence, timestamp, frame,
    /// block and shard). The rest stays parity, which Moonlight recovers lost packets from.
    static func parity(for block: Block) -> [Data] {
        let count = block.packets.count
        return MoonlightFEC.parity(of: block.packets, count: block.parityCount).enumerated().map { row, shard in
            var packet = shard
            func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
                withUnsafeBytes(of: value) { packet.replaceSubrange(offset..<(offset + $0.count), with: $0) }
            }
            packet[0] = 0x90
            put(UInt16(truncatingIfNeeded: block.firstSequence &+ UInt32(count + row)).bigEndian, at: 2)
            put(block.timestamp.bigEndian, at: 4)
            put(block.frameIndex.littleEndian, at: 20)
            packet[27] = block.multiFecBlocks
            put(fecInfo(dataShards: count, index: count + row, percentage: block.percentage).littleEndian, at: 28)
            return packet
        }
    }
}

/// The control stream's encrypted messages: AES-128-GCM under the session key, with a
/// 12-byte nonce of the sender's message counter and a mark of its direction.
enum MoonlightControlCrypto {
    enum Direction {
        case clientToHost, hostToClient
        fileprivate var mark: [UInt8] { self == .clientToHost ? [0x43, 0x43] : [0x48, 0x43] }
    }

    static func nonce(sequence: UInt32, direction: Direction) -> Data {
        var bytes = Data()
        bytes.append(littleEndian: sequence)
        bytes.append(contentsOf: [0, 0, 0, 0, 0, 0])
        bytes.append(contentsOf: direction.mark)
        return bytes
    }

    /// One message, sealed: the wrapper type 0x0001, its length, the counter, the tag, then
    /// the encrypted type, payload length and payload.
    static func seal(type: UInt16, payload: Data, sequence: UInt32, key: SymmetricKey,
                     direction: Direction = .hostToClient) throws -> Data {
        var plain = Data()
        plain.append(littleEndian: type)
        plain.append(littleEndian: UInt16(payload.count))
        plain.append(payload)
        let box = try AES.GCM.seal(plain, using: key,
                                   nonce: try AES.GCM.Nonce(data: nonce(sequence: sequence, direction: direction)))
        var packet = Data()
        packet.append(littleEndian: UInt16(0x0001))
        packet.append(littleEndian: UInt16(4 + 16 + box.ciphertext.count))
        packet.append(littleEndian: sequence)
        packet.append(box.tag)
        packet.append(box.ciphertext)
        return packet
    }

    /// The type and payload of a sealed message, nil when it is not one or does not open.
    static func open(_ packet: Data, key: SymmetricKey,
                     direction: Direction = .clientToHost) -> (type: UInt16, payload: Data)? {
        let bytes = [UInt8](packet)
        guard bytes.count >= 28, UInt16(bytes[0]) | UInt16(bytes[1]) << 8 == 0x0001 else { return nil }
        let length = Int(bytes[2]) | Int(bytes[3]) << 8
        guard length >= 24, bytes.count >= length + 4 else { return nil }
        let sequence = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        guard let nonce = try? AES.GCM.Nonce(data: nonce(sequence: sequence, direction: direction)),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(bytes[24..<(length + 4)]),
                                               tag: Data(bytes[8..<24])),
              let plain = try? AES.GCM.open(box, using: key), plain.count >= 4 else { return nil }
        let inner = [UInt8](plain)
        let type = UInt16(inner[0]) | UInt16(inner[1]) << 8
        let size = min(Int(inner[2]) | Int(inner[3]) << 8, inner.count - 4)
        return (type, Data(inner[4..<(4 + size)]))
    }
}

extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
