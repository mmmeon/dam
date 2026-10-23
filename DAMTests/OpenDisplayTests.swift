//
//  OpenDisplayTests.swift
//  DAMTests
//

import AppKit
import Network
import XCTest
@testable import DAM

final class OpenDisplayTests: XCTestCase {

    // MARK: Framing

    func testFramesCarryTheirLengthBigEndian() {
        XCTAssertEqual([UInt8](OpenDisplayWire.framed(Data([1, 2, 3]))), [0, 0, 0, 3, 1, 2, 3])
        XCTAssertEqual([UInt8](OpenDisplayWire.framed(Data(count: 300)).prefix(4)), [0, 0, 1, 44])
    }

    func testDeframerReassemblesSplitAndPackedFrames() {
        var deframer = OpenDisplayDeframer()
        let a = OpenDisplayWire.framed(Data("{\"type\":\"kf\"}".utf8))
        let b = OpenDisplayWire.framed(Data("{\"type\":\"ping\",\"t\":5}".utf8))
        let both = a + b
        XCTAssertEqual(deframer.append(both.prefix(3)), [])
        XCTAssertEqual(deframer.append(both.dropFirst(3).prefix(a.count)), [Data("{\"type\":\"kf\"}".utf8)])
        XCTAssertEqual(deframer.append(both.dropFirst(3 + a.count)), [Data("{\"type\":\"ping\",\"t\":5}".utf8)])
    }

    func testDeframerRefusesEmptyAndOversizedFrames() {
        var empty = OpenDisplayDeframer()
        XCTAssertNil(empty.append(Data([0, 0, 0, 0])))
        var huge = OpenDisplayDeframer()
        XCTAssertNil(huge.append(Data([0, 0x10, 0, 0])))
    }

