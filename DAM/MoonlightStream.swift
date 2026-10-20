//
//  MoonlightStream.swift
//
//  One Moonlight session after its RTSP handshake: the screen captured, encoded and sent
//  as video packets to where Moonlight's pings come from, the control stream it connects
//  over ENet, and the Mac's sound as Opus. Capture, encoding and sending each run on a
//  thread of their own, handing frames on the moment they are ready; when sending is
//  behind, frames are skipped before they are encoded, never after.
//

import CoreMedia
import CryptoKit
import Foundation
import Network
import os.log

private let msLog = Logger(subsystem: AppIdentity.bundleID, category: "MoonlightStream")

enum MoonlightStreamError: Error {
    case socket(String, Int32)
    case enet
}

// MARK: - Networks

/// Whether an address is on one of the Mac's own networks: loopback, link-local (as over a
/// USB or Thunderbolt cable), or within the subnet of one of its interfaces.
enum LocalNetwork {
    struct Subnet: Equatable {
        let address: [UInt8]
        let mask: [UInt8]

        func contains(_ bytes: [UInt8]) -> Bool {
            bytes.count == address.count && mask.count == address.count
                && zip(zip(bytes, address), mask).allSatisfy { ($0.0 & $1) == ($0.1 & $1) }
        }
    }

    static func contains(_ endpoint: NWEndpoint?, subnets: [Subnet] = interfaceSubnets()) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return contains([UInt8](address.rawValue), subnets: subnets)
        case .ipv6(let address): return contains([UInt8](address.rawValue), subnets: subnets)
        default: return false
        }
    }

    /// `bytes` is an IPv4 or IPv6 address; an IPv4 one written as IPv6 counts as IPv4.
    static func contains(_ bytes: [UInt8], subnets: [Subnet]) -> Bool {
        var bytes = bytes
        if bytes.count == 16, bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            bytes = Array(bytes[12...])
        }
        if bytes.count == 4, bytes[0] == 127 || (bytes[0] == 169 && bytes[1] == 254) { return true }
        if bytes.count == 16, bytes == [UInt8](repeating: 0, count: 15) + [1]
            || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80) { return true }
        return subnets.contains { $0.contains(bytes) }
    }

    /// The subnets of the interfaces that are up.
    static func interfaceSubnets() -> [Subnet] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var subnets: [Subnet] = []
        var next = first
        while let entry = next?.pointee {
            next = entry.ifa_next
            guard entry.ifa_flags & UInt32(IFF_UP) != 0, let address = entry.ifa_addr, let mask = entry.ifa_netmask,
                  let bytes = Self.bytes(address), let maskBytes = Self.bytes(mask, family: address.pointee.sa_family),
                  bytes.count == maskBytes.count else { continue }
            subnets.append(Subnet(address: bytes, mask: maskBytes))
        }
        return subnets
    }

    /// An address's bytes. A netmask may come without its family, so the address's is
    /// given, and cut short where the rest is zeros, so only `sa_len` bytes are read.
    private static func bytes(_ address: UnsafeMutablePointer<sockaddr>, family: sa_family_t? = nil) -> [UInt8]? {
        let (offset, count): (Int, Int)
        switch Int32(family ?? address.pointee.sa_family) {
        case AF_INET: (offset, count) = (MemoryLayout<sockaddr_in>.offset(of: \.sin_addr)!, 4)
        case AF_INET6: (offset, count) = (MemoryLayout<sockaddr_in6>.offset(of: \.sin6_addr)!, 16)
        default: return nil
        }
        let length = Int(address.pointee.sa_len)
        let raw = UnsafeRawPointer(address)
        return (offset..<(offset + count)).map { $0 < length ? raw.load(fromByteOffset: $0, as: UInt8.self) : 0 }
    }
}

// MARK: - UDP

/// An IPv4 UDP socket bound to a port, read on one thread and written on another.
final class MoonlightUDPSocket {
    private let descriptor: Int32
    private let lock = NSLock()
    private var closed = false

    init(port: UInt16) throws {
        descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw MoonlightStreamError.socket("socket", errno) }
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        // Room for a whole keyframe sent at once.
        var buffer: Int32 = 4 << 20
        setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let error = errno
            Darwin.close(descriptor)
            throw MoonlightStreamError.socket("bind \(port)", error)
        }
    }

    deinit { close() }

    /// The next datagram and where it came from, waiting up to `timeout`; nil if none came.
    func receive(timeout: TimeInterval) -> (Data, sockaddr_in)? {
        var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, Int32(timeout * 1000)) > 0, poller.revents & Int16(POLLIN) != 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(descriptor, &buffer, buffer.count, 0, $0, &length)
            }
        }
        guard count > 0 else { return nil }
        return (Data(buffer[0..<count]), from)
    }

    /// Sends `data`; false when macOS would not take it, as when its send queue is full.
    @discardableResult
    func send(_ data: Data, to address: sockaddr_in) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        var to = address
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &to) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, bytes.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == data.count
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(descriptor)
    }
}

