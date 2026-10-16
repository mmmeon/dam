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
    /// Milliseconds of sound in each audio packet: 5, or 10 at low bitrates.
    var audioPacketDuration = 5
    /// Whether audio goes encrypted, as Moonlight on a Mac or PC always asks.
    var audioEncrypted = false
    /// Whether stereo may take a high bitrate; set from the ANNOUNCE request's Host.
    var highQualityAudio = false
    /// Whether the encoder uses low-latency rate control; set from the device's setting,
    /// not from ANNOUNCE.
    var lowLatency = false

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
                                     minimumParity: int("x-nv-vqos[0].fec.minRequiredFecPackets") ?? 0,
                                     audioPacketDuration: int("x-nv-aqos.packetDuration") ?? 5,
                                     // Asked for either way: the legacy flag 0x20, or the newer bit 0x04.
                                     audioEncrypted: (int("x-nv-general.featureFlags") ?? 0) & 0x20 != 0
                                         || (int("x-ss-general.encryptionEnabled") ?? 0) & 0x04 != 0)
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

/// Answers Moonlight's keyframe requests with at most one keyframe per interval. On a lossy
/// link requests come in bursts, one per frame lost; a keyframe for each is a run of large
/// frames, each likelier to be lost again. The first request is answered at once; any more
/// within the interval are answered together once it is over, so none goes unanswered.
struct MoonlightKeyFrameThrottle {
    enum Decision: Equatable {
        case now
        /// After this many nanoseconds, asking again.
        case later(UInt64)
        /// One is already due later.
        case alreadyDue
    }

    let interval: UInt64
    private var last: UInt64?
    private var due = false

    init(interval: UInt64 = 250_000_000) {
        self.interval = interval
    }

    mutating func request(at now: UInt64) -> Decision {
        if let last, now &- last < interval {
            if due { return .alreadyDue }
            due = true
            return .later(interval - (now &- last))
        }
        last = now
        due = false
        return .now
    }
}

/// What Moonlight says of a frame's FEC block that needed parity: sent, as a Sunshine
/// extension (control message 0x5502), for each it rebuilt from parity and each it could
/// not. 21 bytes, big-endian.
struct MoonlightFrameFecStatus: Equatable {
    static let messageType: UInt16 = 0x5502

    let frameIndex: UInt32
    let dataPackets: Int
    let parityPackets: Int
    let receivedData: Int
    let receivedParity: Int

    init(frameIndex: UInt32, dataPackets: Int, parityPackets: Int, receivedData: Int, receivedParity: Int) {
        self.frameIndex = frameIndex
        self.dataPackets = dataPackets
        self.parityPackets = parityPackets
        self.receivedData = receivedData
        self.receivedParity = receivedParity
    }

    init?(payload: Data) {
        let bytes = [UInt8](payload)
        guard bytes.count >= 21 else { return nil }
        func u16(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        frameIndex = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        dataPackets = u16(10)
        parityPackets = u16(12)
        receivedData = u16(14)
        receivedParity = u16(16)
    }

    /// Whether the block was lost: fewer of its packets came than its data needs.
    var isLost: Bool { receivedData + receivedParity < dataPackets }
}

/// Sets a Moonlight stream's bitrate from how much of it the client loses, lower while it
/// loses frames and back up while it does not, as the bitrate the client asked for is often
/// more than its link carries: then nearly every frame is lost and asked for again as a
/// keyframe, larger still. A loss is a frame Moonlight reports it could not rebuild, or a
/// keyframe it asks for (a frame that never came is reported only that way); counted each
/// second, as the larger of the two, since one lost frame brings both.
///
/// Two or more losses in a second take the bitrate down by 30%, and ten or more (a link
/// carrying far less than the stream) by half; then nothing changes for two seconds while
/// the encoder and the frames already sent catch up. Five seconds without a loss, and with
/// few frames needing parity, bring it up by 15%, to at most the client's bitrate.
///
/// Losing packets at random, a link loses as much at a lower bitrate, and each frame then
/// has fewer packets of parity to rebuild it from: a cut only makes it worse. So a cut is
/// tried, along with any cuts that follow it, and judged on the ten seconds after them: if
/// those did not lose at most half as much as the ten seconds before, the bitrate goes back
/// to what it was, and for thirty seconds only losses of ten or more cut it.
struct MoonlightBitrateGovernor {
    /// The client's bitrate, the most this sets.
    let ceiling: Int
    /// The least this sets: a quarter of the client's, and no less than 2 Mbit/s unless
    /// the client asked for less.
    let floor: Int
    private(set) var current: Int
    private var lostFrames = 0, keyFrameRequests = 0, rebuiltFrames = 0
    private var cleanSeconds = 0, holdSeconds = 0
    /// Losses in each of the last `judgedSeconds` seconds, oldest first.
    private var recent: [Int] = []
    /// Cuts being tried: the bitrate before them, the losses a second before them, and the
    /// losses each second since the last of them (past its hold).
    private var trial: (kbps: Int, before: Double, after: [Int])?
    /// Seconds counted; the second from which ordinary losses may cut again.
    private var seconds = 0, cutsAllowedFrom = 0

