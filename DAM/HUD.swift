//
//  HUD.swift
//
//  The on-screen HUD panels: a grid list of choices with a hint row (used by the
//  AirPlay quick-connect and audio output pickers) and the speech caption.
//

import AppKit
import Carbon.HIToolbox

// MARK: - Feedback

/// Where hotkey feedback goes right now. Every enabled surface is used: the Touch Bar when
/// one is available, the screen, and speech. The screen is used regardless when the Touch
/// Bar wouldn't show anything, so a hotkey never goes without visible feedback.
enum Feedback {
    static var touchBar: Bool {
        VisibilityPreferences.touchBarFeedback && ControlStripPresenter.isTouchBarAvailable
    }
    static var screen: Bool { VisibilityPreferences.screenFeedback || !touchBar }
    static var voice:  Bool { VisibilityPreferences.speechEnabled }
}

// MARK: - CaptionHUD

/// On-screen stand-in for the Touch Bar caption on Macs without a Touch Bar: a panel near
/// the bottom of the screen under the mouse, sized to its text. While the text is spoken,
/// words light up as they are said. It never takes focus or clicks.
final class CaptionHUD {

    static let shared = CaptionHUD()

    private static let alpha: CGFloat = 0.97

    private var panel: HUDPanel?
    private var view:  CaptionView?

    private init() {}

    /// Shows `text`, or fades the caption out when nil. `spoken` is how many characters
    /// have been spoken so far, or nil when the text isn't being spoken.
    func show(_ text: String?, spoken: Int?) {
        guard let text else {
            fadeOut()
            return
        }
        let p = panel ?? makeHUDPanel()
        panel = p
        p.ignoresMouseEvents = true

        let v = CaptionView(text: text, spoken: spoken)
        view = v
        let size = v.fittingSize
        v.frame = NSRect(origin: .zero, size: size)
        p.contentView = v
        p.setContentSize(size)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                     ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                     y: frame.minY + frame.height * 0.12))
        }

        if !p.isVisible { p.alphaValue = 0 }
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = Self.alpha
        }
    }

    /// Updates how many characters of the shown text have been spoken.
    func setSpoken(_ spoken: Int?) {
        view?.spoken = spoken
    }

    private func fadeOut() {
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 0
        }, completionHandler: {
            // Unless shown again meanwhile.
            if p.alphaValue == 0 { p.orderOut(nil) }
        })
    }
}

/// The caption's content: the text, with words not yet spoken dimmed.
private final class CaptionView: NSVisualEffectView {

    private static let padding:  CGFloat = 12
    private static let maxWidth: CGFloat = 440
    private static let font = NSFont.systemFont(ofSize: 17, weight: .medium)

    private let text:  String
    private let label: NSTextField

    var spoken: Int? { didSet { updateText() } }

    init(text: String, spoken: Int?) {
        self.text   = text
        self.spoken = spoken
        label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = Self.maxWidth
        super.init(frame: .zero)

        material     = .hudWindow
        blendingMode = .behindWindow
        state        = .active

        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let pad = Self.padding
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            label.topAnchor.constraint(equalTo: topAnchor, constant: pad - 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(pad - 2)),
        ])
        updateText()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateText() {
        let s = NSMutableAttributedString(string: text, attributes: [
            .font: Self.font, .foregroundColor: NSColor.labelColor,
        ])
        if let spoken, spoken < text.utf16.count {
            s.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor,
                           range: NSRange(location: spoken, length: text.utf16.count - spoken))
        }
        label.attributedStringValue = s
    }
}

// MARK: - HUD helpers

/// The borderless floating panel shared by the HUDs. A `nonactivating` panel takes key
/// presses without activating the app, so focus returns to the previous app afterwards.
func makeHUDPanel(nonactivating: Bool = false) -> HUDPanel {
    let p = HUDPanel(contentRect: .zero,
                     styleMask: nonactivating ? [.borderless, .nonactivatingPanel] : [.borderless],
                     backing: .buffered, defer: true)
    p.isFloatingPanel    = true
    p.hidesOnDeactivate  = false   // captions show while another app is active
    p.level              = .modalPanel
    p.backgroundColor    = .clear
    p.isOpaque           = false
    p.hasShadow          = true
    p.alphaValue         = 0.97
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    return p
}

