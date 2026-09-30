//
//  SettingsWindowController.swift
//

import AppKit

final class SettingsWindowController: NSWindowController {

    private let recorder: KeyRecorderView
    private let recorderAirPlay: KeyRecorderView
    private let recorderMirrorToggle: KeyRecorderView
    private let recorderAudioCycle: KeyRecorderView
    private let audioManager: AudioManager
    private let videoManager: VideoManager

    var onSave: ((HotkeyPreference) -> Void)?
    var onSaveAirPlayConnect: ((HotkeyPreference) -> Void)?
    var onSaveMirrorToggle: ((HotkeyPreference) -> Void)?
    var onSaveAudioCycle: ((HotkeyPreference) -> Void)?
    /// Called whenever a visibility checkbox is toggled so the menu/Touch Bar rebuild.
    var onRebuild: (() -> Void)?

    // Tab content views — built once, reused on every tab switch.
    private lazy var hotkeyContent:  NSView = buildHotkeysTab()
    private lazy var generalContent: NSView = buildGeneralTab()
    private lazy var devicesContent: NSView = buildDevicesTab()
    private lazy var virtualContent: NSView = buildVirtualTab()

    // MARK: - Toolbar identifiers

    private enum TabID {
        static let hotkeys = NSToolbarItem.Identifier("\(AppIdentity.shortID).settings.hotkeys")
        static let general = NSToolbarItem.Identifier("\(AppIdentity.shortID).settings.general")
        static let devices = NSToolbarItem.Identifier("\(AppIdentity.shortID).settings.devices")
        static let virtual = NSToolbarItem.Identifier("\(AppIdentity.shortID).settings.virtual")
        static let all: [NSToolbarItem.Identifier] = [general, hotkeys, devices, virtual]
    }

    // MARK: - Init