    /// Frames rebuilt from parity in a second that still count it as clean.
    static let rebuiltAllowed = 2
    /// Losses in a second that halve the bitrate, and cut it even after a cut did not help.
    static let severeLosses = 10
    /// How long a cut is judged on, and the losses before it it is judged against.
    static let judgedSeconds = 10
    /// How long ordinary losses leave the bitrate alone after a cut did not help.
    static let restSeconds = 30

    init(kbps: Int) {
        ceiling = kbps
        floor = min(kbps, max(kbps / 4, 2000))
        current = kbps
    }

    mutating func frameStatus(_ status: MoonlightFrameFecStatus) {
        if status.isLost { lostFrames += 1 } else { rebuiltFrames += 1 }
    }

    mutating func keyFrameRequested() {
        keyFrameRequests += 1
    }

    /// Called once a second; the new bitrate in kbps when it changes.
    mutating func second() -> Int? {
        let losses = max(lostFrames, keyFrameRequests)
        let rebuilt = rebuiltFrames
        lostFrames = 0; keyFrameRequests = 0; rebuiltFrames = 0
        seconds += 1
        let before = recent
        recent = Array((recent + [losses]).suffix(Self.judgedSeconds))
        if holdSeconds > 0 {
            holdSeconds -= 1
            return nil
        }
        let severe = losses >= Self.severeLosses
        if losses >= 2, current > floor, severe || seconds >= cutsAllowedFrom {
            if trial == nil {
                let window = before + [losses]
                trial = (current, Double(window.reduce(0, +)) / Double(window.count), [])
            }
            trial?.after = []
            cleanSeconds = 0
            current = max(floor, severe ? current / 2 : current * 7 / 10)
            holdSeconds = 2
            return current
        }
        if var tried = trial {
            tried.after.append(losses)
            trial = tried
            if tried.after.count >= Self.judgedSeconds {
                trial = nil
                let after = Double(tried.after.reduce(0, +)) / Double(tried.after.count)
                if after > tried.before / 2 {
                    // Lost as much at the lower bitrate: not the bitrate's doing.
                    cutsAllowedFrom = seconds + Self.restSeconds
                    cleanSeconds = 0
                    guard tried.kbps != current else { return nil }
                    current = tried.kbps
                    return current
                }
            }
        }
        cleanSeconds = losses == 0 && rebuilt <= Self.rebuiltAllowed ? cleanSeconds + 1 : 0
        guard cleanSeconds >= 5, current < ceiling else { return nil }
        // Clean at the lower bitrate: the cuts helped.
        trial = nil
        cleanSeconds = 0
        current = min(ceiling, current * 115 / 100)
        return current
    }
}

/// Puts Opus packets in Moonlight's audio packets: a 12-byte RTP header (payload type 97,
/// sequence, a timestamp in milliseconds), then the Opus packet, encrypted with AES-128-CBC
/// when asked. After every fourth packet come two parity packets (type 127) for the four,
/// which Moonlight rebuilds up to two lost ones from.
struct MoonlightAudioPacketizer {
    static let dataType: UInt8 = 97
    static let parityType: UInt8 = 127

    let packetDuration: Int
    /// The session key and the counter its IVs start from; nil sends audio in the clear.
    let key: Data?
    let keyID: UInt32
    private(set) var sequence: UInt16 = 0
    private(set) var timestamp: UInt32 = 0
    /// This block's payloads so far, as sent.
    private var block: [Data] = []

    init(packetDuration: Int, key: Data?, keyID: UInt32) {
        self.packetDuration = packetDuration
        self.key = key
        self.keyID = keyID
    }

    /// The packets to send for one Opus packet: its own, then the block's parity after the
    /// fourth. Nil when it could not be encrypted.
    mutating func packets(for opus: Data) -> [Data]? {
        let payload: Data
        if let key {
            var iv = Data()
            iv.append(bigEndian: keyID &+ UInt32(sequence))
            iv.append(Data(count: 12))
            guard let sealed = try? MoonlightCrypto.aesCBC(opus, key: key, iv: iv) else { return nil }
            payload = sealed
        } else {
            payload = opus
        }
        var packet = Self.header(type: Self.dataType, sequence: sequence, timestamp: timestamp)
        packet.append(payload)
        var packets = [packet]

        // A block is the packets numbered 4k to 4k + 3.
        if sequence % 4 == 0 { block = [] }
        block.append(payload)
        if sequence % 4 == 3, block.count == 4, block.allSatisfy({ $0.count == payload.count }) {
            let base = sequence &- 3
            let baseTimestamp = timestamp &- UInt32(3 * packetDuration)
            for (index, parity) in MoonlightFEC.parity(of: block, rows: MoonlightFEC.audioRows).enumerated() {
                var fec = Self.header(type: Self.parityType, sequence: sequence &+ 1 &+ UInt16(index), timestamp: 0)
                fec.append(contentsOf: [UInt8(index), Self.dataType])
                fec.append(bigEndian: base)
                fec.append(bigEndian: baseTimestamp)
                fec.append(bigEndian: UInt32(0))
                fec.append(parity)
                packets.append(fec)
            }
        }
        sequence &+= 1
        timestamp &+= UInt32(packetDuration)
        return packets
    }

    private static func header(type: UInt8, sequence: UInt16, timestamp: UInt32) -> Data {
        var header = Data([0x80, type])
        header.append(bigEndian: sequence)
        header.append(bigEndian: timestamp)
        header.append(bigEndian: UInt32(0))
        return header
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
