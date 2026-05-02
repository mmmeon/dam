//
//  KeyRecorderView.swift
//  boar
//
//  Click to enter recording mode, then press the desired key combination.
//  Escape cancels. At least one modifier key (⌃ ⌥ ⇧ ⌘) is required.
//

import AppKit
import Carbon.HIToolbox

final class KeyRecorderView: NSView {

    var preference: HotkeyPreference { didSet { needsDisplay = true } }
    var onChanged: ((HotkeyPreference) -> Void)?

    private var isRecording = false { didSet { needsDisplay = true } }

    init(preference: HotkeyPreference) {
        self.preference = preference
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 22) }
    override var acceptsFirstResponder: Bool  { true }
    override var isOpaque: Bool               { false }

    // MARK: - Events

    override func mouseDown(with event: NSEvent) {
        if window?.makeFirstResponder(self) == true {
            isRecording.toggle()
        }
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }

        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
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
        str.draw(at: CGPoint(x: (bounds.width  - sz.width)  / 2,
                             y: (bounds.height - sz.height) / 2))
    }
}