    init(current: HotkeyPreference,
         currentAirPlayConnect: HotkeyPreference,
         currentMirrorToggle: HotkeyPreference,
         currentAudioCycle: HotkeyPreference,
         audioManager: AudioManager,
         videoManager: VideoManager) {
        recorder              = KeyRecorderView(preference: current)
        recorderAirPlay       = KeyRecorderView(preference: currentAirPlayConnect)
        recorderMirrorToggle  = KeyRecorderView(preference: currentMirrorToggle)
        recorderAudioCycle    = KeyRecorderView(preference: currentAudioCycle)
        self.audioManager     = audioManager
        self.videoManager     = videoManager

        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate    = false

        super.init(window: win)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI

    private func buildUI() {
        guard let win = window else { return }

        let toolbar = NSToolbar(identifier: "\(AppIdentity.shortID).settings.toolbar")
        toolbar.delegate                = self
        toolbar.displayMode             = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration  = false
        win.toolbar      = toolbar
        win.toolbarStyle = .preference   // centres items, Xcode-style

        selectTab(TabID.general)
    }

    // MARK: - Tab switching

    private func selectTab(_ id: NSToolbarItem.Identifier) {
        let content: NSView
        let title: String
        switch id {
        case TabID.general:
            content = generalContent; title = "General"
        case TabID.devices:
            content = devicesContent; title = "Devices"
        case TabID.virtual:
            content = virtualContent; title = "Virtual Display"
        default:
            content = hotkeyContent;  title = "Hotkeys"
        }
        window?.contentView                     = content
        window?.toolbar?.selectedItemIdentifier = id
        window?.title                           = title
        fitWindow(to: content)
    }

    /// Wide enough for the toolbar's four items.
    private static let minContentWidth: CGFloat = 420

    /// Sizes the window to the tab's content, keeping its top edge in place. The height
    /// is fixed at that; the width stays adjustable. A tab taller than the screen scrolls.
    private func fitWindow(to content: NSView) {
        guard let win = window, let stack = (content as? NSScrollView)?.documentView else { return }
        stack.layoutSubtreeIfNeeded()
        var height = stack.fittingSize.height
        if let screen = win.screen ?? NSScreen.main {
            let chrome = win.frame.height - win.contentLayoutRect.height
            height = min(height, screen.visibleFrame.height - chrome - 40)
        }
        let minWidth = max(Self.minContentWidth, stack.fittingSize.width)
        let width = max(win.contentLayoutRect.width, minWidth)
        win.contentMinSize = NSSize(width: minWidth, height: height)
        win.contentMaxSize = NSSize(width: .greatestFiniteMagnitude, height: height)
        var frame = win.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height))
        frame.origin = NSPoint(x: win.frame.minX, y: win.frame.maxY - frame.height)
        win.setFrame(frame, display: true, animate: win.isVisible)
    }

    @objc private func toolbarItemTapped(_ item: NSToolbarItem) {
        selectTab(item.itemIdentifier)
    }

    // MARK: - Tabs
    //
    // Each tab is a form like the system settings panes: a right-aligned label column,
    // the controls beside it, the form centred in the window. A group is one label with
    // one or more controls under it; groups are set apart by spacing, not headers.

    private func buildHotkeysTab() -> NSView {
        recorder.onChanged             = { [weak self] pref in self?.onSave?(pref) }
        recorderAirPlay.onChanged      = { [weak self] pref in self?.onSaveAirPlayConnect?(pref) }
        recorderMirrorToggle.onChanged = { [weak self] pref in self?.onSaveMirrorToggle?(pref) }
        recorderAudioCycle.onChanged   = { [weak self] pref in self?.onSaveAudioCycle?(pref) }

        return formTab([
            ("Switcher:", [hotkeyRow(
                recorder, reset: #selector(resetToDefault),
                help: "Opens the Touch Bar switcher for the audio output and AirPlay display. " +
                      "Without a Touch Bar (or with the lid closed) it opens the menu bar menu.")]),
            ("Quick Connect:", [hotkeyRow(
                recorderAirPlay, reset: #selector(resetAirPlayConnectToDefault),
                help: "Connects to an AirPlay display from any application.")]),
            ("Mirror / Extend:", [hotkeyRow(
                recorderMirrorToggle, reset: #selector(resetMirrorToggleToDefault),
                help: "Toggles the connected AirPlay display between mirror and extend mode.")]),
            ("Cycle Audio:", [hotkeyRow(
                recorderAudioCycle, reset: #selector(resetAudioCycleToDefault),
                help: "Switches to the next audio output checked on the Devices tab.")]),
        ])
    }

    private func buildGeneralTab() -> NSView {
        let extraShown = ScreenMirroringPanel.isExtraVisible
        let extraStatus = NSTextField(labelWithString:
            extraShown ? "Menu bar item shown" : "Menu bar item hidden")
        extraStatus.font = .systemFont(ofSize: NSFont.systemFontSize)
        let openCC = NSButton(title: "Control Center…", target: self,
                              action: #selector(openControlCenterSettings))
        openCC.bezelStyle  = .rounded
        openCC.controlSize = .small
        openCC.font        = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let extraRow = NSStackView(views: [extraStatus, openCC])
        extraRow.orientation = .horizontal
        extraRow.spacing = 8
        extraRow.toolTip = "AirPlay displays connect fastest when Control Center shows " +
                           "Screen Mirroring in the menu bar (“Always Show in Menu Bar”)."

        return formTab([
            ("AirPlay:", [
                checkbox(title: "Auto-connect when only one display is available",
                         isOn: VisibilityPreferences.autoConnectSingleDisplay,
                         help: "When only one AirPlay display is visible, skip the selection " +
                               "list and connect immediately.",
                         action: { VisibilityPreferences.autoConnectSingleDisplay = $0 }),
            ]),
            ("Hotkey Feedback:", [
                checkbox(title: "On the Touch Bar",
                         isOn: VisibilityPreferences.touchBarFeedback,
                         help: "Shows pickers and status messages on the Touch Bar, on Macs " +
                               "that have one.",
                         action: { VisibilityPreferences.touchBarFeedback = $0 }),
                checkbox(title: "On screen",
                         isOn: VisibilityPreferences.screenFeedback,
                         help: "Shows pickers and status messages on screen. Used regardless " +
                               "when the Touch Bar isn't showing them.",
                         action: { VisibilityPreferences.screenFeedback = $0 }),
                checkbox(title: "Spoken",
                         isOn: VisibilityPreferences.speechEnabled,
                         help: "Speaks the target device name when connecting to AirPlay, " +
                               "picking an audio output, and toggling mirror / extend mode.",
                         action: { VisibilityPreferences.speechEnabled = $0 }),
            ]),
            ("Audio Devices:", [
                checkbox(title: "Hide virtual devices when first discovered",
                         isOn: VisibilityPreferences.autoHideVirtualAudio,
                         help: "Hides virtual audio devices such as Teams, Zoom, BlackHole, " +
                               "and Loopback when they are first detected. They can be " +
                               "re-enabled in the Devices tab.",
                         action: { VisibilityPreferences.autoHideVirtualAudio = $0 }),
            ]),
            ("Startup:", [
                checkbox(title: "Launch at login",
                         isOn: VisibilityPreferences.launchAtLogin,
                         action: { VisibilityPreferences.launchAtLogin = $0 }),
            ]),
            ("Screen Mirroring:", [extraRow]),
        ])
    }

    @objc private func openControlCenterSettings() {
        ScreenMirroringPanel.openControlCenterSettings()
    }

    /// Unchecked devices are hidden from the menu bar and Touch Bar; they remain
    /// available system-wide.
    private func buildDevicesTab() -> NSView {
        let audio = audioManager.allOutputDevices.map { device in
            checkbox(title: device.name,
                     isOn: VisibilityPreferences.isVisible(audioDevice: device.name),
                     help: "Unchecked: hidden from the menu bar and Touch Bar",
                     action: { [weak self] visible in
                         VisibilityPreferences.setVisible(visible, audioDevice: device.name)
                         self?.audioManager.applyVisibility()
                         self?.onRebuild?()
                     })
        }
        let airPlay = videoManager.allAirPlayDevices.map { device in
            checkbox(title: device.name,
                     isOn: VisibilityPreferences.isVisible(airPlayDevice: device.name),
                     help: "Unchecked: hidden from the menu bar and Touch Bar",
                     action: { [weak self] visible in
                         VisibilityPreferences.setVisible(visible, airPlayDevice: device.name)
                         self?.videoManager.applyVisibility()
                         self?.onRebuild?()
                     })
        }
        let displays = videoManager.allConnectedDisplays.map { display in
            checkbox(title: display.name,
                     isOn: VisibilityPreferences.isVisible(display: display.name),
                     help: "Unchecked: hidden from the menu bar and Touch Bar",
                     action: { [weak self] visible in
                         VisibilityPreferences.setVisible(visible, display: display.name)
                         self?.videoManager.applyVisibility()
                         self?.onRebuild?()
                     })
        }
        return formTab([
            ("Audio Output:",       audio.isEmpty    ? [placeholderLabel("No output devices found")] : audio),
            ("AirPlay Displays:",   airPlay.isEmpty  ? [placeholderLabel("None discovered yet")] : airPlay),
            ("Connected Displays:", displays.isEmpty ? [placeholderLabel("No external displays")] : displays),
        ])
    }

    private func buildVirtualTab() -> NSView {
        let rates = buildRefreshRateGrid()
        rates.toolTip = "Rates the virtual display offers for each kind of display."
        let airPlayDefault = buildDefaultResolutionPopup(for: .airPlay)
        airPlayDefault.toolTip = "When an AirPlay display connects, drive it through the virtual " +
                                 "display at this resolution. “Display's own” leaves it as it is."
        return formTab([
            ("Refresh Rates:", [rates]),
            ("On AirPlay Connect:", [airPlayDefault]),
        ])
    }

    // MARK: - Actions

    @objc private func resetToDefault() {
        let pref = HotkeyPreference.default
        recorder.preference = pref
        onSave?(pref)
    }

    @objc private func resetAirPlayConnectToDefault() {
        let pref = HotkeyPreference.defaultAirPlayConnect
        recorderAirPlay.preference = pref
        onSaveAirPlayConnect?(pref)
    }

    @objc private func resetMirrorToggleToDefault() {
        let pref = HotkeyPreference.defaultMirrorToggle
        recorderMirrorToggle.preference = pref
        onSaveMirrorToggle?(pref)
    }

    @objc private func resetAudioCycleToDefault() {
        let pref = HotkeyPreference.defaultAudioCycle
        recorderAudioCycle.preference = pref
        onSaveAudioCycle?(pref)
    }

    // MARK: - Layout helpers

    private func makeScrollView() -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller  = true
        sv.autohidesScrollers   = true
        sv.drawsBackground      = false
        sv.autoresizingMask     = [.width, .height]
        let clip = FlippedClipView()
        clip.drawsBackground = false
        sv.contentView = clip
        return sv
    }

    private static let formInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

    /// A scrolling tab holding one form. Each group is a label and the controls listed
    /// under it, one per row; the label sits on the group's first row.
    private func formTab(_ groups: [(label: String, controls: [NSView])]) -> NSView {
        let grid = NSGridView()
        grid.rowSpacing    = 6
        grid.columnSpacing = 8
        grid.rowAlignment  = .firstBaseline
        for (g, group) in groups.enumerated() {
            for (i, control) in group.controls.enumerated() {
                let label = i == 0 ? formLabel(group.label) : NSGridCell.emptyContentView
                let row = grid.addRow(with: [label, control])
                if i == 0 && g > 0 { row.topPadding = 10 }
            }
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading

        let scrollView = makeScrollView()
        let stack = SettingsStack()
        stack.orientation = .vertical
        stack.alignment   = .centerX
        stack.edgeInsets  = Self.formInsets
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(grid)
        scrollView.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            // The clip view's width follows the document, so the document's width has to
            // come from the scroll view itself for the form to centre in the window.
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
        return scrollView
    }

    private func formLabel(_ title: String) -> NSView {
        let tf = NSTextField(labelWithString: title)
        tf.font      = .systemFont(ofSize: NSFont.systemFontSize)
        tf.alignment = .right
        return tf
    }

    private func hotkeyRow(_ recorder: KeyRecorderView, reset: Selector, help: String) -> NSView {
        let resetBtn = NSButton(title: "Reset", target: self, action: reset)
        resetBtn.bezelStyle  = .rounded
        resetBtn.controlSize = .small
        resetBtn.font        = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let row = NSStackView(views: [recorder, resetBtn])
        row.orientation = .horizontal
        row.spacing     = 8
        row.toolTip     = help
        NSLayoutConstraint.activate([
            recorder.widthAnchor.constraint(equalToConstant: 140),
            recorder.heightAnchor.constraint(equalToConstant: 22),
        ])
        return row
    }

    // MARK: - Virtual Display helpers

    /// A grid with a row per display kind and a column per refresh rate.
    private func buildRefreshRateGrid() -> NSView {
        let contexts: [(name: String, context: VisibilityPreferences.DisplayContext)] = [
            ("AirPlay", .airPlay), ("External", .external), ("Built-in", .builtIn),
        ]
        let rates = [30, 60, 120, 240]

        var rows: [[NSView]] = [[NSGridCell.emptyContentView] + rates.map { columnHeader("\($0) Hz") }]
        for entry in contexts {
            var row: [NSView] = [rowLabel(entry.name)]
            let enabled = VisibilityPreferences.virtualRefreshRates(for: entry.context)
            for rate in rates {
                row.append(checkbox(title: "", isOn: enabled.contains(rate)) { [weak self] isOn in
                    var rates = VisibilityPreferences.virtualRefreshRates(for: entry.context)
                    if isOn { rates.insert(rate) } else { rates.remove(rate) }
                    if rates.isEmpty { rates = [60] }
                    VisibilityPreferences.setVirtualRefreshRates(rates, for: entry.context)
                    self?.onRebuild?()
                })
            }
            rows.append(row)
        }

        let grid = NSGridView(views: rows)
        grid.rowSpacing    = 2
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .leading
        for c in 1...rates.count { grid.column(at: c).xPlacement = .center }
        for r in 0..<grid.numberOfRows { grid.row(at: r).yPlacement = .center }
        return grid
    }

    private func columnHeader(_ title: String) -> NSView {
        let tf = NSTextField(labelWithString: title)
        tf.font      = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tf.textColor = .secondaryLabelColor
        return tf
    }

    private func rowLabel(_ title: String) -> NSView {
        let tf = NSTextField(labelWithString: title)
        tf.font = .systemFont(ofSize: NSFont.systemFontSize)
        return tf
    }

    /// Popup for choosing the default virtual resolution for a given context.
    private func buildDefaultResolutionPopup(for context: VisibilityPreferences.DisplayContext) -> NSView {
        let popup = DefaultResolutionPopup(onSelect: { [weak self] key in
            VisibilityPreferences.setDefaultVirtualResolution(key, for: context)
            self?.onRebuild?()
        })
        popup.font = .systemFont(ofSize: NSFont.systemFontSize)

        // Options: (title, stored key or nil)
        let options: [(String, String?)] = [
            ("Display's own", nil),
            ("720p",  "1280x720"),
            ("1080p", "1920x1080"),
            ("1440p", "2560x1440"),
            ("4K",    "3840x2160"),
        ]
        for (title, key) in options {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = key
            popup.menu?.addItem(item)
        }

        // Select the item that matches the stored preference.
        let stored = VisibilityPreferences.defaultVirtualResolution(for: context)
        let matchIndex = options.firstIndex { $0.1 == stored } ?? 0
        popup.selectItem(at: matchIndex)
        return popup
    }

    // MARK: - View factories

    private func placeholderLabel(_ text: String) -> NSView {
        let tf = NSTextField(labelWithString: text)
        tf.font      = .systemFont(ofSize: NSFont.systemFontSize)
        tf.textColor = .tertiaryLabelColor
        return tf
    }

    private func checkbox(title: String,
                          isOn: Bool,
                          help: String? = nil,
                          action: @escaping (Bool) -> Void) -> NSView {
        let cb = ClosureButton(title: title, action: action)
        cb.setButtonType(.switch)
        cb.state   = isOn ? .on : .off
        cb.font    = .systemFont(ofSize: NSFont.systemFontSize)
        cb.toolTip = help
        return cb
    }

    // MARK: - Present

    func show() {
        showWindow(nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - NSToolbarDelegate

extension SettingsWindowController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        TabID.all
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        TabID.all
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        TabID.all
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.target = self
        item.action = #selector(toolbarItemTapped(_:))
        switch itemIdentifier {
        case TabID.hotkeys:
            item.label = "Hotkeys"
            item.image = NSImage(systemSymbolName: "keyboard",
                                 accessibilityDescription: "Hotkeys")
        case TabID.general:
            item.label = "General"
            item.image = NSImage(systemSymbolName: "gearshape",
                                 accessibilityDescription: "General")
        case TabID.devices:
            item.label = "Devices"
            item.image = NSImage(systemSymbolName: "display",
                                 accessibilityDescription: "Devices")
        case TabID.virtual:
            item.label = "Virtual Display"
            item.image = NSImage(systemSymbolName: "rectangle.dashed",
                                 accessibilityDescription: "Virtual Display")
        default:
            return nil
        }
        return item
    }
}

// MARK: - SettingsStack

/// A leading-aligned vertical stack whose rows keep their own width but may not extend
/// past the right inset.
private final class SettingsStack: NSStackView {
    override func addArrangedSubview(_ view: NSView) {
        super.addArrangedSubview(view)
        trailingAnchor.anchorWithOffset(to: view.trailingAnchor)
            .constraint(lessThanOrEqualToConstant: -edgeInsets.right).isActive = true
    }
}

// MARK: - FlippedClipView

/// NSClipView with a flipped coordinate system so scroll views display their
/// document from the top-left rather than the bottom-left.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

// MARK: - DefaultResolutionPopup

/// NSPopUpButton subclass that fires a closure when the selection changes, carrying
/// the `representedObject` of the chosen item (a `String?` resolution key or nil).
private final class DefaultResolutionPopup: NSPopUpButton {
    private let handler: (String?) -> Void

    init(onSelect: @escaping (String?) -> Void) {
        handler = onSelect
        super.init(frame: .zero, pullsDown: false)
        target = self
        action = #selector(selectionChanged)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func selectionChanged() {
        handler(selectedItem?.representedObject as? String)
    }
}

// MARK: - ClosureButton

/// NSButton subclass that fires a closure on action, avoiding the target/action
/// indirection needed for dynamically-created checkboxes.
private final class ClosureButton: NSButton {
    private let handler: (Bool) -> Void

    init(title: String, action: @escaping (Bool) -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title  = title
        self.target = self
        self.action = #selector(fired)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func fired() {
        handler(state == .on)
    }
}
