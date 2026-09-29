//
//  AirPlayQuickConnect.swift
//
//  A hotkey-triggered HUD that lets the user pick an AirPlay display by
//  pressing its number (keyboard) or tapping a Touch Bar button, then
//  announces "Connecting to…" via TTS and mirrors after the utterance
//  finishes. Pressing any key or the Touch Bar Cancel button cancels.
//

import AppKit
import Carbon.HIToolbox

// MARK: - Touch Bar identifiers

private extension NSTouchBarItem.Identifier {
    static let qcCancel = NSTouchBarItem.Identifier("\(AppIdentity.shortID).qc.cancel")
    static let qcStatus = NSTouchBarItem.Identifier("\(AppIdentity.shortID).qc.status")
    static func qcDisplay(_ i: Int) -> NSTouchBarItem.Identifier {
        .init("\(AppIdentity.shortID).qc.display.\(i)")
    }
}

// MARK: - State

private enum QCState {
    case idle
    case selecting([DisplayInfo])
    case confirming(DisplayInfo)
}

// MARK: - AirPlayQuickConnect

final class AirPlayQuickConnect: NSObject {

    static let shared = AirPlayQuickConnect()

    private weak var videoManager: VideoManager?
    private var state: QCState = .idle

    // HUD
    private var panel: HUDPanel?

    // Key monitors
    private var localMonitor: Any?
    private var globalMonitor: Any?

    // Touch Bar
    private var touchBar: NSTouchBar?
    private var touchBarDisplays: [DisplayInfo] = []

    private override init() { super.init() }

    // MARK: - Configuration

    func configure(videoManager: VideoManager) {
        self.videoManager = videoManager
    }

    // MARK: - Activation (called by the GlobalHotkey)

    func activate() {
        guard let vm = videoManager else { return }

        let all = vm.airPlayDevices
        guard !all.isEmpty else {
            SpeechSynthesizer.shared.announce("No AirPlay displays found")
            return
        }

        // Exclude displays that are already connected — the hotkey is for connecting,
        // not toggling. Already-active displays are announced and skipped.
        let displays = all.filter { !$0.isConnected }
        guard !displays.isEmpty else {
            SpeechSynthesizer.shared.announce(all.count == 1
                ? "Already connected to \(all[0].name)"
                : "All displays already connected")
            return
        }

        if displays.count == 1 && VisibilityPreferences.autoConnectSingleDisplay {
            startConfirming(display: displays[0])
        } else {
            startSelecting(displays: displays)
        }
    }

    // MARK: - Selecting

    private func startSelecting(displays: [DisplayInfo]) {
        state = .selecting(displays)

        showHUD(.choices(displays.map(\.name), numbered: true), hint: .selecting)
        installMonitor(displays: displays)
        showSelectingTouchBar(displays: displays)

        if VisibilityPreferences.speechEnabled {
            let list = displays.enumerated()
                .map { "\($0.offset + 1). \($0.element.name)" }
                .joined(separator: ". ")
            let speech = "Select a display. \(list)"
            DispatchQueue.main.async {
                // caption: false — the numbered selection buttons must stay tappable,
                // and the HUD already lists the displays.
                SpeechSynthesizer.shared.speak(speech, caption: false)
            }
        }
    }

    // MARK: - Confirming

    /// `choice` is the row picked in the selection HUD; that HUD then animates into the
    /// connecting state. Without it, the HUD opens on the display and highlights it.
    private func startConfirming(display: DisplayInfo, choice: Int? = nil) {
        state = .confirming(display)

        // Without speech, connect shortly after the HUD settles unless cancelled first.
        let speech = VisibilityPreferences.speechEnabled
        let settled = { [weak self] in
            guard !speech else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, case .confirming(let d) = self.state, d.name == display.name
                else { return }
                self.connect(display: display)
            }
        }
        if choice == nil {
            showHUD(.choices([display.name], numbered: false), hint: .connecting)
        }
        if let content = panel?.contentView as? HUDContentView {
            content.select(choice ?? 0, hint: .connecting, completion: settled)
        } else {
            settled()
        }

        if localMonitor == nil {
            installMonitor(displays: [])
        }

        showConfirmingTouchBar(display: display)

