import XCTest
import Carbon.HIToolbox
import CryptoKit
@testable import DAM

final class MoonlightInputTests: XCTestCase {

    /// A packet as moonlight-common-c lays it out: big-endian size, little-endian magic, body.
    private func packet(_ magic: UInt32, _ body: [UInt8]) -> [UInt8] {
        let size = UInt32(4 + body.count)
        return [UInt8(size >> 24), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF),
                UInt8(magic & 0xFF), UInt8(magic >> 8 & 0xFF), UInt8(magic >> 16 & 0xFF), UInt8(magic >> 24)] + body
    }

    // MARK: - Packets

    func testReadsEachKindOfPacket() {
        // flags 0, VK_A with Moonlight's 0x80 high byte, little-endian; shift held; zero
        XCTAssertEqual(MoonlightInput.parse(Data(packet(0x03, [0, 0x41, 0x80, 0x01, 0, 0]))),
                       [.key(code: 0x41, down: true, modifiers: MoonlightKeyModifiers.shift)])
        XCTAssertEqual(MoonlightInput.parse(Data(packet(0x04, [0, 0x41, 0x80, 0, 0, 0]))),
                       [.key(code: 0x41, down: false, modifiers: 0)])
        // 300, 200 of 1280 × 720, big-endian, with the unused field
        XCTAssertEqual(MoonlightInput.parse(Data(packet(0x05, [0x01, 0x2C, 0, 0xC8, 0, 0, 0x05, 0, 0x02, 0xD0]))),
                       [.moveTo(x: 300, y: 200, width: 1280, height: 720)])
        XCTAssertEqual(MoonlightInput.parse(Data(packet(0x07, [0xFF, 0xFE, 0, 3]))), [.move(dx: -2, dy: 3)])
        XCTAssertEqual(MoonlightInput.parse(Data(packet(0x08, [3]))), [.button(3, down: true)])
        XCTAssertEqual(MoonlightInput.parse(Data(packet(0x09, [1]))), [.button(1, down: false)])
        // -120 twice, then zero
        XCTAssertEqual(MoonlightInput.parse(Data(packet(0x0A, [0xFF, 0x88, 0xFF, 0x88, 0, 0]))), [.scroll(-120)])
        XCTAssertEqual(MoonlightInput.parse(Data(packet(0x5500_0001, [0, 30]))), [.horizontalScroll(30)])
        XCTAssertEqual(MoonlightInput.parse(Data(packet(0x17, Array("hé".utf8)))), [.text("hé")])
        XCTAssertEqual(MoonlightInput.parse(Data(packet(0x0C, [0, 0x1A]))), [.other(0x0C)], "a controller's")
    }

    func testReadsSeveralPacketsAndStopsAtOneCutShort() {
        let two = packet(0x07, [0, 1, 0, 2]) + packet(0x08, [1])
        XCTAssertEqual(MoonlightInput.parse(Data(two)), [.move(dx: 1, dy: 2), .button(1, down: true)])
        XCTAssertEqual(MoonlightInput.parse(Data(two.dropLast())), [.move(dx: 1, dy: 2)])
        XCTAssertEqual(MoonlightInput.parse(Data(packet(0x05, [0, 1]))), [.other(0x05)], "too short to read")
        XCTAssertEqual(MoonlightInput.parse(Data()), [])
    }

    func testInputComesInAControlMessage() throws {
        let key = SymmetricKey(data: Data(repeating: 7, count: 16))
        let payload = Data(packet(0x08, [1]))
        let sealed = try MoonlightControlCrypto.seal(type: MoonlightInput.messageType, payload: payload, sequence: 9,
                                                     key: key, direction: .clientToHost)
        let opened = try XCTUnwrap(MoonlightControlCrypto.open(sealed, key: key, direction: .clientToHost))
        XCTAssertEqual(opened.type, 0x0206)
        XCTAssertEqual(MoonlightInput.parse(opened.payload), [.button(1, down: true)])
    }

    // MARK: - Keys

    func testMapsWindowsKeysToTheMacs() {
        XCTAssertEqual(MoonlightKeyMap.macKey(for: 0x41), CGKeyCode(kVK_ANSI_A))
        XCTAssertEqual(MoonlightKeyMap.macKey(for: 0x5A), CGKeyCode(kVK_ANSI_Z))
        XCTAssertEqual(MoonlightKeyMap.macKey(for: 0x30), CGKeyCode(kVK_ANSI_0))
        XCTAssertEqual(MoonlightKeyMap.macKey(for: 0x39), CGKeyCode(kVK_ANSI_9))
        XCTAssertEqual(MoonlightKeyMap.macKey(for: 0x70), CGKeyCode(kVK_F1))
        XCTAssertEqual(MoonlightKeyMap.macKey(for: 0x83), CGKeyCode(kVK_F20))
        XCTAssertEqual(MoonlightKeyMap.macKey(for: 0x69), CGKeyCode(kVK_ANSI_Keypad9))
        XCTAssertEqual(MoonlightKeyMap.macKey(for: 0xBA), CGKeyCode(kVK_ANSI_Semicolon))
        XCTAssertEqual(MoonlightKeyMap.macKey(for: 0xDE), CGKeyCode(kVK_ANSI_Quote))
        XCTAssertEqual(MoonlightKeyMap.macKey(for: 0x08), CGKeyCode(kVK_Delete), "Backspace")
        XCTAssertEqual(MoonlightKeyMap.macKey(for: 0x2E), CGKeyCode(kVK_ForwardDelete))
        XCTAssertEqual(MoonlightKeyMap.macKey(for: 0x0D), CGKeyCode(kVK_Return))
        XCTAssertEqual(MoonlightKeyMap.macKey(for: 0x0D, modifiers: MoonlightKeyModifiers.extended),
                       CGKeyCode(kVK_ANSI_KeypadEnter))
        XCTAssertNil(MoonlightKeyMap.macKey(for: 0x5D), "the menu key has none")
    }

    func testModifiersAreControlOptionAndCommand() {
        XCTAssertEqual(MoonlightKeyMap.macKey(for: 0xA2), CGKeyCode(kVK_Control))
        XCTAssertEqual(MoonlightKeyMap.macKey(for: 0xA3), CGKeyCode(kVK_RightControl))
        XCTAssertEqual(MoonlightKeyMap.macKey(for: 0xA4), CGKeyCode(kVK_Option))
        XCTAssertEqual(MoonlightKeyMap.macKey(for: 0xA5), CGKeyCode(kVK_RightOption))
        XCTAssertEqual(MoonlightKeyMap.macKey(for: 0x5B), CGKeyCode(kVK_Command))
        XCTAssertEqual(MoonlightKeyMap.macKey(for: 0xA1), CGKeyCode(kVK_RightShift))
        XCTAssertEqual(MoonlightKeyMap.modifierFlags(of: CGKeyCode(kVK_RightCommand)),
                       [.maskCommand, CGEventFlags(rawValue: 0x10)], "⌘ and its right-hand side")
        XCTAssertEqual(MoonlightKeyMap.modifierFlags(of: CGKeyCode(kVK_Option)),
                       [.maskAlternate, CGEventFlags(rawValue: 0x20)])
        XCTAssertNil(MoonlightKeyMap.modifierFlags(of: CGKeyCode(kVK_ANSI_A)))
    }

    func testKeysCarryTheFlagsAMacKeyboardGivesThem() {
        XCTAssertEqual(MoonlightKeyMap.keyFlags(of: CGKeyCode(kVK_LeftArrow)), [.maskSecondaryFn, .maskNumericPad])
        XCTAssertEqual(MoonlightKeyMap.keyFlags(of: CGKeyCode(kVK_PageDown)), .maskSecondaryFn)
        XCTAssertEqual(MoonlightKeyMap.keyFlags(of: CGKeyCode(kVK_F5)), .maskSecondaryFn)
        XCTAssertEqual(MoonlightKeyMap.keyFlags(of: CGKeyCode(kVK_ANSI_Keypad5)), .maskNumericPad)
        XCTAssertEqual(MoonlightKeyMap.keyFlags(of: CGKeyCode(kVK_ANSI_A)), [])
    }

    // MARK: - Pointer

    private let display = CGRect(x: 1920, y: 0, width: 1280, height: 720)

    private func point(_ x: Int, _ y: Int, of width: Int = 1280, _ height: Int = 720, stream: (Int, Int) = (1280, 720),
                       on bounds: CGRect? = nil, turned rotation: DisplayRotation = .standard) -> CGPoint {
        MoonlightPointerMapping.point(x: x, y: y, width: width, height: height, streamWidth: stream.0,
                                      streamHeight: stream.1, bounds: bounds ?? display, rotation: rotation)
    }

    func testMapsAStreamPointOntoItsDisplay() {
        XCTAssertEqual(point(0, 0), CGPoint(x: 1920, y: 0))
        XCTAssertEqual(point(640, 360), CGPoint(x: 2560, y: 360))
        XCTAssertEqual(point(1280, 720), CGPoint(x: 3199, y: 719), "kept on the display")
        XCTAssertEqual(point(640, 360, of: 2560, 1440), CGPoint(x: 2240, y: 180), "the client's own picture size")
    }

    func testMapsAHiDPIStreamOntoTheDisplaysPoints() {
        // A 2560 × 1440 stream from a display of half as many points.
        XCTAssertEqual(point(1280, 720, of: 2560, 1440, stream: (2560, 1440)), CGPoint(x: 2560, y: 360))
    }

    func testUndoesTheDisplaysTurn() {
        // A portrait display, 720 × 1280 points, streamed 1280 × 720 turned a quarter clockwise:
        // the stream's top-left was the display's bottom-left.
        let portrait = CGRect(x: 0, y: 0, width: 720, height: 1280)
        XCTAssertEqual(point(0, 0, on: portrait, turned: .quarter), CGPoint(x: 0, y: 1279))
        XCTAssertEqual(point(1280, 0, on: portrait, turned: .quarter), CGPoint(x: 0, y: 0))
        XCTAssertEqual(point(0, 0, on: portrait, turned: .threeQuarters), CGPoint(x: 719, y: 0))
        XCTAssertEqual(point(0, 0, turned: .half), CGPoint(x: 3199, y: 719))
        XCTAssertEqual(point(320, 180, turned: .half), CGPoint(x: 1920 + 960, y: 540))
    }

    func testAllowsForBarsAroundADisplayOfAnotherShape() {
        // A 4:3 display streamed 16:9: bars of 160 on each side of 960 × 720.
        let square = CGRect(x: 0, y: 0, width: 1024, height: 768)
        XCTAssertEqual(point(160, 0, on: square), CGPoint(x: 0, y: 0))
        XCTAssertEqual(point(640, 360, on: square), CGPoint(x: 512, y: 384))
        XCTAssertEqual(point(10, 360, on: square), CGPoint(x: 0, y: 384), "on a bar: the nearest edge")
    }

    func testRelativeMovesStartWhereThePointerIsOnceItHasSettled() {
        let put = CGPoint(x: 10, y: 10), actual = CGPoint(x: 500, y: 300)
        XCTAssertEqual(MoonlightPointerMapping.start(put: put, actual: actual, sinceLastMove: 0.01), put,
                       "moves in a run: the last one may not have landed yet")
        XCTAssertEqual(MoonlightPointerMapping.start(put: put, actual: actual, sinceLastMove: 0.5), actual,
                       "moved at the Mac since")
        XCTAssertEqual(MoonlightPointerMapping.start(put: nil, actual: actual, sinceLastMove: 0), actual)
    }

    // MARK: - Clicks and scrolling

    // MARK: Pointer acceleration

    /// Points per step at each speed, worked out with IOHIDFamily's arithmetic from the
    /// curves in macOS 13's AppleUserHIDDrivers (a script, not this code).
    func testAcceleratesAsMacOSDoes() throws {
        let speeds: [Double] = [1, 5, 10, 30, 60, 120]
        let expected: [Double: [Double]] = [
            0: [0.24, 0.24, 0.24, 0.24, 0.24, 0.24],
            0.6875: [0.245877, 0.327217, 0.429416, 0.844027, 1.447604, 1.861947],
            1.0: [0.275609, 0.457226, 0.686013, 1.620795, 3.017474, 3.881906],
            1.5: [0.295684, 0.548655, 0.868095, 2.181705, 4.178943, 5.310467],
            3.0: [0.382515, 0.961191, 1.703929, 4.89034, 10.176027, 12.498734],
        ]
        for (trackingSpeed, multipliers) in expected {
            let acceleration = try XCTUnwrap(MoonlightPointerAcceleration(speed: trackingSpeed))
            for (velocity, multiplier) in zip(speeds, multipliers) {
                XCTAssertEqual(acceleration.multiplier(velocity: velocity), multiplier, accuracy: 1e-5,
                               "tracking speed \(trackingSpeed), \(velocity) steps a report")
            }
        }
    }

    func testANegativeTrackingSpeedTurnsAccelerationOff() {
        XCTAssertNil(MoonlightPointerAcceleration(speed: -1))
    }

    /// A move after a pause is taken as one report's steps.
    func testAFirstMoveIsOneReport() throws {
        var acceleration = try XCTUnwrap(MoonlightPointerAcceleration(speed: 0.6875))
        let moved = acceleration.accelerate(dx: 30, dy: 0, at: 100)
        XCTAssertEqual(moved.dx, 30 * acceleration.multiplier(velocity: 30), accuracy: 1e-9)
        XCTAssertEqual(moved.dy, 0)
    }

    func testAPauseStartsAMotionAfresh() throws {
        var acceleration = try XCTUnwrap(MoonlightPointerAcceleration(speed: 0.6875))
        for move in 0..<10 { _ = acceleration.accelerate(dx: 60, dy: 0, at: Double(move) * 0.008) }
        let after = acceleration.accelerate(dx: 0, dy: 5, at: 0.072 + MoonlightPointerAcceleration.pause + 0.01)
        XCTAssertEqual(after.dy, 5 * acceleration.multiplier(velocity: 5), accuracy: 1e-9)
    }

    /// Moonlight sends moves as they come, a few steps at a time or many at once; once the
    /// pointer is moving, the same motion goes the same distance either way.
    func testTheSameMotionGoesAsFarHoweverItIsSplit() throws {
        /// How far 3000 steps a second for 0.24 s go in their last 0.16 s.
        func distance(steps: Int, every interval: TimeInterval) throws -> Double {
            var acceleration = try XCTUnwrap(MoonlightPointerAcceleration(speed: 0.6875))
            var total = 0.0
            for move in 0..<Int((0.24 / interval).rounded()) {
                let time = Double(move) * interval
                let moved = acceleration.accelerate(dx: steps, dy: 0, at: time).dx
                if time >= 0.08 - 1e-9 { total += moved }
            }
            return total
        }
        let reports = try distance(steps: 24, every: 0.008)
        let perStep = try XCTUnwrap(MoonlightPointerAcceleration(speed: 0.6875)).multiplier(velocity: 24)
        XCTAssertEqual(reports, 20 * 24 * perStep, accuracy: 1e-6)
        XCTAssertEqual(try distance(steps: 3, every: 0.001), reports, accuracy: reports * 0.01)
        XCTAssertEqual(try distance(steps: 48, every: 0.016), reports, accuracy: reports * 0.01)
        // Slower motion goes less far for each step.
        XCTAssertLessThan(try distance(steps: 1, every: 0.001) * 3, reports * 0.8)
    }

    func testCountsDoubleAndTripleClicks() {
        var clicks = MoonlightClickCounter()
        let at = CGPoint(x: 100, y: 100)
        XCTAssertEqual(clicks.press(1, at: at, time: 10, interval: 0.5), 1)
        XCTAssertEqual(clicks.release(1), 1)
        XCTAssertEqual(clicks.press(1, at: CGPoint(x: 102, y: 99), time: 10.3, interval: 0.5), 2)
        XCTAssertEqual(clicks.release(1), 2)
        XCTAssertEqual(clicks.press(1, at: at, time: 10.6, interval: 0.5), 3)
        XCTAssertEqual(clicks.press(1, at: at, time: 12, interval: 0.5), 1, "too late")
        XCTAssertEqual(clicks.press(1, at: CGPoint(x: 120, y: 100), time: 12.1, interval: 0.5), 1, "too far")
        XCTAssertEqual(clicks.press(3, at: CGPoint(x: 120, y: 100), time: 12.2, interval: 0.5), 1, "another button")
    }

    func testScrollsWholeNotchesByLinesAndPiecesByPixels() {
        var scroll = MoonlightScrollAccumulator()
        XCTAssertEqual(scroll.scroll(240)?.units, .line)
        XCTAssertEqual(scroll.scroll(240)?.value, 2)
        XCTAssertEqual(scroll.scroll(-120)?.value, -1)
        XCTAssertNil(scroll.scroll(1), "less than a pixel, kept")
        XCTAssertEqual(scroll.scroll(2)?.value, 1, "three pieces make a pixel")
        XCTAssertEqual(scroll.scroll(30)?.units, .pixel)
        XCTAssertNil(scroll.scroll(0))
    }

    func testTextIsTypedInPiecesOfWholeCharacters() {
        // 19 letters then an emoji of two UTF-16 units: the emoji goes whole in the next piece.
        let text = String(repeating: "a", count: 19) + "😀" + "b"
        let chunks = MoonlightInputInjector.chunks(of: text)
        XCTAssertEqual(chunks.map(\.count), [19, 3])
        XCTAssertEqual(chunks.map { String(decoding: $0, as: UTF16.self) }, [String(repeating: "a", count: 19), "😀b"])
        XCTAssertEqual(chunks.joined().map { $0 }, Array(text.utf16))

        // A family of four is 11 units, one character: never split, so one to a piece.
        let families = String(repeating: "👨‍👩‍👧‍👦", count: 3)
        XCTAssertEqual(MoonlightInputInjector.chunks(of: families).map(\.count), [11, 11, 11])
        XCTAssertTrue(MoonlightInputInjector.chunks(of: "").isEmpty)

        // A character longer than a piece goes a scalar at a time.
        let long = "e" + String(repeating: "\u{301}", count: 25)
        XCTAssertEqual(MoonlightInputInjector.chunks(of: long).map(\.count), [20, 6])
    }
}
