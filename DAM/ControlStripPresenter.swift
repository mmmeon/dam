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
    /// The system-modal bars DAM has presented and not dismissed.
    private static let presentedSystemModals = NSHashTable<NSTouchBar>.weakObjects()

    /// Whether any system-modal bar of DAM's shows: the switcher's, a picker's, or another.
    static var anySystemModalShowing: Bool {
        presentedSystemModals.allObjects.contains { $0.isVisible }
    }

    // Every system-modal bar gets the system's close box while another app is active,
    // whatever is set: the setter takes no bar, and on macOS 13 it is an empty function. So a
    // bar whose pick is still to come watches for being closed (see `ModalBarWatch`).
    static func presentSystemModal(_ bar: NSTouchBar,
                                   for itemID: NSTouchBarItem.Identifier) {
        let sel = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
        msgSend_present(NSTouchBar.self, sel, bar, itemID.rawValue as NSString)
        presentedSystemModals.add(bar)
        // Set before presenting only, the close box shows once another app comes to the
        // front; set again after, it shows at once.
        DFRSystemModalShowsCloseBoxWhenFrontMost(true)
    }

    /// Present without anchoring to a control-strip item.
    static func presentSystemModal(_ bar: NSTouchBar) {
        let sel = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
        msgSend_present(NSTouchBar.self, sel, bar, nil)
        presentedSystemModals.add(bar)
        DFRSystemModalShowsCloseBoxWhenFrontMost(true)
    }

    static func dismissSystemModal(_ bar: NSTouchBar) {
        let sel = NSSelectorFromString("dismissSystemModalTouchBar:")
        msgSend_dismiss(NSTouchBar.self, sel, bar)
        presentedSystemModals.remove(bar)
    }
}

// MARK: - Watching a bar

/// Checks now and then whether a system-modal bar still shows, and says once it has stopped,
/// as when its close box was tapped: the system tells nothing of that. It ticks in the common
/// modes, so it goes on while an alert or a menu is up.
final class ModalBarWatch {
    private var timer: Timer?
    private var visibility = SwitcherVisibility()

    var isWatching: Bool { timer != nil }

