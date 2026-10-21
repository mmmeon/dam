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
    static let audioSwitched = HUDHint(leading: "Audio output switched", trailing: "")
}

final class AudioOutputPicker {

    static let shared = AudioOutputPicker()

    private weak var audioManager: AudioManager?
    private let picker = ChoicePicker(idPrefix: "\(AppIdentity.shortID).audio",
                                      pickedHint: { _ in .audioSwitched })

    private init() {}

    func configure(audioManager: AudioManager) {
        self.audioManager = audioManager
    }

    /// Opens the picker on the current output (or the next one, as set), or moves to the
    /// next output when already open. Picking the current output again changes nothing.
    func advance() {
        guard !picker.advanceIfOpen(), let audioManager else { return }
        audioManager.refresh()
        let enabled = audioManager.devices
        guard !enabled.isEmpty else {
            SpeechSynthesizer.shared.announce(Spoken.noAudioOutputs)
            return
        }
        let current = enabled.firstIndex { $0.id == audioManager.defaultDeviceID } ?? 0
        picker.open(choices: enabled.map(\.label),
                    cursor: ChoicePicker.startCursor(current: current, count: enabled.count)) { [weak audioManager] i in
            guard let audioManager, enabled[i].id != audioManager.defaultDeviceID else { return }
            audioManager.setDefaultDevice(enabled[i])
        }
    }

#if DEBUG
    /// Plays the picker on sample outputs, without switching the real output.
    func playDebugPreview() {
        picker.playPreview(["MacBook Pro Speakers", "AirPods Pro", "Living Room TV"])
    }
#endif
}
