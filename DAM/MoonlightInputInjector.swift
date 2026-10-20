//
//  MoonlightInputInjector.swift
//
//  Acts on a Moonlight stream's input: moves the pointer on the display it streams,
//  clicks, scrolls, presses keys and types text, through events posted as the HID system
//  would. That needs Accessibility access; without it the input is dropped and the stream
//  goes on as it would without input. Events are posted on a queue of their own, never
//  holding up the control stream. They come from a real HID-state source and
//  carry a click count; posted otherwise, menus open but then break and leave dead menu
//  windows on the screen.
//

import AppKit
import CoreGraphics
import os.log

private let inLog = Logger(subsystem: AppIdentity.bundleID, category: "MoonlightInput")

final class MoonlightInputInjector {
    private let displayID: CGDirectDisplayID
    private let streamWidth: Int
    private let streamHeight: Int
    private let source = CGEventSource(stateID: .hidSystemState)
    /// Where events are posted, one at a time; everything below is only touched on it.
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).moonlight.input", qos: .userInteractive)
    private var closed = false
    private var trusted = false
    /// When access was last found missing, so it is asked of macOS no more than once a second.
    private var checkedAccess: TimeInterval?
    /// Where the pointer was put last; nil until it is.
    private var location: CGPoint?
    private var heldButtons: Set<Int> = []
    private var heldKeys: Set<CGKeyCode> = []
    private var clicks = MoonlightClickCounter()
    private var scrolls = MoonlightScrollAccumulator()
    private var horizontalScrolls = MoonlightScrollAccumulator()
    /// What was logged once already: packets and keys this host does not act on.
    private var unknown: Set<UInt32> = []

    init(displayID: CGDirectDisplayID, streamWidth: Int, streamHeight: Int) {
        self.displayID = displayID
        self.streamWidth = streamWidth
        self.streamHeight = streamHeight
    }

    /// Acts on `events`, in order, soon after.
    func handle(_ events: [MoonlightInput]) {
        guard !events.isEmpty else { return }
        queue.async { [self] in
            guard !closed, hasAccess() else { return }
            for event in events { post(event) }
        }
    }

    /// Lets go of every button and key still held, so none stays down once input stops.
    func releaseAll() {
        queue.async { [self] in releaseHeld() }
    }

    /// Lets go of everything and acts on nothing more; for the stream's end.
    func close() {
        queue.async { [self] in
            releaseHeld()
            closed = true
        }
    }

    // MARK: - Events

    private func post(_ event: MoonlightInput) {
        switch event {
        case let .moveTo(x, y, width, height):
            let point = MoonlightPointerMapping.point(
                x: x, y: y, width: width, height: height, streamWidth: streamWidth, streamHeight: streamHeight,
                bounds: CGDisplayBounds(displayID), rotation: StreamRotations.shared.rotation(of: displayID))
            movePointer(to: point, dx: 0, dy: 0)
        case let .move(dx, dy):
            let from = location ?? CGEvent(source: nil)?.location ?? .zero
            let to = MoonlightPointerMapping.clamp(CGPoint(x: from.x + CGFloat(dx), y: from.y + CGFloat(dy)),
                                                   to: CGDisplayBounds(displayID))
            movePointer(to: to, dx: dx, dy: dy)
        case let .button(button, down):
            press(button, down: down)
        case let .scroll(amount):
            if let (units, value) = scrolls.scroll(amount) { scroll(units: units, vertical: value, horizontal: 0) }
        case let .horizontalScroll(amount):
            // The Mac's second wheel scrolls to the left for positive values.
            if let (units, value) = horizontalScrolls.scroll(amount) { scroll(units: units, vertical: 0, horizontal: -value) }
        case let .key(code, down, modifiers):
            guard let key = MoonlightKeyMap.macKey(for: code, modifiers: modifiers) else {
                return logOnce(0x1_0000 | UInt32(code), "key 0x\(String(code, radix: 16))")
            }
            pressKey(key, down: down)
        case let .text(text):
            type(text)
        case let .other(magic):
            logOnce(magic, "packet 0x\(String(magic, radix: 16))")
        }
    }

    private func movePointer(to point: CGPoint, dx: Int, dy: Int) {
        location = point
        let (type, button): (CGEventType, CGMouseButton)
        if heldButtons.contains(1) {
            (type, button) = (.leftMouseDragged, .left)
        } else if heldButtons.contains(3) {
            (type, button) = (.rightMouseDragged, .right)
        } else if let other = heldButtons.min() {
            (type, button) = (.otherMouseDragged, Self.mouseButton(other))
        } else {
            (type, button) = (.mouseMoved, .left)
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                  mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        event.flags = modifierFlags
        event.post(tap: .cghidEventTap)
    }

    private func press(_ button: Int, down: Bool) {
        guard (1...5).contains(button), down != heldButtons.contains(button) else { return }
        let point = location ?? CGEvent(source: nil)?.location ?? .zero
        let type: CGEventType
        switch button {
        case 1: type = down ? .leftMouseDown : .leftMouseUp
        case 3: type = down ? .rightMouseDown : .rightMouseUp
        default: type = down ? .otherMouseDown : .otherMouseUp
        }
        let count: Int64
        if down {
            count = clicks.press(button, at: point, time: ProcessInfo.processInfo.systemUptime,
                                 interval: NSEvent.doubleClickInterval)
            heldButtons.insert(button)
        } else {
            count = clicks.release(button)
            heldButtons.remove(button)
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                  mouseButton: Self.mouseButton(button)) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: count)
        event.flags = modifierFlags
        event.post(tap: .cghidEventTap)
    }

    private func scroll(units: CGScrollEventUnit, vertical: Int32, horizontal: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: units, wheelCount: 2,
                                  wheel1: vertical, wheel2: horizontal, wheel3: 0) else { return }
        event.flags = modifierFlags
        event.post(tap: .cghidEventTap)
    }

    private func pressKey(_ key: CGKeyCode, down: Bool) {
        if down { heldKeys.insert(key) } else { heldKeys.remove(key) }
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
        event.flags = modifierFlags
        event.post(tap: .cghidEventTap)
    }

    /// Types `text` as it is, whatever the keyboard layout, a few characters an event.
    private func type(_ text: String) {
        let units = Array(text.utf16)
        for start in stride(from: 0, to: units.count, by: 20) {
            let chunk = Array(units[start..<min(start + 20, units.count)])
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event.post(tap: .cghidEventTap)
            }
        }
    }

    /// The modifiers the keys held down make.
    private var modifierFlags: CGEventFlags {
        heldKeys.reduce(into: CGEventFlags()) { flags, key in
            if let flag = MoonlightKeyMap.modifierFlag(of: key) { flags.insert(flag) }
        }
    }

    private func releaseHeld() {
        guard !closed, !heldButtons.isEmpty || !heldKeys.isEmpty else { return }
        // Keys first, so the buttons go up with no modifiers.
        for key in heldKeys.sorted() { pressKey(key, down: false) }
        for button in heldButtons.sorted() { press(button, down: false) }
        inLog.debug("released what was held")
    }

    private static func mouseButton(_ button: Int) -> CGMouseButton {
        switch button {
        case 1: return .left
        case 3: return .right
        case 2: return .center
        default: return CGMouseButton(rawValue: UInt32(button - 1)) ?? .center
        }
    }

    // MARK: - Access

    /// Whether events may be posted. Without Accessibility access macOS drops them; the
    /// input is dropped here instead, and taken up once access is given. The stream does not
    /// ask for it (Settings' Allow Input does), so it goes on as it would without input.
    private func hasAccess() -> Bool {
        if trusted { return true }
        let now = ProcessInfo.processInfo.systemUptime
        if let checkedAccess, now - checkedAccess < 1 { return false }
        trusted = VideoManager.hasAccessibilityAccess(prompting: false)
        if !trusted, checkedAccess == nil {
            inLog.error("input dropped: \(AppIdentity.name, privacy: .public) has no Accessibility access")
        }
        checkedAccess = now
        return trusted
    }

    private func logOnce(_ id: UInt32, _ what: String) {
        guard unknown.insert(id).inserted else { return }
        inLog.debug("ignoring Moonlight's \(what, privacy: .public)")
    }
}