    /// Starts watching what `showing` reports, unless already watching. `ended` is called once,
    /// with `.closed` when it was seen showing and no longer is, or `.unknown` when it never
    /// was seen showing.
    func start(showing: @escaping () -> Bool, ended: @escaping (SwitcherVisibility.State) -> Void) {
        guard timer == nil else { return }
        visibility = SwitcherVisibility()
        let timer = Timer(timeInterval: SwitcherVisibility.interval, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let state = self.visibility.check(showing: showing())
            guard state != .open else { return }
            self.stop()
            ended(state)
        }
        // The alert's and the menu's modes by name too: AppKit may make them common only
        // once the first one runs.
        for mode in [RunLoop.Mode.common, .modalPanel, .eventTracking] { RunLoop.main.add(timer, forMode: mode) }
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
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
    /// The switcher's own close button, in place of the system's close box, which isn't shown
    /// while DAM is the active app.
    static let modalCloseID           = NSTouchBarItem.Identifier("\(AppIdentity.bundleID).modal.close")
    private static let audioSegID     = NSTouchBarItem.Identifier("\(AppIdentity.bundleID).audio.outputs")

    // Prefixes for per-display dynamic identifiers.
    private static let displayPopoverPrefix = "\(AppIdentity.bundleID).modal.display."
    static let displayResPrefix             = "\(AppIdentity.bundleID).modal.res."

    private weak var audioManager: AudioManager?
    private weak var videoManager: VideoManager?
    private weak var sidecarManager: SidecarManager?
    private var modalBar: NSTouchBar?

    /// Maps each resolution segmented control → (display, ordered modes) so the
    /// action handler can look up exactly which mode was chosen.
    private var resolutionSegMap: [ObjectIdentifier: (display: DisplayInfo, modes: [DisplayMode])] = [:]
    /// Maps each display button → DisplayInfo so the tap action can identify which display was chosen.
    private var displayButtonMap: [ObjectIdentifier: DisplayInfo] = [:]
    /// Maps each button of the mirror-targets page → the pick it stands for.
    private var mirrorChoiceMap: [ObjectIdentifier: MirrorSelection] = [:]
    /// Maps each audio outputs control → the devices its segments stand for, as built.
    private var audioSegMap: [ObjectIdentifier: [AudioDevice]] = [:]
    /// Maps each connect control → the displays and iPads its segments stand for, as built.
    private var videoSegMap: [ObjectIdentifier: [ConnectTarget]] = [:]

    /// The display whose resolution bar is currently presented (so the delegate can build its items).
    private var activeResolutionDisplay: DisplayInfo?
    private var activeResolutionPage: DisplayPage = .resolutions
    /// External and built-in displays have two pages: pick a resolution, then its refresh rate.
    /// Any display with several others to mirror on has a page to pick them.
    private enum DisplayPage { case resolutions, rates, mirrorTargets }
    private var resolutionBar: NSTouchBar?
    /// The audio outputs page, while it is presented.
    private var audioBar: NSTouchBar?

    /// Called once the switcher opened with `openModal` has closed, however it closed: its
    /// close box, or a pick that took its last bar away. Never where the system doesn't say
    /// whether its bars show.
    var onModalClose: (() -> Void)?
    /// Called instead of `onModalClose` when the system never said whether the switcher's bars
    /// show, so whether it closed is not known.
    var onModalWatchGaveUp: (() -> Void)?
    /// Checks whether the switcher still shows, while it may.
    private let closeWatch = ModalBarWatch()
    /// Counts the switcher's closes, so a change that settles after one doesn't bring it back.
    private var closes = SwitcherCloses()

    init(audioManager: AudioManager, videoManager: VideoManager, sidecarManager: SidecarManager? = nil) {
        self.audioManager = audioManager
        self.videoManager = videoManager
        self.sidecarManager = sidecarManager
        super.init()
        SpeechSynthesizer.shared.onSpokenLengthChanged = {
            CaptionHUD.shared.setSpoken(SpeechSynthesizer.shared.spokenLength)
        }
        SpeechSynthesizer.shared.onDisplayTextChanged = { [weak self] in
            DispatchQueue.main.async {
                Self.showCaptionOnScreen()
                guard Feedback.touchBar else { return }
                self?.rebuild()
            }
        }
        // The Touch Bar stops showing a caption when another app comes forward; the screen
        // takes it over.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { _ in
            if SpeechSynthesizer.shared.displayText != nil && !Feedback.screen { Self.showCaptionOnScreen() }
        }
    }

