//
//  ChoicePicker.swift
//
//  The picker behind the hotkey-driven choosers (audio outputs, mirror targets): a numbered
//  list shown on screen and on the Touch Bar, and spoken, as enabled. The owner opens it on
//  a choice; each further hotkey press moves on. Pressing a number (or tapping a choice on
//  the Touch Bar) picks that choice, Return picks the tinted one, and pausing picks it too,
//  so a single press still moves to the next choice. Esc cancels.
//

import AppKit
import Carbon.HIToolbox

final class ChoicePicker: NSObject {

    /// How long after the last hotkey press the tinted choice is picked.
    static let pickDelay: TimeInterval = 2.0

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
    /// The app to hand focus back to on close, when DAM was activated for the Touch Bar.
    private var previousApp: NSRunningApplication?
    private var onPick: ((Int) -> Void)?

    private var panel: HUDPanel?
    private var touchBar: NSTouchBar?
    /// The choice buttons by index, as the Touch Bar creates them.
    private var touchBarButtons: [Int: NSButton] = [:]
    private var pickTimer: Timer?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    /// `idPrefix` keeps the Touch Bar item identifiers of one picker apart from another's.
    init(idPrefix: String, pickingHint: HUDHint, pickedHint: @escaping (String) -> HUDHint) {
        self.idPrefix    = idPrefix
        self.pickingHint = pickingHint
        self.pickedHint  = pickedHint
        super.init()
    }

    /// Whether a hotkey press should move the cursor rather than open the picker anew.
    var isCycling: Bool { isOpen && !isFinishing }

    // MARK: - Showing

    /// Shows `choices` with the cursor on `cursor`. `onPick` runs with the picked index.
    func open(choices: [String], cursor: Int, preview: Bool = false,
              onPick: @escaping (Int) -> Void) {
        close()
        self.choices = choices
        self.cursor  = cursor
        self.onPick  = onPick
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

    /// Moves the cursor to the next choice, wrapping round.
    func advance() {
        guard isCycling else { return }
        move(to: (cursor + 1) % choices.count)
    }

    private var content: HUDContentView? { panel?.contentView as? HUDContentView }

    private func move(to index: Int) {
        cursor = index
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
        pickTimer = .scheduledTimer(withTimeInterval: Self.pickDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.pick(self.cursor)
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
            onPick?(index)
            if Feedback.voice && spokenIndex != index {
                SpeechSynthesizer.shared.speak(name, caption: false)
            }
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
    }

    private func updateTouchBar() {
        for (i, btn) in touchBarButtons {
            btn.bezelColor = i == cursor ? .controlAccentColor : nil
        }
    }

    private func dismissTouchBar() {
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

    private func truncated(_ s: String, maxLength: Int = 16) -> String {
        s.count > maxLength ? String(s.prefix(maxLength - 1)) + "…" : s
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
        let btn = NSButton(title: "\(i + 1).  \(truncated(choices[i]))",
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
    /// Steps a preview's cursor, as a hotkey press would, unless the preview has ended.
    func previewMove(to index: Int) {
        guard isPreview, isCycling else { return }
        move(to: index)
    }
}
#endif