// MARK: - Video

/// Counts of what a stream sent and what went wrong, logged every few seconds.
final class MoonlightStreamStats {
    private let lock = NSLock()
    private var frames = 0, keyFrames = 0, videoPackets = 0, videoBytes = 0, videoRefused = 0
    private var audioPackets = 0, audioRefused = 0, keyFrameRequests = 0, coveredRequests = 0, rebuilt = 0, lost = 0

    func video(packets: Int, bytes: Int, refused: Int, keyFrame: Bool) {
        lock.lock(); defer { lock.unlock() }
        frames += 1; keyFrames += keyFrame ? 1 : 0; videoPackets += packets; videoBytes += bytes; videoRefused += refused
    }

    func audio(packets: Int, refused: Int) {
        lock.lock(); defer { lock.unlock() }
        audioPackets += packets; audioRefused += refused
    }

    func keyFrameRequested(covered: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        keyFrameRequests += 1
        coveredRequests += covered ? 1 : 0
    }

    func frameStatus(_ status: MoonlightFrameFecStatus) {
        lock.lock(); defer { lock.unlock() }
        if status.isLost { lost += 1 } else { rebuilt += 1 }
    }

    /// The counts since the last call, as a line for the log.
    func take(seconds: Double) -> String {
        lock.lock(); defer { lock.unlock() }
        let line = String(format: "%.1f fps (%d keyframes), %.1f Mbit/s, %d keyframe requests (%d covered); " +
                          "blocks rebuilt from parity %d, lost %d; packets refused: video %d of %d, audio %d of %d",
                          Double(frames) / seconds, keyFrames, Double(videoBytes) * 8 / seconds / 1e6, keyFrameRequests,
                          coveredRequests, rebuilt, lost, videoRefused, videoPackets, audioRefused, audioPackets)
        frames = 0; keyFrames = 0; videoPackets = 0; videoBytes = 0; videoRefused = 0
        audioPackets = 0; audioRefused = 0; keyFrameRequests = 0; coveredRequests = 0; rebuilt = 0; lost = 0
        return line
    }
}

