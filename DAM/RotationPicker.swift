//
//  RotationPicker.swift
//
//  The rotation hotkey's picker: the four ways up for the display under the pointer,
//  opened on the current one (or the next one, as set); each further press moves on, and
//  the choice picker handles the rest (numbers, Return, pausing, Esc, the Touch Bar and
//  speech).
//

import AppKit

private extension HUDHint {
    static let rotationPicking  = HUDHint(leading: "Hotkey for next, or press a number",
                                          trailing: "Esc to cancel")
    static let rotationChanging = HUDHint(leading: "Rotating the display", trailing: "")
}

final class RotationPicker {

    static let shared = RotationPicker()

    private weak var videoManager: VideoManager?
    /// Turns a display to a picked rotation, as the menu's rotation items do.
    private var select: ((DisplayRotation, DisplayInfo) -> Void)?
    private let picker = ChoicePicker(idPrefix: "\(AppIdentity.shortID).rotation",
                                      pickingHint: .rotationPicking,
                                      pickedHint: { _ in .rotationChanging })

    private init() {}

    func configure(videoManager: VideoManager, select: @escaping (DisplayRotation, DisplayInfo) -> Void) {
        self.videoManager = videoManager
        self.select = select
    }

    /// Opens the picker on the current rotation of the display under the pointer (or the
    /// next one, as set), or moves to the next rotation when already open. Picking the
    /// current rotation again changes nothing.
    func advance() {
        if picker.isCycling {
            picker.advance()
            return
        }
        picker.close()
        guard let vm = videoManager else { return }
        vm.refresh()
        guard let display = vm.displayUnderPointer() else { return }
        if let master = vm.anchoredMaster(of: display) {
            SpeechSynthesizer.shared.announce(Spoken.follows(display.label, master.label))
            return
        }
        guard let current = vm.rotation(of: display) else {
            SpeechSynthesizer.shared.announce(Spoken.cannotRotate(display.label))
            return
        }
        let rotations = DisplayRotation.allCases
        let currentIndex = rotations.firstIndex(of: current) ?? 0
        picker.open(choices: rotations.map(\.label),
                    cursor: ChoicePicker.startCursor(current: currentIndex, count: rotations.count)) { [weak self] i in
            guard i != currentIndex else { return }
            self?.select?(rotations[i], display)
        }
    }
}