        SpeechSynthesizer.shared.stop()
        if speech {
            DispatchQueue.main.async {
                SpeechSynthesizer.shared.onFinish = { [weak self] in
                    self?.connect(display: display)
                }
                // caption: false — the HUD and Touch Bar already show "Connecting…".
                SpeechSynthesizer.shared.speak("Connecting to \(display.name)", caption: false)
            }
        }
    }

    // MARK: - Connect / Cancel

    private func connect(display: DisplayInfo) {
        dismiss()
        videoManager?.connectAirPlay(deviceName: display.name)
    }

    func cancel() {
        SpeechSynthesizer.shared.stop()
        dismiss()
    }

    private func dismiss() {
        state = .idle
        removeMonitors()
        dismissTouchBar()
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Key Monitors

    private func installMonitor(displays: [DisplayInfo]) {
        removeMonitors()

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event, displays: displays) == true ? nil : event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Int(event.keyCode) == kVK_Escape else { return }
            self?.cancel()
        }
    }

    /// Returns `true` if the event was consumed.
    private func handleKey(_ event: NSEvent, displays: [DisplayInfo]) -> Bool {
        switch state {
        case .selecting(let ds):
            if Int(event.keyCode) == kVK_Escape { cancel(); return true }
            if let n = digitValue(event), n >= 1, n <= ds.count {
                SpeechSynthesizer.shared.stop()
                startConfirming(display: ds[n - 1], choice: n - 1)
                return true
            }

        case .confirming:
            cancel(); return true

        case .idle:
            break
        }
        return false
    }

    private func removeMonitors() {
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor  = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    }

    // MARK: - Digit helper

    private func digitValue(_ event: NSEvent) -> Int? {
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

    // MARK: - Touch Bar

    private func showSelectingTouchBar(displays: [DisplayInfo]) {
        touchBarDisplays = displays
        dismissTouchBar()

        let bar = NSTouchBar()
        bar.delegate = self
        var ids: [NSTouchBarItem.Identifier] = displays.indices.map { .qcDisplay($0) }
        ids += [.flexibleSpace, .qcCancel]
        bar.defaultItemIdentifiers = ids
        touchBar = bar
        NSTouchBar.presentSystemModal(bar)
    }

    private func showConfirmingTouchBar(display: DisplayInfo) {
        dismissTouchBar()

        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [.qcStatus, .flexibleSpace, .qcCancel]
        touchBar = bar
        NSTouchBar.presentSystemModal(bar)
    }

    private func dismissTouchBar() {
        if let bar = touchBar {
            NSTouchBar.dismissSystemModal(bar)
            touchBar = nil
        }
    }

    // MARK: - HUD

    private func showHUD(_ body: HUDBody, hint: HUDHint) {
        let p = panel ?? makeHUDPanel()
        panel = p
        layoutHUD(p, body: body, hint: hint) { frame, size in frame.midY + size.height / 2 }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }
}

#if DEBUG
// MARK: - Debug preview

extension AirPlayQuickConnect {

    /// Shows the selection HUD (or, with `connecting`, the single-display connecting HUD,
    /// playing its highlight) with sample displays, without key monitors, Touch Bar or
    /// speech, so its look can be checked (e.g. across light/dark) without real devices.
    func showDebugPreview(connecting: Bool = false) {
        let names = ["Living Room TV", "Office Apple TV", "Bedroom TV"]
        let body: HUDBody = .choices(connecting ? [names[1]] : names, numbered: !connecting)
        let hint: HUDHint = connecting ? .connecting : .selecting
        let p = panel ?? makeHUDPanel()
        panel = p
        p.ignoresMouseEvents = true
        layoutHUD(p, body: body, hint: hint) { frame, size in
            frame.midY + size.height / 2
        }
        p.orderFrontRegardless()
        if connecting {
            (p.contentView as? HUDContentView)?.select(0, hint: hint) {}
        }
    }

    /// Plays the select animation on the selection preview, choosing row `index`.
    func playDebugSelect(_ index: Int = 1) {
        guard case .idle = state else { return }
        showDebugPreview()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            (self?.panel?.contentView as? HUDContentView)?
                .select(index, hint: .connecting) {}
        }
    }

    func hideDebugPreview() {
        guard case .idle = state else { return }
        panel?.orderOut(nil)
        panel = nil
    }
}
#endif

// MARK: - CaptionHUD

/// On-screen stand-in for the Touch Bar caption on Macs without a Touch Bar: a small
/// panel near the bottom of the screen under the mouse. It never takes focus or clicks.
final class CaptionHUD {

    static let shared = CaptionHUD()

    private var panel: HUDPanel?

    private init() {}

    /// Shows `text`, or hides the caption when nil.
    func show(_ text: String?) {
        guard let text else {
            panel?.orderOut(nil)
            return
        }
        let p = panel ?? makeHUDPanel()
        panel = p
        p.ignoresMouseEvents = true
        layoutHUD(p, body: .message(text), hint: nil) { frame, _ in frame.minY + frame.height * 0.12 }
        p.orderFrontRegardless()
    }
}

// MARK: - HUD helpers