/// Learns where Moonlight wants video from its pings, and sends frames there, paced: a
/// frame's packets go out spread at a few times the stream's bitrate rather than at once,
/// as a burst at full speed overflows Wi-Fi queues and loses packets. Sending happens on a
/// thread of its own, so the encoder goes on with the next frame while one is on its way.
/// Encoded frames are never dropped, as each one is what the next is predicted from; when
/// sending falls behind (a keyframe takes many frames' time), `isBehind` says so and the
/// capture side skips frames before they are encoded instead.
final class MoonlightVideoSender {
    private let socket: MoonlightUDPSocket
    private let pingPayload: Data
    private let lock = NSLock()
    private var peer: sockaddr_in?
    private var running = true
    /// Only touched on `queue`.
    private var packetizer: MoonlightPacketizer
    /// Seals each packet, when the client turned on encrypted video; on `queue`.
    private var crypto: MoonlightVideoCrypto?
    private let start = DispatchTime.now().uptimeNanoseconds
    /// Nanoseconds each byte may take on the way out.
    private let nanosecondsPerByte: Double
    let stats = MoonlightStreamStats()
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).moonlight.video.send", qos: .userInteractive)
    /// Frames encoded and not yet sent, oldest first; the one being sent is not among them.
    private var waiting: [MoonlightVideoEncoder.Frame] = []
    /// Whether the sending thread is taking frames from `waiting`.
    private var sending = false

    /// Called on the ping thread when the first ping arrives.
    var onFirstPing: (() -> Void)?
    /// Called on the sending thread when a frame could not be sent, so the next can be a keyframe.
    var onFrameTooLarge: (() -> Void)?
    /// Called on the sending thread once a keyframe's last packet is out.
    var onKeyFrameSent: (() -> Void)?

    /// Parity for a fifth of each block's data, as Sunshine sends by default.
    static let fecPercentage = 20

    /// `key` seals every packet, for a client that turned on encrypted video.
    init(port: UInt16, pingPayload: String, packetSize: Int, minimumParity: Int, bitrateKbps: Int,
         key: Data? = nil) throws {
        socket = try MoonlightUDPSocket(port: port)
        // Six times the stream's rate, within 60 to 400 Mbit/s: a typical frame in a fraction
        // of a frame's time, a keyframe spread over a few frames'.
        let rate = Double(min(max(bitrateKbps * 6, 60_000), 400_000)) * 1000
        nanosecondsPerByte = 8e9 / rate
        self.pingPayload = Data(pingPayload.utf8)
        packetizer = MoonlightPacketizer(packetSize: packetSize, fecPercentage: Self.fecPercentage,
                                         minimumParity: minimumParity)
        crypto = key.map(MoonlightVideoCrypto.init(key:))
    }

    var hasPeer: Bool {
        lock.lock(); defer { lock.unlock() }
        return peer != nil
    }

    func startListening() {
        Thread.detachNewThread { [self] in
            Thread.current.name = "Moonlight video pings"
            while isRunning {
                guard let (data, from) = socket.receive(timeout: 0.25) else { continue }
                // A 16-byte payload and a counter, or "PING" from a client without one.
                guard data.prefix(16) == pingPayload || data == Data("PING".utf8) else { continue }
                lock.lock()
                let first = peer == nil
                peer = from
                lock.unlock()
                if first {
                    msLog.debug("video ping from \(Self.describe(from), privacy: .public)")
                    onFirstPing?()
                }
            }
            socket.close()
        }
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    /// Whether a frame is still waiting behind the one being sent: encoding another now would
    /// only make it later, so the caller had better skip it.
    var isBehind: Bool {
        lock.lock(); defer { lock.unlock() }
        return !waiting.isEmpty
    }

    /// Queues `frame` for the sending thread and returns at once.
    func send(_ frame: MoonlightVideoEncoder.Frame) {
        lock.lock()
        guard peer != nil, running else { lock.unlock(); return }
        waiting.append(frame)
        let start = !sending
        sending = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    /// Sends frames from `waiting` until it is empty.
    private func drain() {
        while true {
            lock.lock()
            guard running, let peer, !waiting.isEmpty else {
                sending = false
                lock.unlock()
                return
            }
            let frame = waiting.removeFirst()
            lock.unlock()
            sendNow(frame, to: peer)
        }
    }

    /// Packetizes and sends one frame, paced.
    private func sendNow(_ frame: MoonlightVideoEncoder.Frame, to peer: sockaddr_in) {
        let now = DispatchTime.now().uptimeNanoseconds
        let timestamp = UInt32(truncatingIfNeeded: (frame.submitted - start) * 9 / 100_000)
        let latency = UInt16(min((now - frame.submitted) / 100_000, UInt64(UInt16.max)))
        guard let blocks = packetizer.blocks(for: frame.data, isKeyFrame: frame.isKeyFrame,
                                             timestamp: timestamp, latency: latency) else {
            msLog.error("frame of \(frame.data.count) bytes too large to send")
            onFrameTooLarge?()
            return
        }
        // Each block's data, then its parity, worked out only once the data is on its way:
        // Moonlight needs the parity only when data was lost, and gives up on a block once
        // the next one starts.
        let began = DispatchTime.now().uptimeNanoseconds
        var bytes = 0, packets = 0, refused = 0
        func send(_ plain: Data) {
            // Sealed last, after parity was worked out over the plain packets.
            guard let packet = crypto == nil ? plain : crypto?.seal(plain) else { refused += 1; return }
            // Paced: wait until this packet's share of the rate is due.
            let due = began + UInt64(Double(bytes) * nanosecondsPerByte)
            let now = DispatchTime.now().uptimeNanoseconds
            if due > now + 50_000 { usleep(useconds_t((due - now) / 1000)) }
            if !socket.send(packet, to: peer) { refused += 1 }
            bytes += packet.count
            packets += 1
        }
        for block in blocks {
            for packet in block.packets { send(packet) }
            for packet in MoonlightPacketizer.parity(for: block) { send(packet) }
        }
        stats.video(packets: packets, bytes: bytes, refused: refused, keyFrame: frame.isKeyFrame)
        if frame.isKeyFrame { onKeyFrameSent?() }
    }

    static func describe(_ address: sockaddr_in) -> String {
        var addr = address.sin_addr
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &text, socklen_t(INET_ADDRSTRLEN))
        return "\(String(cString: text)):\(UInt16(bigEndian: address.sin_port))"
    }
}

