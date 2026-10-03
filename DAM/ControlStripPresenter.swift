//
//  ControlStripPresenter.swift
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
private typealias GetStatusFn   = @convention(c) () -> UInt32

private let _showsClose:   ShowsCloseFn?  = dfrSym("DFRSystemModalShowsCloseBoxWhenFrontMost")
private let _setPresence:  SetPresenceFn? = dfrSym("DFRElementSetControlStripPresenceForIdentifier")
private let _getStatus:    GetStatusFn?   = dfrSym("DFRGetStatus")

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
    static let stripID               = NSTouchBarItem.Identifier("\(AppIdentity.bundleID).strip")
    private static let modalAudioID  = NSTouchBarItem.Identifier("\(AppIdentity.bundleID).modal.audio")
    private static let modalVideoID  = NSTouchBarItem.Identifier("\(AppIdentity.bundleID).modal.video")
    private static let speechStatusID = NSTouchBarItem.Identifier("\(AppIdentity.bundleID).speechStatus")
    private static let modalArrangeID = NSTouchBarItem.Identifier("\(AppIdentity.bundleID).modal.arrange")
    private static let audioBackID    = NSTouchBarItem.Identifier("\(AppIdentity.bundleID).audio.back")
    private static let audioSegID     = NSTouchBarItem.Identifier("\(AppIdentity.bundleID).audio.outputs")

    // Prefixes for per-display dynamic identifiers.
    private static let displayPopoverPrefix = "\(AppIdentity.bundleID).modal.display."
    private static let displayResPrefix     = "\(AppIdentity.bundleID).modal.res."

    private weak var audioManager: AudioManager?
    private weak var videoManager: VideoManager?
    private var modalBar: NSTouchBar?

    /// Maps each resolution segmented control → (display, ordered modes) so the
    /// action handler can look up exactly which mode was chosen.
    private var resolutionSegMap: [ObjectIdentifier: (display: DisplayInfo, modes: [DisplayMode])] = [:]
    /// Maps each display button → DisplayInfo so the tap action can identify which display was chosen.
    private var displayButtonMap: [ObjectIdentifier: DisplayInfo] = [:]
    /// Maps each button of the mirror-targets page → the pick it stands for.
    private var mirrorChoiceMap: [ObjectIdentifier: MirrorSelection] = [:]

    /// The display whose resolution bar is currently presented (so the delegate can build its items).
    private var activeResolutionDisplay: DisplayInfo?
    private var activeResolutionPage: DisplayPage = .resolutions
    /// External and built-in displays have two pages: pick a resolution, then its refresh rate.
    /// Any display with several others to mirror on has a page to pick them.
    private enum DisplayPage { case resolutions, rates, mirrorTargets }
    private var resolutionBar: NSTouchBar?
    /// The audio outputs page, while it is presented.
    private var audioBar: NSTouchBar?

    init(audioManager: AudioManager, videoManager: VideoManager) {
        self.audioManager = audioManager
        self.videoManager = videoManager
        super.init()
        SpeechSynthesizer.shared.onSpokenLengthChanged = {
            CaptionHUD.shared.setSpoken(SpeechSynthesizer.shared.spokenLength)
        }
        SpeechSynthesizer.shared.onDisplayTextChanged = { [weak self] in
            DispatchQueue.main.async {
                let text = SpeechSynthesizer.shared.displayText
                // On screen, without taking focus.
                CaptionHUD.shared.show(Feedback.screen ? text : nil,
                                       spoken: SpeechSynthesizer.shared.spokenLength)
                guard Feedback.touchBar else { return }
                // Bring the app to the foreground so NSApp.touchBar is visible.
                // Only activate on the leading edge (text just appeared); on clear
                // we leave focus wherever it ended up.
                if text != nil {
                    NSApp.activate(ignoringOtherApps: true)
                }
                self?.rebuild()
            }
        }
    }

    /// The caption to show on the Touch Bar, unless Touch Bar feedback is off.
    private static var captionText: String? {
        VisibilityPreferences.touchBarFeedback ? SpeechSynthesizer.shared.displayText : nil
    }

    /// True when a Touch Bar is usable right now. DFRGetStatus bit 0 is set while the
    /// Touch Bar is up; it is clear on Macs without one, and briefly at login and wake.
    static var isTouchBarAvailable: Bool {
        #if DEBUG
        // `-DAMDebugNoTouchBar YES` behaves as a Mac without one, e.g. to see captions.
        if UserDefaults.standard.bool(forKey: "DAMDebugNoTouchBar") { return false }
        #endif
        return (_getStatus?() ?? 0) & 0x1 != 0
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
        if let bar = audioBar, let item = bar.item(forIdentifier: Self.audioSegID) as? NSCustomTouchBarItem {
            item.view = audioSegmented()
        }
        refreshResolutionBar()
    }

    /// Re-presents an open resolution bar for the current state of its display, so its
    /// mirror / extend button and modes follow a change made elsewhere. Closes it when the
    /// display has gone away.
    private func refreshResolutionBar() {
        guard let bar = resolutionBar, let stale = activeResolutionDisplay else { return }
        let all = (videoManager?.airPlayDevices ?? []) + (videoManager?.connectedDisplays ?? [])
        guard let fresh = all.first(where: { $0.id == stale.id && $0.cgDisplayID != 0 }) else {
            NSTouchBar.dismissSystemModal(bar)
            resolutionBar = nil
            return
        }
        showDisplayPage(fresh, activeResolutionPage)
    }

    // MARK: - Touch Bar construction

    private func makeStripBar() -> NSTouchBar {
        // Use templateItems directly rather than a delegate — the item must be
        // immediately available in the bar object when the system queries for it.
        let stripItem = NSCustomTouchBarItem(identifier: Self.stripID)
        let btn = NSButton(
            image: NSImage(systemSymbolName: "airplayvideo",
                           accessibilityDescription: AppIdentity.name) ?? NSImage(),
            target: self,
            action: #selector(openModal)
        )
        btn.bezelStyle = .rounded
        stripItem.view = btn

        let bar = NSTouchBar()
        if let text = Self.captionText {
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
        mirrorChoiceMap.removeAll()
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = modalItemIdentifiers()
        return bar
    }

    /// The modal bar's items for the current state: the arrange flow (with two or more
    /// desktops), the audio outputs page and the AirPlay picker on the left, then a button
    /// per connected AirPlay and physical display that opens its resolutions.
    private func modalItemIdentifiers() -> [NSTouchBarItem.Identifier] {
        var ids: [NSTouchBarItem.Identifier] = []
        if (videoManager?.currentLayout().placements.count ?? 0) >= 2 { ids.append(Self.modalArrangeID) }
        ids += [Self.modalAudioID, .fixedSpaceSmall, Self.modalVideoID]
        let connectedAirPlay = (videoManager?.airPlayDevices ?? [])
            .filter { $0.isConnected && $0.cgDisplayID != 0 }
        let physical = videoManager?.connectedDisplays ?? []
        let rightDisplays = connectedAirPlay + physical
        if !rightDisplays.isEmpty {
            ids.append(.flexibleSpace)
            rightDisplays.forEach { ids.append(displayPopoverID(for: $0)) }
        }
        return ids
    }

    /// Brings an open modal bar up to date in place: the pickers, which displays are
    /// listed, and each display button's mirror / anchor icon.
    private func updateModalBar(_ bar: NSTouchBar) {
        if let item = bar.item(forIdentifier: Self.modalVideoID) as? NSCustomTouchBarItem {
            item.view = videoSegmented()
        }
        let ids = modalItemIdentifiers()
        if bar.defaultItemIdentifiers != ids { bar.defaultItemIdentifiers = ids }
        for id in ids {
            guard let display = display(for: id),
                  let item = bar.item(forIdentifier: id) as? NSCustomTouchBarItem else { continue }
            if let old = item.view as? NSButton { displayButtonMap.removeValue(forKey: ObjectIdentifier(old)) }
            item.view = displayButton(for: display)
        }
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
        item.view = displayButton(for: display)
        return item
    }

    /// A button for `display` in the modal bar, with its current mirror / anchor icon.
    private func displayButton(for display: DisplayInfo) -> NSButton {
        let btn = NSButton(title: truncated(display.label, max: 10),
                           target: self,
                           action: #selector(displayButtonTapped(_:)))
        btn.bezelStyle = .rounded

        // Same rule as the menu: sparkles while a virtual anchor drives the display, the
        // mirror symbol while it is in a mirror set as slave or master.
        let isAirPlay    = videoManager?.allAirPlayDevices.contains(where: { $0.id == display.id }) ?? false
        let hasAnchor    = videoManager?.hasVirtualAnchor(for: display.name) ?? false
        let mirrorActive = display.isMirroring || (videoManager?.isBeingMirrored(display) ?? false)
        let symbolName: String?
        if hasAnchor {
            symbolName = "sparkles"
        } else if mirrorActive {
            symbolName = "square.on.square"
        } else if isAirPlay {
            symbolName = "airplayvideo"
        } else if display.isBuiltIn {
            symbolName = "laptopcomputer"
        } else {
            symbolName = nil
        }
        if let name = symbolName,
           let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            btn.image = img
            btn.imagePosition = .imageLeading
        }

        displayButtonMap[ObjectIdentifier(btn)] = display
        return btn
    }

    /// The display a tapped button stands for, in its current state rather than as it was
    /// when the button was made.
    private func tappedDisplay(_ btn: NSButton) -> DisplayInfo? {
        guard let stale = displayButtonMap[ObjectIdentifier(btn)] else { return nil }
        return latest(stale) ?? stale
    }

    /// The current entry for `display`, or nil once it has gone.
    private func latest(_ display: DisplayInfo) -> DisplayInfo? {
        let all = (videoManager?.airPlayDevices ?? []) + (videoManager?.connectedDisplays ?? [])
        return all.first { $0.id == display.id }
    }

    private func makeResolutionBar(for display: DisplayInfo, page: DisplayPage) -> NSTouchBar {
        activeResolutionDisplay = display
        activeResolutionPage    = page
        let bar = NSTouchBar()
        bar.delegate = self
        resolutionBar = bar

        if page == .rates {
            bar.defaultItemIdentifiers = [
                NSTouchBarItem.Identifier(Self.displayResPrefix + display.id + ".back"),
                .flexibleSpace,
                NSTouchBarItem.Identifier(Self.displayResPrefix + display.id + ".rates"),
            ]
            return bar
        }
        if page == .mirrorTargets {
            mirrorChoiceMap.removeAll()
            let targets = videoManager?.mirrorTargets(for: display) ?? []
            var ids: [NSTouchBarItem.Identifier] = [
                NSTouchBarItem.Identifier(Self.displayResPrefix + display.id + ".back"), .flexibleSpace,
            ]
            ids += targets.indices.map {
                NSTouchBarItem.Identifier(Self.displayResPrefix + display.id + ".target.\($0)")
            }
            if targets.count >= 2 {
                ids.append(NSTouchBarItem.Identifier(Self.displayResPrefix + display.id + ".target.all"))
            }
            bar.defaultItemIdentifiers = ids
            return bar
        }

        let isAirPlay    = videoManager?.allAirPlayDevices.contains(where: { $0.id == display.id }) ?? false
        let mirrorID     = NSTouchBarItem.Identifier(Self.displayResPrefix + display.id + ".mirror")
        let mirrorOnID   = NSTouchBarItem.Identifier(Self.displayResPrefix + display.id + ".mirroron")
        let mainID       = NSTouchBarItem.Identifier(Self.displayResPrefix + display.id + ".main")
        let optimizeID   = NSTouchBarItem.Identifier(Self.displayResPrefix + display.id + ".optimize")
        let disconnectID = NSTouchBarItem.Identifier(Self.displayResPrefix + display.id + ".disconnect")
        let resID        = NSTouchBarItem.Identifier(Self.displayResPrefix + display.id)

        let targets = videoManager?.mirrorTargets(for: display) ?? []
        let inSet   = display.isMirroring || (videoManager?.isBeingMirrored(display) ?? false)
        var ids: [NSTouchBarItem.Identifier] = []
        // Same rule as the menu: one other display gets a toggle; several get a "Mirror…"
        // page, with "Extend" alongside while this display has slaves.
        if !targets.isEmpty && (inSet || targets.count == 1) { ids.append(mirrorID) }
        if targets.count >= 2 && !display.isMirroring { ids.append(mirrorOnID) }
        if videoManager?.canBeMain(display) ?? false { ids.append(mainID) }
        // Mirrors the menu's "Optimize for": a slave can be promoted to the set's master
        // without leaving mirror mode.
        if display.isMirroring { ids.append(optimizeID) }
        if isAirPlay { ids.append(disconnectID) }
        ids += [.flexibleSpace, resID]
        bar.defaultItemIdentifiers = ids
        return bar
    }

    /// Presents `page` of `display`'s resolution bar, replacing any presented one.
    private func showDisplayPage(_ display: DisplayInfo, _ page: DisplayPage) {
        if let existing = resolutionBar { NSTouchBar.dismissSystemModal(existing) }
        NSTouchBar.presentSystemModal(makeResolutionBar(for: display, page: page), for: Self.stripID)
    }

    /// Builds the mirror/extend toggle button for the resolution bar.
    private func makeMirrorToggleItem(id: NSTouchBarItem.Identifier,
                                      display: DisplayInfo) -> NSTouchBarItem {
        // Same rule as the menu: the display is mirroring whether it is the slave or the
        // master of a set, and a virtual anchor does not count.
        let isMirroring = display.isMirroring || (videoManager?.isBeingMirrored(display) ?? false)
        return displayActionItem(id: id, title: isMirroring ? "Extend" : "Mirror", display: display,
                                 action: #selector(mirrorToggleTapped(_:)))
    }

    /// A button on the mirror-targets page: one display that can mirror `display`, tinted
    /// while it does, or "All", tinted while every one does.
    private func makeMirrorTargetItem(id: NSTouchBarItem.Identifier, display: DisplayInfo,
                                      key: String) -> NSTouchBarItem? {
        guard let vm = videoManager else { return nil }
        let targets = vm.mirrorTargets(for: display)
        let slaves  = Set(vm.slaveDisplays(of: display).map(\.id))
        let selection: MirrorSelection
        let title: String
        let active: Bool
        if key == "all" {
            selection = MirrorSelection(display: display, target: nil)
            title     = "All"
            active    = slaves.count == targets.count
        } else {
            guard let i = Int(key), targets.indices.contains(i) else { return nil }
            selection = MirrorSelection(display: display, target: targets[i])
            title     = truncated(targets[i].label, max: 12)
            active    = slaves.contains(targets[i].id)
        }
        let item = NSCustomTouchBarItem(identifier: id)
        let btn  = NSButton(title: title, target: self, action: #selector(mirrorTargetTapped(_:)))
        btn.bezelStyle = .rounded
        btn.bezelColor = active ? .controlAccentColor : nil
        mirrorChoiceMap[ObjectIdentifier(btn)] = selection
        item.view = btn
        return item
    }

    /// A button acting on `display`; the action looks the display up in `displayButtonMap`.
    private func displayActionItem(id: NSTouchBarItem.Identifier, title: String,
                                   display: DisplayInfo, action: Selector) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: id)
        let btn  = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .rounded
        displayButtonMap[ObjectIdentifier(btn)] = display
        item.view = btn
        return item
    }

    /// Builds the resolution segments for a display's first page (called by the delegate):
    /// one segment per size, capped at 5 and keeping the current size visible; a tap opens
    /// the rates page. AirPlay lists its native sizes, then its virtual ones.
    private func makeResolutionSegItem(id: NSTouchBarItem.Identifier,
                                       display: DisplayInfo) -> NSTouchBarItem {
        let options  = resolutionChoices(for: display)
        let window   = Self.window(options.modes, around: options.currentIndex, limit: 5)
        let selected = options.currentIndex.map { $0 - window.startIndex }
        return modeSegmentsItem(id: id, display: display, modes: Array(window),
                                labels: window.map { $0.shortLabel }, selected: selected,
                                action: #selector(resolutionPickTapped(_:)))
    }

    /// The sizes on a display's resolution page and the index of the one in effect.
    private func resolutionChoices(for display: DisplayInfo) -> (modes: [DisplayMode], currentIndex: Int?) {
        guard let vm = videoManager else { return ([], nil) }
        guard vm.displayContext(for: display) == .airPlay else { return vm.resolutionOptions(for: display) }
        let options = vm.airPlayResolutionOptions(for: display)
        return Self.airPlayResolutionChoices(native: options.native, virtual: options.virtual,
                                             current: options.current)
    }

    /// AirPlay sizes for the Touch Bar: the native ones in the aspect ratio of the largest,
    /// then the virtual ones; the current index points into the combined list.
    static func airPlayResolutionChoices(native: [DisplayMode], virtual: [DisplayMode],
                                         current: (native: Int?, virtual: Int?))
        -> (modes: [DisplayMode], currentIndex: Int?) {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        func aspect(_ m: DisplayMode) -> (Int, Int) {
            let g = gcd(m.width, m.height)
            return (m.width / g, m.height / g)
        }
        let largest = native.first.map(aspect)
        let kept = native.indices.filter { i in largest.map { aspect(native[i]) == $0 } ?? true }
        let currentIndex = current.native.flatMap { kept.firstIndex(of: $0) }
            ?? current.virtual.map { kept.count + $0 }
        return (kept.map { native[$0] } + virtual, currentIndex)
    }

    /// Builds the refresh-rate segments for a display's second page: rates at the current
    /// resolution, capped at 5 and keeping the current rate visible.
    /// Native rate → native mode; virtual rate → virtual anchor.
    private func makeRateSegItem(id: NSTouchBarItem.Identifier,
                                 display: DisplayInfo) -> NSTouchBarItem {
        let allModes = videoManager.map {
            $0.displayContext(for: display) == .airPlay
                ? $0.airPlayRateOptions(for: display)
                : $0.refreshRateOptions(for: display)?.modes ?? []
        } ?? []
        let current  = videoManager?.currentModes(for: display)
        let currentIdx = VideoManager.currentModeIndex(
            in: allModes, anchorCurrent: current?.anchor, nativeCurrent: current?.native)
        let window = Self.window(allModes, around: currentIdx, limit: 5)
        return modeSegmentsItem(id: id, display: display, modes: Array(window),
                                labels: window.map { $0.rateLabel },
                                selected: currentIdx.map { $0 - window.startIndex },
                                action: #selector(resolutionSegmentTapped(_:)))
    }

    /// A segmented control of `modes` for `display`, or a "No modes" label when empty.
    /// The action looks the tapped mode up in `resolutionSegMap`.
    private func modeSegmentsItem(id: NSTouchBarItem.Identifier, display: DisplayInfo,
                                  modes: [DisplayMode], labels: [String], selected: Int?,
                                  action: Selector) -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: id)
        NSLog("\(AppIdentity.name) segItem: display='%@' id=%@ cgID=%u selected=%d",
              display.name, id.rawValue, display.cgDisplayID, selected ?? -1)
        for (i, m) in modes.enumerated() {
            NSLog("\(AppIdentity.name) segItem:   modes[%d] %dx%d @%.1fHz virtual=%d ioModeID=%d label='%@'",
                  i, m.width, m.height, m.refreshRate, m.isVirtual, m.ioModeID, labels[i])
        }
        guard !modes.isEmpty else {
            let tf = NSTextField(labelWithString: display.cgDisplayID == 0 ? "No display ID" : "No modes")
            tf.textColor = .white
            tf.font = .systemFont(ofSize: 12)
            item.view = tf
            return item
        }
        let seg = NSSegmentedControl(labels: labels, trackingMode: .selectOne,
                                     target: self, action: action)
        seg.segmentStyle = .rounded
        if let selected { seg.setSelected(true, forSegment: selected) }
        resolutionSegMap[ObjectIdentifier(seg)] = (display: display, modes: modes)
        item.view = seg
        return item
    }

    // MARK: - Segment control factories

    private func audioSegmented() -> NSView {
        let devices = audioManager?.devices ?? []
        guard !devices.isEmpty else { return placeholder("No audio devices") }
        let ctrl = NSSegmentedControl(
            labels: devices.map { truncated($0.label) },
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

    /// AirPlay devices offered for connection — connected ones appear as buttons on the
    /// right side of the bar instead. Segment indices in `videoSegmented()` index this list.
    private var connectableAirPlayDevices: [DisplayInfo] {
        (videoManager?.airPlayDevices ?? []).filter { !$0.isConnected }
    }

    private func videoSegmented() -> NSView {
        let displays = connectableAirPlayDevices
        guard !displays.isEmpty else {
            let anyConnected = videoManager?.airPlayDevices.contains { $0.isConnected } ?? false
            return placeholder(anyConnected ? "AirPlay connected" : "No AirPlay")
        }
        let ctrl = NSSegmentedControl(
            labels: displays.map { truncated($0.label) },
            trackingMode: .selectAny,
            target: self,
            action: #selector(videoSegmentTapped(_:))
        )
        ctrl.segmentStyle = .rounded
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
        if let existing = resolutionBar { NSTouchBar.dismissSystemModal(existing); resolutionBar = nil }
        if let existing = audioBar { NSTouchBar.dismissSystemModal(existing); audioBar = nil }
        if let existing = modalBar { NSTouchBar.dismissSystemModal(existing) }
        let bar = makeModalBar()
        modalBar = bar
        DFRSystemModalShowsCloseBoxWhenFrontMost(true)
        NSTouchBar.presentSystemModal(bar, for: Self.stripID)
    }

    /// Opens the arrange flow in place of the modal bar; it comes back here when done.
    @objc private func arrangeTapped() {
        guard let vm = videoManager else { return }
        ArrangeTouchBar.shared.start(videoManager: vm) { [weak self] in self?.openModal() }
    }

    /// Presents the audio outputs page over the modal bar.
    @objc private func audioPageTapped() {
        if let existing = audioBar { NSTouchBar.dismissSystemModal(existing) }
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [Self.audioBackID, .flexibleSpace, Self.audioSegID]
        audioBar = bar
        NSTouchBar.presentSystemModal(bar, for: Self.stripID)
    }

    @objc private func audioBackTapped() {
        openModal()
    }

    /// Picks the output, then returns to the modal bar.
    @objc private func audioSegmentTapped(_ ctrl: NSSegmentedControl) {
        let devices = audioManager?.devices ?? []
        let idx = ctrl.selectedSegment
        guard idx >= 0, idx < devices.count else { return }
        audioManager?.setDefaultDevice(devices[idx])
        openModal()
    }

    @objc private func videoSegmentTapped(_ ctrl: NSSegmentedControl) {
        let displays = connectableAirPlayDevices
        let idx = ctrl.selectedSegment
        guard idx >= 0, idx < displays.count else { return }
        videoManager?.connectAirPlay(deviceName: displays[idx].name,
                                     announcing: "Selected \(displays[idx].label)")
    }

    @objc private func displayButtonTapped(_ btn: NSButton) {
        guard let display = tappedDisplay(btn) else {
            NSLog("\(AppIdentity.name): displayButtonTapped – display not found in map")
            return
        }
        NSLog("\(AppIdentity.name): display '%@' cgDisplayID=%u", display.name, display.cgDisplayID)
        showDisplayPage(display, .resolutions)
    }

    @objc private func backToResolutionsTapped(_ btn: NSButton) {
        guard let display = tappedDisplay(btn) else { return }
        showDisplayPage(display, .resolutions)
    }


    @objc private func disconnectTapped(_ btn: NSButton) {
        guard let display = tappedDisplay(btn) else { return }
        videoManager?.disconnectAirPlay(deviceName: display.name,
                                        announcing: "Deselected \(display.label)")
        // Close the modal — the display is going away.
        if let bar = modalBar { NSTouchBar.dismissSystemModal(bar) }
        modalBar = nil
    }

    @objc private func optimizeTapped(_ btn: NSButton) {
        guard let display = tappedDisplay(btn) else { return }
        // Re-present the modal once the display config has settled so the buttons refresh.
        videoManager?.setAsOptimizedDisplay(display) { [weak self] result in
            if case .failure(let error) = result {
                SpeechSynthesizer.shared.announce(error.localizedDescription)
            }
            self?.openModal()
        }
    }

    @objc private func mainTapped(_ btn: NSButton) {
        guard let display = tappedDisplay(btn) else { return }
        // Re-present the modal once the arrangement has settled so the tint refreshes.
        videoManager?.setMainDisplay(display) { [weak self] result in
            if case .failure(let error) = result {
                SpeechSynthesizer.shared.announce(error.localizedDescription)
            }
            self?.openModal()
        }
    }

    @objc private func mirrorOnTapped(_ btn: NSButton) {
        guard let display = tappedDisplay(btn) else { return }
        showDisplayPage(display, .mirrorTargets)
    }

    @objc private func mirrorTargetTapped(_ btn: NSButton) {
        guard let selection = mirrorChoiceMap[ObjectIdentifier(btn)] else { return }
        // Re-present the page once the change has settled so the tints refresh.
        videoManager?.applyMirrorSelection(selection) { [weak self] result in
            if case .failure(let error) = result {
                SpeechSynthesizer.shared.announce(error.localizedDescription)
            }
            guard let self, let display = self.latest(selection.display) else { return }
            self.showDisplayPage(display, .mirrorTargets)
        }
    }

    @objc private func mirrorToggleTapped(_ btn: NSButton) {
        guard let display = tappedDisplay(btn) else { return }
        // Re-present the modal once the display config has settled so the label refreshes.
        videoManager?.toggleMirroring(for: display) { [weak self] result in
            if case .failure(let error) = result {
                SpeechSynthesizer.shared.announce(error.localizedDescription)
            }
            self?.openModal()
        }
    }

    @objc private func resolutionSegmentTapped(_ seg: NSSegmentedControl) {
        guard let ctx = resolutionSegMap[ObjectIdentifier(seg)] else { return }
        let idx = seg.selectedSegment
        guard idx >= 0, idx < ctx.modes.count, let vm = videoManager else { return }
        let mode = ctx.modes[idx]
        if mode.isVirtual {
            // Virtual mode: enable anchor if needed, then set mode.
            vm.selectVirtualMode(mode, for: ctx.display)
        } else {
            applyNativeMode(mode, for: ctx.display)
        }
    }

    /// Resolution page: tapping the current resolution opens its rates; tapping another
    /// switches to it, then opens its rates once the change has settled.
    @objc private func resolutionPickTapped(_ seg: NSSegmentedControl) {
        guard let ctx = resolutionSegMap[ObjectIdentifier(seg)] else { return }
        let idx = seg.selectedSegment
        guard idx >= 0, idx < ctx.modes.count, let vm = videoManager else { return }
        let mode    = ctx.modes[idx]
        let display = ctx.display
        let options = resolutionChoices(for: display)
        let isCurrent = options.currentIndex.map {
            let cur = options.modes[$0]
            return cur.width == mode.width && cur.height == mode.height
                && cur.isHiDPI == mode.isHiDPI && cur.isVirtual == mode.isVirtual
        } ?? false
        guard !isCurrent else {
            showDisplayPage(display, .rates)
            return
        }
        let delay: TimeInterval
        if mode.isVirtual {
            // Starting an anchor takes a few seconds (the menu waits 4 s before rebuilding).
            delay = vm.hasVirtualAnchor(for: display.name) ? 0 : 3.3
            vm.selectVirtualMode(mode, for: display)
        } else {
            delay = applyNativeMode(mode, for: display)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.7) { [weak self] in
            self?.showDisplayPage(display, .rates)
        }
    }

    /// Sets a native mode, first tearing down the display's virtual anchor if one is active.
    /// Returns how long until the mode change is issued.
    @discardableResult
    private func applyNativeMode(_ mode: DisplayMode, for display: DisplayInfo) -> TimeInterval {
        guard let vm = videoManager else { return 0 }
        guard vm.hasVirtualAnchor(for: display.name) else {
            vm.setMode(mode, for: display.cgDisplayID)
            return 0
        }
        vm.disableVirtualAnchor(for: display)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            vm.setMode(mode, for: display.cgDisplayID)
        }
        return 0.8
    }

    // MARK: - Segment windowing (extracted for testability)

    /// Up to `limit` consecutive items, positioned so the item at `current` stays visible
    /// (centred where possible). With no current item, the first `limit` items are kept.
    static func window<T>(_ items: [T], around current: Int?, limit: Int) -> ArraySlice<T> {
        guard items.count > limit else { return items[...] }
        let start = min(max((current ?? 0) - limit / 2, 0), items.count - limit)
        return items[start..<start + limit]
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
                               accessibilityDescription: AppIdentity.name) ?? NSImage(),
                target: self,
                action: #selector(openModal)
            )
            btn.bezelStyle = .rounded
            item.view = btn
            return item

        case Self.speechStatusID:
            if let text = Self.captionText {
                return makeSpeechStatusItem(text: text)
            }
            return nil

        case Self.modalAudioID:
            // "Audio" opens the outputs page.
            let item = NSCustomTouchBarItem(identifier: id)
            let btn = NSButton(title: "Audio", target: self, action: #selector(audioPageTapped))
            btn.bezelStyle = .rounded
            if let img = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil) {
                btn.image = img
                btn.imagePosition = .imageLeading
            }
            item.view = btn
            return item

        case Self.audioBackID:
            let item = NSCustomTouchBarItem(identifier: id)
            let btn = NSButton(title: "◀", target: self, action: #selector(audioBackTapped))
            btn.bezelStyle = .rounded
            item.view = btn
            return item

        case Self.audioSegID:
            let item = NSCustomTouchBarItem(identifier: id)
            item.view = audioSegmented()
            return item

        case Self.modalVideoID:
            let item = NSCustomTouchBarItem(identifier: id)
            item.view = videoSegmented()
            return item

        case Self.modalArrangeID:
            let item = NSCustomTouchBarItem(identifier: id)
            let btn = NSButton(title: "Arrange", target: self, action: #selector(arrangeTapped))
            btn.bezelStyle = .rounded
            if let img = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil) {
                btn.image = img
                btn.imagePosition = .imageLeading
            }
            item.view = btn
            return item

        default:
            // Display button in the main modal bar.
            if let display = display(for: id) {
                return makeDisplayButtonItem(id: id, display: display)
            }

            // Resolution bar items, keyed by suffix after the display's identifier.
            guard let display = activeResolutionDisplay,
                  id.rawValue.hasPrefix(Self.displayResPrefix + display.id) else { return nil }
            let suffix = String(id.rawValue.dropFirst((Self.displayResPrefix + display.id).count))
            if suffix.hasPrefix(".target.") {
                return makeMirrorTargetItem(id: id, display: display,
                                            key: String(suffix.dropFirst(".target.".count)))
            }
            switch suffix {
            case ".mirror":
                return makeMirrorToggleItem(id: id, display: display)
            case ".mirroron":
                return displayActionItem(id: id, title: "Mirror…", display: display,
                                         action: #selector(mirrorOnTapped(_:)))
            case ".main":
                // "Main", tinted while this is the main display.
                let item = displayActionItem(id: id, title: "Main", display: display,
                                             action: #selector(mainTapped(_:)))
                (item.view as? NSButton)?.bezelColor = display.isMain ? .controlAccentColor : nil
                return item
            case ".optimize":
                // "Optimize for this Display" (mirror slaves only).
                return displayActionItem(id: id, title: "Optimize", display: display,
                                         action: #selector(optimizeTapped(_:)))
            case ".disconnect":
                return displayActionItem(id: id, title: "Disconnect", display: display,
                                         action: #selector(disconnectTapped(_:)))
            case ".back":
                return displayActionItem(id: id, title: "◀ Resolution", display: display,
                                         action: #selector(backToResolutionsTapped(_:)))
            case ".rates":
                return makeRateSegItem(id: id, display: display)
            case "":
                return makeResolutionSegItem(id: id, display: display)
            default:
                return nil
            }
        }
    }
}
