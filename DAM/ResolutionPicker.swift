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
    static let resolutionPicking  = HUDHint(leading: "Hotkey for next, or press a number",
                                            trailing: "Esc to cancel")
    static let resolutionChanging = HUDHint(leading: "Changing the resolution", trailing: "")
}

final class ResolutionPicker {

    static let shared = ResolutionPicker()

    private weak var videoManager: VideoManager?
    /// Applies a picked mode to its display, as the menu's resolution items do.
    private var select: ((DisplayMode, DisplayInfo) -> Void)?
    private let picker = ChoicePicker(idPrefix: "\(AppIdentity.shortID).resolution",
                                      pickingHint: .resolutionPicking,
                                      pickedHint: { _ in .resolutionChanging })

    private init() {}

    func configure(videoManager: VideoManager, select: @escaping (DisplayMode, DisplayInfo) -> Void) {
        self.videoManager = videoManager
        self.select = select
    }

    /// An AirPlay display's resolutions as one list, native then virtual, and the index of
    /// the one in effect.
    static func choices(native: [DisplayMode], virtual: [DisplayMode],
                        current: (native: Int?, virtual: Int?)) -> (modes: [DisplayMode], current: Int?) {
        (native + virtual, current.native ?? current.virtual.map { native.count + $0 })
    }

    /// Opens the picker on the current resolution of the display under the pointer (or the
    /// next one, as set), or moves to the next resolution when already open. Picking the
    /// current resolution again changes nothing.
    func advance() {
        if picker.isCycling {
            picker.advance()
            return
        }
        picker.close()
        guard let vm = videoManager else { return }
        vm.refresh()
        guard let display = displayUnderPointer(vm) else { return }
        if let master = vm.anchoredMaster(of: display) {
            SpeechSynthesizer.shared.announce("\(display.label) follows \(master.label)")
            return
        }
        let (modes, current) = resolutionChoices(for: display, vm)
        guard modes.count >= 2 else {
            SpeechSynthesizer.shared.announce("No other resolution for \(display.label)")
            return
        }
        let start = current.map { ChoicePicker.startCursor(current: $0, count: modes.count) } ?? 0
        picker.open(choices: modes.map(\.resolutionLabel), cursor: start) { [weak self] i in
            guard i != current else { return }
            self?.select?(modes[i], display)
        }
    }

    /// The display whose screen holds the pointer. A screen an anchor drives stands for the
    /// display behind it.
    private func displayUnderPointer(_ vm: VideoManager) -> DisplayInfo? {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let screenID = CGDirectDisplayID(number.uint32Value)
        let cgID = vm.anchorTarget(of: screenID) ?? screenID
        return (vm.allConnectedDisplays + vm.allAirPlayDevices).first { $0.cgDisplayID == cgID }
    }

    /// The resolutions the display's menu lists, and the index of the one in effect.
    private func resolutionChoices(for display: DisplayInfo,
                                   _ vm: VideoManager) -> (modes: [DisplayMode], current: Int?) {
        if display.isSidecar, vm.hasVirtualAnchor(for: display.name) {
            let options = vm.sidecarResolutionOptions(for: display)
            return (options.modes, options.currentIndex)
        }
        if vm.displayContext(for: display) == .airPlay {
            let options = vm.airPlayResolutionOptions(for: display)
            return Self.choices(native: options.native, virtual: options.virtual, current: options.current)
        }
        let options = vm.resolutionOptions(for: display, includeLarger1x: true)
        return (options.modes, options.currentIndex)
    }

#if DEBUG
    /// Opens the picker on sample resolutions, steps the cursor once, then lets it pick after
    /// the pause, silently, without changing the display.
    func playDebugPreview() {
        picker.open(choices: ["2560 × 1440  HiDPI", "1920 × 1080  HiDPI", "1280 × 720  HiDPI"],
                    cursor: 1, preview: true) { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [picker] in
            picker.previewMove(to: 2)
        }
    }
#endif
}