// MARK: - Audio

/// Learns where Moonlight wants sound from its pings, and sends it the Mac's sound as Opus,
/// one packet per packet's time. Capture hands sound over in pieces of about 20 ms, which
/// would reach Moonlight as bursts; Moonlight drops sound once more than 30 ms of it waits,
/// so packets go out evenly instead, from a line kept short: at most 40 ms, the oldest
/// dropped beyond that. While nothing is captured it sends encoded silence, so the first
/// half second Moonlight throws away at the start is silence, not sound.
final class MoonlightAudioSender {
    /// Encoding and sending happen here, captured sound and silence alike.
    let queue = DispatchQueue(label: "\(AppIdentity.bundleID).moonlight.audio", qos: .userInteractive)
    private let socket: MoonlightUDPSocket
    private let pingPayload: Data
    private let lock = NSLock()
    private var peer: sockaddr_in?
    private var running = true
    private var encoder: MoonlightAudioEncoder?
    private var packetizer: MoonlightAudioPacketizer
    private let packetDuration: Int
    private var lastCaptured: UInt64 = 0
    /// Encoded packets waiting for their turn; on `queue`.
    private var waiting: [Data] = []
    private static let maxWaiting = 8
    private var pacer: DispatchSourceTimer?
    private let stats: MoonlightStreamStats

    init(port: UInt16, pingPayload: String, config: MoonlightStreamConfig, key: Data, keyID: UInt32,
         stats: MoonlightStreamStats) throws {
        socket = try MoonlightUDPSocket(port: port)
        self.stats = stats
        self.pingPayload = Data(pingPayload.utf8)
        packetDuration = config.audioPacketDuration
        packetizer = MoonlightAudioPacketizer(packetDuration: config.audioPacketDuration,
                                              key: config.audioEncrypted ? key : nil, keyID: keyID)
        // Sunshine's stereo rates: 512 kbit/s when Moonlight allows high quality, else 96.
        encoder = try MoonlightAudioEncoder(packetDuration: config.audioPacketDuration,
                                            bitrate: config.highQualityAudio ? 512_000 : 96_000) { [weak self] opus in
            guard let self else { return }
            self.waiting.append(opus)
            if self.waiting.count > Self.maxWaiting { self.waiting.removeFirst() }
        }
    }

    func startListening() {
        Thread.detachNewThread { [self] in
            Thread.current.name = "Moonlight audio pings"
            while isRunning {
                guard let (data, from) = socket.receive(timeout: 0.25) else { continue }
                guard data.prefix(16) == pingPayload || data == Data("PING".utf8) else { continue }
                lock.lock()
                let first = peer == nil
                peer = from
                lock.unlock()
                if first {
                    msLog.debug("audio ping from \(MoonlightVideoSender.describe(from), privacy: .public)")
                    queue.async { self.startPacing() }
                }
            }
            socket.close()
        }
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        queue.async { [self] in
            pacer?.cancel()
            pacer = nil
        }
    }

    /// Takes a piece of captured sound; on `queue`.
    func encode(_ sample: CMSampleBuffer) {
        lastCaptured = DispatchTime.now().uptimeNanoseconds
        encoder?.encode(sample)
    }

    /// Every packet's time, sends the next packet waiting; with nothing captured for a while,
    /// a packet of silence. Captured sound arrives about 20 ms apart, so it waits longer than that.
    private func startPacing() {
        let silence = [Float](repeating: 0, count: MoonlightAudioEncoder.sampleRate * packetDuration / 1000 * 2)
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(packetDuration), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.waiting.isEmpty, DispatchTime.now().uptimeNanoseconds - self.lastCaptured > 100_000_000 {
                silence.withUnsafeBufferPointer { self.encoder?.encode(interleaved: $0) }
            }
            guard !self.waiting.isEmpty else { return }
            self.send(self.waiting.removeFirst())
        }
        pacer = timer
        timer.resume()
    }

    /// Packs and sends one Opus packet, and its block's parity after every fourth.
    private func send(_ opus: Data) {
        lock.lock()
        let peer = self.peer
        lock.unlock()
        guard let peer, let packets = packetizer.packets(for: opus) else { return }
        let refused = packets.filter { !socket.send($0, to: peer) }.count
        stats.audio(packets: packets.count, refused: refused)
    }
}

// MARK: - Control

