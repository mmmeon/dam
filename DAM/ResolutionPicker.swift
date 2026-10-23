//
//  ResolutionPicker.swift
//
//  The resolution hotkey's picker: the resolutions of the display under the pointer, as
//  its menu lists them, opened on the current one (or the next one, as set); each further
//  press moves on, and the choice picker handles the rest (numbers, Return, pausing, Esc,
//  the Touch Bar and speech).
//

import AppKit

private extension HUDHint {
    static let resolutionChanging = HUDHint(leading: "Changing the resolution", trailing: "")
}

final class ResolutionPicker {

    static let shared = ResolutionPicker()

    private weak var videoManager: VideoManager?
    /// Applies a picked mode to its display, as the menu's resolution items do.
    private var select: ((DisplayMode, DisplayInfo) -> Void)?
    private let picker = ChoicePicker(idPrefix: "\(AppIdentity.shortID).resolution",
                                      pickedHint: { _ in .resolutionChanging })

    private init() {}

    func configure(videoManager: VideoManager, select: @escaping (DisplayMode, DisplayInfo) -> Void) {
        self.videoManager = videoManager
        self.select = select
    }

    /// Opens the picker on the current resolution of the display under the pointer (or the
    /// next one, as set), or moves to the next resolution when already open. Picking the
    /// current resolution again changes nothing.
    func advance() {
        guard !picker.advanceIfOpen(), let vm = videoManager else { return }
        vm.refresh()
        guard let display = ChoicePicker.displayUnderPointer(in: vm) else { return }
        let (modes, current) = vm.resolutionChoices(for: display, includeLarger1x: true).flattened()
        guard modes.count >= 2 else {
            SpeechSynthesizer.shared.announce(Spoken.noOtherResolution(for: display.label))
            return
        }
        picker.open(choices: modes.map(\.resolutionLabel), current: current) { [weak self] i in
            guard i != current else { return }
            self?.select?(modes[i], display)
        }
    }

#if DEBUG
    /// Plays the picker on sample resolutions, without changing the display.
    func playDebugPreview() {
        picker.playPreview(["2560 × 1440  HiDPI", "1920 × 1080  HiDPI", "1280 × 720  HiDPI"])
    }
#endif
}
