//
//  MoonlightStream.swift
//
//  One Moonlight session after its RTSP handshake: the screen captured, encoded and sent
//  as video packets to where Moonlight's pings come from, the control stream it connects
//  over ENet, and an audio port that stays quiet for now. Nothing waits in a queue: a frame
//  is packetized and sent on the encoder's thread the moment it is encoded.
//

import CoreMedia
import CryptoKit
import Foundation
import os.log

private let msLog = Logger(subsystem: AppIdentity.bundleID, category: "MoonlightStream")

enum MoonlightStreamError: Error {
    case socket(String, Int32)
    case enet
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

    func send(_ data: Data, to address: sockaddr_in) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        var to = address
        data.withUnsafeBytes { bytes in
            _ = withUnsafePointer(to: &to) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, bytes.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
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

/// Learns where Moonlight wants video from its pings, and sends frames there.
final class MoonlightVideoSender {
    private let socket: MoonlightUDPSocket
    private let pingPayload: Data
    private let lock = NSLock()
    private var peer: sockaddr_in?
    private var running = true
    private var packetizer: MoonlightPacketizer
    private let start = DispatchTime.now().uptimeNanoseconds

    /// Called on the ping thread when the first ping arrives.
    var onFirstPing: (() -> Void)?

    init(port: UInt16, pingPayload: String, packetSize: Int) throws {
        socket = try MoonlightUDPSocket(port: port)
        self.pingPayload = Data(pingPayload.utf8)
        packetizer = MoonlightPacketizer(packetSize: packetSize)
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

    /// Packetizes and sends `frame` now, on the caller's thread. Returns false when the
    /// frame was too large to send.
    @discardableResult
    func send(_ frame: MoonlightVideoEncoder.Frame) -> Bool {
        lock.lock()
        guard let peer else { lock.unlock(); return true }
        let now = DispatchTime.now().uptimeNanoseconds
        let timestamp = UInt32(truncatingIfNeeded: (frame.submitted - start) * 9 / 100_000)
        let latency = UInt16(min((now - frame.submitted) / 100_000, UInt64(UInt16.max)))
        let packets = packetizer.packets(for: frame.data, isKeyFrame: frame.isKeyFrame,
                                         timestamp: timestamp, latency: latency)
        lock.unlock()
        guard let packets else {
            msLog.error("frame of \(frame.data.count) bytes too large to send")
            return false
        }
        for packet in packets { socket.send(packet, to: peer) }
        return true
    }

    static func describe(_ address: sockaddr_in) -> String {
        var addr = address.sin_addr
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &text, socklen_t(INET_ADDRSTRLEN))
        return "\(String(cString: text)):\(UInt16(bigEndian: address.sin_port))"
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

    /// Called on the control thread when Moonlight asks for a keyframe.
    var onKeyFrameRequest: (() -> Void)?
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
                onKeyFrameRequest?()
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

/// A stream from one display to one Moonlight client.
final class MoonlightStream {
    static let videoPort: UInt16 = 47998
    static let controlPort: UInt16 = 47999
    static let audioPort: UInt16 = 48000

    let config: MoonlightStreamConfig
    let displayID: CGDirectDisplayID
    private let video: MoonlightVideoSender
    private let control: MoonlightControlServer
    private let audio: MoonlightUDPSocket
    private let lock = NSLock()
    private var encoder: MoonlightVideoEncoder?
    private var capture: MoonlightScreenCapture?
    private var lastFrame: (buffer: CVPixelBuffer, time: CMTime, at: UInt64)?
    private var repeater: DispatchSourceTimer?
    private var ended = false

    /// Called once on the main queue when the stream ends on its own, with why.
    var onEnd: ((String) -> Void)?

    init(config: MoonlightStreamConfig, displayID: CGDirectDisplayID, key: Data,
         pingPayload: String, connectData: UInt32) throws {
        self.config = config
        self.displayID = displayID
        video = try MoonlightVideoSender(port: Self.videoPort, pingPayload: pingPayload, packetSize: config.packetSize)
        control = try MoonlightControlServer(port: Self.controlPort, key: key, connectData: connectData)
        audio = try MoonlightUDPSocket(port: Self.audioPort)
    }

    func start() {
        control.onKeyFrameRequest = { [weak self] in self?.sendKeyFrame() }
        control.onDisconnect = { [weak self] in self?.end("Moonlight disconnected") }
        video.onFirstPing = { [weak self] in self?.startPicture() }
        control.start()
        video.startListening()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.video.hasPeer else { return }
            self.end("Moonlight never asked for video")
        }
        msLog.debug("stream \(self.config.width)×\(self.config.height)@\(self.config.fps) from display \(self.displayID)")
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
        capture?.stop()
        control.stop()
        video.stop()
        audio.close()
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
                                bitrateKbps: config.bitrateKbps)) { [weak self] frame in
                guard let self, !self.video.send(frame) else { return }
                self.sendKeyFrame()
            }
            let capture = MoonlightScreenCapture(displayID: displayID, width: config.width, height: config.height,
                                                 fps: config.fps) { [weak self] buffer, time in
                guard let self else { return }
                self.lock.lock()
                self.lastFrame = (buffer, time, DispatchTime.now().uptimeNanoseconds)
                self.lock.unlock()
                encoder.encode(buffer, at: time)
            }
            lock.lock()
            self.encoder = encoder
            self.capture = capture
            lock.unlock()
            capture.start { [weak self] error in
                guard let error else { return }
                self?.end(error is MoonlightCaptureError ? "\(AppIdentity.name) may not record the screen"
                                                         : "Capture failed: \(error.localizedDescription)")
            }
            startRepeating()
        } catch {
            end("The encoder could not start")
        }
    }

    /// The next frame as a keyframe, made from the last picture at once when the screen is
    /// still and no new frame would come.
    private func sendKeyFrame() {
        lock.lock()
        let encoder = self.encoder
        let last = lastFrame
        lock.unlock()
        encoder?.requestKeyFrame()
        if let last { encoder?.encode(last.buffer, at: last.time) }
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
