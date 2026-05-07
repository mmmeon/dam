//
//  ControlStripPresenter.swift
//  boar
//
//  Injects a persistent button into the macOS Control Strip (right side of the
//  Touch Bar) using private DFRFoundation APIs. The button stays visible
//  regardless of which app is in the foreground. Tapping it presents a
//  system-modal Touch Bar with audio-output and AirPlay-display switcher controls.
//
//  DFRFoundation is loaded at runtime via dlopen — no build-time link needed.
//  objc_msgSend is resolved via dlsym so casting from a raw pointer to a typed
//  @convention(c) function is valid (same pointer size; no convention mismatch).
//

import AppKit
import Darwin

// MARK: - DFRFoundation runtime bindings

private let _dfrHandle: UnsafeMutableRawPointer? = {
    dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation",
           RTLD_LAZY | RTLD_GLOBAL)
}()

/// Resolves a symbol from DFRFoundation directly via its handle.
private func dfrSym<Fn>(_ name: String) -> Fn? {
    guard let raw = dlsym(_dfrHandle, name) else { return nil }
    return unsafeBitCast(raw, to: Fn.self)   // raw pointer → fn pointer: same size, always valid
}

private typealias ShowsCloseFn  = @convention(c) (Bool) -> Void
private typealias SetPresenceFn = @convention(c) (NSString, Bool) -> Void

private let _showsClose:   ShowsCloseFn?  = dfrSym("DFRSystemModalShowsCloseBoxWhenFrontMost")
private let _setPresence:  SetPresenceFn? = dfrSym("DFRElementSetControlStripPresenceForIdentifier")

private func DFRSystemModalShowsCloseBoxWhenFrontMost(_ show: Bool) {
    _showsClose?(show)
}

private func DFRElementSetControlStripPresenceForIdentifier(
    _ identifier: NSTouchBarItem.Identifier, _ present: Bool
) {
    _setPresence?(identifier.rawValue as NSString, present)
}

// MARK: - objc_msgSend typed wrappers (resolved via dlsym)

// RTLD_DEFAULT = (void*)-2 on Darwin; not exported as a Swift constant so use the raw value.
private let _rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
private let _msgSendRaw  = dlsym(_rtldDefault, "objc_msgSend")

private typealias MsgSendPresentFn = @convention(c) (AnyObject, Selector, NSTouchBar, NSString?) -> Void
private typealias MsgSendDismissFn = @convention(c) (AnyObject, Selector, NSTouchBar) -> Void

private func msgSend_present(_ recv: AnyObject, _ sel: Selector,
                              _ bar: NSTouchBar, _ id: NSString?) {
    guard let raw = _msgSendRaw else { return }
    unsafeBitCast(raw, to: MsgSendPresentFn.self)(recv, sel, bar, id)
}

private func msgSend_dismiss(_ recv: AnyObject, _ sel: Selector, _ bar: NSTouchBar) {
    guard let raw = _msgSendRaw else { return }
    unsafeBitCast(raw, to: MsgSendDismissFn.self)(recv, sel, bar)
}

// MARK: - NSTouchBar private class-method bridge

// Internal so AirPlayQuickConnect can reuse the same bridge without duplicating
// the objc_msgSend wiring.
extension NSTouchBar {
    static func presentSystemModal(_ bar: NSTouchBar,
                                   for itemID: NSTouchBarItem.Identifier) {
        let sel = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
        msgSend_present(NSTouchBar.self, sel, bar, itemID.rawValue as NSString)
    }

    /// Present without anchoring to a control-strip item.
    static func presentSystemModal(_ bar: NSTouchBar) {
        let sel = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
        msgSend_present(NSTouchBar.self, sel, bar, nil)
    }

    static func dismissSystemModal(_ bar: NSTouchBar) {
        let sel = NSSelectorFromString("dismissSystemModalTouchBar:")
        msgSend_dismiss(NSTouchBar.self, sel, bar)
    }
}

// MARK: -

final class ControlStripPresenter: NSObject {

    // Stable identifier — the system uses this to remember the button's slot.
    private static let stripID       = NSTouchBarItem.Identifier("mmmeon.hldm.strip")
    private static let modalAudioID  = NSTouchBarItem.Identifier("mmmeon.hldm.modal.audio")
    private static let modalVideoID  = NSTouchBarItem.Identifier("mmmeon.hldm.modal.video")
    private static let speechStatusID = NSTouchBarItem.Identifier("mmmeon.hldm.speechStatus")

