//
//  AudioOutputPicker.swift
//
//  A hotkey-triggered HUD listing the enabled audio outputs. The first press opens it on
//  the output after the current one; each further press moves on. Pressing a number picks
//  that output, Return picks the tinted one, and pausing picks it too — so a single press
//  still cycles to the next output. Esc cancels.
//

import AppKit
import Carbon.HIToolbox
import CoreAudio

private extension HUDHint {
    static let audioPicking  = HUDHint(leading: "Hotkey for next, or press a number",
                                       trailing: "Esc to cancel")
    static let audioSwitched = HUDHint(leading: "Audio output switched", trailing: "")
}

final class AudioOutputPicker {

    static let shared = AudioOutputPicker()

    /// How long after the last hotkey press the tinted output is picked.
    private static let pickDelay: TimeInterval = 1.5

    private weak var audioManager: AudioManager?
    private var devices: [AudioDevice] = []
    private var cursor = 0
    private var panel: HUDPanel?
    private var pickTimer: Timer?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    /// Set while the switch animation plays; the panel no longer takes input.
    private var isFinishing = false
    /// Debug previews show sample outputs and don't switch.
    private var isPreview = false

    private init() {}

    func configure(audioManager: AudioManager) {
        self.audioManager = audioManager
    }

    // MARK: - Hotkey

    /// Opens the picker on the output after the current one, or moves to the next output
    /// when already open.
    func advance() {
        if panel != nil && !isFinishing {
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
        let p = makeHUDPanel(nonactivating: true)
        panel = p
        layoutHUD(p, body: .choices(devices.map(\.name), numbered: true),
                  hint: .audioPicking) { frame, size in frame.midY + size.height / 2 }
        content?.setCursor(cursor)
        p.makeKeyAndOrderFront(nil)
        installMonitors()
        restartPickTimer()
    }

    private var content: HUDContentView? { panel?.contentView as? HUDContentView }

    private func move(to index: Int) {
        cursor = index
        content?.setCursor(index)
        restartPickTimer()
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
        guard !isFinishing, devices.indices.contains(index) else { return }
        isFinishing = true
        pickTimer?.invalidate()
        removeMonitors()

        let device = devices[index]
        if !isPreview {
            audioManager?.setDefaultDevice(device)
            if VisibilityPreferences.speechEnabled {
                SpeechSynthesizer.shared.speak(device.name, caption: false)
            }
        }
        content?.select(index, hint: .audioSwitched, pulses: false) { [weak self] in
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
        panel?.orderOut(nil)
        panel = nil
        isFinishing = false
        isPreview = false
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
        guard panel != nil, !isFinishing else { return false }
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

#if DEBUG
// MARK: - Debug preview

extension AudioOutputPicker {

    /// Opens the picker on sample outputs, steps the cursor once, then lets it pick after
    /// the pause — without switching the real output.
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
