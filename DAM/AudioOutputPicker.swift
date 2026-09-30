//
//  AudioOutputPicker.swift
//
//  A hotkey-triggered picker for the enabled audio outputs, shown on screen and on the
//  Touch Bar, and spoken, as enabled. The first press opens it on the output after the
//  current one; each further press moves on. Pressing a number (or tapping an output on
//  the Touch Bar) picks that output, Return picks the tinted one, and pausing picks it
//  too — so a single press still cycles to the next output. Esc cancels.
//

import AppKit
import Carbon.HIToolbox
import CoreAudio

private extension HUDHint {
    static let audioPicking  = HUDHint(leading: "Hotkey for next, or press a number",
                                       trailing: "Esc to cancel")
    static let audioSwitched = HUDHint(leading: "Audio output switched", trailing: "")
}

private extension NSTouchBarItem.Identifier {
    static let audioCancel = NSTouchBarItem.Identifier("\(AppIdentity.shortID).audio.cancel")
    static func audioOutput(_ i: Int) -> NSTouchBarItem.Identifier {
        .init("\(AppIdentity.shortID).audio.output.\(i)")
    }
}

final class AudioOutputPicker: NSObject {

    static let shared = AudioOutputPicker()

    /// How long after the last hotkey press the tinted output is picked.
    private static let pickDelay: TimeInterval = 2.0

    private weak var audioManager: AudioManager?
    private var devices: [AudioDevice] = []
    private var cursor = 0
    private var isOpen = false
    /// Set while the switch animation plays; the picker no longer takes input.
    private var isFinishing = false
    /// Debug previews show sample outputs, stay silent and don't switch.
    private var isPreview = false
    /// The output last spoken, so a pick doesn't repeat it.
    private var spokenIndex: Int?
    /// The app to hand focus back to on close, when DAM was activated for the Touch Bar.
    private var previousApp: NSRunningApplication?

    private var panel: HUDPanel?
    private var touchBar: NSTouchBar?
    /// The output buttons by index, as the Touch Bar creates them.
    private var touchBarButtons: [Int: NSButton] = [:]
    private var pickTimer: Timer?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    private override init() { super.init() }

    func configure(audioManager: AudioManager) {
        self.audioManager = audioManager
    }

    // MARK: - Hotkey

    /// Opens the picker on the output after the current one, or moves to the next output
    /// when already open.
    func advance() {
        if isOpen && !isFinishing {
            move(to: (cursor + 1) % devices.count)
            return
        }
        close()
        guard let audioManager else { return }
        audioManager.refresh()
        let enabled = audioManager.devices
        guard let next = AudioManager.device(after: audioManager.defaultDeviceID, in: enabled)
        else {
            SpeechSynthesizer.shared.announce("No audio outputs enabled")
            return
        }
        open(devices: enabled, cursor: enabled.firstIndex(of: next) ?? 0)
    }

    // MARK: - Showing

    private func open(devices: [AudioDevice], cursor: Int) {
        self.devices = devices
        self.cursor  = cursor
        isOpen = true

        if Feedback.touchBar { showTouchBar() }
        if Feedback.screen {
            let p = makeHUDPanel(nonactivating: true)
            panel = p
            layoutHUD(p, body: .choices(devices.map(\.name), numbered: true),
                      hint: .audioPicking) { frame, size in frame.midY + size.height / 2 }
            content?.setCursor(cursor)
            if Feedback.touchBar { previousApp = activateForHUDTouchBar() }
            p.makeKeyAndOrderFront(nil)
            installMonitors()
        }
        speakCursor()
        restartPickTimer()
    }

    private var content: HUDContentView? { panel?.contentView as? HUDContentView }

    private func move(to index: Int) {
        cursor = index
        content?.setCursor(index)
        updateTouchBar()
        speakCursor()
        restartPickTimer()
    }

    private func speakCursor() {
        guard Feedback.voice, !isPreview else { return }
        SpeechSynthesizer.shared.speak(devices[cursor].name, caption: false)
        spokenIndex = cursor
    }

    private func restartPickTimer() {
        pickTimer?.invalidate()
        pickTimer = .scheduledTimer(withTimeInterval: Self.pickDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.pick(self.cursor)
        }
    }

