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
    static let mainPicking  = HUDHint(leading: "Hotkey for next, or press a number",
                                      trailing: "Esc to cancel")
    static let mainChanging = HUDHint(leading: "Moving the menu bar", trailing: "")
}

final class MainDisplayPicker {

    static let shared = MainDisplayPicker()

    private weak var videoManager: VideoManager?
    private let picker = ChoicePicker(idPrefix: "\(AppIdentity.shortID).main",
                                      pickingHint: .mainPicking,
                                      pickedHint: { _ in .mainChanging })

    private init() {}

    func configure(videoManager: VideoManager) {
        self.videoManager = videoManager
    }

    /// The picker's entries for `candidates` and the one that is main now (the first when
    /// none is marked).
    static func choices(from candidates: [DisplayInfo]) -> (names: [String], current: Int) {
        (candidates.map(\.name), candidates.firstIndex(where: \.isMain) ?? 0)
    }

    /// Opens the picker on the current main display (or the next one, as set), or moves to
    /// the next display when already open. Picking the current main display again changes
    /// nothing.
    func advance() {
        if picker.isCycling {
            picker.advance()
            return
        }
        picker.close()
        guard let vm = videoManager else { return }
        vm.refresh()
        let candidates = vm.mainDisplayCandidates()
        guard candidates.count >= 2 else {
            SpeechSynthesizer.shared.announce("No other display")
            return
        }
        let (names, current) = Self.choices(from: candidates)
        picker.open(choices: names,
                    cursor: ChoicePicker.startCursor(current: current, count: names.count)) { [weak self] i in
            guard i != current else { return }
            self?.videoManager?.setMainDisplay(candidates[i]) { result in
                if case .failure(let error) = result {
                    SpeechSynthesizer.shared.announce(error.localizedDescription)
                }
            }
        }
    }

#if DEBUG
    /// Opens the picker on sample displays, steps the cursor once, then lets it pick after
    /// the pause, silently, without changing the displays.
    func playDebugPreview() {
        picker.open(choices: ["Built-in Display", "LEN T24i-20", "Living Room TV"],
                    cursor: 1, preview: true) { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [picker] in
            picker.previewMove(to: 2)
        }
    }
#endif
}
