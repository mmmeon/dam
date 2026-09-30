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

    var preference: HotkeyPreference { didSet { needsDisplay = true } }
    var onChanged: ((HotkeyPreference) -> Void)?

    private var isRecording = false {
        didSet {
            needsDisplay = true
            toolTip = isRecording ? "Press the new shortcut. Esc cancels." : nil
            isRecording ? installOutsideClickMonitor() : removeOutsideClickMonitor()
        }
    }
    /// Cancels recording on a click anywhere but this field.
    private var outsideClickMonitor: Any?
    private var windowObserver: Any?

    /// The ⓧ shown at the right edge while recording.
    private var cancelRect: NSRect {
        let side: CGFloat = 14
        return NSRect(x: bounds.maxX - side - 5, y: (bounds.height - side) / 2, width: side, height: side)
    }

    init(preference: HotkeyPreference) {
        self.preference = preference
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 140, height: 22) }
    override var acceptsFirstResponder: Bool  { true }
    override var isOpaque: Bool               { false }

    // MARK: - Events

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            cancel()   // the ⓧ, or a second click on the field
        } else if window?.makeFirstResponder(self) == true {
            isRecording = true
        }
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
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5),
                                    xRadius: 6, yRadius: 6)
            ring.lineWidth = 3
            ring.stroke()
        }

        let label = isRecording ? "Type shortcut…" : preference.displayString
        let color: NSColor = isRecording ? .secondaryLabelColor : .labelColor
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

        if isRecording, let glyph = NSImage(systemSymbolName: "xmark.circle.fill",
                                            accessibilityDescription: "Cancel") {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(.init(paletteColors: [.secondaryLabelColor]))
            glyph.withSymbolConfiguration(config)?
                .draw(in: cancelRect, from: .zero, operation: .sourceOver, fraction: 1,
                      respectFlipped: true, hints: nil)
        }
    }
}
