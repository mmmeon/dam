//
//  AirPlayQuickConnect.swift
//  boar
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
    static let qcCancel = NSTouchBarItem.Identifier("hldm.qc.cancel")
    static let qcStatus = NSTouchBarItem.Identifier("hldm.qc.status")
    static func qcDisplay(_ i: Int) -> NSTouchBarItem.Identifier {
        .init("hldm.qc.display.\(i)")
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
            if VisibilityPreferences.speechEnabled {
                SpeechSynthesizer.shared.speak("No AirPlay displays found")
            }
            return
        }

        // Exclude displays that are already connected — the hotkey is for connecting,
        // not toggling. Already-active displays are announced and skipped.
        let displays = all.filter { !$0.isConnected }
        guard !displays.isEmpty else {
            if VisibilityPreferences.speechEnabled {
                let msg = all.count == 1
                    ? "Already connected to \(all[0].name)"
                    : "All displays already connected"
                SpeechSynthesizer.shared.speak(msg)
            }
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

        let lines = displays.enumerated().map { "\($0.offset + 1).  \($0.element.name)" }
        showHUD(lines: lines, subtitle: "Press a number to connect  •  Esc to cancel")
        installMonitor(displays: displays)
        showSelectingTouchBar(displays: displays)

        if VisibilityPreferences.speechEnabled {
            let list = displays.enumerated()
                .map { "\($0.offset + 1). \($0.element.name)" }
                .joined(separator: ". ")
            let speech = "Select a display. \(list)"
            DispatchQueue.main.async {
                // touchBar: false — the numbered selection buttons must stay tappable.
                SpeechSynthesizer.shared.speak(speech, touchBar: false)
            }
        }
    }

    // MARK: - Confirming

    private func startConfirming(display: DisplayInfo) {
        state = .confirming(display)
        showHUD(lines: ["Connecting to \(display.name)…"], subtitle: "Press any key to cancel")

        if localMonitor == nil {
            installMonitor(displays: [])
        }

        showConfirmingTouchBar(display: display)

        SpeechSynthesizer.shared.stop()
        if VisibilityPreferences.speechEnabled {
            DispatchQueue.main.async {
                SpeechSynthesizer.shared.onFinish = { [weak self] in
                    self?.connect(display: display)
                }
                SpeechSynthesizer.shared.speak("Connecting to \(display.name)")
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.connect(display: display)
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
                startConfirming(display: ds[n - 1])
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

    private func showHUD(lines: [String], subtitle: String) {
        if panel == nil {
            let p = HUDPanel()
            p.isFloatingPanel    = true
            p.level              = .modalPanel
            p.backgroundColor    = .clear
            p.isOpaque           = false
            p.hasShadow          = true
            p.alphaValue         = 0.97
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.styleMask          = [.borderless]
            panel = p
        }

        let width:   CGFloat = 320
        let padding: CGFloat = 20
        let lineH:   CGFloat = 22
        let subH:    CGFloat = subtitle.isEmpty ? 0 : 30
        let height = padding * 2
                     + CGFloat(lines.count) * lineH
                     + (lines.count > 1 ? CGFloat(lines.count - 1) * 6 : 0)
                     + subH
        let sz = NSSize(width: width, height: height)

        let content = HUDContentView(lines: lines, subtitle: subtitle)
        content.frame = NSRect(origin: .zero, size: sz)
        panel?.contentView = content
        panel?.setContentSize(sz)

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                     ?? NSScreen.main
        if let screen {
            let ox = screen.visibleFrame.midX - sz.width  / 2
            let oy = screen.visibleFrame.midY + sz.height / 2
            panel?.setFrameOrigin(NSPoint(x: ox, y: oy))
        }

        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
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
        let prefix = "hldm.qc.display."
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
        startConfirming(display: displays[sender.tag])
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

private final class HUDContentView: NSView {

    private static let padding:     CGFloat = 20
    private static let lineSpacing: CGFloat = 6
    private static let bodySize:    CGFloat = 15
    private static let subSize:     CGFloat = 11

    init(lines: [String], subtitle: String) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        layer?.cornerRadius    = 12
        layer?.masksToBounds   = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = Self.lineSpacing
        stack.edgeInsets  = NSEdgeInsets(top: Self.padding, left: Self.padding,
                                         bottom: Self.padding, right: Self.padding)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for line in lines {
            stack.addArrangedSubview(
                label(line, size: Self.bodySize, weight: .medium,
                      color: NSColor(white: 0.95, alpha: 1))
            )
        }

        if !subtitle.isEmpty {
            let sep = NSBox()
            sep.boxType    = .separator
            sep.borderColor = NSColor(white: 0.4, alpha: 0.6)
            stack.addArrangedSubview(sep)
            stack.addArrangedSubview(
                label(subtitle, size: Self.subSize, weight: .regular,
                      color: NSColor(white: 0.65, alpha: 1))
            )
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func label(_ text: String, size: CGFloat,
                       weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let tf = NSTextField(labelWithString: text)
        tf.font                    = .monospacedDigitSystemFont(ofSize: size, weight: weight)
        tf.textColor               = color
        tf.lineBreakMode           = .byWordWrapping
        tf.maximumNumberOfLines    = 0
        tf.preferredMaxLayoutWidth = 280
        return tf
    }
}