    func testControlMessagesPassForJSONOnTheReceiversSide() throws {
        let welcome = try XCTUnwrap(OpenDisplayReply.welcome())
        let payload = welcome.dropFirst(4)
        XCTAssertEqual(payload.first, UInt8(ascii: "{"))
        XCTAssertFalse(payload.contains(0))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "welcome")
        XCTAssertEqual(json["pv"] as? Int, 3)
        XCTAssertEqual(json["min"] as? Int, 1)
        // Too long to pass for one, so not sent.
        XCTAssertNil(OpenDisplayWire.control(["type": "x", "pad": String(repeating: "a", count: 40_000)]))
    }

    func testVideoFramesStartWithTheTelemetryPrefix() {
        let unit = Data([0, 0, 0, 1, 0x67, 0x42])
        let frame = OpenDisplayWire.video(unit, capturedMs: 1000, sentMs: 1005)
        let payload = frame.dropFirst(4)
        XCTAssertEqual(String(decoding: payload.prefix(23), as: UTF8.self), "{\"cap\":1000,\"snd\":1005}")
        XCTAssertEqual(Data(payload.suffix(unit.count)), unit)
        // Its start code's NUL keeps the receiver from taking it for JSON.
        XCTAssertTrue(payload.contains(0))
    }

    // MARK: Hello

    private func hello(_ json: String) -> OpenDisplayHello? {
        guard case .hello(let hello)? = OpenDisplayMessage.parse(Data(json.utf8)) else { return nil }
        return hello
    }

    func testAnIPadsHelloGetsA2xDesktopOfItsPoints() throws {
        let h = try XCTUnwrap(hello("""
        {"type":"hello","pixelsWide":2048,"pixelsHigh":1536,"scale":2,"device":"iPad","id":"A-1","pv":3,
         "panel":{"pixelsWide":2048,"pixelsHigh":1536,"scale":2},"displayMaxFrameRate":60}
        """))
        XCTAssertEqual(h.id, "A-1")
        XCTAssertEqual(h.device, "iPad")
        XCTAssertEqual(h.pv, 3)
        XCTAssertNil(h.cursorPort)
        let desktop = try XCTUnwrap(h.desktop())
        XCTAssertEqual(desktop.mode, StreamingDisplayModes.Mode(width: 1024, height: 768, refreshRate: 60, hiDPI: true))
        XCTAssertEqual(desktop.streamWidth, 2048)
        XCTAssertEqual(desktop.streamHeight, 1536)
        XCTAssertEqual(desktop.fps, 60)
    }

    func testCursorPortIsTakenWhenItIsOne() throws {
        XCTAssertEqual(try XCTUnwrap(hello(#"{"type":"hello","pixelsWide":4,"pixelsHigh":4,"cursorPort":9001}"#)).cursorPort, 9001)
        XCTAssertNil(try XCTUnwrap(hello(#"{"type":"hello","pixelsWide":4,"pixelsHigh":4,"cursorPort":70000}"#)).cursorPort)
    }

    func testAMacReceiverGivesItsPoints() throws {
        let h = try XCTUnwrap(hello("""
        {"type":"hello","pixelsWide":2880,"pixelsHigh":1800,"scale":2,
         "panel":{"pixelsWide":2880,"pixelsHigh":1800,"scale":2,"pointsWide":1680,"pointsHigh":1050}}
        """))
        let desktop = try XCTUnwrap(h.desktop())
        XCTAssertEqual(desktop.mode.width, 1680)
        XCTAssertEqual(desktop.mode.height, 1050)
        XCTAssertTrue(desktop.mode.hiDPI)
        // Its 3360 × 2100 pixels go out at the panel's 2880 × 1800.
        XCTAssertEqual(desktop.streamWidth, 2880)
        XCTAssertEqual(desktop.streamHeight, 1800)
    }

    func testA1xPanelGetsItsPixels() throws {
        let h = try XCTUnwrap(hello(#"{"type":"hello","panel":{"pixelsWide":1920,"pixelsHigh":1080,"scale":1}}"#))
        let desktop = try XCTUnwrap(h.desktop())
        XCTAssertEqual(desktop.mode, StreamingDisplayModes.Mode(width: 1920, height: 1080, refreshRate: 60))
    }

    func testAMalformedPanelFallsBackToTheOldFields() throws {
        let h = try XCTUnwrap(hello(#"{"type":"hello","pixelsWide":2532,"pixelsHigh":1170,"scale":3,"panel":{"pixelsWide":2532,"scale":3}}"#))
        XCTAssertNil(h.panel)
        let desktop = try XCTUnwrap(h.desktop())
        XCTAssertEqual(desktop.mode.width, 1266)
        XCTAssertEqual(desktop.mode.height, 584)
        XCTAssertTrue(desktop.mode.hiDPI)
    }

    func testTheDecodeCeilingShrinksTheStreamAndDesktop() throws {
        let h = try XCTUnwrap(hello("""
        {"type":"hello","panel":{"pixelsWide":5120,"pixelsHigh":2880,"scale":2},"maxEncodeWide":3840,"maxEncodeHigh":2160,
         "videoCaps":[{"codec":"h264","maxWidth":4096,"maxHeight":2304,"maxFrameRate":50},{"codec":"hevc","maxWidth":5120}]}
        """))
        let desktop = try XCTUnwrap(h.desktop())
        XCTAssertEqual(desktop.streamWidth, 3840)
        XCTAssertEqual(desktop.streamHeight, 2160)
        XCTAssertEqual(desktop.mode.width, 1920)
        XCTAssertEqual(desktop.fps, 50)
    }

    func testOutlandishSizesAreSizedWithoutOverflowing() throws {
        // An H.264 envelope with a side left out is unbounded on that side, so the roomier.
        let open = try XCTUnwrap(hello("""
        {"type":"hello","panel":{"pixelsWide":2048,"pixelsHigh":1536,"scale":2},
         "videoCaps":[{"codec":"h264","maxWidth":1024,"maxHeight":768},{"codec":"h264","maxWidth":4096}]}
        """))
        XCTAssertEqual(try XCTUnwrap(open.desktop()).streamWidth, 2048)
        let huge = try XCTUnwrap(hello("""
        {"type":"hello","panel":{"pixelsWide":4,"pixelsHigh":4,"scale":2,"pointsWide":9223372036854775807,"pointsHigh":4}}
        """))
        XCTAssertNil(huge.desktop())
    }

    func testAHelloWithNoSizeMakesNoDesktop() throws {
        XCTAssertNil(try XCTUnwrap(hello(#"{"type":"hello"}"#)).desktop())
    }

    // MARK: Messages

    func testReceiverMessages() {
        XCTAssertEqual(OpenDisplayMessage.parse(Data(#"{"type":"ping","t":1712345678901}"#.utf8)), .ping(t: 1712345678901))
        XCTAssertEqual(OpenDisplayMessage.parse(Data(#"{"type":"touch","phase":"began","x":0.5,"y":0.25,"t":3}"#.utf8)),
                       .touch(.began, x: 0.5, y: 0.25, t: 3))
        XCTAssertEqual(OpenDisplayMessage.parse(Data(#"{"type":"pencil","phase":"move","x":0.5,"y":0.25,"t":7}"#.utf8)),
                       .pencil("move", x: 0.5, y: 0.25, t: 7))
        XCTAssertEqual(OpenDisplayMessage.parse(Data(#"{"type":"scroll","dx":-3,"dy":12.5}"#.utf8)), .scroll(dx: -3, dy: 12.5))
        XCTAssertEqual(OpenDisplayMessage.parse(Data(#"{"type":"kf"}"#.utf8)), .keyFrame)
        XCTAssertEqual(OpenDisplayMessage.parse(Data(#"{"type":"closing"}"#.utf8)), .closing)
        XCTAssertEqual(OpenDisplayMessage.parse(Data(#"{"type":"sleeping"}"#.utf8)), .sleeping)
        XCTAssertEqual(OpenDisplayMessage.parse(Data(#"{"type":"cursorAck"}"#.utf8)), .cursorAck)
        XCTAssertEqual(OpenDisplayMessage.parse(Data(#"{"type":"stroke"}"#.utf8)), .other("stroke"))
        // Not JSON, or no type: ignored, not fatal.
        XCTAssertNil(OpenDisplayMessage.parse(Data("hello".utf8)))
        XCTAssertNil(OpenDisplayMessage.parse(Data(#"{"phase":"began"}"#.utf8)))
    }

    func testPingsCarryTheSendersHealth() throws {
        var health = OpenDisplayHealth(capFps: 59.96, encDrops: 2, netDrops: 3, pending: 4)
        health.inp50 = 12.4
        let ping = try XCTUnwrap(OpenDisplayReply.ping(health))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: ping.dropFirst(4)) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "ping")
        XCTAssertEqual(json["capFps"] as? Double, 60)
        XCTAssertEqual(json["encDrops"] as? Int, 2)
        XCTAssertEqual(json["netDrops"] as? Int, 3)
        XCTAssertEqual(json["drops"] as? Int, 5)
        XCTAssertEqual(json["pending"] as? Int, 4)
        XCTAssertEqual(json["inp50"] as? Double, 12)
        XCTAssertNil(json["inp95"], "no input, no latency")
    }

    func testPercentiles() {
        XCTAssertNil(OpenDisplayHealth.percentile([], 0.5))
        XCTAssertEqual(OpenDisplayHealth.percentile([7], 0.95), 7)
        let values = (1...100).map(Double.init).shuffled()
        XCTAssertEqual(OpenDisplayHealth.percentile(values, 0.5), 50)
        XCTAssertEqual(OpenDisplayHealth.percentile(values, 0.95), 95)
    }

    func testTouchesBecomeClicksAndDrags() {
        let began = OpenDisplayTouches.events(for: .touch(.began, x: 0.5, y: 1))
        XCTAssertEqual(began, [.moveTo(x: 5000, y: 9999, width: 10_000, height: 10_000), .button(1, down: true)])
        XCTAssertEqual(OpenDisplayTouches.events(for: .touch(.moved, x: 0, y: 0)), [.moveTo(x: 0, y: 0, width: 10_000, height: 10_000)])
        XCTAssertEqual(OpenDisplayTouches.events(for: .touch(.cancelled, x: 0, y: 0)), [.button(1, down: false)])
        XCTAssertEqual(OpenDisplayTouches.events(for: .pencil("hover", x: 0.1, y: 0.1)).count, 1)
        XCTAssertEqual(OpenDisplayTouches.events(for: .pencil("up", x: 0.1, y: 0.1)).last, .button(1, down: false))
    }

    func testCursorMessages() throws {
        let shown = try XCTUnwrap(OpenDisplayReply.cursor(at: CGPoint(x: 0.123456, y: 0.5)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: shown.dropFirst(4)) as? [String: Any])
        XCTAssertEqual(json["x"] as? Double, 0.1235)
        XCTAssertEqual(json["v"] as? Int, 1)
        let hidden = try XCTUnwrap(OpenDisplayReply.cursor(at: nil))
        XCTAssertEqual(String(decoding: hidden.dropFirst(4), as: UTF8.self), #"{"type":"cursor","v":0}"#)
        XCTAssertNil(OpenDisplayReply.cursorImage(png: Data(count: 24001), size: .zero, hotSpot: .zero))
        // Numbered, over TCP and as a datagram alike; the datagram has no length before it.
        let framed = try XCTUnwrap(OpenDisplayReply.cursor(at: CGPoint(x: 0.5, y: 0.25), sequence: 88))
        let datagram = try XCTUnwrap(OpenDisplayReply.cursorDatagram(at: CGPoint(x: 0.5, y: 0.25), sequence: 88))
        XCTAssertEqual(Data(framed.dropFirst(4)), datagram)
        XCTAssertEqual(String(decoding: datagram, as: UTF8.self), #"{"s":88,"type":"cursor","v":1,"x":0.5,"y":0.25}"#)
    }

    // MARK: A turned display

    /// A display at `rotation` as DAM makes it for a 2048 × 1536 stream: its sides traded on
    /// a quarter turn, in points at half the stream's pixels.
    private func turnedDisplay(_ rotation: DisplayRotation) -> CGRect {
        let size = rotation.inverse.size(width: 1024, height: 768)
        return CGRect(x: 1920, y: 0, width: size.width, height: size.height)
    }

    func testThePointerGoesBackThroughTheTurnTouchesComeThrough() {
        let grid = 10_000
        for rotation in DisplayRotation.allCases {
            let bounds = turnedDisplay(rotation)
            for (x, y) in [(5000, 5000), (1000, 2000), (9000, 300), (2500, 8000)] {
                let onDisplay = MoonlightPointerMapping.point(x: x, y: y, width: grid, height: grid, streamWidth: 2048,
                                                              streamHeight: 1536, bounds: bounds, rotation: rotation)
                let back = MoonlightPointerMapping.streamPoint(of: onDisplay, streamWidth: 2048, streamHeight: 1536,
                                                               bounds: bounds, rotation: rotation)
                XCTAssertEqual(back.x, Double(x) / Double(grid), accuracy: 1e-9, "\(rotation) \(x),\(y)")
                XCTAssertEqual(back.y, Double(y) / Double(grid), accuracy: 1e-9, "\(rotation) \(x),\(y)")
            }
        }
    }

    func testAPointOnATurnedDisplayLiesTurnedInTheStream() {
        let portrait = turnedDisplay(.quarter)
        // Turned a quarter clockwise, the display's top-left is the stream's top-right.
        let topLeft = MoonlightPointerMapping.streamPoint(of: portrait.origin, streamWidth: 2048, streamHeight: 1536,
                                                          bounds: portrait, rotation: .quarter)
        XCTAssertEqual(topLeft, CGPoint(x: 1, y: 0))
        let half = MoonlightPointerMapping.streamPoint(of: CGPoint(x: 1920 + 256, y: 192), streamWidth: 2048,
                                                       streamHeight: 1536, bounds: turnedDisplay(.half), rotation: .half)
        XCTAssertEqual(half, CGPoint(x: 0.75, y: 0.75))
        // A 4:3 display streamed 16:9 sits between bars.
        let square = CGRect(x: 0, y: 0, width: 1024, height: 768)
        XCTAssertEqual(MoonlightPointerMapping.streamPoint(of: .zero, streamWidth: 1280, streamHeight: 720,
                                                           bounds: square, rotation: .standard), CGPoint(x: 0.125, y: 0))
    }

    func testAScrollIsTurnedAsTouchesAre() {
        // On a square display and stream, a scroll moves as far as a touch moved by as much.
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        for rotation in DisplayRotation.allCases {
            func at(_ x: Int, _ y: Int) -> CGPoint {
                MoonlightPointerMapping.point(x: x, y: y, width: 1000, height: 1000, streamWidth: 1000, streamHeight: 1000,
                                              bounds: bounds, rotation: rotation)
            }
            let from = at(500, 500), to = at(530, 430)
            let scroll = OpenDisplayTouches.scroll(dx: 30, dy: -70, rotation: rotation)
            XCTAssertEqual(scroll.dx, Double(to.x - from.x), accuracy: 1e-9, "\(rotation)")
            XCTAssertEqual(scroll.dy, Double(to.y - from.y), accuracy: 1e-9, "\(rotation)")
        }
    }

    func testThePointersPictureIsTurnedAsTheDisplaysIs() throws {
        // 20 × 10 points, its top-left corner marked.
        let image = NSImage(size: NSSize(width: 20, height: 10), flipped: true) { _ in
            NSColor.red.setFill()
            NSRect(x: 0, y: 0, width: 5, height: 5).fill()
            return true
        }
        func marked(_ rotation: DisplayRotation) throws -> (width: Int, height: Int, corners: [Bool]) {
            let png = try XCTUnwrap(OpenDisplayCursor.png(of: image, turnedBy: rotation))
            let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
            let w = rep.pixelsWide, h = rep.pixelsHigh
            // Top-left, top-right, bottom-right, bottom-left.
            let corners = [(2, 2), (w - 3, 2), (w - 3, h - 3), (2, h - 3)].map {
                (rep.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 0) > 0.5
            }
            return (w, h, corners)
        }
        let standard = try marked(.standard)
        XCTAssertEqual([standard.width, standard.height], [40, 20])
        XCTAssertEqual(standard.corners, [true, false, false, false])
        let quarter = try marked(.quarter)
        XCTAssertEqual([quarter.width, quarter.height], [20, 40])
        XCTAssertEqual(quarter.corners, [false, true, false, false])
        XCTAssertEqual(try marked(.half).corners, [false, false, true, false])
        XCTAssertEqual(try marked(.threeQuarters).corners, [false, false, false, true])
        // Its hot spot goes with it.
        XCTAssertEqual(MoonlightPointerMapping.turned(CGPoint(x: 0, y: 0), by: .quarter), CGPoint(x: 1, y: 0))
    }

    // MARK: usbmuxd

    func testUsbmuxdMessages() throws {
        let message = try XCTUnwrap(Usbmuxd.message(["MessageType": "Connect", "DeviceID": 7,
                                                     "PortNumber": Usbmuxd.portNumber(9000)], tag: 3))
        let header = [UInt8](message.prefix(16))
        XCTAssertEqual(Int(header[0]) | Int(header[1]) << 8, message.count)
        XCTAssertEqual(Array(header[4..<16]), [1, 0, 0, 0, 8, 0, 0, 0, 3, 0, 0, 0])
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: message.dropFirst(16), format: nil) as? [String: Any])
        // 9000 is 0x2328; usbmuxd reads it byte-swapped.
        XCTAssertEqual(plist["PortNumber"] as? Int, 0x2823)
        XCTAssertEqual(plist["DeviceID"] as? Int, 7)
    }

    func testUsbmuxdTakesOnlyCabledDevices() {
        let usb: [String: Any] = ["MessageType": "Attached", "DeviceID": 4,
                                  "Properties": ["ConnectionType": "USB", "SerialNumber": "00008027-AB", "DeviceID": 4] as [String: Any]]
        XCTAssertEqual(Usbmuxd.device(usb), Usbmuxd.Device(deviceID: 4, serial: "00008027-AB"))
        let network: [String: Any] = ["MessageType": "Attached", "DeviceID": 5,
                                      "Properties": ["ConnectionType": "Network", "SerialNumber": "00008027-AB"]]
        XCTAssertNil(Usbmuxd.device(network))
    }

    // MARK: Channels

    private final class FakeChannel: OpenDisplayChannel {
        var onReady: (() -> Void)?
        var onReceive: ((Data) -> Void)?
        var onClose: ((String) -> Void)?
        let pendingBytes = 0
        let pendingSends = 0
        let transport: OpenDisplayTransport
        var started = false, closed = false
        var sent: [Data] = []
        init(_ transport: OpenDisplayTransport) { self.transport = transport }
        func start() { started = true }
        func send(_ data: Data) { sent.append(data) }
        func close() { closed = true }
    }

    func testACableTakesOverOnlyOnceItConnects() {
        let sender = OpenDisplaySender()
        let session = OpenDisplaySession(key: "A-1", name: "iPad", sender: sender)
        defer { session.end(reason: "test over") }
        let wifi = FakeChannel(.wifi)
        session.attach(wifi)
        wifi.onReady?()
        XCTAssertEqual(session.transport, .wifi)

        // A cable that fails leaves the stream on WiFi.
        let refused = FakeChannel(.usb)
        session.takeOver(with: refused)
        XCTAssertTrue(refused.started)
        XCTAssertTrue(session.isDialing)
        XCTAssertEqual(session.transport, .wifi)
        refused.onClose?("refused")
        XCTAssertFalse(wifi.closed)
        XCTAssertFalse(session.isDialing)
        XCTAssertEqual(session.transport, .wifi)

        // One that connects takes it over, and only then is WiFi let go.
        let cable = FakeChannel(.usb)
        session.takeOver(with: cable)
        XCTAssertFalse(wifi.closed)
        cable.onReady?()
        XCTAssertTrue(wifi.closed)
        XCTAssertEqual(session.transport, .usb)
        XCTAssertTrue(session.hasLink)
    }

    /// A connected session's channel saying `hello`.
    private func say(_ json: String, on channel: FakeChannel) {
        channel.onReceive?(OpenDisplayWire.framed(Data(json.utf8)))
    }

    func testAHelloFromAnotherReceiverLosesTheLink() {
        let sender = OpenDisplaySender()
        let session = OpenDisplaySession(key: "A-1", name: "iPad", sender: sender)
        defer { session.end(reason: "test over") }
        let wifi = FakeChannel(.wifi)
        session.attach(wifi)
        wifi.onReady?()
        say(#"{"type":"hello","id":"B-2","pv":3}"#, on: wifi)
        // Neither welcomed nor streamed to.
        XCTAssertTrue(wifi.sent.isEmpty)
        XCTAssertTrue(wifi.closed)
        XCTAssertFalse(session.hasLink)
        XCTAssertEqual(session.key, "A-1")

        // The right one, dialed again, is.
        let again = FakeChannel(.wifi)
        session.attach(again)
        again.onReady?()
        say(#"{"type":"hello","id":"A-1","pv":3}"#, on: again)
        XCTAssertFalse(again.sent.isEmpty)
        XCTAssertFalse(again.closed)
        XCTAssertTrue(session.hasLink)
    }

    func testAHelloGivesACabledReceiverItsID() {
        let sender = OpenDisplaySender()
        sender.setOn(true, key: "usb:00008027-AB")
        defer { sender.forget(key: "A-1") }
        let session = OpenDisplaySession(key: "usb:00008027-AB", name: "iPad", sender: sender)
        defer { session.end(reason: "test over") }
        let cable = FakeChannel(.usb)
        session.attach(cable)
        cable.onReady?()
        say(#"{"type":"hello","id":"A-1","pv":3}"#, on: cable)
        XCTAssertEqual(session.key, "A-1")
        XCTAssertTrue(session.hasLink)
        XCTAssertFalse(cable.sent.isEmpty)
        // Turned on by its ID now, and no longer by its cable's.
        XCTAssertEqual(sender.receivers.filter(\.isOn).map(\.key), ["A-1"])
    }

    func testWiFiDialsAlternateWithTheAddressReachedLast() {
        let found = NWEndpoint.service(name: "iPad", type: OpenDisplayWire.serviceType, domain: "local.", interface: nil)
        let last = NWEndpoint.hostPort(host: "192.168.1.20", port: 9000)
        XCTAssertEqual(OpenDisplaySender.wifiEndpoint(found: found, lastReached: last, failures: 0), found)
        XCTAssertEqual(OpenDisplaySender.wifiEndpoint(found: found, lastReached: last, failures: 1), last)
        XCTAssertEqual(OpenDisplaySender.wifiEndpoint(found: found, lastReached: last, failures: 2), found)
        XCTAssertEqual(OpenDisplaySender.wifiEndpoint(found: found, lastReached: nil, failures: 1), found)
    }

    func testTCPChannelTalksToAListener() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        var received = Data()
        let gotHello = expectation(description: "the channel's bytes reach the listener")
        let gotReply = expectation(description: "the listener's bytes reach the channel")
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { data, _, _, _ in
                received = data ?? Data()
                gotHello.fulfill()
                connection.send(content: OpenDisplayWire.framed(Data("{\"type\":\"kf\"}".utf8)), completion: .idempotent)
            }
        }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .main)
        wait(for: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        let channel = OpenDisplayTCPChannel(endpoint: .hostPort(host: "127.0.0.1", port: port))
        var deframer = OpenDisplayDeframer()
        channel.onReady = { [weak channel] in channel?.send(Data("hello".utf8)) }
        channel.onReceive = { data in
            if deframer.append(data)?.first.flatMap(OpenDisplayMessage.parse) == .keyFrame { gotReply.fulfill() }
        }
        channel.start()
        wait(for: [gotHello, gotReply], timeout: 5)
        XCTAssertEqual(received, Data("hello".utf8))
        let closed = expectation(description: "closed")
        channel.onClose = { _ in closed.fulfill() }
        listener.cancel()
        channel.close()
        wait(for: [closed], timeout: 5)
        XCTAssertEqual(channel.pendingBytes, 0)
    }

    func testTCPChannelReportsARefusedDial() {
        let channel = OpenDisplayTCPChannel(endpoint: .hostPort(host: "127.0.0.1", port: 1))
        let closed = expectation(description: "refused")
        channel.onClose = { _ in closed.fulfill() }
        channel.start()
        wait(for: [closed], timeout: 10)
    }
}