    // MARK: - Picking

    private func pick(_ index: Int) {
        guard isOpen, !isFinishing, devices.indices.contains(index) else { return }
        isFinishing = true
        pickTimer?.invalidate()
        removeMonitors()
        dismissTouchBar()

        let device = devices[index]
        if !isPreview {
            audioManager?.setDefaultDevice(device)
            if Feedback.voice && spokenIndex != index {
                SpeechSynthesizer.shared.speak(device.name, caption: false)
            }
        }
        guard let content else { close(); return }
        content.select(index, hint: .audioSwitched, pulses: false) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.fadeOut() }
        }
    }

    private func fadeOut() {
        guard let p = panel, isFinishing else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if self?.panel === p { self?.close() }
        })
    }

    private func close() {
        pickTimer?.invalidate()
        pickTimer = nil
        removeMonitors()
        dismissTouchBar()
        panel?.orderOut(nil)
        panel = nil
        isOpen = false
        isFinishing = false
        isPreview = false
        spokenIndex = nil
        restoreFocus(to: previousApp)
        previousApp = nil
    }

    // MARK: - Touch Bar

    /// A button per output, numbered, with the tinted one highlighted, then Cancel.
    private func showTouchBar() {
        dismissTouchBar()
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = devices.indices.map { .audioOutput($0) }
                                     + [.flexibleSpace, .audioCancel]
        touchBar = bar
        NSTouchBar.presentSystemModal(bar, for: ControlStripPresenter.stripID)
    }

    private func updateTouchBar() {
        for (i, btn) in touchBarButtons {
            btn.bezelColor = i == cursor ? .controlAccentColor : nil
        }
    }

    private func dismissTouchBar() {
        if let bar = touchBar { NSTouchBar.dismissSystemModal(bar) }
        touchBar = nil
        touchBarButtons = [:]
    }

    @objc private func touchBarOutputTapped(_ sender: NSButton) {
        pick(sender.tag)
    }

    @objc private func touchBarCancelTapped() {
        close()
    }

    private func truncated(_ s: String, maxLength: Int = 16) -> String {
        s.count > maxLength ? String(s.prefix(maxLength - 1)) + "…" : s
    }

    // MARK: - Keys

    private func installMonitors() {
        removeMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) == true ? nil : event
        }
        // Esc still cancels if another app took focus.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Int(event.keyCode) == kVK_Escape { self?.close() }
        }
    }

    private func removeMonitors() {
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor  = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    }

    /// Returns `true` if the event was consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard isOpen, !isFinishing else { return false }
        switch Int(event.keyCode) {
        case kVK_Escape:
            close()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            pick(cursor)
        default:
            guard let n = hudDigit(event), n <= devices.count else { return false }
            pick(n - 1)
        }
        return true
    }
}

// MARK: - NSTouchBarDelegate

extension AudioOutputPicker: NSTouchBarDelegate {

    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: identifier)
        if identifier == .audioCancel {
            let btn = NSButton(title: "Cancel", target: self, action: #selector(touchBarCancelTapped))
            btn.bezelColor = .systemRed
            item.view = btn
            return item
        }
        guard let i = devices.indices.first(where: { .audioOutput($0) == identifier }) else {
            return nil
        }
        let btn = NSButton(title: "\(i + 1).  \(truncated(devices[i].name))",
                           target: self, action: #selector(touchBarOutputTapped(_:)))
        btn.tag = i
        btn.bezelColor = i == cursor ? .controlAccentColor : nil
        touchBarButtons[i] = btn
        item.view = btn
        return item
    }
}

#if DEBUG
// MARK: - Debug preview

extension AudioOutputPicker {

    /// Opens the picker on sample outputs, steps the cursor once, then lets it pick after
    /// the pause — silently, without switching the real output.
    func playDebugPreview() {
        close()
        isPreview = true
        let names = ["MacBook Pro Speakers", "AirPods Pro", "Living Room TV"]
        open(devices: names.enumerated().map { AudioDevice(id: AudioDeviceID($0.offset + 1),
                                                           name: $0.element) },
             cursor: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.isPreview, !self.isFinishing else { return }
            self.move(to: 2)
        }
    }
}
#endif
