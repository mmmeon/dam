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

// MARK: - Hints

private extension HUDHint {
    static let selecting  = HUDHint(leading: "Press a number to connect", trailing: "Esc to cancel")
    static let connecting = HUDHint(leading: "Connecting", trailing: "Press any key to cancel",
                                    animatesDots: true)
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
            if let n = hudDigit(event), n >= 1, n <= ds.count {
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

    // MARK: - Touch Bar

    private func showSelectingTouchBar(displays: [DisplayInfo]) {
        touchBarDisplays = displays
        dismissTouchBar()
        guard Feedback.touchBar else { return }

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
        guard Feedback.touchBar else { return }

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
        guard Feedback.screen else { return }
        // Non-activating, so the previous app keeps focus once the HUD closes.
        let p = panel ?? makeHUDPanel(nonactivating: true)
        panel = p
        layoutHUD(p, body: body, hint: hint) { frame, size in frame.midY + size.height / 2 }
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
        let p = panel ?? makeHUDPanel(nonactivating: true)
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
