//
//  ChoicePicker.swift
//
//  The picker behind the hotkey-driven choosers (audio outputs, mirror targets, the main
//  display): a numbered list shown on screen and on the Touch Bar, and spoken, as enabled.
//  The owner opens it on the current choice, or on the next one, as set; each further
//  hotkey press moves on. Pressing a number (or tapping a choice on the Touch Bar) picks
//  that choice, Return picks the tinted one, and pausing for the set delay picks it too.
//  Esc cancels, as does closing its Touch Bar with the system's close box.
//

import AppKit
import Carbon.HIToolbox

extension HUDHint {
    /// What a picker's hint says while it is open.
    static let picking = HUDHint(leading: "Hotkey for next, or press a number", trailing: "Esc to cancel")
}

extension String {
    /// At most `max` characters, the last an ellipsis when some are cut, for a Touch Bar
    /// button or label.
    func truncated(to max: Int) -> String {
        count > max ? String(prefix(max - 1)) + "…" : self
    }
}

final class ChoicePicker: NSObject {

    /// Where a picker opens for the choice that is current now: on it, or on the one after
    /// it, as the preference says. With none of them current, as when the current one is
    /// hidden, it opens on the first.
    static func startCursor(current: Int?, count: Int) -> Int {
        guard count > 0, let current else { return 0 }
        return VisibilityPreferences.pickerStartsOnCurrent ? current : (current + 1) % count
    }

    /// Whether the pause picks the choice the picker opened on before any press moved it.
    /// Not when the picker opens on what is current, yet nothing listed is: the pause would
    /// then pick the first choice, for a press meant only to see what is current.
    static func pausePicksStart(current: Int?) -> Bool {
        current != nil || !VisibilityPreferences.pickerStartsOnCurrent
    }

    /// Where a hotkey press moves the cursor from `cursor`: to the next choice, wrapping
    /// round, or, while the pause isn't to pick (opened on the first with none current, and
    /// not moved since), onto the choice it shows, so the first press doesn't skip it.
    static func cursor(advancingFrom cursor: Int, count: Int, pausePicks: Bool) -> Int {
        guard count > 0 else { return 0 }
        return pausePicks ? (cursor + 1) % count : cursor
    }

    /// The display under the pointer, for a picker that changes it; nil when there is none,
    /// or, announced, when it mirrors an iPad's anchor, whose settings it follows.
    static func displayUnderPointer(in vm: VideoManager) -> DisplayInfo? {
        guard let display = vm.displayUnderPointer() else { return nil }
        if let master = vm.anchoredMaster(of: display) {
            SpeechSynthesizer.shared.announce(Spoken.follows(display.label, master.label))
            return nil
        }
        return display
    }

    private let idPrefix: String
    private let pickingHint: HUDHint
    /// The hint shown once a choice is picked, given that choice's name.
    private let pickedHint: (String) -> HUDHint

    private var choices: [String] = []
    private var cursor = 0
    private var isOpen = false
    /// Set while the pick animation plays; the picker no longer takes input.
    private var isFinishing = false
    /// Debug previews stay silent and don't call `onPick`.
    private var isPreview = false
    /// The choice last spoken, so a pick doesn't repeat it.
    private var spokenIndex: Int?
    /// False while the pause is to close the picker rather than pick, until the cursor moves.
    private var pausePicks = true
    /// The app to hand focus back to on close, when DAM was activated for the Touch Bar.
    private var previousApp: NSRunningApplication?
    private var onPick: ((Int) -> Void)?

    private var panel: HUDPanel?
    private var touchBar: NSTouchBar?
    /// The choice buttons by index, as the Touch Bar creates them.
    private var touchBarButtons: [Int: NSButton] = [:]
    /// Cancels the picker once its bar goes without its being dismissed here, as by the
    /// system's close box, so the pause doesn't pick after the user closed it.
    private let barWatch = ModalBarWatch()
    private var pickTimer: Timer?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    /// `idPrefix` keeps the Touch Bar item identifiers of one picker apart from another's.
    init(idPrefix: String, pickingHint: HUDHint = .picking, pickedHint: @escaping (String) -> HUDHint) {
        self.idPrefix    = idPrefix
        self.pickingHint = pickingHint
        self.pickedHint  = pickedHint
        super.init()
    }

    /// Whether a hotkey press should move the cursor rather than open the picker anew.
    private var isCycling: Bool { isOpen && !isFinishing }

    // MARK: - Showing

    /// Shows `choices` opened for `current`, the one that is current now (nil when none
    /// listed is), as `startCursor(current:count:)` places it. `onPick` runs with the picked index.
    func open(choices: [String], current: Int?, onPick: @escaping (Int) -> Void) {
        open(choices: choices, cursor: Self.startCursor(current: current, count: choices.count),
             pausePicks: Self.pausePicksStart(current: current), onPick: onPick)
    }

    /// Shows `choices` with the cursor on `cursor`. `onPick` runs with the picked index.
    func open(choices: [String], cursor: Int, pausePicks: Bool = true, preview: Bool = false,
              onPick: @escaping (Int) -> Void) {
        close()
        self.choices = choices
        self.cursor  = cursor
        self.onPick  = onPick
        self.pausePicks = pausePicks
        isPreview = preview
        isOpen = true

        if Feedback.touchBar { showTouchBar() }
        if Feedback.screen {
            let p = makeHUDPanel(nonactivating: true)
            panel = p
            layoutHUD(p, body: .choices(choices, numbered: true),
                      hint: pickingHint) { frame, size in frame.midY + size.height / 2 }
            content?.setCursor(cursor)
            if Feedback.touchBar { previousApp = activateForHUDTouchBar() }
            p.makeKeyAndOrderFront(nil)
            installMonitors()
        }
        speakCursor()
        restartPickTimer()
    }

