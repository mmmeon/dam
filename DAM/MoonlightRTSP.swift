//
//  MoonlightRTSP.swift
//
//  The RTSP handshake Moonlight performs after launching an app: OPTIONS, DESCRIBE, three
//  SETUPs, ANNOUNCE with the stream's settings, and PLAY, each on a TCP connection of its
//  own that the host closes after replying, as that is how Moonlight finds the reply's end.
//  The host offers H.264, the encrypted control stream (v2), encrypted audio, and
//  encrypted video when the launch is to have it.
//

import Foundation
import Network
import os.log

private let rtLog = Logger(subsystem: AppIdentity.bundleID, category: "MoonlightRTSP")

/// An app launched from Moonlight, from /launch or /resume until /cancel.
struct MoonlightLaunch {
    let appID: Int
    let displayID: CGDirectDisplayID
    /// The session's AES key, from the launch request.
    let key: Data
    /// What the audio's IVs count from (rikeyid, sent signed).
    let keyID: UInt32
    /// Sixteen characters Moonlight echoes in its video and audio pings.
    let pingPayload: String
    /// The token Moonlight connects to the control stream with.
    let connectData: UInt32
    let sessionID: String
    /// Whether the display was made for this launch, and goes with it.
    let ownsDisplay: Bool
    /// Whether the device that launched it wants low-latency rate control.
    var lowLatency = false
    /// Whether encrypted video is offered; clients turn it on whenever it is.
    var offersEncryptedVideo = false

    init(appID: Int, displayID: CGDirectDisplayID, key: Data, keyID: UInt32 = 0, ownsDisplay: Bool = false) {
        self.appID = appID
        self.displayID = displayID
        self.key = key
        self.keyID = keyID
        self.ownsDisplay = ownsDisplay
        pingPayload = MoonlightCrypto.hex(MoonlightPairing.randomBytes(8))
        connectData = UInt32.random(in: 1...UInt32.max)
        sessionID = MoonlightCrypto.hex(MoonlightPairing.randomBytes(6))
    }
}

final class MoonlightRTSP {

    struct Request: Equatable {
        let method: String
        let target: String
        let headers: [String: String]
        let body: String
    }

    /// The launch the handshake is for; nil turns it away.
    var launch: () -> MoonlightLaunch? = { nil }
    /// Starts the stream ANNOUNCE describes; returns why it could not, or nil once started.
    var announce: (MoonlightLaunch, MoonlightStreamConfig) -> String? = { _, _ in "Not ready" }

    private var connections: [ObjectIdentifier: NWConnection] = [:]

    func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready: self.receive(on: connection, buffer: Data())
            case .failed: connection.cancel()
            case .cancelled: self.connections[ObjectIdentifier(connection)] = nil
            default: break
            }
        }
        connection.start(queue: .main)
    }

    func closeAll() {
        connections.values.forEach { $0.cancel() }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let buffer = buffer + (data ?? Data())
            if let request = Self.parse(buffer) {
                let reply = Self.response(to: request, launch: self.launch(), announce: self.announce)
                rtLog.debug("\(request.method, privacy: .public) \(request.target, privacy: .public) → \(reply.prefix(while: { $0 != "\r" }), privacy: .public)")
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            guard !isComplete, error == nil, buffer.count < 65536 else { return connection.cancel() }
            self.receive(on: connection, buffer: buffer)
        }
    }

    /// A whole request in `data`, nil while some of it has yet to come.
    static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["Content-length"] ?? headers["Content-Length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(first[0]), target: String(first[1]), headers: headers,
                       body: String(decoding: body.prefix(length), as: UTF8.self))
    }

    /// The reply to `request`. Moonlight needs at least one header in every reply, values
    /// after exactly one space, and a non-empty DESCRIBE body.
    static func response(to request: Request, launch: MoonlightLaunch?,
                         announce: (MoonlightLaunch, MoonlightStreamConfig) -> String?) -> String {
        let sequence = request.headers["CSeq"] ?? "0"
        func reply(_ status: String, _ headers: KeyValuePairs<String, String> = [:], body: String = "") -> String {
            var text = "RTSP/1.0 \(status)\r\nCSeq: \(sequence)\r\n"
            for (name, value) in headers { text += "\(name): \(value)\r\n" }
            return text + "\r\n" + body
        }
        guard let launch else { return reply("503 Service Unavailable") }
        let session = "\(launch.sessionID);timeout = 90"
        switch request.method {
        case "OPTIONS", "PLAY":
            return reply("200 OK")
        case "DESCRIBE":
            // No HEVC or AV1 markers, so H.264; control encryption v2 and audio encryption,
            // which Moonlight asks for regardless, and video encryption when offered. None
            // is required, so a client without fast AES may leave video plain.
            let supported = 0x05 | (launch.offersEncryptedVideo ? MoonlightVideoCrypto.encryptionBit : 0)
            return reply("200 OK", body: "a=x-ss-general.featureFlags:0\r\n" +
                                         "a=x-ss-general.encryptionSupported:\(supported)\r\n" +
                                         "a=x-ss-general.encryptionRequested:0\r\n")
        case "SETUP":
            let stream = request.target.split(separator: "=").dropFirst().first?.split(separator: "/").first ?? ""
            switch stream {
            case "audio":
                return reply("200 OK", ["Session": session, "Transport": "server_port=\(MoonlightStream.audioPort)",
                                        "X-SS-Ping-Payload": launch.pingPayload])
            case "video":
                return reply("200 OK", ["Session": session, "Transport": "server_port=\(MoonlightStream.videoPort)",
                                        "X-SS-Ping-Payload": launch.pingPayload])
            case "control":
                return reply("200 OK", ["Session": session, "Transport": "server_port=\(MoonlightStream.controlPort)",
                                        "X-SS-Connect-Data": "\(launch.connectData)"])
            default:
                return reply("404 Not Found")
            }
        case "ANNOUNCE":
            guard var config = MoonlightStreamConfig.parse(sdp: request.body) else { return reply("400 Bad Request") }
            // Moonlight names the host in Host only when stereo may be high quality.
            config.highQualityAudio = !(request.headers["Host"] ?? "0.0.0.0").contains("0.0.0.0")
            guard config.videoFormat == 0, !config.videoEncrypted || launch.offersEncryptedVideo else {
                return reply("400 Bad Request")
            }
            if let problem = announce(launch, config) {
                rtLog.error("announce: \(problem, privacy: .public)")
                return reply("500 Internal Server Error")
            }
            return reply("200 OK")
        default:
            return reply("404 Not Found")
        }
    }
}
