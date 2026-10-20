//
//  OpenDisplayTests.swift
//  DAMTests
//

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

    func testAHelloWithNoSizeMakesNoDesktop() throws {
        XCTAssertNil(try XCTUnwrap(hello(#"{"type":"hello"}"#)).desktop())
    }

    // MARK: Messages

    func testReceiverMessages() {
        XCTAssertEqual(OpenDisplayMessage.parse(Data(#"{"type":"ping","t":1712345678901}"#.utf8)), .ping(t: 1712345678901))
        XCTAssertEqual(OpenDisplayMessage.parse(Data(#"{"type":"touch","phase":"began","x":0.5,"y":0.25,"t":3}"#.utf8)),
                       .touch(.began, x: 0.5, y: 0.25))
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
                                  "Properties": ["ConnectionType": "USB", "SerialNumber": "00008027-AB", "DeviceID": 4]]
        XCTAssertEqual(Usbmuxd.device(usb), Usbmuxd.Device(deviceID: 4, serial: "00008027-AB"))
        let network: [String: Any] = ["MessageType": "Attached", "DeviceID": 5,
                                      "Properties": ["ConnectionType": "Network", "SerialNumber": "00008027-AB"]]
        XCTAssertNil(Usbmuxd.device(network))
    }

    // MARK: Channels

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
        channel.onReady = { channel.send(Data("hello".utf8)) }
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