/// The hint row under a HUD's body: `leading` on the left and `trailing` on the right.
/// With `animatesDots`, "." to "..." cycle after `leading`.
struct HUDHint: Equatable {
    var leading:  String
    var trailing: String
    var animatesDots = false

}

/// What a HUD shows above its hint.
enum HUDBody {
    /// Choices drawn as grid rows. `numbered` adds a number column, which slides in from the
    /// left when the HUD appears.
    case choices([String], numbered: Bool)
}

/// Fills `panel` with `body` and `hint`, sizes it, and centres it horizontally on the
/// screen under the mouse; `originY` picks the bottom edge from that screen's visible frame
/// and the panel size.
func layoutHUD(_ panel: NSPanel, body: HUDBody, hint: HUDHint?,
                       originY: (NSRect, NSSize) -> CGFloat) {
    let content = HUDContentView(body: body, hint: hint)
    let sz = content.fittingSize
    content.frame = NSRect(origin: .zero, size: sz)
    panel.contentView = content
    panel.setContentSize(sz)

    let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                 ?? NSScreen.main
    if let screen {
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - sz.width / 2, y: originY(frame, sz)))
    }
}

// MARK: - HUDPanel

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool  { true  }
    override var canBecomeMain: Bool { false }
}

// MARK: - HUDContentView

/// Uses a system material and semantic colours so it follows the system light/dark
/// appearance, including switches while it is on screen. It has a fixed width and takes
/// its height from its content. Section and grid lines run to the panel edges.
final class HUDContentView: NSVisualEffectView {

    private static let width:        CGFloat = 320
    private static let padding:      CGFloat = 12
    private static let rowPadding:   CGFloat = 8
    private static let numberColumn: CGFloat = 36
    private static let bodySize:     CGFloat = 15
    private static let subSize:      CGFloat = 11

    private let stack = NSStackView()
    private var rows: [ChoiceRow] = []
    private var rowLines: [GridLine] = []
    private var hintRow: HintRow?