/// The borderless floating panel shared by the quick-connect HUD and captions.
private func makeHUDPanel() -> HUDPanel {
    let p = HUDPanel()
    p.isFloatingPanel    = true
    p.hidesOnDeactivate  = false   // captions show while another app is active
    p.level              = .modalPanel
    p.backgroundColor    = .clear
    p.isOpaque           = false
    p.hasShadow          = true
    p.alphaValue         = 0.97
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    p.styleMask          = [.borderless]
    return p
}

/// The hint row under a HUD's body: `leading` on the left and `trailing` on the right.
/// With `animatesDots`, "." to "..." cycle after `leading`.
private struct HUDHint: Equatable {
    var leading:  String
    var trailing: String
    var animatesDots = false

    static let selecting  = HUDHint(leading: "Press a number to connect", trailing: "Esc to cancel")
    static let connecting = HUDHint(leading: "Connecting", trailing: "Press any key to cancel",
                                    animatesDots: true)
}

/// What a HUD shows above its hint.
private enum HUDBody {
    /// A single centred message.
    case message(String)
    /// Choices drawn as grid rows. `numbered` adds a number column, which slides in from the
    /// left when the HUD appears.
    case choices([String], numbered: Bool)
}

/// Fills `panel` with `body` and `hint`, sizes it, and centres it horizontally on the
/// screen under the mouse; `originY` picks the bottom edge from that screen's visible frame
/// and the panel size.
private func layoutHUD(_ panel: NSPanel, body: HUDBody, hint: HUDHint?,
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

// MARK: - NSTouchBarDelegate

extension AirPlayQuickConnect: NSTouchBarDelegate {

    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        // Cancel button — shown in both states
        if identifier == .qcCancel {
            let item = NSCustomTouchBarItem(identifier: identifier)
            let btn  = NSButton(title: "Cancel", target: self, action: #selector(touchBarCancelTapped))
            btn.bezelColor = .systemRed
            item.view = btn
            return item
        }

        // Status label — confirming state
        if identifier == .qcStatus {
            let item = NSCustomTouchBarItem(identifier: identifier)
            let name: String
            if case .confirming(let display) = state { name = display.name } else { name = "" }
            let label = NSTextField(labelWithString: "Connecting to \(name)…")
            label.textColor = .white
            label.font = .systemFont(ofSize: 13)
            item.view = label
            return item
        }

        // Numbered display button — selecting state
        let prefix = "\(AppIdentity.shortID).qc.display."
        if identifier.rawValue.hasPrefix(prefix),
           let idx = Int(identifier.rawValue.dropFirst(prefix.count)),
           idx < touchBarDisplays.count {
            let item = NSCustomTouchBarItem(identifier: identifier)
            let display = touchBarDisplays[idx]
            let btn = NSButton(title: "\(idx + 1).  \(truncated(display.name))",
                               target: self,
                               action: #selector(touchBarDisplayTapped(_:)))
            btn.tag = idx
            item.view = btn
            return item
        }

        return nil
    }

    @objc private func touchBarCancelTapped() {
        cancel()
    }

    @objc private func touchBarDisplayTapped(_ sender: NSButton) {
        guard case .selecting(let displays) = state, sender.tag < displays.count else { return }
        SpeechSynthesizer.shared.stop()
        startConfirming(display: displays[sender.tag], choice: sender.tag)
    }

    private func truncated(_ s: String, maxLength: Int = 16) -> String {
        s.count > maxLength ? String(s.prefix(maxLength - 1)) + "…" : s
    }
}

// MARK: - HUDPanel

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool  { true  }
    override var canBecomeMain: Bool { false }
}

// MARK: - HUDContentView

/// Uses a system material and semantic colours so it follows the system light/dark
/// appearance, including switches while it is on screen. It has a fixed width and takes
/// its height from its content. Section and grid lines run to the panel edges.
private final class HUDContentView: NSVisualEffectView {

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
        case .message(let text):
            let tf = Self.label(text, size: Self.bodySize, weight: .medium, color: .labelColor,
                                alignment: .center, width: Self.width - 2 * Self.padding)
            addSection(Self.padded(tf, vertical: Self.padding))
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
    /// plays. Once settled the highlight pulses, and `completion` is called.
    func select(_ index: Int, hint: HUDHint, completion: @escaping () -> Void) {
        guard rows.indices.contains(index) else { completion(); return }
        let row    = rows[index]
        let others = otherSections(than: index)
        let highlightOnly = others.isEmpty && hintRow?.hint == hint
        let completion = {
            row.pulse()
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

    /// Wraps `view` with the standard horizontal padding and `vertical` padding.
    private static func padded(_ view: NSView, vertical: CGFloat) -> NSView {
        let box = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: padding),
            view.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -padding),
            view.topAnchor.constraint(equalTo: box.topAnchor, constant: vertical),
            view.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -vertical),
        ])
        return box
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
private class FillView: NSView {

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
private final class GridLine: FillView {

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
