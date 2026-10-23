//
//  MainDisplayPicker.swift
//
//  The main-display hotkey's picker: every display that shows its own desktop, opened on
//  the current main display (or the next one, as set); each further press moves on, and
//  the choice picker handles the rest (numbers, Return, pausing, Esc, the Touch Bar and
//  speech).
//

import AppKit

private extension HUDHint {
    static let mainChanging = HUDHint(leading: "Moving the menu bar", trailing: "")
}

final class MainDisplayPicker {

    static let shared = MainDisplayPicker()

    private weak var videoManager: VideoManager?
    private let picker = ChoicePicker(idPrefix: "\(AppIdentity.shortID).main",
                                      pickedHint: { _ in .mainChanging })

    private init() {}

    func configure(videoManager: VideoManager) {
        self.videoManager = videoManager
    }

    /// The picker's entries for `candidates` and the one that is main now, nil when none is
    /// marked.
    static func choices(from candidates: [DisplayInfo]) -> (names: [String], current: Int?) {
        (candidates.map(\.label), candidates.firstIndex(where: \.isMain))
    }

    /// Opens the picker on the current main display (or the next one, as set), or moves to
    /// the next display when already open. Picking the current main display again changes
    /// nothing.
    func advance() {
        guard !picker.advanceIfOpen(), let vm = videoManager else { return }
        vm.refresh()
        let candidates = vm.mainDisplayCandidates()
        guard candidates.count >= 2 else {
            SpeechSynthesizer.shared.announce(Spoken.noOtherDisplay)
            return
        }
        let (names, current) = Self.choices(from: candidates)
        picker.open(choices: names, current: current) { [weak self] i in
            guard i != current else { return }
            self?.videoManager?.setMainDisplay(candidates[i]) { result in
                if case .failure(let error) = result {
                    SpeechSynthesizer.shared.announce(error.localizedDescription)
                }
            }
        }
    }

#if DEBUG
    /// Plays the picker on sample displays, without changing the displays.
    func playDebugPreview() {
        picker.playPreview(["Built-in Display", "LEN T24i-20", "Living Room TV"])
    }
#endif
}
