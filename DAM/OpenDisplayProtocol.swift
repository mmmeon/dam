//
//  OpenDisplayProtocol.swift
//  DAM
//
//  The OpenDisplay wire protocol, pv 3, from the sender's side: what crosses the socket
//  between DAM and an OpenDisplay receiver (its iPhone, iPad and Mac apps). Written from
//  the published specification (PROTOCOL.md in peetzweg/opendisplay), not from its code.
//
//  Every message is a 4-byte big-endian length and its payload. The receiver sends JSON
//  control messages only; the sender sends JSON control messages and H.264 Annex B video
//  frames on the same connection, told apart by the receiver (a payload under 32768 bytes
//  that starts with `{` and has no NUL is JSON).
//

import CoreGraphics
import Foundation

enum OpenDisplayWire {
    /// The TCP port receivers listen on, over WiFi and through usbmuxd.
    static let port: UInt16 = 9000
    /// The Bonjour type receivers advertise (from the project's first name).
    static let serviceType = "_opensidecar._tcp"
    /// The protocol version DAM speaks, and the oldest receiver's it takes.
    static let protocolVersion = 3
    static let oldestReceiver = 1
    /// A receiver's payload is shorter than this; a longer one, or none, breaks the stream.
    static let maxReceiverPayload = 1 << 20
    /// A control message is shorter than this, or the receiver takes it for video.
    static let maxControlPayload = 32768
    /// Seconds without a byte after which a link is dead, and between pings.
    static let silenceLimit: TimeInterval = 5
    static let pingInterval: TimeInterval = 2

    /// `payload` with its length before it.
    static func framed(_ payload: Data) -> Data {
        var out = Data(capacity: payload.count + 4)
        let n = UInt32(payload.count)
        out.append(contentsOf: [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
        out.append(payload)
        return out
    }

    /// A control message, framed; nil when it would not pass for one on the receiver's side.
    static func control(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object),
              let json = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              json.count < maxControlPayload, json.first == UInt8(ascii: "{"), !json.contains(0) else { return nil }
        return framed(json)
    }

    /// A video frame, framed: an Annex B access unit after the telemetry prefix, which gives
    /// the capture and send times in milliseconds since 1970.
    static func video(_ accessUnit: Data, capturedMs: Int64, sentMs: Int64) -> Data {
        var payload = Data("{\"cap\":\(capturedMs),\"snd\":\(sentMs)}".utf8)
        payload.append(accessUnit)
        return framed(payload)
    }

    /// Milliseconds since 1970, now.
    static func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
}

/// Splits what comes off the socket into payloads, however the reads cut them.
struct OpenDisplayDeframer {
    private var buffer = Data()

    /// The whole payloads `data` completes, or nil once the stream is broken: a length of 0,
    /// or one too long for a receiver's message.
    mutating func append(_ data: Data) -> [Data]? {
        buffer.append(data)
        var payloads: [Data] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start..<(start + 4)].reduce(0) { $0 << 8 | Int($1) }
            guard length > 0, length < OpenDisplayWire.maxReceiverPayload else { return nil }
            guard buffer.count >= 4 + length else { break }
            payloads.append(Data(buffer[(start + 4)..<(start + 4 + length)]))
            buffer.removeSubrange(start..<(start + 4 + length))
        }
        return payloads
    }
}

/// What a receiver says about itself and its panel; sent first, and again when it turns.
struct OpenDisplayHello: Equatable {
    /// Facts about the panel, in its current orientation.
    struct Panel: Equatable {
        var pixelsWide: Int
        var pixelsHigh: Int
        var scale: Double
        var pointsWide: Int?
        var pointsHigh: Int?
    }

