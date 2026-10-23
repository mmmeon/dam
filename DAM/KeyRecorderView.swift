//
//  KeyRecorderView.swift
//
//  Click to enter recording mode, then press the desired key combination. Escape, the
//  ⓧ at the right of the field, clicking anywhere else, or the window losing focus
//  cancels. At least one modifier key (⌃ ⌥ ⇧ ⌘) is required.
//

import AppKit
import Carbon.HIToolbox

final class KeyRecorderView: NSView {

    var preference: HotkeyPreference {
        didSet { needsDisplay = true; NSAccessibility.post(element: self, notification: .valueChanged) }
    }
    var onChanged: ((HotkeyPreference) -> Void)?
    /// What else of the app's has the same shortcut, which then shows in red; nil when nothing does.
    var clash: String? {
        didSet { needsDisplay = true; if !isRecording { toolTip = warningTip } }
    }
    /// Whether another app has the shortcut, so it couldn't be registered; shows in red too.
    var isTakenElsewhere = false {
        didSet { needsDisplay = true; if !isRecording { toolTip = warningTip } }
    }
    private var warningTip: String? {
        if let clash { return "\(clash) has the same shortcut; only one of them works." }
        return isTakenElsewhere
            ? String(localized: "Another app uses this shortcut.",
                     comment: "Tooltip of a shortcut field whose keys another app has registered")
            : nil
    }

    private var isRecording = false {
        didSet {
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
            toolTip = isRecording ? "Press the new shortcut. Esc cancels." : warningTip
            isRecording ? installOutsideClickMonitor() : removeOutsideClickMonitor()
            // The app's shortcuts are off while recording, so their keys can be recorded
            // rather than acted on.
            if isRecording != oldValue { isRecording ? GlobalHotkey.pauseAll() : GlobalHotkey.resumeAll() }
        }
    }
    /// Cancels recording on a click anywhere but this field.
    private var outsideClickMonitor: Any?
    private var windowObserver: Any?

    /// The ⓧ shown at the right edge while recording.
    private var cancelRect: NSRect {
        let side: CGFloat = 9.5
        return NSRect(x: bounds.maxX - side - 5, y: (bounds.height - side) / 2, width: side, height: side)
    }

    init(preference: HotkeyPreference) {
        self.preference = preference
        super.init(frame: .zero)
        focusRingType = .none   // draw() paints its own rounded ring while recording
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 140, height: 22) }
    override var acceptsFirstResponder: Bool  { true }
    override var isOpaque: Bool               { false }

    // MARK: - Events

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            cancel()   // the ⓧ, or a second click on the field
        } else {
            startRecording()
        }
    }

    /// Takes the keys and waits for the new shortcut, as a click on the field does.
    func startRecording() {
        guard !isRecording, window?.makeFirstResponder(self) == true else { return }
        isRecording = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = windowObserver { NotificationCenter.default.removeObserver(o) }
        windowObserver = nil
        guard let window else { return }
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in self?.cancel() }
    }

    deinit {
        if let o = windowObserver { NotificationCenter.default.removeObserver(o) }
        removeOutsideClickMonitor()
        if isRecording { GlobalHotkey.resumeAll() }
    }

    /// Leaves recording mode, keeping the current shortcut.
    func cancel() {
        guard isRecording else { return }
        isRecording = false
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            let inField = event.window === self.window
                && self.bounds.contains(self.convert(event.locationInWindow, from: nil))
            if !inField { self.cancel() }
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
    }

    /// While recording, a key with ⌘ (⌘Q, ⌘W, ⌘H, ⌥⌘H…) is recorded here, before the menus
    /// and the window act on it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }

        if event.keyCode == UInt16(kVK_Escape) {
            cancel()
            return
        }

        let mods = event.modifierFlags.carbonFlags
        guard mods != 0 else { return }   // bare keys aren't valid global hotkeys

        preference = HotkeyPreference(keyCode: UInt32(event.keyCode), modifiers: mods)
        isRecording = false
        onChanged?(preference)
    }

    // MARK: - Accessibility

    // A button whose value is the shortcut; the owner sets its label to what the shortcut does.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityValue() -> Any? {
        isRecording ? "Type shortcut" : preference.displayString
    }
    override func accessibilityHelp() -> String? {
        isRecording ? "Press the new shortcut. Escape cancels." : warningTip ?? "Press to record a new shortcut."
    }
    override func accessibilityPerformPress() -> Bool {
        isRecording ? cancel() : startRecording()
        return true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)

        (isRecording ? NSColor.selectedControlColor : NSColor.controlBackgroundColor).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        if isRecording {
            NSColor.keyboardFocusIndicatorColor.withAlphaComponent(0.4).setStroke()
            // Kept inside bounds: the view clips, and an overhanging ring gets square outer corners.
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
                                    xRadius: 4, yRadius: 4)
            ring.lineWidth = 3
            ring.stroke()
        }

        let label = isRecording ? "Type shortcut…" : preference.displayString
        let color: NSColor = isRecording ? .secondaryLabelColor
                           : clash != nil || isTakenElsewhere ? .systemRed : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize - 1),
            .foregroundColor: color,
        ]
        let str = NSAttributedString(string: label, attributes: attrs)
        let sz  = str.size()
        // While recording the text is centred in the space left of the ⓧ.
        let textWidth = isRecording ? cancelRect.minX : bounds.width
        str.draw(at: CGPoint(x: (textWidth - sz.width) / 2,
                             y: (bounds.height - sz.height) / 2))

        if isRecording {
            // A bare x in the text color.
            let r = cancelRect
            let x = NSBezierPath()
            let d = r.width * 0.3
            x.move(to: NSPoint(x: r.midX - d, y: r.midY - d)); x.line(to: NSPoint(x: r.midX + d, y: r.midY + d))
            x.move(to: NSPoint(x: r.midX - d, y: r.midY + d)); x.line(to: NSPoint(x: r.midX + d, y: r.midY - d))
            x.lineWidth = 1.2
            x.lineCapStyle = .round
            NSColor.labelColor.setStroke()
            x.stroke()
        }
    }
}
