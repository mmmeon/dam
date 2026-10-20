//
//  MoonlightInput.swift
//
//  What Moonlight sends to control the Mac: its input packets, as moonlight-common-c
//  sends them to a Sunshine host (7.1.431.-1) inside control message 0x0206, already
//  decrypted with the rest of the control stream. Each packet is a big-endian u32 size
//  (not counting itself), a little-endian u32 magic, then its fields, big-endian but for
//  the key code. Also the pure parts of acting on them: Windows key codes to the Mac's,
//  a stream's point to the display's, and click counting.
//

import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// One input event from Moonlight.
enum MoonlightInput: Equatable {
    /// A key, by its Windows virtual-key code; `modifiers` as MoonlightKeyModifiers.
    case key(code: UInt8, down: Bool, modifiers: UInt8)
    /// The pointer to `x`, `y` of a `width` × `height` picture of the stream.
    case moveTo(x: Int, y: Int, width: Int, height: Int)
    /// The pointer moved by `dx`, `dy`.
    case move(dx: Int, dy: Int)
    /// A mouse button: 1 left, 2 middle, 3 right, 4 and 5 the side buttons.
    case button(Int, down: Bool)
    /// The wheel, 120 a notch as Windows counts it; positive away from the user.
    case scroll(Int)
    /// The horizontal wheel, 120 a notch; positive to the right.
    case horizontalScroll(Int)
    /// Text typed on a keyboard that sends no keys, such as a phone's.
    case text(String)
    /// A packet this host does not act on, such as a controller's, by its magic.
    case other(UInt32)

    static let messageType: UInt16 = 0x0206

    /// The events in a 0x0206 payload, in order; a packet cut short ends them.
    static func parse(_ payload: Data) -> [MoonlightInput] {
        let bytes = [UInt8](payload)
        var events: [MoonlightInput] = []
        var at = 0
        while at + 8 <= bytes.count {
            let size = Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
            let end = at + 4 + size
            guard size >= 4, end <= bytes.count else { break }
            let magic = UInt32(bytes[at + 4]) | UInt32(bytes[at + 5]) << 8 | UInt32(bytes[at + 6]) << 16
                      | UInt32(bytes[at + 7]) << 24
            let body = Array(bytes[(at + 8)..<end])
            events.append(event(magic: magic, body: body) ?? .other(magic))
            at = end
        }
        return events
    }

    private static func event(magic: UInt32, body: [UInt8]) -> MoonlightInput? {
        func i16(_ at: Int) -> Int { Int(Int16(bitPattern: UInt16(body[at]) << 8 | UInt16(body[at + 1]))) }
        switch magic {
        case 0x03, 0x04:
            // flags, key code (little-endian, 0x80 in its high byte), modifiers, zero
            guard body.count >= 4 else { return nil }
            return .key(code: body[1], down: magic == 0x03, modifiers: body[3])
        case 0x05:
            guard body.count >= 10 else { return nil }
            return .moveTo(x: i16(0), y: i16(2), width: i16(6), height: i16(8))
        case 0x07:
            guard body.count >= 4 else { return nil }
            return .move(dx: i16(0), dy: i16(2))
        case 0x08, 0x09:
            guard body.count >= 1 else { return nil }
            return .button(Int(body[0]), down: magic == 0x08)
        case 0x0A:
            guard body.count >= 2 else { return nil }
            return .scroll(i16(0))
        case 0x5500_0001:
            guard body.count >= 2 else { return nil }
            return .horizontalScroll(i16(0))
        case 0x17:
            return String(bytes: body, encoding: .utf8).map(MoonlightInput.text)
        default:
            return nil
        }
    }
}

/// The modifier bits of Moonlight's key packets.
enum MoonlightKeyModifiers {
    static let shift: UInt8 = 0x01
    static let control: UInt8 = 0x02
    static let alt: UInt8 = 0x04
    static let meta: UInt8 = 0x08
    /// An extended key, as Sunshine has it: the keypad's Enter rather than Return.
    static let extended: UInt8 = 0x10
}

/// Windows virtual-key codes to the Mac's, at a US keyboard's places. Control stays
/// Control, Alt is Option and the Windows key Command.
enum MoonlightKeyMap {
    static func macKey(for code: UInt8, modifiers: UInt8 = 0) -> CGKeyCode? {
        if code == 0x0D, modifiers & MoonlightKeyModifiers.extended != 0 { return CGKeyCode(kVK_ANSI_KeypadEnter) }
        return table[code].map(CGKeyCode.init)
    }