    init(body: HUDBody, hint: HUDHint?) {
        super.init(frame: .zero)

        material     = .hudWindow
        blendingMode = .behindWindow
        state        = .active

        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let bottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        // Below required so the panel can animate its height while rows collapse.
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            bottom,
        ])

        switch body {
        case .choices(let names, let numbered):
            for (i, name) in names.enumerated() {
                if i > 0 {
                    let line = GridLine()
                    rowLines.append(line)
                    addSection(line)
                }
                let row = ChoiceRow(number: numbered ? i + 1 : nil, name: name)
                rows.append(row)
                addSection(row)
            }
        }

        if let hint {
            addSection(GridLine())
            let row = HintRow(hint)
            hintRow = row
            addSection(row)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Once on screen, pops each row's number column in, cascading from the top row down.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        for (i, row) in rows.enumerated() {
            row.popInNumber(after: Double(i) * 0.06)
        }
    }

    /// Animates choosing row `index`: its number cell fills, then its name cell, then the
    /// other rows fade and collapse while the panel shrinks towards its top edge, and the
    /// hint changes to `hint`. With a single row and an unchanged hint only the highlight
    /// plays. Once settled the highlight pulses (with `pulses`), and `completion` is called.
    func select(_ index: Int, hint: HUDHint, pulses: Bool = true,
                completion: @escaping () -> Void) {
        guard rows.indices.contains(index) else { completion(); return }
        let row    = rows[index]
        let others = otherSections(than: index)
        let highlightOnly = others.isEmpty && hintRow?.hint == hint
        let completion = {
            if pulses { row.pulse() }
            completion()
        }

        Self.animate(row.hasNumber ? 0.15 : 0, { row.highlightNumber() }) {
            Self.animate(0.15, { row.highlightName() }) {
                if highlightOnly { completion(); return }
                Self.animate(0.2, {
                    others.forEach { $0.animator().alphaValue = 0 }
                    self.hintRow?.animator().alphaValue = 0
                }) {
                    others.forEach { $0.isHidden = true }
                    self.hintRow?.hint = hint
                    self.collapse {
                        Self.animate(0.15, { self.hintRow?.animator().alphaValue = 1 },
                                     then: completion)
                    }
                }
            }
        }
    }

    /// Lightly tints row `index` as the current candidate, clearing the previous one.
    func setCursor(_ index: Int) {
        Self.animate(0.12, {
            for (i, row) in self.rows.enumerated() { row.setCursor(i == index) }
        }) {}
    }

    /// Shrinks the window to the current fitting height, keeping its top edge, while the
    /// remaining sections slide into place.
    private func collapse(then completion: @escaping () -> Void) {
        guard let window else { completion(); return }
        var frame = window.frame
        let height = fittingSize.height
        frame.origin.y += frame.height - height
        frame.size.height = height
        Self.animate(0.25, {
            NSAnimationContext.current.allowsImplicitAnimation = true
            window.animator().setFrame(frame, display: true)
            self.layoutSubtreeIfNeeded()
        }, then: completion)
    }

    /// Every row and row line except row `index`.
    private func otherSections(than index: Int) -> [NSView] {
        rows.enumerated().filter { $0.offset != index }.map(\.element) + rowLines
    }

    private func addSection(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private static func animate(_ duration: TimeInterval, _ changes: @escaping () -> Void,
                                then completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            changes()
        }, completionHandler: completion)
    }


    fileprivate static func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                                  color: NSColor, alignment: NSTextAlignment,
                                  width: CGFloat) -> NSTextField {
        let tf = NSTextField(labelWithString: text)
        tf.font                    = .monospacedDigitSystemFont(ofSize: size, weight: weight)
        tf.textColor               = color
        tf.alignment               = alignment
        tf.lineBreakMode           = .byWordWrapping
        tf.maximumNumberOfLines    = 0
        tf.preferredMaxLayoutWidth = width
        return tf
    }

    // MARK: HintRow

    /// The hint row: leading text on the left, trailing text on the right, with optional
    /// animated dots after the leading text while on screen.
    private final class HintRow: NSView {

        var hint: HUDHint { didSet { update() } }

        private let leading  = HUDContentView.label("", size: HUDContentView.subSize,
                                                    weight: .regular, color: .secondaryLabelColor,
                                                    alignment: .natural, width: 0)
        private let trailing = HUDContentView.label("", size: HUDContentView.subSize,
                                                    weight: .regular, color: .secondaryLabelColor,
                                                    alignment: .natural, width: 0)
        private var dotsTimer: Timer?
        private var dots = 0

        init(_ hint: HUDHint) {
            self.hint = hint
            super.init(frame: .zero)
            for tf in [leading, trailing] {
                tf.maximumNumberOfLines = 1
                tf.lineBreakMode = .byTruncatingTail
                tf.translatesAutoresizingMaskIntoConstraints = false
                addSubview(tf)
            }
            trailing.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            let pad = HUDContentView.padding, rowPad = HUDContentView.rowPadding
            NSLayoutConstraint.activate([
                leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
                leading.topAnchor.constraint(equalTo: topAnchor, constant: rowPad),
                leading.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -rowPad),
                trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
                trailing.firstBaselineAnchor.constraint(equalTo: leading.firstBaselineAnchor),
                trailing.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor,
                                                  constant: pad),
            ])
            update()
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            update()
        }

        private func update() {
            trailing.stringValue = hint.trailing
            dots = 0
            dotsTimer?.invalidate()
            dotsTimer = nil
            if hint.animatesDots && window != nil {
                dotsTimer = .scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.dots = self.dots % 3 + 1
                    self.showDots()
                }
            }
            showDots()
        }

        /// Shows `dots` dots (all three when not animating), padding with clear dots so the
        /// width doesn't change.
        private func showDots() {
            guard hint.animatesDots else {
                leading.stringValue = hint.leading
                return
            }
            let shown = dotsTimer == nil ? 3 : dots
            let font  = leading.font ?? .systemFont(ofSize: HUDContentView.subSize)
            let text  = NSMutableAttributedString(
                string: hint.leading + String(repeating: ".", count: shown),
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            text.append(NSAttributedString(
                string: String(repeating: ".", count: 3 - shown),
                attributes: [.font: font, .foregroundColor: NSColor.clear]))
            leading.attributedStringValue = text
        }
    }

    // MARK: ChoiceRow

    /// One grid row: an optional number cell and a vertical line spanning the row, then the
    /// name cell. The number cell starts collapsed to zero width; `revealNumber()` grows it,
    /// sliding the number in from the left. Each cell has a light accent tint, hidden until
    /// highlighted.
    private final class ChoiceRow: NSView {

        private static let tint: () -> NSColor = { .controlAccentColor.withAlphaComponent(0.25) }

        private let nameFill = FillView(color: tint)
        private let name:      NSTextField
        private let numberCell: NumberCell?

        /// The number column, clipped to its animated width.
        private final class NumberCell: NSView {
            let fill = FillView(color: ChoiceRow.tint)
            let label: NSTextField

            init(number: Int) {
                label = HUDContentView.label("\(number)", size: HUDContentView.bodySize,
                                             weight: .medium, color: .secondaryLabelColor,
                                             alignment: .center, width: HUDContentView.numberColumn)
                super.init(frame: .zero)
                wantsLayer = true
                layer?.masksToBounds = true
                fill.alphaValue = 0
                for v in [fill, label] {
                    v.translatesAutoresizingMaskIntoConstraints = false
                    addSubview(v)
                }
                NSLayoutConstraint.activate([
                    fill.leadingAnchor.constraint(equalTo: leadingAnchor),
                    fill.trailingAnchor.constraint(equalTo: trailingAnchor),
                    fill.topAnchor.constraint(equalTo: topAnchor),
                    fill.bottomAnchor.constraint(equalTo: bottomAnchor),
                    // Pinned to the trailing edge, so the number slides in as the cell grows.
                    label.trailingAnchor.constraint(equalTo: trailingAnchor),
                    label.widthAnchor.constraint(equalToConstant: HUDContentView.numberColumn),
                ])
            }

            required init?(coder: NSCoder) { fatalError() }
        }

        private var numberWidth: NSLayoutConstraint?

        /// `number` nil leaves out the number column and its line.
        init(number n: Int?, name text: String) {
            let columns = n == nil ? 0 : HUDContentView.numberColumn + GridLine.maxThickness
            name = HUDContentView.label(text, size: HUDContentView.bodySize, weight: .medium,
                                        color: .labelColor, alignment: .natural,
                                        width: HUDContentView.width - columns
                                               - 2 * HUDContentView.padding)
            numberCell = n.map(NumberCell.init)
            super.init(frame: .zero)

            nameFill.alphaValue = 0
            for v in [nameFill, name] {
                v.translatesAutoresizingMaskIntoConstraints = false
                addSubview(v)
            }
            let pad = HUDContentView.padding, rowPad = HUDContentView.rowPadding
            var constraints = [
                name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -pad),
                name.topAnchor.constraint(equalTo: topAnchor, constant: rowPad),
                name.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -rowPad),

                nameFill.trailingAnchor.constraint(equalTo: trailingAnchor),
                nameFill.topAnchor.constraint(equalTo: topAnchor),
                nameFill.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]

            if let cell = numberCell {
                let line = GridLine()
                for v in [cell, line] {
                    v.translatesAutoresizingMaskIntoConstraints = false
                    addSubview(v)
                }
                let width = cell.widthAnchor.constraint(equalToConstant: 0)
                numberWidth = width
                constraints += [
                    cell.leadingAnchor.constraint(equalTo: leadingAnchor),
                    cell.topAnchor.constraint(equalTo: topAnchor),
                    cell.bottomAnchor.constraint(equalTo: bottomAnchor),
                    width,
                    cell.label.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),

                    line.leadingAnchor.constraint(equalTo: cell.trailingAnchor),
                    line.topAnchor.constraint(equalTo: topAnchor),
                    line.bottomAnchor.constraint(equalTo: bottomAnchor),

                    name.leadingAnchor.constraint(equalTo: line.trailingAnchor, constant: pad),
                    nameFill.leadingAnchor.constraint(equalTo: line.trailingAnchor),
                ]
            } else {
                constraints += [
                    name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
                    nameFill.leadingAnchor.constraint(equalTo: leadingAnchor),
                ]
            }
            NSLayoutConstraint.activate(constraints)
        }

        required init?(coder: NSCoder) { fatalError() }

        var hasNumber: Bool { numberCell != nil }

        /// After `delay`, pops the number column in from the left: it grows slightly past full
        /// width, then settles. (Constraint animations clamp overshooting timing curves, so
        /// the overshoot is its own step.)
        func popInNumber(after delay: TimeInterval) {
            guard numberWidth != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.animateNumberWidth(overshoot: 4, duration: 0.2) {
                    self.animateNumberWidth(overshoot: 0, duration: 0.12) {}
                }
            }
        }

        private func animateNumberWidth(overshoot: CGFloat, duration: TimeInterval,
                                        then completion: @escaping () -> Void) {
            HUDContentView.animate(duration, {
                NSAnimationContext.current.allowsImplicitAnimation = true
                self.numberWidth?.animator().constant = HUDContentView.numberColumn + overshoot
                self.layoutSubtreeIfNeeded()
            }, then: completion)
        }

        /// Pulses the highlight tint until the HUD goes away, to show work in progress.
        func pulse() {
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue      = 1
            anim.toValue        = 0.35
            anim.duration       = 0.7
            anim.autoreverses   = true
            anim.repeatCount    = .infinity
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for fill in [numberCell?.fill, nameFill].compactMap({ $0 }) {
                fill.layer?.add(anim, forKey: "pulse")
            }
        }

        /// Shows or clears the light candidate tint across the row; call inside an
        /// animation group.
        func setCursor(_ on: Bool) {
            numberCell?.label.textColor = on ? .labelColor : .secondaryLabelColor
            for fill in [numberCell?.fill, nameFill].compactMap({ $0 }) {
                fill.animator().alphaValue = on ? 0.5 : 0
            }
        }

        /// Fades in the number cell's tint; call inside an animation group.
        func highlightNumber() {
            guard let cell = numberCell else { return }
            Self.highlight(cell.fill, label: cell.label)
        }

        /// Fades in the name cell's tint; call inside an animation group.
        func highlightName() {
            Self.highlight(nameFill, label: name)
        }

        private static func highlight(_ fill: FillView, label: NSTextField) {
            label.textColor = .labelColor
            fill.animator().alphaValue = 1
        }
    }
}

