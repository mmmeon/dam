//
//  AirPlayQuickConnect.swift
//
//  A hotkey-triggered HUD that lets the user pick an AirPlay display or an iPad by
//  pressing its number (keyboard) or tapping a Touch Bar button. For AirPlay the
//  Screen Mirroring panel is driven right away, up to the display's row; the row is
//  pressed once the cancel window after the HUD settles has passed, and
//  "Connecting to…" is announced once the panel closed again. An iPad is connected
//  over Sidecar once the cancel window has passed. Pressing any key or the Touch Bar
//  Cancel button before then cancels (and closes the panel).
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

// MARK: - Targets

/// Something that can be connected without a screen to click on: an AirPlay display or an
/// iPad over Sidecar. The connect hotkey and the Touch Bar list both.
enum ConnectTarget: Hashable {
    case airPlay(DisplayInfo)
    case sidecar(SidecarDevice)

    var label: String {
        switch self {
        case .airPlay(let display): return display.label
        case .sidecar(let device):  return device.label
        }
    }

    var isConnected: Bool {
        switch self {
        case .airPlay(let display): return display.isConnected
        case .sidecar(let device):  return device.isConnected
        }
    }

    /// AirPlay displays first, then iPads, connected or not.
    static func all(video: VideoManager, sidecar: SidecarManager?) -> [ConnectTarget] {
        video.airPlayDevices.map(ConnectTarget.airPlay) + (sidecar?.devices ?? []).map(ConnectTarget.sidecar)
    }

    /// "Connecting to pad over USB" for an iPad, naming the link it will use.
    var connectingAnnouncement: String {
        guard case .sidecar(let device) = self, let link = device.link else { return "Connecting to \(label)" }
        return "Connecting to \(label) over \(link.rawValue)"
    }
}

// MARK: - State

private enum QCState {
    case idle
    case selecting([ConnectTarget])
    case confirming(ConnectTarget)
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

    /// How long after the HUD settles on the chosen display a key press still cancels,
    /// before the display's row is pressed in the Screen Mirroring panel.
    private static let cancelWindow: TimeInterval = 1.5

    private weak var videoManager: VideoManager?
    private weak var sidecarManager: SidecarManager?
    private var state: QCState = .idle

    // The press waits on both: the cancel window passing and the panel finding the row.
    /// The panel driver's continuation, once it holds at the display's row.
    private var pendingPress: ((Bool) -> Void)?
    private var cancelWindowPassed = false

    // HUD
    private var panel: HUDPanel?
    /// The app to hand focus back to on dismiss, when DAM was activated for the Touch Bar.
    private var previousApp: NSRunningApplication?

    // Key monitors
    private var localMonitor: Any?
    private var globalMonitor: Any?

    // Touch Bar
    private var touchBar: NSTouchBar?
    private var touchBarDisplays: [ConnectTarget] = []

    private override init() { super.init() }

    // MARK: - Configuration

    func configure(videoManager: VideoManager, sidecarManager: SidecarManager? = nil) {
        self.videoManager = videoManager
        self.sidecarManager = sidecarManager
    }

    // MARK: - Activation (called by the GlobalHotkey)

    func activate() {
        guard let vm = videoManager else { return }

        sidecarManager?.refresh()
        let all = ConnectTarget.all(video: vm, sidecar: sidecarManager)
        guard !all.isEmpty else {
            SpeechSynthesizer.shared.announce("No AirPlay displays or iPads found")
            return
        }

        // Exclude displays that are already connected — the hotkey is for connecting,
        // not toggling. Already-active displays are announced and skipped.
        let displays = all.filter { !$0.isConnected }
        guard !displays.isEmpty else {
            SpeechSynthesizer.shared.announce(all.count == 1
                ? "Already connected to \(all[0].label)"
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

    private func startSelecting(displays: [ConnectTarget]) {
        state = .selecting(displays)

        showHUD(.choices(displays.map(\.label), numbered: true), hint: .selecting)
        installMonitor(displays: displays)
        showSelectingTouchBar(displays: displays)

        if VisibilityPreferences.speechEnabled {
            let list = displays.enumerated()
                .map { "\($0.offset + 1). \($0.element.label)" }
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
    private func startConfirming(display: ConnectTarget, choice: Int? = nil) {
        state = .confirming(display)
        pendingPress = nil
        cancelWindowPassed = false

        // Press once the cancel window after the HUD settles passes uncancelled.
        let settled = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.cancelWindow) { [weak self] in
                guard let self, case .confirming(let d) = self.state, d == display
                else { return }
                self.cancelWindowPassed = true
                self.pressIfReady()
            }
        }
        if choice == nil {
            showHUD(.choices([display.label], numbered: false), hint: .connecting)
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

        // The HUD and Touch Bar show "Connecting…"; it is spoken once the display was
        // actually selected in the Screen Mirroring panel.
        SpeechSynthesizer.shared.stop()

        switch display {
        case .airPlay(let airPlay):
            // Meanwhile the panel opens and finds the row, holding there for the press.
            videoManager?.connectAirPlay(
                deviceName: airPlay.name,
                announcing: display.connectingAnnouncement,
                gate: { [weak self] proceed in
                    guard let self, case .confirming(let d) = self.state, d == display
                    else { return proceed(false) }
                    self.pendingPress = proceed
                    self.pressIfReady()
                },
                completion: { [weak self] _ in
                    // Ended before the press (a failure, or nothing to press): drop the HUD.
                    guard let self, case .confirming(let d) = self.state, d == display
                    else { return }
                    self.dismiss()
                })
        case .sidecar(let device):
            // Nothing to prepare: connect once the cancel window passes.
            pendingPress = { [weak self] proceed in
                guard proceed, let self, let vm = self.videoManager, let sidecar = self.sidecarManager
                else { return }
                SpeechSynthesizer.shared.announce(display.connectingAnnouncement)
                sidecar.connect(device, videoManager: vm)
            }
        }
    }

    // MARK: - Connect / Cancel

    private func pressIfReady() {
        guard cancelWindowPassed, let proceed = pendingPress else { return }
        pendingPress = nil
        dismiss()
        proceed(true)
    }

    func cancel() {
        SpeechSynthesizer.shared.stop()
        let proceed = pendingPress
        dismiss()
        proceed?(false)
    }

    private func dismiss() {
        state = .idle
        pendingPress = nil
        removeMonitors()
        dismissTouchBar()
        panel?.orderOut(nil)
        panel = nil
        restoreFocus(to: previousApp)
        previousApp = nil
    }

    // MARK: - Key Monitors

    private func installMonitor(displays: [ConnectTarget]) {
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
    private func handleKey(_ event: NSEvent, displays: [ConnectTarget]) -> Bool {
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

    private func showSelectingTouchBar(displays: [ConnectTarget]) {
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

    private func showConfirmingTouchBar(display: ConnectTarget) {
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
        // Non-activating, so the previous app keeps focus — unless the Touch Bar is also
        // showing, which needs DAM active; focus is handed back on dismiss.
        let p = panel ?? makeHUDPanel(nonactivating: true)
        panel = p
        layoutHUD(p, body: body, hint: hint) { frame, size in frame.midY + size.height / 2 }
        if Feedback.touchBar && previousApp == nil { previousApp = activateForHUDTouchBar() }
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
            if case .confirming(let display) = state { name = display.label } else { name = "" }
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
            let btn = NSButton(title: "\(idx + 1).  \(truncated(display.label))",
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
