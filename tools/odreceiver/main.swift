// A stand-in OpenDisplay receiver for testing DAM's sender, from PROTOCOL.md (pv 3):
// listens on TCP 9000, advertises _opensidecar._tcp with an id, sends an iPad's hello and
// pings, and checks what comes back. It decodes nothing; it reads the NAL units.
//
// Build (the binary is ignored by git):
//   swiftc -O -o tools/odreceiver/odreceiver tools/odreceiver/main.swift
//
//   tools/odreceiver/odreceiver [--seconds N] [--size WxH] [--id ID] [--touch] [--hover] [--no-udp] [--no-ack] [--no-close]
//
// --no-close drops the connection at the end without saying closing, as a cut cable does.
// --hover moves the Mac's pointer across the display (stylus hover: no clicks), to see
// pointer messages. The pointer goes over UDP to a port of its own unless --no-udp; --no-ack never
// acknowledges it, so the sender should fall back to TCP.
//
// --touch sends a tap in the middle of the display: it moves the Mac's pointer.

import Foundation
import Network

var seconds = 12.0, width = 2048, height = 1536, id = "dam-odreceiver-test", touch = false, noClose = false, hover = false, udp = true, ack = true
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--seconds": seconds = Double(args.popFirst() ?? "") ?? seconds
    case "--size":
        let parts = (args.popFirst() ?? "").split(separator: "x").compactMap { Int($0) }
        if parts.count == 2 { (width, height) = (parts[0], parts[1]) }
    case "--id": id = args.popFirst() ?? id
    case "--touch": touch = true
    case "--no-close": noClose = true
    case "--hover": hover = true
    case "--no-udp": udp = false
    case "--no-ack": ack = false
    default: print("unknown option \(arg)"); exit(2)
    }
}

func say(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
    print("\(f.string(from: Date())) \(s)"); fflush(stdout)
}
func framed(_ object: [String: Any]) -> Data {
    let json = try! JSONSerialization.data(withJSONObject: object)
    var out = Data(); let n = UInt32(json.count)
    out.append(contentsOf: [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
    out.append(json); return out
}
func nowMs() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }

var connection: NWConnection?
var buffer = Data()
var controls: [String: Int] = [:]
var order: [String] = []
var frames = 0, keyFrames = 0, bytes = 0, firstVideoIsIDR: Bool?
var streamConfig: [String: Any]?
var latencies: [Double] = []
var connectedAt: Date?
var problems: [String] = []
var kfAskedAt: Date?, kfAnswered: Double?
var udpCursors = 0, tcpCursors = 0, tcpCursorsAfterAck = 0, lastSeq = 0, seqProblems = 0, acked = false

func nalTypes(_ unit: Data) -> [UInt8] {
    var types: [UInt8] = []
    let b = [UInt8](unit); var i = 0
    while i + 4 < b.count {
        if b[i] == 0, b[i + 1] == 0, b[i + 2] == 0, b[i + 3] == 1 { types.append(b[i + 4] & 0x1F); i += 4 } else { i += 1 }
    }
    return types
}

func handle(_ payload: Data) {
    let isJSON = payload.count < 32768 && payload.first == UInt8(ascii: "{") && !payload.contains(0)
    if isJSON {
        guard let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let type = json["type"] as? String else { problems.append("a control message with no type"); return }
        controls[type, default: 0] += 1
        if order.count < 6 && !order.contains(type) { order.append(type) }
        if type == "streamConfig" { streamConfig = json; say("streamConfig \(json)") }
        if type == "welcome" { say("welcome \(json)") }
        if type == "pong", let t = json["t"] as? Double { latencies.append(nowMs() - t) }
        if type == "cursor" {
            tcpCursors += 1
            if acked { tcpCursorsAfterAck += 1 }
            if let seq = json["s"] as? Int { if seq > lastSeq { lastSeq = seq } }
        }
        return
    }
    // Video: the telemetry prefix, then Annex B.
    guard let start = payload.firstRange(of: Data([0, 0, 0, 1])) else { problems.append("a video frame with no start code"); return }
    if order.count < 6 && !order.contains("video") { order.append("video") }
    let unit = payload[start.lowerBound...]
    let types = nalTypes(Data(unit))
    let idr = types.contains(5)
    if firstVideoIsIDR == nil {
        firstVideoIsIDR = idr && types.contains(7) && types.contains(8)
        say("first frame: NAL types \(types), \(payload.count) bytes")
    }
    if idr && !(types.contains(7) && types.contains(8)) { problems.append("an IDR without SPS and PPS") }
    if idr {
        keyFrames += 1
        if let at = kfAskedAt, kfAnswered == nil { kfAnswered = Date().timeIntervalSince(at) * 1000 }
    }
    frames += 1; bytes += payload.count
}

func send(_ object: [String: Any]) { connection?.send(content: framed(object), completion: .idempotent) }

/// Connections that have yet to send a byte; one that does replaces the live one, as the
/// official receiver's newcomer rule has it (a dial racing addresses opens more than one).
var newcomers: [ObjectIdentifier: NWConnection] = [:]

func receive(_ c: NWConnection) {
    c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
        if let data, !data.isEmpty, newcomers.removeValue(forKey: ObjectIdentifier(c)) != nil {
            if connection !== c {
                connection?.cancel()
                connection = c
                buffer = Data()
                if connectedAt == nil { connectedAt = Date() }
                say("sender proved itself from \(c.endpoint)")
            }
        }
        guard connection === c else {
            if done || error != nil { newcomers[ObjectIdentifier(c)] = nil; return }
            return receive(c)
        }
        if let data {
            buffer.append(data)
            while buffer.count >= 4 {
                let n = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
                guard buffer.count >= 4 + n else { break }
                handle(Data(buffer.dropFirst(4).prefix(n)))
                buffer.removeFirst(4 + n)
            }
        }
        if done || error != nil { say("sender closed: \(error?.localizedDescription ?? "end of stream")"); return }
        receive(c)
    }
}