// MARK: - FillView

/// A layer-backed view filled with `color`, re-resolved in `updateLayer` so it follows
/// appearance and accent colour changes.
class FillView: NSView {

    private let color: () -> NSColor

    init(color: @escaping () -> NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color().cgColor
        }
    }
}

// MARK: - GridLine

/// A one-pixel line in a translucent label colour; horizontal or vertical depending on how it
/// is constrained.
final class GridLine: FillView {

    /// Upper bound on the thickness (1pt on a 1x screen), for fixed layout sums.
    static let maxThickness: CGFloat = 1

    init() {
        super.init(color: { NSColor.labelColor.withAlphaComponent(0.3) })
    }

    required init?(coder: NSCoder) { fatalError() }

    private var thickness: CGFloat { 1 / (window?.backingScaleFactor ?? 2) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: thickness, height: thickness)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidateIntrinsicContentSize()
    }
}

// MARK: - Focus

/// DAM's system-modal Touch Bar doesn't show while a DAM window is on screen unless DAM is
/// the active app. When a HUD pairs with the Touch Bar this activates DAM, returning the
/// app that was active so `restoreFocus(to:)` can hand focus back when the HUD closes.
func activateForHUDTouchBar() -> NSRunningApplication? {
    guard !NSApp.isActive else { return nil }
    let previous = NSWorkspace.shared.frontmostApplication
    NSApp.activate(ignoringOtherApps: true)
    return previous
}

/// Hands focus back to `app`, unless the user has moved on from DAM meanwhile.
func restoreFocus(to app: NSRunningApplication?) {
    guard let app, NSApp.isActive else { return }
    app.activate(options: [])
}

// MARK: - Keys

/// The number 1–9 for a digit key press, else nil.
func hudDigit(_ event: NSEvent) -> Int? {
    switch Int(event.keyCode) {
    case kVK_ANSI_1: return 1
    case kVK_ANSI_2: return 2
    case kVK_ANSI_3: return 3
    case kVK_ANSI_4: return 4
    case kVK_ANSI_5: return 5
    case kVK_ANSI_6: return 6
    case kVK_ANSI_7: return 7
    case kVK_ANSI_8: return 8
    case kVK_ANSI_9: return 9
    default:         return nil
    }
}