    // Prefixes for per-display dynamic identifiers.
    private static let displayPopoverPrefix = "mmmeon.hldm.modal.display."
    private static let displayResPrefix     = "mmmeon.hldm.modal.res."

    private weak var audioManager: AudioManager?
    private weak var videoManager: VideoManager?
    private var modalBar: NSTouchBar?

    /// Maps each resolution segmented control → (display, ordered modes) so the
    /// action handler can look up exactly which mode was chosen.
    private var resolutionSegMap: [ObjectIdentifier: (display: DisplayInfo, modes: [DisplayMode])] = [:]
    /// Maps each display button → DisplayInfo so the tap action can identify which display was chosen.
    private var displayButtonMap: [ObjectIdentifier: DisplayInfo] = [:]

    /// The display whose resolution bar is currently presented (so the delegate can build its items).
    private var activeResolutionDisplay: DisplayInfo?
    private var resolutionBar: NSTouchBar?

    init(audioManager: AudioManager, videoManager: VideoManager) {
        self.audioManager = audioManager
        self.videoManager = videoManager
        super.init()
        SpeechSynthesizer.shared.onDisplayTextChanged = { [weak self] in
            DispatchQueue.main.async {
                // Bring the app to the foreground so NSApp.touchBar is visible.
                // Only activate on the leading edge (text just appeared); on clear
                // we leave focus wherever it ended up.
                if SpeechSynthesizer.shared.displayText != nil {
                    NSApp.activate(ignoringOtherApps: true)
                }
                self?.rebuild()
            }
        }
    }

    // MARK: - Lifecycle

    /// Call once after `applicationDidFinishLaunching`.
    func install() {
        NSApp.touchBar = makeStripBar()
        DFRSystemModalShowsCloseBoxWhenFrontMost(true)
        DFRElementSetControlStripPresenceForIdentifier(Self.stripID, true)

        // On Ventura, DFRElementSetControlStripPresenceForIdentifier alone doesn't
        // render the button — a presentSystemModal call is needed to bind the item
        // view to the Control Strip slot. Present then immediately dismiss so the
        // modal doesn't stay open at launch.
        let bar = makeModalBar()
        modalBar = bar
        NSTouchBar.presentSystemModal(bar, for: Self.stripID)
        NSTouchBar.dismissSystemModal(bar)
        modalBar = nil
    }

    /// Call whenever manager state changes.
    func rebuild() {
        NSApp.touchBar = makeStripBar()
        if let bar = modalBar { updateModalBar(bar) }
    }

    // MARK: - Touch Bar construction

    private func makeStripBar() -> NSTouchBar {
        // Use templateItems directly rather than a delegate — the item must be
        // immediately available in the bar object when the system queries for it.
        let stripItem = NSCustomTouchBarItem(identifier: Self.stripID)
        let btn = NSButton(
            image: NSImage(systemSymbolName: "airplayvideo",
                           accessibilityDescription: "HLDM") ?? NSImage(),
            target: self,
            action: #selector(openModal)
        )
        btn.bezelStyle = .rounded
        stripItem.view = btn

        let bar = NSTouchBar()
        if let text = SpeechSynthesizer.shared.displayText {
            let speechItem = makeSpeechStatusItem(text: text)
            bar.templateItems  = [stripItem, speechItem]
            bar.defaultItemIdentifiers = [Self.stripID, .flexibleSpace, Self.speechStatusID]
        } else {
            bar.templateItems  = [stripItem]
            bar.defaultItemIdentifiers = [Self.stripID]
        }
        return bar
    }

    private func makeSpeechStatusItem(text: String) -> NSTouchBarItem {
        let item  = NSCustomTouchBarItem(identifier: Self.speechStatusID)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing     = 4
        stack.edgeInsets  = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)

        if let icon = NSImage(systemSymbolName: "speaker.wave.2.fill",
                              accessibilityDescription: nil) {
            let imgView = NSImageView(image: icon)
            imgView.contentTintColor = .white
            imgView.setContentHuggingPriority(.required, for: .horizontal)
            stack.addArrangedSubview(imgView)
        }

        let label = NSTextField(labelWithString: truncated(text, max: 40))
        label.textColor = .white
        label.font      = .systemFont(ofSize: 12)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(label)

