//
//  MirrorPicker.swift
//
//  The mirror hotkey's picker: for the connected AirPlay display, the choice between its
//  own desktop, showing it on one of the other displays, or on all of them. The first
//  press opens it on the current state (or the next choice, as set); each further press
//  moves on, and the choice picker handles the rest (numbers, Return, pausing, Esc, the
//  Touch Bar and speech).
//

import AppKit

private extension HUDHint {
    static let mirrorPicking = HUDHint(leading: "Hotkey for next, or press a number",
                                       trailing: "Esc to cancel")
    static let mirrorChanging = HUDHint(leading: "Changing displays", trailing: "")
}

final class MirrorPicker {

    static let shared = MirrorPicker()

    /// One entry of the picker.
    enum Choice: Equatable {
        /// The display shows its own desktop.
        case separate
        /// The given display mirrors it.
        case display(DisplayInfo)
        /// Every other display mirrors it.
        case all

        var name: String {
            switch self {
            case .separate:       return "Separate Display"
            case .display(let d): return "Mirror on \(d.name)"
            case .all:            return "Mirror on All Displays"
            }
        }
    }

    private weak var videoManager: VideoManager?
    private let picker = ChoicePicker(idPrefix: "\(AppIdentity.shortID).mirror",
                                      pickingHint: .mirrorPicking,
                                      pickedHint: { _ in .mirrorChanging })

    private init() {}

    func configure(videoManager: VideoManager) {
        self.videoManager = videoManager
    }

    // MARK: - Choices

    /// The choices for a display given the displays that can mirror it: its own desktop,
    /// each other display, and all of them when there are several.
    static func choices(targets: [DisplayInfo]) -> [Choice] {
        [.separate] + targets.map { .display($0) } + (targets.count >= 2 ? [.all] : [])
    }

    /// The choice matching the current state: the display the subject mirrors, else all
    /// when every target mirrors the subject, else the first display that does, else
    /// separate.
    static func currentChoice(in choices: [Choice], slaves: [DisplayInfo], master: DisplayInfo?) -> Int {
        if let master, let i = choices.firstIndex(of: .display(master)) { return i }
        guard let first = slaves.first else { return 0 }
        let targetCount = choices.filter { if case .display = $0 { return true } else { return false } }.count
        if slaves.count == targetCount, let all = choices.firstIndex(of: .all) { return all }
        return choices.firstIndex(of: .display(first)) ?? 0
    }

    // MARK: - Hotkey

    /// Opens the picker on the current state (or the next choice, as set), or moves to the
    /// next choice when already open. Picking the current state again changes nothing.
    func advance() {
        if picker.isCycling {
            picker.advance()
            return
        }
        picker.close()
        guard let vm = videoManager else { return }
        vm.refresh()
        guard let display = vm.airPlayDevices.first(where: { $0.isConnected && $0.cgDisplayID != 0 }) else {
            SpeechSynthesizer.shared.announce("No AirPlay display connected")
            return
        }
        let targets = vm.mirrorTargets(for: display)
        guard !targets.isEmpty else {
            SpeechSynthesizer.shared.announce("No other display to mirror")
            return
        }
        let choices = Self.choices(targets: targets)
        let current = Self.currentChoice(in: choices, slaves: vm.slaveDisplays(of: display),
                                         master: vm.masterDisplay(of: display))
        picker.open(choices: choices.map(\.name),
                    cursor: ChoicePicker.startCursor(current: current, count: choices.count)) { [weak self] i in
            guard i != current else { return }
            self?.apply(choices[i], to: display)
        }
    }

    private func apply(_ choice: Choice, to display: DisplayInfo) {
        guard let vm = videoManager else { return }
        let report: (Result<Void, VideoManager.MirrorError>) -> Void = { result in
            if case .failure(let error) = result {
                SpeechSynthesizer.shared.announce(error.localizedDescription)
            }
        }
        switch choice {
        case .separate:       vm.extend(display, completion: report)
        case .display(let d): vm.mirror(display, on: [d], completion: report)
        case .all:            vm.mirror(display, on: vm.mirrorTargets(for: display), completion: report)
        }
    }

#if DEBUG
    /// Opens the picker on sample choices, steps the cursor once, then lets it pick after
    /// the pause, silently, without changing the displays.
    func playDebugPreview() {
        picker.open(choices: ["Separate Display", "Mirror on Built-in Display",
                              "Mirror on Living Room TV", "Mirror on All Displays"],
                    cursor: 1, preview: true) { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [picker] in
            picker.previewMove(to: 2)
        }
    }
#endif
}