    /// Shows the caption on screen, without taking focus, when screen feedback is on or the
    /// Touch Bar can't show it. The app's Touch Bar shows only while the app is active, and a
    /// caption doesn't activate it: most come from something no one pressed a key for (a
    /// session starting, a stream ending), and focus taken then would take the user's typing.
    private static func showCaptionOnScreen() {
        let onTouchBar = Feedback.touchBar && NSApp.isActive
        let text = SpeechSynthesizer.shared.displayText
        CaptionHUD.shared.show(Feedback.screen || !onTouchBar ? text : nil,
                               spoken: SpeechSynthesizer.shared.spokenLength)
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

        // The close button comes and goes as DAM becomes the active app and stops being it,
        // on every page of the switcher.
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if let bar = self.modalBar { self.updateModalBar(bar) }
                if let bar = self.audioBar { bar.defaultItemIdentifiers = self.audioItemIdentifiers() }
                self.refreshResolutionBar()
                ArrangeTouchBar.shared.activeAppChanged()
            }
        }
    }

    /// Call whenever manager state changes.
    func rebuild() {
        NSApp.touchBar = makeStripBar()
        if let bar = modalBar { updateModalBar(bar) }
        if let bar = audioBar, let item = bar.item(forIdentifier: Self.audioSegID) as? NSCustomTouchBarItem {
            audioSegMap.removeValue(forKey: ObjectIdentifier(item.view))
            item.view = audioSegmented()
        }
        refreshResolutionBar()
    }

    /// Brings an open resolution bar up to date in place for the current state of its
    /// display, so its mirror / extend button and modes follow a change made elsewhere.
    /// In place rather than presented again, so a bar closed with its close box stays closed.
    /// Closes it when the display has gone away.
    private func refreshResolutionBar() {
        guard let bar = resolutionBar, let stale = activeResolutionDisplay else { return }
        let all = (videoManager?.airPlayDevices ?? []) + (videoManager?.connectedDisplays ?? [])
        guard let fresh = all.first(where: { $0.id == stale.id && $0.cgDisplayID != 0 }) else {
            closeResolutionBar()
            return
        }
        activeResolutionDisplay = fresh
        let ids = resolutionItemIdentifiers(for: fresh, page: activeResolutionPage)
        if bar.defaultItemIdentifiers != ids { bar.defaultItemIdentifiers = ids }
        if activeResolutionPage == .mirrorTargets { mirrorChoiceMap.removeAll() }
        for id in ids {
            guard let item = bar.item(forIdentifier: id) as? NSCustomTouchBarItem,
                  let made = touchBar(bar, makeItemForIdentifier: id) as? NSCustomTouchBarItem else { continue }
            // The replaced view's entries go, as updateModalBar's do, so the maps don't grow.
            resolutionSegMap.removeValue(forKey: ObjectIdentifier(item.view))
            displayButtonMap.removeValue(forKey: ObjectIdentifier(item.view))
            item.view = made.view
        }
    }

    /// Dismisses the resolution bar, if one is up, and forgets it, so rebuilds leave it be.
    private func closeResolutionBar() {
        if let bar = resolutionBar { NSTouchBar.dismissSystemModal(bar) }
        resolutionBar = nil
        activeResolutionDisplay = nil
    }

    // MARK: - Touch Bar construction

    private func makeStripBar() -> NSTouchBar {
        // Use templateItems directly rather than a delegate — the item must be
        // immediately available in the bar object when the system queries for it.
        let stripItem = makeStripItem()

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

    /// The Control Strip button, which opens the modal bar.
    private func makeStripItem() -> NSCustomTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: Self.stripID)
        let btn = NSButton(
            image: NSImage(systemSymbolName: "airplayvideo",
                           accessibilityDescription: AppIdentity.name) ?? NSImage(),
            target: self,
            action: #selector(openModal)
        )
        btn.bezelStyle = .rounded
        item.view = btn
        return item
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

        let label = NSTextField(labelWithString: text.truncated(to: 40))
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
        audioSegMap.removeAll()
        videoSegMap.removeAll()
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = modalItemIdentifiers()
        return bar
    }

    /// The modal bar's items for the current state: the arrange flow (with two or more
    /// desktops), the audio outputs page and the AirPlay picker on the left, then a button
    /// per connected AirPlay and physical display that opens its resolutions.
    private func modalItemIdentifiers() -> [NSTouchBarItem.Identifier] {
        var ids: [NSTouchBarItem.Identifier] = NSApp.isActive ? [Self.modalCloseID] : []
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
            videoSegMap.removeValue(forKey: ObjectIdentifier(item.view))
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
        let btn = NSButton(title: display.label.truncated(to: 10),
                           target: self,
                           action: #selector(displayButtonTapped(_:)))
        btn.bezelStyle = .rounded

        // The menu's state symbol, else one for the kind of display.
        let isAirPlay = videoManager?.allAirPlayDevices.contains(where: { $0.id == display.id }) ?? false
        let symbolName: String?
        if let state = videoManager.flatMap({ displayStateSymbol(for: display, video: $0) }) {
            symbolName = state
        } else if isAirPlay {
            symbolName = "airplayvideo"
        } else if display.isBuiltIn {
            symbolName = "laptopcomputer"
        } else if display.isSidecar {
            symbolName = "ipad"
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
        if page == .mirrorTargets { mirrorChoiceMap.removeAll() }
        bar.defaultItemIdentifiers = resolutionItemIdentifiers(for: display, page: page)
        return bar
    }

    /// The ways out of a display's page, put before its items: DAM's own close button while
    /// DAM is the active app, as the system shows no close box then, and on the resolutions
    /// page a ◀ back to the switcher. The other pages have a ◀ back to the resolutions page.
    static func pageExits(displayID: String, onResolutions: Bool, damActive: Bool) -> [NSTouchBarItem.Identifier] {
        (damActive ? [modalCloseID] : [])
            + (onResolutions ? [NSTouchBarItem.Identifier(displayResPrefix + displayID + ".switcher")] : [])
    }

    /// The items of `page` of `display`'s resolution bar, for its current state, its ways out first.
    private func resolutionItemIdentifiers(for display: DisplayInfo, page: DisplayPage) -> [NSTouchBarItem.Identifier] {
        Self.pageExits(displayID: display.id, onResolutions: page == .resolutions, damActive: NSApp.isActive)
            + pageItemIdentifiers(for: display, page: page)
    }

    private func pageItemIdentifiers(for display: DisplayInfo, page: DisplayPage) -> [NSTouchBarItem.Identifier] {
        if page == .rates {
            return [
                NSTouchBarItem.Identifier(Self.displayResPrefix + display.id + ".back"),
                .flexibleSpace,
                NSTouchBarItem.Identifier(Self.displayResPrefix + display.id + ".rates"),
            ]
        }
        if page == .mirrorTargets {
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
            return ids
        }

        let isAirPlay    = videoManager?.allAirPlayDevices.contains(where: { $0.id == display.id }) ?? false
        let mirrorID     = NSTouchBarItem.Identifier(Self.displayResPrefix + display.id + ".mirror")
        let mirrorOnID   = NSTouchBarItem.Identifier(Self.displayResPrefix + display.id + ".mirroron")
        let mainID       = NSTouchBarItem.Identifier(Self.displayResPrefix + display.id + ".main")
        let optimizeID   = NSTouchBarItem.Identifier(Self.displayResPrefix + display.id + ".optimize")
        let disconnectID = NSTouchBarItem.Identifier(Self.displayResPrefix + display.id + ".disconnect")
        let resID        = NSTouchBarItem.Identifier(Self.displayResPrefix + display.id)

        let targets = videoManager?.mirrorTargets(for: display) ?? []
        let inSet   = videoManager?.isInMirrorSet(display) ?? false
        var ids: [NSTouchBarItem.Identifier] = []
        // Same rule as the menu: one other display gets a toggle; several get a "Mirror…"
        // page, with "Extend" alongside while this display has slaves.
        if !targets.isEmpty && (inSet || targets.count == 1) { ids.append(mirrorID) }
        if targets.count >= 2 && !display.isMirroring { ids.append(mirrorOnID) }
        if videoManager?.canBeMain(display) ?? false { ids.append(mainID) }
        // Mirrors the menu's "Optimize for": a slave can be promoted to the set's master
        // without leaving mirror mode.
        if display.isMirroring { ids.append(optimizeID) }
        if isAirPlay || display.isSidecar { ids.append(disconnectID) }
        ids += [.flexibleSpace, resID]
        return ids
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
        let isMirroring = videoManager?.isInMirrorSet(display) ?? false
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
            title     = targets[i].label.truncated(to: 12)
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
        // Same rule as the menu: a display mirroring an anchored iPad runs at the anchor's
        // size, and setting a mode on it would make the anchor mirror it instead.
        if let vm = videoManager, let master = vm.anchoredMaster(of: display) {
            let size = vm.currentModes(for: master).anchor.map { " · \($0.shortLabel)" } ?? ""
            let item = NSCustomTouchBarItem(identifier: id)
            item.view = placeholder("Follows \(master.label.truncated(to: 16))\(size)")
            return item
        }
        let options  = resolutionChoices(for: display)
        let window   = Self.window(options.modes, around: options.current, limit: 5)
        let selected = options.current.map { $0 - window.startIndex }
        return modeSegmentsItem(id: id, display: display, modes: Array(window),
                                labels: window.map { $0.shortLabel }, selected: selected,
                                action: #selector(resolutionPickTapped(_:)))
    }

    /// The sizes on a display's resolution page and the index of the one in effect. AirPlay
    /// lists only its native sizes in the aspect ratio of the largest, then its virtual ones.
    private func resolutionChoices(for display: DisplayInfo) -> (modes: [DisplayMode], current: Int?) {
        videoManager?.resolutionChoices(for: display).flattened(nativeInLargestAspect: true) ?? ([], nil)
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
        NSLog("\(AppIdentity.name) segItem: display='%@' id=%@ cgID=%u modes=%d selected=%d",
              display.name, id.rawValue, display.cgDisplayID, modes.count, selected ?? -1)
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
            labels: devices.map { $0.label.truncated(to: 30) },
            trackingMode: .selectOne,
            target: self,
            action: #selector(audioSegmentTapped(_:))
        )
        ctrl.segmentStyle = .rounded
        if let defaultID = audioManager?.defaultDeviceID,
           let idx = devices.firstIndex(where: { $0.id == defaultID }) {
            ctrl.setSelected(true, forSegment: idx)
        }
        audioSegMap[ObjectIdentifier(ctrl)] = devices
        return ctrl
    }

    /// AirPlay displays and iPads offered for connection — connected ones appear as buttons
    /// on the right side of the bar instead.
    private var connectableTargets: [ConnectTarget] {
        guard let vm = videoManager else { return [] }
        return ConnectTarget.all(video: vm, sidecar: sidecarManager).filter { !$0.isConnected }
    }

    private func videoSegmented() -> NSView {
        let displays = connectableTargets
        guard !displays.isEmpty else {
            let anyConnected = videoManager.map { ConnectTarget.all(video: $0, sidecar: sidecarManager) }?
                .contains { $0.isConnected } ?? false
            return placeholder(anyConnected ? "Displays connected" : "No AirPlay or iPads")
        }
        let ctrl = NSSegmentedControl(
            labels: displays.map { $0.label.truncated(to: 30) },
            trackingMode: .selectAny,
            target: self,
            action: #selector(videoSegmentTapped(_:))
        )
        ctrl.segmentStyle = .rounded
        videoSegMap[ObjectIdentifier(ctrl)] = displays
        return ctrl
    }

    private func placeholder(_ text: String) -> NSView {
        let tf = NSTextField(labelWithString: text)
        tf.textColor = .secondaryLabelColor
        tf.font = .systemFont(ofSize: 12)
        return tf
    }

    // MARK: - Actions

    /// Opens the system-modal Touch Bar panel. Can be called externally (e.g. from a hotkey).
    @objc func openModal() {
        audioManager?.refresh()
        videoManager?.refresh()
        closeResolutionBar()
        if let existing = audioBar { NSTouchBar.dismissSystemModal(existing); audioBar = nil }
        if let existing = modalBar { NSTouchBar.dismissSystemModal(existing) }
        let bar = makeModalBar()
        modalBar = bar
        DFRSystemModalShowsCloseBoxWhenFrontMost(true)
        NSTouchBar.presentSystemModal(bar, for: Self.stripID)
        watchForClose()
    }

    /// Checks now and then whether any of the switcher's bars shows, its pages and the arrange
    /// flow's included, until it has closed: the system tells nothing of its close box. Any
    /// other bar of DAM's counts too: a picker over the switcher hides it without closing it.
    private func watchForClose() {
        closeWatch.start(showing: { NSTouchBar.anySystemModalShowing }) { [weak self] state in
            guard let self else { return }
            switch state {
            case .closed:
                self.closes.closed()
                self.onModalClose?()
            case .unknown:
                self.onModalWatchGaveUp?()
            case .open:
                break
            }
        }
    }

    /// `body`, to run once a change has settled, made to do nothing if the switcher has been
    /// closed by then: a change still settling doesn't bring a closed switcher back.
    private func unlessClosedMeanwhile(_ body: @escaping (ControlStripPresenter) -> Void) -> () -> Void {
        let closesNow = closes.count
        return { [weak self] in
            guard let self, self.closes.noneSince(closesNow) else { return }
            body(self)
        }
    }

    /// Opens the arrange flow in place of the modal bar; it comes back here when done, unless
    /// the switcher was closed meanwhile.
    @objc private func arrangeTapped() {
        guard let vm = videoManager else { return }
        ArrangeTouchBar.shared.start(videoManager: vm,
                                     back: unlessClosedMeanwhile { $0.openModal() },
                                     close: { [weak self] in self?.modalCloseTapped() })
    }

    /// Presents the audio outputs page over the modal bar.
    @objc private func audioPageTapped() {
        closeResolutionBar()
        if let existing = audioBar { NSTouchBar.dismissSystemModal(existing) }
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = audioItemIdentifiers()
        audioBar = bar
        NSTouchBar.presentSystemModal(bar, for: Self.stripID)
    }

    @objc private func audioBackTapped() {
        openModal()
    }

    private func audioItemIdentifiers() -> [NSTouchBarItem.Identifier] {
        (NSApp.isActive ? [Self.modalCloseID] : []) + [Self.audioBackID, .flexibleSpace, Self.audioSegID]
    }

    /// Closes the switcher, its pages and the arrange flow included, as its close box would.
    @objc private func modalCloseTapped() {
        closeResolutionBar()
        ArrangeTouchBar.shared.close()
        for bar in [audioBar, modalBar].compactMap({ $0 }) { NSTouchBar.dismissSystemModal(bar) }
        audioBar = nil
        modalBar = nil
        closeWatch.stop()
        closes.closed()
        onModalClose?()
    }

    /// From a display's resolutions page back to the switcher.
    @objc private func switcherBackTapped() {
        openModal()
    }

    /// Picks the output, then returns to the modal bar.
    @objc private func audioSegmentTapped(_ ctrl: NSSegmentedControl) {
        let devices = audioSegMap[ObjectIdentifier(ctrl)] ?? []
        let idx = ctrl.selectedSegment
        guard idx >= 0, idx < devices.count else { return }
        audioManager?.setDefaultDevice(devices[idx])
        openModal()
    }

    /// Connects the display or iPad tapped, as the control showed it; nothing when it has
    /// gone or been connected meanwhile.
    @objc private func videoSegmentTapped(_ ctrl: NSSegmentedControl) {
        let shown = videoSegMap[ObjectIdentifier(ctrl)] ?? []
        let idx = ctrl.selectedSegment
        guard idx >= 0, idx < shown.count, let vm = videoManager,
              let target = connectableTargets.first(where: { $0.isSame(as: shown[idx]) }) else { return }
        switch target {
        case .airPlay(let display):
            vm.connectAirPlay(deviceName: display.name, announcing: Spoken.selected(display.label))
        case .sidecar(let device):
            SpeechSynthesizer.shared.announce(target.connectingAnnouncement)
            sidecarManager?.connect(device, videoManager: vm)
        }
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
        if display.isSidecar {
            SpeechSynthesizer.shared.announce(Spoken.disconnecting(display.label))
            sidecarManager?.disconnect(display: display)
        } else {
            videoManager?.disconnectAirPlay(deviceName: display.name,
                                            announcing: Spoken.deselected(display.label))
        }
        // Close the bar it was tapped on — the display is going away.
        closeResolutionBar()
    }

    @objc private func optimizeTapped(_ btn: NSButton) {
        guard let display = tappedDisplay(btn) else { return }
        // Re-present the modal once the display config has settled so the buttons refresh.
        let reopen = unlessClosedMeanwhile { $0.openModal() }
        videoManager?.setAsOptimizedDisplay(display) { result in
            if case .failure(let error) = result {
                SpeechSynthesizer.shared.announce(error.localizedDescription)
            }
            reopen()
        }
    }

    @objc private func mainTapped(_ btn: NSButton) {
        guard let display = tappedDisplay(btn) else { return }
        // Re-present the modal once the arrangement has settled so the tint refreshes.
        let reopen = unlessClosedMeanwhile { $0.openModal() }
        videoManager?.setMainDisplay(display) { result in
            if case .failure(let error) = result {
                SpeechSynthesizer.shared.announce(error.localizedDescription)
            }
            reopen()
        }
    }

    @objc private func mirrorOnTapped(_ btn: NSButton) {
        guard let display = tappedDisplay(btn) else { return }
        showDisplayPage(display, .mirrorTargets)
    }

    @objc private func mirrorTargetTapped(_ btn: NSButton) {
        guard let selection = mirrorChoiceMap[ObjectIdentifier(btn)] else { return }
        // Re-present the page once the change has settled so the tints refresh.
        let reshow = unlessClosedMeanwhile { presenter in
            guard let display = presenter.latest(selection.display) else { return }
            presenter.showDisplayPage(display, .mirrorTargets)
        }
        videoManager?.applyMirrorSelection(selection) { result in
            if case .failure(let error) = result {
                SpeechSynthesizer.shared.announce(error.localizedDescription)
            }
            reshow()
        }
    }

    @objc private func mirrorToggleTapped(_ btn: NSButton) {
        guard let display = tappedDisplay(btn) else { return }
        // Re-present the modal once the display config has settled so the label refreshes.
        let reopen = unlessClosedMeanwhile { $0.openModal() }
        videoManager?.toggleMirroring(for: display) { result in
            if case .failure(let error) = result {
                SpeechSynthesizer.shared.announce(error.localizedDescription)
            }
            reopen()
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
        let isCurrent = options.current.map {
            let cur = options.modes[$0]
            return cur.width == mode.width && cur.height == mode.height
                && cur.isHiDPI == mode.isHiDPI && cur.isVirtual == mode.isVirtual
        } ?? false
        guard !isCurrent else {
            showDisplayPage(display, .rates)
            return
        }
        let bar = resolutionBar
        let delay: TimeInterval
        if mode.isVirtual {
            // Starting an anchor takes a few seconds (the menu waits 4 s before rebuilding).
            delay = vm.hasVirtualAnchor(for: display.name) ? 0 : 3.3
            vm.selectVirtualMode(mode, for: display)
        } else {
            delay = applyNativeMode(mode, for: display)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.7) { [weak self] in
            // Only while that page is still up: the user may have moved on or closed it.
            guard let self, let bar, self.resolutionBar === bar, self.activeResolutionPage == .resolutions,
                  let fresh = self.latest(display), fresh.cgDisplayID != 0 else { return }
            self.showDisplayPage(fresh, .rates)
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
        vm.disableVirtualAnchor(for: display) {
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

// MARK: - Switcher closes

/// Counts the switcher's closes, so what was started while it was open (a change still
/// settling) can tell later whether it has closed since.
struct SwitcherCloses {
    private(set) var count = 0

    mutating func closed() { count += 1 }

    /// Whether it hasn't closed since `count` was `earlier`.
    func noneSince(_ earlier: Int) -> Bool { count == earlier }
}

// MARK: - Switcher visibility

/// Whether the switcher is still open, from whether any of its bars showed at each check. It
/// has closed once a bar was seen showing and none has for `hiddenChecks` checks running, as
/// a page replacing another may show none for a moment. Where no bar is ever seen showing
/// (the system not saying), it gives up rather than taking the switcher for closed.
struct SwitcherVisibility {
    enum State { case open, closed, unknown }

    static let interval: TimeInterval = 0.25
    static let hiddenChecks = 2
    /// Five seconds' checks without a bar seen.
    static let unseenChecks = 20

    private var seen = false
    /// Checks running with no bar showing.
    private var hidden = 0

    mutating func check(showing: Bool) -> State {
        if showing {
            seen = true
            hidden = 0
            return .open
        }
        hidden += 1
        if seen { return hidden >= Self.hiddenChecks ? .closed : .open }
        return hidden >= Self.unseenChecks ? .unknown : .open
    }
}

// MARK: - NSTouchBarDelegate

extension ControlStripPresenter: NSTouchBarDelegate {
    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch id {
        case Self.stripID:
            return makeStripItem()

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

        case Self.modalCloseID:
            let item = NSCustomTouchBarItem(identifier: id)
            let btn = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")!,
                               target: self, action: #selector(modalCloseTapped))
            btn.isBordered = false
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
            case ".switcher":
                let item = NSCustomTouchBarItem(identifier: id)
                let btn = NSButton(title: "◀", target: self, action: #selector(switcherBackTapped))
                btn.bezelStyle = .rounded
                btn.setAccessibilityLabel("Back")
                item.view = btn
                return item
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