        item.view = stack
        return item
    }

    private func makeModalBar() -> NSTouchBar {
        resolutionSegMap.removeAll()
        displayButtonMap.removeAll()

        var ids: [NSTouchBarItem.Identifier] = [
            Self.modalAudioID, .fixedSpaceSmall, Self.modalVideoID,
        ]

        // Right side: connected AirPlay displays + physical displays, all as buttons
        // that navigate to the resolution picker.
        let connectedAirPlay = (videoManager?.airPlayDevices ?? [])
            .filter { $0.isConnected && $0.cgDisplayID != 0 }
        let physical = videoManager?.connectedDisplays ?? []
        let rightDisplays = connectedAirPlay + physical

        if !rightDisplays.isEmpty {
            ids.append(.flexibleSpace)
            rightDisplays.forEach { ids.append(displayPopoverID(for: $0)) }
        }

        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = ids
        return bar
    }

    private func updateModalBar(_ bar: NSTouchBar) {
        if let item = bar.item(forIdentifier: Self.modalAudioID) as? NSCustomTouchBarItem {
            item.view = audioSegmented()
        }
        if let item = bar.item(forIdentifier: Self.modalVideoID) as? NSCustomTouchBarItem {
            item.view = videoSegmented()
        }
        // Display popovers rebuild their content lazily on next open — no in-place update needed.
    }

    // MARK: - Display identifier helpers

    private func displayPopoverID(for display: DisplayInfo) -> NSTouchBarItem.Identifier {
        NSTouchBarItem.Identifier(Self.displayPopoverPrefix + display.id)
    }

    private func display(for id: NSTouchBarItem.Identifier) -> DisplayInfo? {
        guard id.rawValue.hasPrefix(Self.displayPopoverPrefix) else { return nil }
        let name = String(id.rawValue.dropFirst(Self.displayPopoverPrefix.count))
        let all = (videoManager?.connectedDisplays ?? []) + (videoManager?.airPlayDevices ?? [])
        return all.first { $0.id == name }
    }

    // MARK: - Display button + resolution bar
    //
    // NSPopoverTouchBarItem doesn't expand correctly inside a DFR system-modal bar,
    // so instead each display is a plain button. Tapping it presents a new system-modal
    // bar showing the available resolutions. A ◀ back button returns to the main modal.

    private func makeDisplayButtonItem(id: NSTouchBarItem.Identifier,
                                       display: DisplayInfo) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: id)
        let btn  = NSButton(title: truncated(display.name, max: 10),
                            target: self,
                            action: #selector(displayButtonTapped(_:)))
        btn.bezelStyle = .rounded

        let isAirPlay = videoManager?.allAirPlayDevices.contains(where: { $0.id == display.id }) ?? false
        let symbolName: String?
        if isAirPlay {
            let isAirPlayMirroring = display.isMirroring || (videoManager?.isBeingMirrored(display) ?? false)
            symbolName = isAirPlayMirroring ? "square.on.square" : "airplayvideo"
        } else if display.isBuiltIn {
            symbolName = "laptopcomputer"
        } else if display.isMirroring {
            symbolName = "square.on.square"
        } else {
            symbolName = nil
        }
        if let name = symbolName,
           let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            btn.image = img
            btn.imagePosition = .imageLeading
        }

        displayButtonMap[ObjectIdentifier(btn)] = display
        item.view = btn
        return item
    }

    private func makeResolutionBar(for display: DisplayInfo) -> NSTouchBar {
        activeResolutionDisplay = display

        let isAirPlay    = videoManager?.allAirPlayDevices.contains(where: { $0.id == display.id }) ?? false
        let mirrorID     = NSTouchBarItem.Identifier(Self.displayResPrefix + display.id + ".mirror")
        let disconnectID = NSTouchBarItem.Identifier(Self.displayResPrefix + display.id + ".disconnect")
        let resID        = NSTouchBarItem.Identifier(Self.displayResPrefix + display.id)

        let allActive = ((videoManager?.allAirPlayDevices ?? []) + (videoManager?.allConnectedDisplays ?? []))
            .filter { $0.cgDisplayID != 0 }
        var ids: [NSTouchBarItem.Identifier] = []
        if allActive.count >= 2 { ids.append(mirrorID) }
        if isAirPlay { ids.append(disconnectID) }
        ids += [.flexibleSpace, resID]

        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = ids
        resolutionBar = bar
        return bar
    }

    /// Builds the mirror/extend toggle button for the resolution bar.
    private func makeMirrorToggleItem(id: NSTouchBarItem.Identifier,
                                      display: DisplayInfo) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: id)
        // For AirPlay displays the relevant state is whether something is mirroring
        // them (they are the master). For physical displays use their own isMirroring flag.
        let isAirPlay = videoManager?.allAirPlayDevices.contains(where: { $0.id == display.id }) ?? false
        let isMirroring = isAirPlay
            ? (display.isMirroring || (videoManager?.isBeingMirrored(display) ?? false))
            : display.isMirroring
        let title = isMirroring ? "Extend" : "Mirror"
        let btn = NSButton(title: title, target: self, action: #selector(mirrorToggleTapped(_:)))
        btn.bezelStyle = .rounded
        displayButtonMap[ObjectIdentifier(btn)] = display
        item.view = btn
        return item
    }

    /// Builds the segmented-control item showing available resolutions (called by the delegate).
    private func makeResolutionSegItem(id: NSTouchBarItem.Identifier,
                                       display: DisplayInfo) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: id)

        // Filter to modes matching the native aspect ratio, then cap at 5.
        let resID    = videoManager?.resolutionControlID(for: display) ?? display.cgDisplayID
        let allModes = videoManager?.availableModesDeduped(for: resID) ?? []
        let modes: [DisplayMode]
        if let native = allModes.first {
            func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
            let g = gcd(native.width, native.height)
            let arW = native.width / g, arH = native.height / g
            let sameAR = allModes.filter {
                let g2 = gcd($0.width, $0.height)
                return $0.width / g2 == arW && $0.height / g2 == arH
            }
            modes = Array(sameAR.prefix(5))
        } else {
            modes = []
        }
        let current  = videoManager?.currentMode(for: resID)

        NSLog("HLDM: makeResolutionSegItem display='%@' resID=%u modes=%d (capped from %d)",
              display.name, resID, modes.count, allModes.count)

        if modes.isEmpty {
            let tf = NSTextField(labelWithString: display.cgDisplayID == 0 ? "No display ID" : "No modes")
            tf.textColor = .white
            tf.font = .systemFont(ofSize: 12)
            item.view = tf
        } else {
            // Use compact "1440p" / "1080p" labels so all segments fit.
            let labels = modes.map { "\($0.height)p" }
            let seg = NSSegmentedControl(
                labels: labels,
                trackingMode: .selectOne,
                target: self,
                action: #selector(resolutionSegmentTapped(_:))
            )
            seg.segmentStyle = .rounded
            if let cur = current,
               let idx = modes.firstIndex(where: { $0.ioModeID == cur.ioModeID }) {
                seg.setSelected(true, forSegment: idx)
            }
            resolutionSegMap[ObjectIdentifier(seg)] = (display: display, modes: modes)
            item.view = seg
        }
        return item
    }

    // MARK: - Segment control factories

    private func audioSegmented() -> NSView {
        let devices = audioManager?.devices ?? []
        guard !devices.isEmpty else { return placeholder("No audio devices") }
        let ctrl = NSSegmentedControl(
            labels: devices.map { truncated($0.name) },
            trackingMode: .selectOne,
            target: self,
            action: #selector(audioSegmentTapped(_:))
        )
        ctrl.segmentStyle = .rounded
        if let defaultID = audioManager?.defaultDeviceID,
           let idx = devices.firstIndex(where: { $0.id == defaultID }) {
            ctrl.setSelected(true, forSegment: idx)
        }
        return ctrl
    }

    private func videoSegmented() -> NSView {
        // Only show devices that aren't already connected — connected ones appear
        // as buttons on the right side of the bar.
        let displays = (videoManager?.airPlayDevices ?? []).filter { !$0.isConnected }
        guard !displays.isEmpty else { return placeholder("No AirPlay") }
        let ctrl = NSSegmentedControl(
            labels: displays.map { truncated($0.name) },
            trackingMode: .selectAny,
            target: self,
            action: #selector(videoSegmentTapped(_:))
        )
        ctrl.segmentStyle = .rounded
        for (i, d) in displays.enumerated() where d.isConnected {
            ctrl.setSelected(true, forSegment: i)
        }
        return ctrl
    }

    private func placeholder(_ text: String) -> NSView {
        let tf = NSTextField(labelWithString: text)
        tf.textColor = .secondaryLabelColor
        tf.font = .systemFont(ofSize: 12)
        return tf
    }

    private func truncated(_ s: String, max: Int = 30) -> String {
        s.count > max ? String(s.prefix(max - 1)) + "…" : s
    }

    // MARK: - Actions

    /// Opens the system-modal Touch Bar panel. Can be called externally (e.g. from a hotkey).
    @objc func openModal() {
        audioManager?.refresh()
        videoManager?.refresh()
        let bar = makeModalBar()
        modalBar = bar
        DFRSystemModalShowsCloseBoxWhenFrontMost(true)
        NSTouchBar.presentSystemModal(bar, for: Self.stripID)
    }

    @objc private func audioSegmentTapped(_ ctrl: NSSegmentedControl) {
        let devices = audioManager?.devices ?? []
        let idx = ctrl.selectedSegment
        guard idx >= 0, idx < devices.count else { return }
        audioManager?.setDefaultDevice(devices[idx])
    }

    @objc private func videoSegmentTapped(_ ctrl: NSSegmentedControl) {
        let displays = videoManager?.airPlayDevices ?? []
        let idx = ctrl.selectedSegment
        guard idx >= 0, idx < displays.count else { return }
        videoManager?.connectAirPlay(deviceName: displays[idx].name)
    }

    @objc private func displayButtonTapped(_ btn: NSButton) {
        guard let display = displayButtonMap[ObjectIdentifier(btn)] else {
            NSLog("HLDM: displayButtonTapped – display not found in map")
            return
        }
        let modes = videoManager?.availableModesDeduped(for: display.cgDisplayID) ?? []
        NSLog("HLDM: display '%@' cgDisplayID=%u modes=%d", display.name, display.cgDisplayID, modes.count)
        let bar = makeResolutionBar(for: display)
        NSTouchBar.presentSystemModal(bar, for: Self.stripID)
    }

    private func makeDisconnectItem(id: NSTouchBarItem.Identifier,
                                    display: DisplayInfo) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: id)
        let btn  = NSButton(title: "Disconnect", target: self, action: #selector(disconnectTapped(_:)))
        btn.bezelStyle = .rounded
        displayButtonMap[ObjectIdentifier(btn)] = display
        item.view = btn
        return item
    }

    @objc private func disconnectTapped(_ btn: NSButton) {
        guard let display = displayButtonMap[ObjectIdentifier(btn)] else { return }
        videoManager?.disconnectAirPlay(deviceName: display.name)
        // Close the modal — the display is going away.
        if let bar = modalBar { NSTouchBar.dismissSystemModal(bar) }
        modalBar = nil
    }

    @objc private func mirrorToggleTapped(_ btn: NSButton) {
        guard let display = displayButtonMap[ObjectIdentifier(btn)] else { return }
        videoManager?.toggleMirroring(for: display)
        // Re-present the modal after the display config settles so the button label refreshes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.openModal()
        }
    }

    @objc private func resolutionSegmentTapped(_ seg: NSSegmentedControl) {
        guard let ctx = resolutionSegMap[ObjectIdentifier(seg)] else { return }
        let idx = seg.selectedSegment
        guard idx >= 0, idx < ctx.modes.count else { return }
        guard let vm = videoManager else { return }
        vm.setMode(ctx.modes[idx], for: vm.resolutionControlID(for: ctx.display))
    }
}