/// The control stream: an ENet host Moonlight connects to with the session's token, and
/// encrypted messages over it. All ENet calls happen on its one thread.
final class MoonlightControlServer {
    /// Moonlight's message types this host acts on.
    static let requestKeyFrame: UInt16 = 0x0302
    static let invalidateReferenceFrames: UInt16 = 0x0301
    static let termination: UInt16 = 0x0109
    /// "Server terminated, closed", which Moonlight shows as a normal end.
    static let gracefulReason: UInt32 = 0x8003_0023

    private static let initialized: Bool = enet_initialize() == 0

    private let host: UnsafeMutablePointer<ENetHost>
    private let key: SymmetricKey
    private let connectData: UInt32
    private let lock = NSLock()
    private var stopRequested = false
    private var peer: UnsafeMutablePointer<ENetPeer>?
    private var sequence: UInt32 = 0

    /// Called on the control thread when Moonlight asks for a keyframe, with its round trip
    /// time as ENet measures it (mean plus twice the variance), in nanoseconds.
    var onKeyFrameRequest: ((UInt64) -> Void)?
    /// Called on the control thread when Moonlight reports a frame that needed parity.
    var onFrameStatus: ((MoonlightFrameFecStatus) -> Void)?
    /// Called on the control thread with each input message's payload (see MoonlightInput).
    var onInput: ((Data) -> Void)?
    /// Called on the control thread when Moonlight connects, and when it leaves.
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?

    init(port: UInt16, key: Data, connectData: UInt32) throws {
        guard Self.initialized else { throw MoonlightStreamError.enet }
        var address = ENetAddress(host: 0, port: port)
        // Moonlight opens 48 channels; 0 lets it have them all.
        guard let host = enet_host_create(&address, 4, 0, 0, 0) else { throw MoonlightStreamError.enet }
        self.host = host
        self.key = SymmetricKey(data: key)
        self.connectData = connectData
    }

    func start() {
        Thread.detachNewThread { [self] in
            Thread.current.name = "Moonlight control"
            var event = ENetEvent()
            while !isStopRequested {
                if enet_host_service(host, &event, 10) > 0 { handle(event) }
            }
            if let peer {
                sendTermination(to: peer)
                enet_peer_disconnect_later(peer, 0)
                // Long enough to deliver the termination and disconnect.
                let deadline = DispatchTime.now().uptimeNanoseconds + 300_000_000
                while DispatchTime.now().uptimeNanoseconds < deadline, enet_host_service(host, &event, 10) >= 0 {
                    if event.type == ENET_EVENT_TYPE_RECEIVE { enet_packet_destroy(event.packet) }
                    if event.type == ENET_EVENT_TYPE_DISCONNECT { break }
                }
            }
            enet_host_destroy(host)
        }
    }

    /// Ends the session: Moonlight is told the host closed it, then disconnected.
    func stop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
    }

    private var isStopRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopRequested
    }

    private func handle(_ event: ENetEvent) {
        switch event.type {
        case ENET_EVENT_TYPE_CONNECT:
            guard peer == nil, event.data == connectData else {
                msLog.error("control: refusing a connection with token \(event.data)")
                return enet_peer_disconnect_now(event.peer, 0)
            }
            peer = event.peer
            msLog.debug("control: connected")
            onConnect?()
        case ENET_EVENT_TYPE_RECEIVE:
            let data = Data(bytes: event.packet.pointee.data, count: Int(event.packet.pointee.dataLength))
            enet_packet_destroy(event.packet)
            guard event.peer == peer, let message = MoonlightControlCrypto.open(data, key: key) else { return }
            if message.type == Self.requestKeyFrame || message.type == Self.invalidateReferenceFrames {
                let peer = event.peer.pointee
                onKeyFrameRequest?(UInt64(peer.roundTripTime + 2 * peer.roundTripTimeVariance) * 1_000_000)
            } else if message.type == MoonlightFrameFecStatus.messageType,
                      let status = MoonlightFrameFecStatus(payload: message.payload) {
                onFrameStatus?(status)
            } else if message.type == MoonlightInput.messageType {
                onInput?(message.payload)
            }
        case ENET_EVENT_TYPE_DISCONNECT:
            guard event.peer == peer else { return }
            peer = nil
            msLog.debug("control: disconnected")
            onDisconnect?()
        default:
            break
        }
    }

    private func sendTermination(to peer: UnsafeMutablePointer<ENetPeer>) {
        var reason = Data()
        reason.append(bigEndian: Self.gracefulReason)
        guard let sealed = try? MoonlightControlCrypto.seal(type: Self.termination, payload: reason,
                                                            sequence: sequence, key: key) else { return }
        sequence += 1
        sealed.withUnsafeBytes { bytes in
            let packet = enet_packet_create(bytes.baseAddress, sealed.count, ENET_PACKET_FLAG_RELIABLE.rawValue)
            enet_peer_send(peer, 0, packet)
        }
        enet_host_flush(host)
    }
}