    /// For a hotkey press: moves the cursor to the next choice, wrapping round, when the
    /// picker is open and returns true; else closes what is left of it (a pick fading out)
    /// and returns false, for the owner to open it anew.
    func advanceIfOpen() -> Bool {
        guard isCycling else {
            close()
            return false
        }
        move(to: Self.cursor(advancingFrom: cursor, count: choices.count, pausePicks: pausePicks))
        return true
    }

    private var content: HUDContentView? { panel?.contentView as? HUDContentView }

    private func move(to index: Int) {
        cursor = index
        pausePicks = true
        content?.setCursor(index)
        updateTouchBar()
        speakCursor()
        restartPickTimer()
    }

    private func speakCursor() {
        guard Feedback.voice, !isPreview else { return }
        SpeechSynthesizer.shared.speak(choices[cursor], caption: false)
        spokenIndex = cursor
    }

    private func restartPickTimer() {
        pickTimer?.invalidate()
        pickTimer = .scheduledTimer(withTimeInterval: VisibilityPreferences.pickDelay,
                                    repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.pausePicks { self.pick(self.cursor) } else { self.close() }
        }
    }

    // MARK: - Picking

    private func pick(_ index: Int) {
        guard isOpen, !isFinishing, choices.indices.contains(index) else { return }
        isFinishing = true
        pickTimer?.invalidate()
        removeMonitors()
        dismissTouchBar()

        let name = choices[index]
        if !isPreview {
            // Before the pick, so what it announces, as an error, is heard over the name.
            if Feedback.voice && spokenIndex != index {
                SpeechSynthesizer.shared.speak(name, caption: false)
            }
            onPick?(index)
        }
        guard let content else { close(); return }
        content.select(index, hint: pickedHint(name), pulses: false) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.fadeOut() }
        }
    }

    private func fadeOut() {
        guard let p = panel, isFinishing else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if self?.panel === p { self?.close() }
        })
    }

    func close() {
        pickTimer?.invalidate()
        pickTimer = nil
        removeMonitors()
        dismissTouchBar()
        panel?.orderOut(nil)
        panel = nil
        isOpen = false
        isFinishing = false
        isPreview = false
        spokenIndex = nil
        pausePicks = true
        onPick = nil
        restoreFocus(to: previousApp)
        previousApp = nil
    }

    // MARK: - Touch Bar

    private var cancelID: NSTouchBarItem.Identifier { .init("\(idPrefix).cancel") }
    private func choiceID(_ i: Int) -> NSTouchBarItem.Identifier { .init("\(idPrefix).choice.\(i)") }

    /// A button per choice, numbered, with the tinted one highlighted, then Cancel.
    private func showTouchBar() {
        dismissTouchBar()
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = choices.indices.map { choiceID($0) } + [.flexibleSpace, cancelID]
        touchBar = bar
        NSTouchBar.presentSystemModal(bar, for: ControlStripPresenter.stripID)
        barWatch.start(showing: { [weak self] in self?.touchBar?.isVisible == true }) { [weak self] state in
            if state == .closed { self?.close() }
        }
    }

    private func updateTouchBar() {
        for (i, btn) in touchBarButtons {
            btn.bezelColor = i == cursor ? .controlAccentColor : nil
        }
    }

    private func dismissTouchBar() {
        barWatch.stop()
        if let bar = touchBar { NSTouchBar.dismissSystemModal(bar) }
        touchBar = nil
        touchBarButtons = [:]
    }

    @objc private func touchBarChoiceTapped(_ sender: NSButton) {
        pick(sender.tag)
    }

    @objc private func touchBarCancelTapped() {
        close()
    }

    // MARK: - Keys

    private func installMonitors() {
        removeMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) == true ? nil : event
        }
        // Esc still cancels if another app took focus.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Int(event.keyCode) == kVK_Escape { self?.close() }
        }
    }

    private func removeMonitors() {
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor  = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    }

    /// Returns `true` if the event was consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard isOpen, !isFinishing else { return false }
        switch Int(event.keyCode) {
        case kVK_Escape:
            close()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            pick(cursor)
        default:
            guard let n = hudDigit(event), n <= choices.count else { return false }
            pick(n - 1)
        }
        return true
    }
}

// MARK: - NSTouchBarDelegate

extension ChoicePicker: NSTouchBarDelegate {

    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: identifier)
        if identifier == cancelID {
            let btn = NSButton(title: "Cancel", target: self, action: #selector(touchBarCancelTapped))
            btn.bezelColor = .systemRed
            item.view = btn
            return item
        }
        guard let i = choices.indices.first(where: { choiceID($0) == identifier }) else {
            return nil
        }
        let btn = NSButton(title: (hudNumber(at: i).map { "\($0).  " } ?? "") + choices[i].truncated(to: 16),
                           target: self, action: #selector(touchBarChoiceTapped(_:)))
        btn.tag = i
        btn.bezelColor = i == cursor ? .controlAccentColor : nil
        touchBarButtons[i] = btn
        item.view = btn
        return item
    }
}

#if DEBUG
extension ChoicePicker {
    /// Opens the picker on `samples`, steps the cursor once, then lets it pick after the
    /// pause, silently, changing nothing.
    func playPreview(_ samples: [String]) {
        open(choices: samples, cursor: 1, preview: true) { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.previewMove(to: 2)
        }
    }

    /// Steps a preview's cursor, as a hotkey press would, unless the preview has ended.
    private func previewMove(to index: Int) {
        guard isPreview, isCycling else { return }
        move(to: index)
    }
}
#endif