/// The UDP port pointer datagrams come to, a plain socket of its own each run (a socket left
/// on a shared port can take the datagrams).
var cursorPort: Int?
if udp {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = INADDR_ANY
    _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
    cursorPort = Int(UInt16(bigEndian: address.sin_port))
    Thread {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n < 0 && errno != EINTR { break }
            guard n > 0 else { continue }
            let data = Data(buffer[0..<n])
            DispatchQueue.main.async {
                guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      json["type"] as? String == "cursor", let seq = json["s"] as? Int else { return }
                udpCursors += 1
                if seq < lastSeq { seqProblems += 1 }
                lastSeq = max(lastSeq, seq)
                if !acked && ack {
                    acked = true
                    send(["type": "cursorAck"])
                    say("first pointer datagram (s=\(seq)); sent cursorAck")
                }
            }
        }
    }.start()
}

let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
let tcpParameters = NWParameters(tls: nil, tcp: tcp)
// IPv4 only: on the sender's own Mac, a dial would otherwise land on a link-local IPv6
// address of one of its interfaces, which carries TCP to itself but not UDP.
(tcpParameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
let listener = try! NWListener(using: tcpParameters, on: 9000)
listener.service = NWListener.Service(name: "DAM test receiver", type: "_opensidecar._tcp",
                                      txtRecord: NWTXTRecord(["id": id, "pv": "3"]))
listener.newConnectionHandler = { c in
    newcomers[ObjectIdentifier(c)] = c
    say("sender dialed from \(c.endpoint)")
    c.start(queue: .main)
    let hello = framed(["type": "hello", "pixelsWide": width, "pixelsHigh": height, "scale": 2, "device": "iPad", "id": id, "pv": 3,
          "panel": ["pixelsWide": width, "pixelsHigh": height, "scale": 2], "displayMaxFrameRate": 60]
        .merging(cursorPort.map { ["cursorPort": $0] } ?? [:]) { $1 })
    c.send(content: hello, completion: .idempotent)
    receive(c)
}
listener.stateUpdateHandler = { state in
    switch state {
    case .ready: say("listening on 9000 as \"DAM test receiver\" (id \(id))")
    case .failed(let e): say("listener failed: \(e)"); exit(1)
    default: break
    }
}
listener.start(queue: .main)

Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    guard connection != nil else { return }
    send(["type": "ping", "t": nowMs()])
}
var phase = 0
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
    guard let at = connectedAt else { return }
    let t = Date().timeIntervalSince(at)
    if phase == 0 && t > seconds * 0.5 {
        phase = 1; kfAskedAt = Date(); send(["type": "kf"]); say("asked for a keyframe")
        if hover {
            say("hovering across the display")
            for i in 0..<40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(i)) {
                    send(["type": "pencil", "phase": "hover", "x": 0.2 + 0.015 * Double(i), "y": 0.5,
                          "pressure": 0, "azimuth": 0, "altitude": 1.5, "rotation": 0])
                }
            }
        }
        if touch {
            send(["type": "touch", "phase": "began", "x": 0.5, "y": 0.5])
            send(["type": "touch", "phase": "ended", "x": 0.5, "y": 0.5])
            say("tapped the middle")
        }
    }
    if phase == 1 && t > seconds {
        phase = 2
        if noClose { say("dropping the connection") } else { send(["type": "closing"]); say("sent closing") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            connection?.cancel()
            let streamed = t
            print("""
            --- summary
            first messages: \(order.joined(separator: ", "))
            controls: \(controls.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
            video: \(frames) frames (\(String(format: "%.1f", Double(frames) / streamed)) fps), \(keyFrames) keyframes, \(bytes / 1024) KB (\(String(format: "%.1f", Double(bytes) * 8 / streamed / 1e6)) Mbit/s)
            first frame an IDR with SPS+PPS: \(firstVideoIsIDR.map(String.init) ?? "no video")
            streamConfig: \(streamConfig.map { "\($0["codec"] ?? "")" + " \($0["width"] ?? "")x\($0["height"] ?? "")@\($0["framesPerSecond"] ?? "")" } ?? "none")
            keyframe after kf: \(kfAnswered.map { String(format: "%.0f ms", $0) } ?? "none")
            ping round trip: \(latencies.isEmpty ? "none" : String(format: "%.1f ms median", latencies.sorted()[latencies.count / 2]))
            pointer: \(udpCursors) over UDP, \(tcpCursors) over TCP (\(tcpCursorsAfterAck) after the ack), highest s \(lastSeq), out of order \(seqProblems)
            problems: \(problems.isEmpty ? "none" : problems.joined(separator: "; "))
            """)
            exit(problems.isEmpty && firstVideoIsIDR == true ? 0 : 1)
        }
    }
}
Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in
    if connectedAt == nil { say("no sender connected within 60 s"); exit(1) }
}
RunLoop.main.run()