// MARK: - Session

/// When Moonlight's video goes encrypted, for clients that can take it so (Moonlight on a
/// Mac, PC, iPhone or iPad, and Android with fast AES). Control and audio always are.
enum MoonlightVideoEncryption: String, CaseIterable {
    /// For clients outside the Mac's own networks, as Sunshine does by default.
    case offLocalNetwork
    case always
    case never

    var title: String {
        switch self {
        case .offLocalNetwork: return "Off the Local Network"
        case .always: return "Always"
        case .never: return "Never"
        }
    }

    var summary: String {
        switch self {
        case .offLocalNetwork:
            return "Encrypts video for devices outside this Mac's own networks, such as over the internet or a VPN."
        case .always: return "Encrypts video for every device, at a little more work for each."
        case .never: return "Sends video unencrypted; anyone who can see the network traffic can watch."
        }
    }

    /// Whether to offer it to a client at `peer`.
    func offers(to peer: NWEndpoint?) -> Bool {
        switch self {
        case .offLocalNetwork: return !LocalNetwork.contains(peer)
        case .always: return true
        case .never: return false
        }
    }
}

/// A stream from one display to one Moonlight client.
final class MoonlightStream {
    static let videoPort: UInt16 = 47998
    static let controlPort: UInt16 = 47999
    static let audioPort: UInt16 = 48000

    /// A stream's UDP ports, GameStream's for the first session and a hundred further on
    /// for each other one; Moonlight takes them from the RTSP SETUP replies.
    struct Ports: Equatable {
        let video: UInt16
        let control: UInt16
        let audio: UInt16

        init(slot: Int) {
            let offset = UInt16(slot * 100)
            video = MoonlightStream.videoPort + offset
            control = MoonlightStream.controlPort + offset
            audio = MoonlightStream.audioPort + offset
        }
    }

    private static let adaptsBitrateKey = "\(AppIdentity.shortID).moonlight.adaptiveBitrate"
    private static let showsPointerKey = "\(AppIdentity.shortID).moonlight.showsPointer"
    private static let videoEncryptionKey = "\(AppIdentity.shortID).moonlight.videoEncryption"

    /// When video goes encrypted; from the next launch.
    static var videoEncryption: MoonlightVideoEncryption {
        get { UserDefaults.dam.string(forKey: videoEncryptionKey).flatMap(MoonlightVideoEncryption.init(rawValue:))
              ?? .offLocalNetwork }
        set { UserDefaults.dam.set(newValue.rawValue, forKey: videoEncryptionKey) }
    }

    /// Whether streams lower their bitrate when the client loses packets, and raise it back.
    static var adaptsBitrate: Bool {
        get { UserDefaults.dam.object(forKey: adaptsBitrateKey) as? Bool ?? true }
        set { UserDefaults.dam.set(newValue, forKey: adaptsBitrateKey) }
    }

    /// Whether streams, Moonlight's and the browser's, show the pointer; from the next stream.
    static var showsPointer: Bool {
        get { UserDefaults.dam.object(forKey: showsPointerKey) as? Bool ?? true }
        set { UserDefaults.dam.set(newValue, forKey: showsPointerKey) }
    }

    let config: MoonlightStreamConfig
    let displayID: CGDirectDisplayID
    private let video: MoonlightVideoSender
    private let control: MoonlightControlServer
    private let audio: MoonlightAudioSender
    private let input: MoonlightInputInjector
    private let lock = NSLock()
    private var encoder: MoonlightVideoEncoder?
    private var capture: SharedScreenCapture.Subscription?
    private var lastFrame: (buffer: CVPixelBuffer, time: CMTime, at: UInt64)?
    private var repeater: DispatchSourceTimer?
    private var ended = false
    private var inputAllowed: Bool
    private var keyFrames = MoonlightKeyFrameRequests()
    /// The bitrate, set from the client's losses; nil when `adaptsBitrate` is off, for the
    /// client's bitrate throughout.
    private var bitrate: MoonlightBitrateGovernor?
    private var bitrateTimer: DispatchSourceTimer?

    /// Called once on the main queue when the stream ends on its own, with why.
    var onEnd: ((String) -> Void)?
    /// Keeps macOS from throttling DAM (App Nap) and the Mac from sleeping while streaming:
    /// DAM shows no window, and the stream's threads and timers must keep time.
    private var activity: NSObjectProtocol?
    private var statsTimer: DispatchSourceTimer?