    private static let table: [UInt8: Int] = {
        var table: [UInt8: Int] = [
            0x08: kVK_Delete, 0x09: kVK_Tab, 0x0C: kVK_ANSI_KeypadClear, 0x0D: kVK_Return,
            0x10: kVK_Shift, 0x11: kVK_Control, 0x12: kVK_Option, 0x14: kVK_CapsLock, 0x1B: kVK_Escape,
            0x20: kVK_Space, 0x21: kVK_PageUp, 0x22: kVK_PageDown, 0x23: kVK_End, 0x24: kVK_Home,
            0x25: kVK_LeftArrow, 0x26: kVK_UpArrow, 0x27: kVK_RightArrow, 0x28: kVK_DownArrow,
            0x2D: kVK_Help, 0x2E: kVK_ForwardDelete,
            0x5B: kVK_Command, 0x5C: kVK_RightCommand,
            0x6A: kVK_ANSI_KeypadMultiply, 0x6B: kVK_ANSI_KeypadPlus, 0x6D: kVK_ANSI_KeypadMinus,
            0x6E: kVK_ANSI_KeypadDecimal, 0x6F: kVK_ANSI_KeypadDivide, 0x90: kVK_ANSI_KeypadClear,
            0xA0: kVK_Shift, 0xA1: kVK_RightShift, 0xA2: kVK_Control, 0xA3: kVK_RightControl,
            0xA4: kVK_Option, 0xA5: kVK_RightOption,
            0xAD: kVK_Mute, 0xAE: kVK_VolumeDown, 0xAF: kVK_VolumeUp,
            0xBA: kVK_ANSI_Semicolon, 0xBB: kVK_ANSI_Equal, 0xBC: kVK_ANSI_Comma, 0xBD: kVK_ANSI_Minus,
            0xBE: kVK_ANSI_Period, 0xBF: kVK_ANSI_Slash, 0xC0: kVK_ANSI_Grave,
            0xDB: kVK_ANSI_LeftBracket, 0xDC: kVK_ANSI_Backslash, 0xDD: kVK_ANSI_RightBracket,
            0xDE: kVK_ANSI_Quote, 0xE2: kVK_ISO_Section,
        ]
        let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                      kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        let keypad = [kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4,
                      kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9]
        let letters = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
                       kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
                       kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
                       kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z]
        let functions = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                         kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (i, key) in digits.enumerated() { table[0x30 + UInt8(i)] = key }
        for (i, key) in keypad.enumerated() { table[0x60 + UInt8(i)] = key }
        for (i, key) in letters.enumerated() { table[0x41 + UInt8(i)] = key }
        for (i, key) in functions.enumerated() { table[0x70 + UInt8(i)] = key }
        return table
    }()

    /// The flags a Mac modifier key sets while held, the modifier's and its side's, as a
    /// keyboard sets them; nil for any other key.
    static func modifierFlags(of key: CGKeyCode) -> CGEventFlags? {
        // NX_DEVICE…KEYMASK, from IOLLEvent.h.
        func side(_ bits: UInt64) -> CGEventFlags { CGEventFlags(rawValue: bits) }
        switch Int(key) {
        case kVK_Shift:          return [.maskShift, side(0x02)]
        case kVK_RightShift:     return [.maskShift, side(0x04)]
        case kVK_Control:        return [.maskControl, side(0x01)]
        case kVK_RightControl:   return [.maskControl, side(0x2000)]
        case kVK_Option:         return [.maskAlternate, side(0x20)]
        case kVK_RightOption:    return [.maskAlternate, side(0x40)]
        case kVK_Command:        return [.maskCommand, side(0x08)]
        case kVK_RightCommand:   return [.maskCommand, side(0x10)]
        default:                 return nil
        }
    }

    /// The flags a Mac keyboard sets on a key's own events whatever is held: Fn for the
    /// arrows, the keys above them and the function keys, and the keypad's for the arrows
    /// and the keypad.
    static func keyFlags(of key: CGKeyCode) -> CGEventFlags {
        var flags: CGEventFlags = []
        if fnKeys.contains(Int(key)) { flags.insert(.maskSecondaryFn) }
        if keypadKeys.contains(Int(key)) { flags.insert(.maskNumericPad) }
        return flags
    }

    private static let arrows: Set<Int> = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
    private static let fnKeys: Set<Int> = arrows.union([
        kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete, kVK_Help,
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ])
    private static let keypadKeys: Set<Int> = arrows.union([
        kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4,
        kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9,
        kVK_ANSI_KeypadDecimal, kVK_ANSI_KeypadMultiply, kVK_ANSI_KeypadPlus, kVK_ANSI_KeypadClear,
        kVK_ANSI_KeypadDivide, kVK_ANSI_KeypadEnter, kVK_ANSI_KeypadMinus, kVK_ANSI_KeypadEquals,
    ])
}

