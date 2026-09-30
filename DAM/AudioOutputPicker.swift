//
//  AudioOutputPicker.swift
//
//  A hotkey-triggered picker for the enabled audio outputs. The first press opens it on
//  the output after the current one; each further press moves on, and the choice picker
//  handles the rest (numbers, Return, pausing, Esc, the Touch Bar and speech).
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

    /// Opens the picker on the output after the current one, or moves to the next output
    /// when already open.
    func advance() {
        if picker.isCycling {
            picker.advance()
            return
        }
        picker.close()
        guard let audioManager else { return }
        audioManager.refresh()
        let enabled = audioManager.devices
        guard let next = AudioManager.device(after: audioManager.defaultDeviceID, in: enabled)
        else {
            SpeechSynthesizer.shared.announce("No audio outputs enabled")
            return
        }
        picker.open(choices: enabled.map(\.name),
                    cursor: enabled.firstIndex(of: next) ?? 0) { [weak audioManager] i in
            audioManager?.setDefaultDevice(enabled[i])
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