    init(config: MoonlightStreamConfig, displayID: CGDirectDisplayID, key: Data, keyID: UInt32,
         pingPayload: String, connectData: UInt32, ports: Ports = Ports(slot: 0), allowsInput: Bool = true) throws {
        self.config = config
        self.displayID = displayID
        inputAllowed = allowsInput
        input = MoonlightInputInjector(displayID: displayID, streamWidth: config.width, streamHeight: config.height)
        video = try MoonlightVideoSender(port: ports.video, pingPayload: pingPayload, packetSize: config.packetSize,
                                         minimumParity: config.minimumParity, bitrateKbps: config.bitrateKbps,
                                         key: config.videoEncrypted ? key : nil)
        control = try MoonlightControlServer(port: ports.control, key: key, connectData: connectData)
        audio = try MoonlightAudioSender(port: ports.audio, pingPayload: pingPayload, config: config,
                                         key: key, keyID: keyID, stats: video.stats)
    }

    func start() {
        control.onKeyFrameRequest = { [weak self] roundTrip in
            guard let self else { return }
            // Covered or not, each request is a frame the client lost.
            self.lock.lock()
            self.bitrate?.keyFrameRequested()
            self.lock.unlock()
            let covered = self.sendKeyFrame(roundTrip: roundTrip) == .covered
            self.video.stats.keyFrameRequested(covered: covered)
        }
        video.onKeyFrameSent = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.keyFrames.keyFrameSent(at: DispatchTime.now().uptimeNanoseconds)
            self.lock.unlock()
        }
        control.onFrameStatus = { [weak self] status in
            guard let self else { return }
            self.video.stats.frameStatus(status)
            if status.isLost {
                msLog.debug("lost frame \(status.frameIndex): \(status.receivedData)+\(status.receivedParity) of \(status.dataPackets) data and \(status.parityPackets) parity packets")
            }
            self.lock.lock()
            self.bitrate?.frameStatus(status)
            self.lock.unlock()
        }
        startAdaptingBitrate()
        // What went out and what went wrong, every 5 seconds.
        let stats = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        stats.schedule(deadline: .now() + 5, repeating: 5)
        stats.setEventHandler { [weak self] in
            guard let self else { return }
            msLog.debug("stats: \(self.video.stats.take(seconds: 5), privacy: .public)")
        }
        statsTimer = stats
        stats.resume()
        control.onInput = { [weak self] payload in
            guard let self, self.allowsInput else { return }
            self.input.handle(MoonlightInput.parse(payload))
        }
        control.onDisconnect = { [weak self] in self?.end("Moonlight disconnected") }
        video.onFirstPing = { [weak self] in self?.startPicture() }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "Streaming to Moonlight")
        control.start()
        video.startListening()
        audio.startListening()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.video.hasPeer else { return }
            self.end("Moonlight never asked for video")
        }
        msLog.debug("stream \(self.config.width)×\(self.config.height)@\(self.config.fps) from display \(self.displayID), video \(self.config.videoEncrypted ? "encrypted" : "plain", privacy: .public)")
    }

    /// Whether the client's mouse, keyboard and text reach the Mac; turned off, whatever
    /// it holds down is let go.
    var allowsInput: Bool {
        get { lock.lock(); defer { lock.unlock() }; return inputAllowed }
        set {
            lock.lock()
            inputAllowed = newValue
            lock.unlock()
            if !newValue { input.releaseAll() }
        }
    }

    /// Stops everything; Moonlight is told the host ended the stream.
    func stop() {
        lock.lock()
        ended = true
        let capture = self.capture
        self.capture = nil
        repeater?.cancel()
        repeater = nil
        lock.unlock()
        capture?.cancel()
        input.close()
        control.stop()
        video.stop()
        audio.stop()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        statsTimer?.cancel()
        statsTimer = nil
        bitrateTimer?.cancel()
        bitrateTimer = nil
    }

    /// Each second, sets the encoder's bitrate from the client's losses (see
    /// MoonlightBitrateGovernor).
    private func startAdaptingBitrate() {
        guard Self.adaptsBitrate else { return }
        bitrate = MoonlightBitrateGovernor(kbps: config.bitrateKbps)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let was = self.bitrate?.current
            let kbps = self.bitrate?.second()
            let encoder = self.encoder
            self.lock.unlock()
            guard let kbps, let was else { return }
            msLog.debug("bitrate \(was) → \(kbps) kbps")
            encoder?.setBitrate(kbps: kbps)
        }
        bitrateTimer = timer
        timer.resume()
    }

    private func end(_ reason: String) {
        lock.lock()
        let first = !ended
        lock.unlock()
        guard first else { return }
        msLog.debug("stream ended: \(reason, privacy: .public)")
        stop()
        DispatchQueue.main.async { self.onEnd?(reason) }
    }

    /// Starts capturing and encoding once Moonlight is listening for video.
    private func startPicture() {
        do {
            let encoder = try MoonlightVideoEncoder(
                settings: .init(width: config.width, height: config.height, fps: config.fps,
                                bitrateKbps: config.bitrateKbps, lowLatency: config.lowLatency)) { [weak self] frame in
                self?.video.send(frame)
            }
            video.onFrameTooLarge = { [weak self] in self?.sendKeyFrame(roundTrip: nil) }
            // What the Mac plays, as it plays it; where it plays is left alone.
            let audio = self.audio
            let key = SharedScreenCapture.Key(displayID: displayID, width: config.width, height: config.height,
                                              fps: config.fps, showsCursor: Self.showsPointer)
            lock.lock()
            self.encoder = encoder
            lock.unlock()
            let capture = SharedScreenCapture.subscribe(key, frame: { [weak self] buffer, time in
                guard let self else { return }
                self.lock.lock()
                self.lastFrame = (buffer, time, DispatchTime.now().uptimeNanoseconds)
                self.lock.unlock()
                // Encoded while a keyframe is still going out, this frame would only wait
                // behind it; it is kept as the last picture and left out instead.
                guard !self.video.isBehind else { return }
                encoder.encode(buffer, at: time)
            }, audio: { sample in
                audio.queue.async { audio.encode(sample) }
            }, started: { [weak self] error in
                guard let error else { return }
                switch error {
                case MoonlightCaptureError.serviceNotAnswering:
                    self?.end("macOS's screen capture service is not answering")
                case is MoonlightCaptureError:
                    self?.end("\(AppIdentity.name) may not record the screen")
                default:
                    self?.end("Capture failed: \(error.localizedDescription)")
                }
            })
            lock.lock()
            let ended = self.ended
            if !ended { self.capture = capture }
            lock.unlock()
            // Stopped while subscribing: let go at once.
            if ended { capture.cancel() }
            // Capture can start and still send nothing; say so rather than leave Moonlight
            // waiting for video that will not come. Allows for capture restarting replayd.
            let wait = 5 + MoonlightScreenCapture.answerTimeout + 1
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let captured = self.lastFrame != nil
                self.lock.unlock()
                if !captured { self.end("Screen capture did not start") }
            }
            startRepeating()
        } catch {
            end("The encoder could not start")
        }
    }

    /// The next frame as a keyframe, made from the last picture at once when the screen is
    /// still and no new frame would come; no more than one a quarter second, and none for a
    /// request a keyframe on its way answers (see MoonlightKeyFrameRequests). `roundTrip` is
    /// the client's for its requests, nil for the host's own.
    @discardableResult
    private func sendKeyFrame(roundTrip: UInt64?) -> MoonlightKeyFrameRequests.Decision {
        lock.lock()
        let decision = keyFrames.request(at: DispatchTime.now().uptimeNanoseconds, roundTrip: roundTrip)
        switch decision {
        case .now:
            break
        case .later(let wait):
            lock.unlock()
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .nanoseconds(Int(wait))) {
                [weak self] in self?.sendKeyFrame(roundTrip: roundTrip)
            }
            return decision
        case .alreadyDue, .covered:
            lock.unlock()
            return decision
        }
        let encoder = self.encoder
        let last = lastFrame
        lock.unlock()
        encoder?.requestKeyFrame()
        if let last { encoder?.encode(last.buffer, at: last.time) }
        return decision
    }

    /// Sends the last picture again while the screen is still, at most every half second,
    /// so the client's decoder never idles for long.
    private func startRepeating() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let encoder = self.encoder
            let last = self.lastFrame
            self.lock.unlock()
            guard let last, DispatchTime.now().uptimeNanoseconds - last.at > 500_000_000 else { return }
            let time = CMTimeAdd(last.time, CMTime(value: Int64(DispatchTime.now().uptimeNanoseconds - last.at),
                                                   timescale: 1_000_000_000))
            encoder?.encode(last.buffer, at: time)
        }
        lock.lock()
        repeater = timer
        lock.unlock()
        timer.resume()
    }
}
