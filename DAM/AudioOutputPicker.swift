//
//  AudioOutputPicker.swift
//
//  A hotkey-triggered picker for the enabled audio outputs. The first press opens it on
//  the current output (or the next one, as set); each further press moves on, and the
//  choice picker handles the rest (numbers, Return, pausing, Esc, the Touch Bar and speech).
//

import AppKit
import CoreAudio

private extension HUDHint {
    static let audioPicking  = HUDHint(leading: "Hotkey for next, or press a number",
                                       trailing: "Esc to cancel")
    static let audioSwitched = HUDHint(leading: "Audio output switched", trailing: "")
}

final class AudioOutputPicker {

    static let shared = AudioOutputPicker()

    private weak var audioManager: AudioManager?
    private let picker = ChoicePicker(idPrefix: "\(AppIdentity.shortID).audio",
                                      pickingHint: .audioPicking,
                                      pickedHint: { _ in .audioSwitched })

    private init() {}

    func configure(audioManager: AudioManager) {
        self.audioManager = audioManager
    }

    /// Opens the picker on the current output (or the next one, as set), or moves to the
    /// next output when already open. Picking the current output again changes nothing.
    func advance() {
        if picker.isCycling {
            picker.advance()
            return
        }
        picker.close()
        guard let audioManager else { return }
        audioManager.refresh()
        let enabled = audioManager.devices
        guard !enabled.isEmpty else {
            SpeechSynthesizer.shared.announce("No audio outputs enabled")
            return
        }
        let current = enabled.firstIndex { $0.id == audioManager.defaultDeviceID } ?? 0
        picker.open(choices: enabled.map(\.name),
                    cursor: ChoicePicker.startCursor(current: current, count: enabled.count)) { [weak audioManager] i in
            guard let audioManager, enabled[i].id != audioManager.defaultDeviceID else { return }
            audioManager.setDefaultDevice(enabled[i])
        }
    }

#if DEBUG
    /// Opens the picker on sample outputs, steps the cursor once, then lets it pick after
    /// the pause, silently, without switching the real output.
    func playDebugPreview() {
        picker.open(choices: ["MacBook Pro Speakers", "AirPods Pro", "Living Room TV"],
                    cursor: 1, preview: true) { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [picker] in
            picker.previewMove(to: 2)
        }
    }
#endif
}