// MARK: - NSTouchBarDelegate

extension ControlStripPresenter: NSTouchBarDelegate {
    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch id {
        case Self.stripID:
            let item = NSCustomTouchBarItem(identifier: id)
            let btn = NSButton(
                image: NSImage(systemSymbolName: "airplayvideo",
                               accessibilityDescription: "HLDM") ?? NSImage(),
                target: self,
                action: #selector(openModal)
            )
            btn.bezelStyle = .rounded
            item.view = btn
            return item

        case Self.speechStatusID:
            if let text = SpeechSynthesizer.shared.displayText {
                return makeSpeechStatusItem(text: text)
            }
            return nil

        case Self.modalAudioID:
            let item = NSCustomTouchBarItem(identifier: id)
            item.view = audioSegmented()
            return item

        case Self.modalVideoID:
            let item = NSCustomTouchBarItem(identifier: id)
            item.view = videoSegmented()
            return item

        default:
            // Display button in the main modal bar.
            if let display = display(for: id) {
                return makeDisplayButtonItem(id: id, display: display)
            }

            // Resolution bar: mirror/extend toggle button.
            if id.rawValue.hasSuffix(".mirror"),
               id.rawValue.hasPrefix(Self.displayResPrefix),
               let display = activeResolutionDisplay {
                return makeMirrorToggleItem(id: id, display: display)
            }

            // Resolution bar: disconnect button (AirPlay only).
            if id.rawValue.hasSuffix(".disconnect"),
               id.rawValue.hasPrefix(Self.displayResPrefix),
               let display = activeResolutionDisplay {
                return makeDisconnectItem(id: id, display: display)
            }

            // Resolution bar: segmented control for the active display.
            if id.rawValue.hasPrefix(Self.displayResPrefix),
               !id.rawValue.hasSuffix(".mirror"),
               let display = activeResolutionDisplay {
                return makeResolutionSegItem(id: id, display: display)
            }

            return nil
        }
    }
}