/// Where a point of the stream's picture lies on the display it shows.
enum MoonlightPointerMapping {
    /// `x`, `y` of a `width` × `height` picture of a `streamWidth` × `streamHeight` stream,
    /// on a display at `bounds`, captured turned back by `rotation` and fitted to the
    /// stream's shape as ScreenCaptureKit fits it, bars around it if it is not.
    static func point(x: Int, y: Int, width: Int, height: Int, streamWidth: Int, streamHeight: Int,
                      bounds: CGRect, rotation: DisplayRotation) -> CGPoint {
        guard width > 0, height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGPoint(x: bounds.midX, y: bounds.midY)
        }
        let u = min(max(Double(x) / Double(width), 0), 1)
        let v = min(max(Double(y) / Double(height), 0), 1)
        // Frames are turned clockwise by `rotation` on their way out; undo that.
        let (du, dv): (Double, Double)
        switch rotation {
        case .standard:      (du, dv) = (u, v)
        case .quarter:       (du, dv) = (v, 1 - u)
        case .half:          (du, dv) = (1 - u, 1 - v)
        case .threeQuarters: (du, dv) = (1 - v, u)
        }
        // The captured frame, the display's way up, and the display's picture within it.
        let captured = rotation.inverse.size(width: max(streamWidth, 1), height: max(streamHeight, 1))
        let frameWidth = Double(captured.width), frameHeight = Double(captured.height)
        let scale = min(frameWidth / bounds.width, frameHeight / bounds.height)
        let left = (frameWidth - bounds.width * scale) / 2, top = (frameHeight - bounds.height * scale) / 2
        let px = (du * frameWidth - left) / scale, py = (dv * frameHeight - top) / scale
        return CGPoint(x: bounds.minX + min(max(px, 0), bounds.width - 1),
                       y: bounds.minY + min(max(py, 0), bounds.height - 1))
    }

    /// How long after its last move the pointer is taken to be where macOS says it is,
    /// rather than where it was put: posted moves take a moment to land.
    static let settle: TimeInterval = 0.1

    /// Where a relative move starts: where the pointer was put last, while moves follow
    /// closely; otherwise where it is, so that a move after someone at the Mac moved it
    /// carries on from there rather than jumping back.
    static func start(put: CGPoint?, actual: CGPoint, sinceLastMove: TimeInterval) -> CGPoint {
        guard let put, sinceLastMove < settle else { return actual }
        return put
    }

    /// `point` kept on the display at `bounds`.
    static func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX - 1),
                y: min(max(point.y, bounds.minY), bounds.maxY - 1))
    }
}

/// Counts clicks as macOS does, for each button down's click state: the same button
/// again, soon enough and near enough, is a double click, then a triple. Without a
/// count, macOS takes a click for none at all and menus break.
struct MoonlightClickCounter {
    /// How far apart, in points, two clicks of a double click may be.
    static let slop: CGFloat = 4

    private var last: (button: Int, at: CGPoint, time: TimeInterval, count: Int64)?

    /// The click state of `button` going down at `point` at `time`.
    mutating func press(_ button: Int, at point: CGPoint, time: TimeInterval, interval: TimeInterval) -> Int64 {
        var count: Int64 = 1
        if let last, last.button == button, time - last.time <= interval,
           abs(point.x - last.at.x) <= Self.slop, abs(point.y - last.at.y) <= Self.slop {
            count = last.count + 1
        }
        last = (button, point, time, count)
        return count
    }

    /// The click state of `button` going up: its press's.
    func release(_ button: Int) -> Int64 {
        last?.button == button ? last?.count ?? 1 : 1
    }
}

/// Turns Moonlight's wheel amounts into the Mac's scrolling. A wheel's whole notches
/// scroll a line each, as a mouse's do on the Mac; finer amounts, from a trackpad or a
/// touch screen, scroll smoothly by pixels, what is left of a pixel kept for the next.
struct MoonlightScrollAccumulator {
    static let notch = 120
    /// The pixels a notch scrolls by when it comes in pieces.
    static let pixelsPerNotch = 40

    private var leftover = 0

    /// How to scroll for `amount`: by lines or pixels, and how many; nil for nothing yet.
    mutating func scroll(_ amount: Int) -> (units: CGScrollEventUnit, value: Int32)? {
        if amount % Self.notch == 0 {
            leftover = 0
            return amount == 0 ? nil : (.line, Int32(amount / Self.notch))
        }
        let total = leftover + amount * Self.pixelsPerNotch
        let pixels = total / Self.notch
        leftover = total - pixels * Self.notch
        return pixels == 0 ? nil : (.pixel, Int32(pixels))
    }
}