    /// The receiver's stable ID, which its Bonjour TXT record also carries.
    var id: String?
    /// "iPhone" or "iPad" from the official receiver.
    var device: String?
    /// Its protocol version; 1 when it gives none.
    var pv = 1
    var panel: Panel?
    /// The deprecated size: pixels of a 2x desktop.
    var pixelsWide = 0
    var pixelsHigh = 0
    var displayMaxFrameRate: Int?
    /// The largest H.264 stream it decodes at frame rate.
    var maxEncodeWide: Int?
    var maxEncodeHigh: Int?
    /// Its H.264 envelopes from `videoCaps`: largest size and rate.
    var h264Caps: [(maxWidth: Int?, maxHeight: Int?, maxFrameRate: Int?)] = []
    /// The UDP port it takes pointer positions on, while it listens there.
    var cursorPort: UInt16?

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.device == b.device && a.pv == b.pv && a.panel == b.panel
            && a.pixelsWide == b.pixelsWide && a.pixelsHigh == b.pixelsHigh
            && a.displayMaxFrameRate == b.displayMaxFrameRate
            && a.maxEncodeWide == b.maxEncodeWide && a.maxEncodeHigh == b.maxEncodeHigh && a.cursorPort == b.cursorPort
            && a.h264Caps.count == b.h264Caps.count
            && zip(a.h264Caps, b.h264Caps).allSatisfy { $0 == $1 }
    }

    init(json: [String: Any]) {
        func int(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
            return number.intValue
        }
        id = (json["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        device = json["device"] as? String
        pv = int(json["pv"]) ?? 1
        pixelsWide = int(json["pixelsWide"]) ?? 0
        pixelsHigh = int(json["pixelsHigh"]) ?? 0
        displayMaxFrameRate = int(json["displayMaxFrameRate"]).flatMap { $0 > 0 ? $0 : nil }
        maxEncodeWide = int(json["maxEncodeWide"]).flatMap { $0 > 0 ? $0 : nil }
        maxEncodeHigh = int(json["maxEncodeHigh"]).flatMap { $0 > 0 ? $0 : nil }
        cursorPort = int(json["cursorPort"]).flatMap { (1...65535).contains($0) ? UInt16($0) : nil }
        if let caps = json["videoCaps"] as? [[String: Any]] {
            h264Caps = caps.filter { ($0["codec"] as? String)?.lowercased() == "h264" }.map {
                (int($0["maxWidth"]), int($0["maxHeight"]), int($0["maxFrameRate"]))
            }
        }
        // Taken whole or not at all.
        if let p = json["panel"] as? [String: Any], let w = int(p["pixelsWide"]), let h = int(p["pixelsHigh"]),
           w >= 2, h >= 2, let scale = (p["scale"] as? NSNumber)?.doubleValue, scale.isFinite, scale > 0 {
            let pw = int(p["pointsWide"]), ph = int(p["pointsHigh"])
            if pw == nil && ph == nil {
                panel = Panel(pixelsWide: w, pixelsHigh: h, scale: scale)
            } else if let pw, let ph, pw >= 2, ph >= 2 {
                panel = Panel(pixelsWide: w, pixelsHigh: h, scale: scale, pointsWide: pw, pointsHigh: ph)
            }
        }
    }

    /// What DAM makes for it: the display's mode, and the stream's size and rate.
    struct Desktop: Equatable {
        var mode: StreamingDisplayModes.Mode
        var streamWidth: Int
        var streamHeight: Int
        var fps: Int
    }

    /// The desktop for this panel, as the official sender sizes it: a 2x desktop for a
    /// scale of 1.5 or more, of the receiver's points when it gives them, else half its
    /// pixels; at 1x, its pixels. A desktop too big for what the receiver decodes, or for
    /// `maxSide` (the encoder's and the display's limit), shrinks to fit, so capture stays
    /// 1:1; the stream is its pixels, scaled down to the panel's when they are more.
    /// Nil when it gives no usable size.
    func desktop(maxSide: Int = 4096, maxFPS: Int = 60) -> Desktop? {
        var width: Int, height: Int, hiDPI: Bool
        var panelPixels: (w: Int, h: Int)?
        if let panel {
            hiDPI = panel.scale >= 1.5
            if hiDPI {
                width = panel.pointsWide ?? panel.pixelsWide / 2
                height = panel.pointsHigh ?? panel.pixelsHigh / 2
            } else {
                width = panel.pointsWide ?? panel.pixelsWide
                height = panel.pointsHigh ?? panel.pixelsHigh
            }
            panelPixels = (panel.pixelsWide, panel.pixelsHigh)
        } else {
            guard pixelsWide >= 2, pixelsHigh >= 2 else { return nil }
            (width, height, hiDPI) = (pixelsWide / 2, pixelsHigh / 2, true)
        }
        guard width >= 2, height >= 2 else { return nil }
        let factor = hiDPI ? 2 : 1
        var limitW = maxSide, limitH = maxSide
        if let w = maxEncodeWide { limitW = min(limitW, w) }
        if let h = maxEncodeHigh { limitH = min(limitH, h) }
        var fps = min(displayMaxFrameRate ?? 60, maxFPS)
        // The roomiest H.264 envelope it offers.
        if let cap = h264Caps.max(by: { ($0.maxWidth ?? .max) * ($0.maxHeight ?? .max) < ($1.maxWidth ?? .max) * ($1.maxHeight ?? .max) }) {
            if let w = cap.maxWidth { limitW = min(limitW, w) }
            if let h = cap.maxHeight { limitH = min(limitH, h) }
            if let r = cap.maxFrameRate, r > 0 { fps = min(fps, r) }
        }
        /// `w` × `h` scaled down by `scale`, in steps of `step` (even, and halving evenly at 2x).
        func shrunk(_ w: Int, _ h: Int, by scale: Double, step: Int) -> (Int, Int) {
            (Int(Double(w) * scale) / step * step, Int(Double(h) * scale) / step * step)
        }
        let fit = min(1, Double(limitW) / Double(width * factor), Double(limitH) / Double(height * factor))
        (width, height) = fit < 1 ? shrunk(width, height, by: fit, step: 2) : (width - width % 2, height - height % 2)
        guard width >= 2, height >= 2 else { return nil }
        let mode = StreamingDisplayModes.Mode(width: width, height: height, refreshRate: fps, hiDPI: hiDPI)
        var streamW = mode.pixelWidth, streamH = mode.pixelHeight
        if let panelPixels {
            let scale = min(1, Double(panelPixels.w) / Double(streamW), Double(panelPixels.h) / Double(streamH))
            if scale < 1 { (streamW, streamH) = shrunk(streamW, streamH, by: scale, step: 2) }
        }
        guard streamW >= 2, streamH >= 2 else { return nil }
        return Desktop(mode: mode, streamWidth: streamW, streamHeight: streamH, fps: fps)
    }
}

/// A message from a receiver.
enum OpenDisplayMessage: Equatable {
    enum Phase: String { case began, moved, ended, cancelled }

    case hello(OpenDisplayHello)
    /// The receiver's clock, in milliseconds since 1970, to echo back.
    case ping(t: Double)
    /// A finger, at a normalized point of the video.
    case touch(Phase, x: Double, y: Double)
    /// Two fingers scrolling, in video pixels, content following them.
    case scroll(dx: Double, dy: Double)
    /// The stylus; "down", "move", "up" or "hover".
    case pencil(String, x: Double, y: Double)
    case keyFrame
    /// The first pointer datagram arrived.
    case cursorAck
    case sleeping
    case closing
    /// Telemetry, only for the log.
    case stats(String)
    /// A type this end doesn't act on.
    case other(String)

    /// The message in `payload`, or nil for one that isn't JSON or has no type.
    static func parse(_ payload: Data) -> OpenDisplayMessage? {
        guard let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let type = json["type"] as? String else { return nil }
        func number(_ key: String) -> Double? {
            (json[key] as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite ? $0 : nil }
        }
        switch type {
        case "hello":
            return .hello(OpenDisplayHello(json: json))
        case "ping":
            return number("t").map { .ping(t: $0) } ?? .other(type)
        case "touch":
            guard let phase = (json["phase"] as? String).flatMap(Phase.init(rawValue:)),
                  let x = number("x"), let y = number("y") else { return .other(type) }
            return .touch(phase, x: x, y: y)
        case "scroll":
            guard let dx = number("dx"), let dy = number("dy") else { return .other(type) }
            return .scroll(dx: dx, dy: dy)
        case "pencil":
            guard let phase = json["phase"] as? String, let x = number("x"), let y = number("y") else { return .other(type) }
            return .pencil(phase, x: x, y: y)
        case "kf":
            return .keyFrame
        case "cursorAck":
            return .cursorAck
        case "sleeping":
            return .sleeping
        case "closing":
            return .closing
        case "stats":
            let text = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return .stats(text)
        default:
            return .other(type)
        }
    }
}

/// The sender's messages.
enum OpenDisplayReply {
    static func welcome() -> Data? {
        OpenDisplayWire.control(["type": "welcome", "pv": OpenDisplayWire.protocolVersion, "min": OpenDisplayWire.oldestReceiver])
    }

    static func pong(t: Double) -> Data? {
        OpenDisplayWire.control(["type": "pong", "t": t, "mt": OpenDisplayWire.nowMs()])
    }

    static func ping(capFps: Double?, netDrops: Int) -> Data? {
        var object: [String: Any] = ["type": "ping", "netDrops": netDrops]
        if let capFps { object["capFps"] = (capFps * 10).rounded() / 10 }
        return OpenDisplayWire.control(object)
    }

    static func streamConfig(width: Int, height: Int, fps: Int) -> Data? {
        OpenDisplayWire.control(["type": "streamConfig", "codec": "h264", "width": width, "height": height,
                                 "framesPerSecond": fps])
    }

    /// The pointer at a normalized point of the video, or hidden with nil; with its number
    /// in the connection's sequence, which the receiver keeps rising across UDP and TCP.
    static func cursor(at point: CGPoint?, sequence: Int? = nil) -> Data? {
        OpenDisplayWire.control(cursorObject(point, sequence))
    }

    /// The same as a UDP datagram: the message alone, without its length.
    static func cursorDatagram(at point: CGPoint?, sequence: Int) -> Data? {
        let object = cursorObject(point, sequence)
        guard let json = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return json
    }

    private static func cursorObject(_ point: CGPoint?, _ sequence: Int?) -> [String: Any] {
        var object: [String: Any] = ["type": "cursor", "v": point == nil ? 0 : 1]
        if let point {
            func rounded(_ v: CGFloat) -> Double { (Double(v) * 10_000).rounded() / 10_000 }
            object["x"] = rounded(point.x)
            object["y"] = rounded(point.y)
        }
        if let sequence { object["s"] = sequence }
        return object
    }

    /// The pointer's picture: a PNG of at most 24000 bytes, its size as fractions of the
    /// display's, and its hot spot as fractions of its own.
    static func cursorImage(png: Data, size: CGSize, hotSpot: CGPoint) -> Data? {
        guard png.count <= 24000 else { return nil }
        return OpenDisplayWire.control(["type": "cursorImg", "png": png.base64EncodedString(),
                                        "nw": Double(size.width), "nh": Double(size.height),
                                        "ax": Double(hotSpot.x), "ay": Double(hotSpot.y)])
    }
}

/// A receiver's touches and scrolls as the mouse events DAM's injector posts.
enum OpenDisplayTouches {
    /// The grid the injector maps normalized points through.
    static let grid = 10_000

    static func events(for message: OpenDisplayMessage) -> [MoonlightInput] {
        func at(_ x: Double, _ y: Double) -> MoonlightInput {
            func clamp(_ v: Double) -> Int { Int((min(max(v, 0), 1) * Double(Self.grid - 1)).rounded()) }
            return .moveTo(x: clamp(x), y: clamp(y), width: Self.grid, height: Self.grid)
        }
        switch message {
        case let .touch(phase, x, y):
            switch phase {
            case .began: return [at(x, y), .button(1, down: true)]
            case .moved: return [at(x, y)]
            case .ended: return [at(x, y), .button(1, down: false)]
            case .cancelled: return [.button(1, down: false)]
            }
        case let .pencil(phase, x, y):
            // As a finger, the stylus hovering moving the pointer only.
            switch phase {
            case "down":
                return [at(x, y), .button(1, down: true)]
            case "up":
                return [at(x, y), .button(1, down: false)]
            default:
                return [at(x, y)]
            }
        default:
            return []
        }
    }
}
