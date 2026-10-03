//
//  SettingsWindowController.swift
//

import AppKit

final class SettingsWindowController: NSWindowController {

    private let recorder: KeyRecorderView
    private let recorderAirPlay: KeyRecorderView
    private let recorderMirrorToggle: KeyRecorderView
    private let recorderAudioCycle: KeyRecorderView
    private let recorderMainDisplay: KeyRecorderView
    private let audioManager: AudioManager
    private let videoManager: VideoManager
    private let sidecarManager: SidecarManager

    var onSave: ((HotkeyPreference) -> Void)?
    var onSaveAirPlayConnect: ((HotkeyPreference) -> Void)?
    var onSaveMirrorToggle: ((HotkeyPreference) -> Void)?
    var onSaveAudioCycle: ((HotkeyPreference) -> Void)?
    var onSaveMainDisplay: ((HotkeyPreference) -> Void)?
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
         currentMainDisplay: HotkeyPreference,
         audioManager: AudioManager,
         videoManager: VideoManager,
         sidecarManager: SidecarManager) {
        recorder              = KeyRecorderView(preference: current)
        recorderAirPlay       = KeyRecorderView(preference: currentAirPlayConnect)
        recorderMirrorToggle  = KeyRecorderView(preference: currentMirrorToggle)
        recorderAudioCycle    = KeyRecorderView(preference: currentAudioCycle)
        recorderMainDisplay   = KeyRecorderView(preference: currentMainDisplay)
        self.audioManager     = audioManager
        self.videoManager     = videoManager
        self.sidecarManager   = sidecarManager

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
    private static let minContentWidth: CGFloat = 340

    /// Sizes the window to the tab's content, keeping its top edge in place. The height
    /// is fixed at that; the width starts at what the content needs and stays adjustable. A tab taller than the screen scrolls.
    private func fitWindow(to content: NSView) {
        guard let win = window, let stack = (content as? NSScrollView)?.documentView else { return }
        stack.layoutSubtreeIfNeeded()
        var height = stack.fittingSize.height
        if let screen = win.screen ?? NSScreen.main {
            let chrome = win.frame.height - win.contentLayoutRect.height
            height = min(height, screen.visibleFrame.height - chrome - 40)
        }
        let minWidth = max(Self.minContentWidth, stack.fittingSize.width)
        let width = minWidth
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
        recorderMainDisplay.onChanged  = { [weak self] pref in self?.onSaveMainDisplay?(pref) }

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
                help: "Picks where the connected AirPlay display is mirrored: nowhere, " +
                      "on one of the other displays, or on all of them.")]),
            ("Cycle Audio:", [hotkeyRow(
                recorderAudioCycle, reset: #selector(resetAudioCycleToDefault),
                help: "Picks an audio output among those checked on the Devices tab.")]),
            ("Main Display:", [hotkeyRow(
                recorderMainDisplay, reset: #selector(resetMainDisplayToDefault),
                help: "Picks the display that has the menu bar.")]),
        ], leftAligned: true)
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
                               "picking an audio output, and picking where to mirror.",
                         action: { VisibilityPreferences.speechEnabled = $0 }),
            ]),
            ("Pickers:", [
                checkbox(title: "Open on the current choice",
                         isOn: VisibilityPreferences.pickerStartsOnCurrent,
                         help: "The audio, mirror and main display pickers open on what is " +
                               "current. Unchecked, they open on the next choice, so a single " +
                               "press followed by the pause moves on.",
                         action: { VisibilityPreferences.pickerStartsOnCurrent = $0 }),
                pickDelayRow(),
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
        let sidecar = sidecarManager.devices.map { device in
            nicknameRow(.sidecar, for: device.name, checkbox: rowLabel(device.name))
        }
        let airPlay = videoManager.allAirPlayDevices.map { device in
            nicknameRow(.display, for: device.name, checkbox: checkbox(title: device.name,
                     isOn: VisibilityPreferences.isVisible(airPlayDevice: device.name),
                     help: "Unchecked: hidden from the menu bar and Touch Bar",
                     action: { [weak self] visible in
                         VisibilityPreferences.setVisible(visible, airPlayDevice: device.name)
                         self?.videoManager.applyVisibility()
                         self?.onRebuild?()
                     }))
        }
        // A Sidecar iPad has its row under "Sidecar:" above.
        let displays = videoManager.allConnectedDisplays.filter { !$0.isSidecar }.map { display in
            nicknameRow(.display, for: display.name, checkbox: checkbox(title: display.name,
                     isOn: VisibilityPreferences.isVisible(display: display.name),
                     help: "Unchecked: hidden from the menu bar and Touch Bar",
                     action: { [weak self] visible in
                         VisibilityPreferences.setVisible(visible, display: display.name)
                         self?.videoManager.applyVisibility()
                         self?.onRebuild?()
                     }))
        }
        return formTab([
            ("Audio Output:",       audio.isEmpty    ? [placeholderLabel("No output devices found")] : audio),
            ("AirPlay Displays:",   airPlay.isEmpty  ? [placeholderLabel("None discovered yet")] : airPlay),
            ("Sidecar:",            sidecar.isEmpty  ? [placeholderLabel("No Sidecar devices found")] : sidecar),
            ("Connected Displays:", displays.isEmpty ? [placeholderLabel("No external displays")] : displays),
        ])
    }

    /// A device's visibility checkbox with a field beside it for its nickname, which the
    /// menu, Touch Bar and spoken pickers show in place of the device's own name.
    private func nicknameRow(_ kind: VisibilityPreferences.NicknameKind, for name: String,
                             checkbox: NSView) -> NSView {
        let field = NicknameField(kind: kind, deviceName: name) { [weak self] in self?.onRebuild?() }
        field.stringValue = VisibilityPreferences.nickname(kind, for: name) ?? ""
        field.placeholderString = "Nickname"
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.widthAnchor.constraint(equalToConstant: 130).isActive = true
        field.toolTip = "A name to show for this device in \(AppIdentity.name). Leave blank to use “\(name)”."
        let row = NSStackView(views: [checkbox, field])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func buildVirtualTab() -> NSView {
        let rates = buildRefreshRateGrid()
        rates.toolTip = "Rates the virtual display offers for each kind of display."
        let airPlayDefault = buildDefaultResolutionPopup(for: .airPlay)
        airPlayDefault.toolTip = "When an AirPlay display connects, drive it through the virtual " +
                                 "display at this resolution. “Display's own” leaves it as it is."
        let sidecarBacking = checkbox(title: "Back a connected iPad with a virtual display",
                                      isOn: VisibilityPreferences.backsSidecarWithVirtualDisplay,
                                      help: "The iPad mirrors a virtual display in its own shape, " +
                                            "so it can be the Mac's only display and can run at " +
                                            "other resolutions. " +
                                            "Applies on the next Sidecar connection.",
                                      action: { VisibilityPreferences.backsSidecarWithVirtualDisplay = $0 })
        return formTab([
            ("Refresh Rates:", [rates]),
            ("On AirPlay Connect:", [airPlayDefault]),
            ("On Sidecar Connect:", [sidecarBacking]),
        ], leftAligned: true)
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

    @objc private func resetMainDisplayToDefault() {
        let pref = HotkeyPreference.defaultMainDisplay
        recorderMainDisplay.preference = pref
        onSaveMainDisplay?(pref)
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
    private func formTab(_ groups: [(label: String, controls: [NSView])], leftAligned: Bool = false) -> NSView {
        let grid = NSGridView()
        grid.rowSpacing    = 6
        grid.columnSpacing = 8
        grid.rowAlignment  = .firstBaseline
        for (g, group) in groups.enumerated() {
            for (i, control) in group.controls.enumerated() {
                let label = i == 0 ? formLabel(group.label) : NSGridCell.emptyContentView
                let row = grid.addRow(with: [label, control])
                row.cell(at: 1).xPlacement = .leading
                if i == 0 && g > 0 { row.topPadding = 10 }
            }
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        // Keep the grid at its natural width; stretched, its trailing-placed label column
        // would push the whole form to the right.
        grid.setContentHuggingPriority(.required, for: .horizontal)

        let scrollView = makeScrollView()
        let stack = SettingsStack()
        stack.orientation = .vertical
        stack.alignment   = leftAligned ? .leading : .centerX
        stack.edgeInsets  = Self.formInsets
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stack
        stack.addArrangedSubview(grid)
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

        var rows: [[NSView]] = [[NSGridCell.emptyContentView] + rates.map { rotatedColumnHeader("\($0) Hz") }]
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

        let grid = BaselineRowGridView(views: rows)
        grid.baselineRow   = 1
        grid.rowSpacing    = 2
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .leading
        for c in 1...rates.count { grid.column(at: c).xPlacement = .center }
        for r in 0..<grid.numberOfRows { grid.row(at: r).yPlacement = .center }
        // The rotated headers start at the bottom, so each one's first letter sits the same
        // distance above its checkboxes whatever the label's length.
        grid.row(at: 0).yPlacement = .bottom
        return grid
    }

    private func columnHeader(_ title: String) -> NSView {
        let tf = NSTextField(labelWithString: title)
        tf.font      = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tf.textColor = .secondaryLabelColor
        return tf
    }

    /// Column header with its text rotated 90° counter-clockwise (reads bottom to top),
    /// so each column is only as wide as a checkbox.
    private func rotatedColumnHeader(_ title: String) -> NSView {
        RotatedLabelView(text: title,
                         font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                         color: .secondaryLabelColor)
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

    /// "Pick after [2.0] s": how long a picker waits after the last press before it picks.
    private func pickDelayRow() -> NSView {
        let range = VisibilityPreferences.pickDelayRange
        let field = RoundedTextField(frame: .zero)
        field.stringValue = Self.delayText(VisibilityPreferences.pickDelay)
        field.alignment = .right
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let stepper = NSStepper()
        stepper.minValue  = range.lowerBound
        stepper.maxValue  = range.upperBound
        stepper.increment = 0.5
        stepper.doubleValue = VisibilityPreferences.pickDelay
        stepper.controlSize = .small
        let apply: (Double) -> Void = { value in
            let clamped = VisibilityPreferences.clampedPickDelay(value)
            VisibilityPreferences.pickDelay = clamped
            stepper.doubleValue = clamped
            field.stringValue = Self.delayText(clamped)
        }
        pickDelayFieldHandler   = { apply(Double($0.stringValue.replacingOccurrences(of: ",", with: ".")) ?? VisibilityPreferences.pickDelay) }
        pickDelayStepperHandler = { apply($0.doubleValue) }
        field.target   = self
        field.action   = #selector(pickDelayFieldChanged(_:))
        stepper.target = self
        stepper.action = #selector(pickDelayStepperChanged(_:))
        let row = NSStackView(views: [smallLabel("Pick after"), field, stepper, smallLabel("s")])
        row.orientation = .horizontal
        row.spacing = 4
        row.toolTip = "How long a picker waits after the last hotkey press before it picks " +
                      "the tinted choice."
        return row
    }

    private var pickDelayFieldHandler:   ((NSTextField) -> Void)?
    private var pickDelayStepperHandler: ((NSStepper) -> Void)?

    @objc private func pickDelayFieldChanged(_ sender: NSTextField)  { pickDelayFieldHandler?(sender) }
    @objc private func pickDelayStepperChanged(_ sender: NSStepper)  { pickDelayStepperHandler?(sender) }

    private static func delayText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func smallLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return label
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


/// Saves a device's nickname when editing ends; blank clears it.
private final class NicknameField: RoundedTextField, NSTextFieldDelegate {
    private let kind: VisibilityPreferences.NicknameKind
    private let deviceName: String
    private let onChange: () -> Void

    init(kind: VisibilityPreferences.NicknameKind, deviceName: String, onChange: @escaping () -> Void) {
        self.kind = kind
        self.deviceName = deviceName
        self.onChange = onChange
        super.init(frame: .zero)
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func controlTextDidEndEditing(_ obj: Notification) {
        VisibilityPreferences.setNickname(stringValue, kind, for: deviceName)
        onChange()
    }
}


/// A text field drawn like the hotkey recorder: rounded, 1pt separator border on the control
/// background, with a soft accent ring while editing. No system focus ring.
private class RoundedTextField: NSTextField {

    private final class Cell: NSTextFieldCell {
        private let inset = NSSize(width: 6, height: 2)

        override func drawingRect(forBounds rect: NSRect) -> NSRect {
            super.drawingRect(forBounds: rect.insetBy(dx: inset.width, dy: inset.height))
        }
        override func cellSize(forBounds rect: NSRect) -> NSSize {
            let s = super.cellSize(forBounds: rect)
            return NSSize(width: s.width + inset.width * 2, height: s.height + inset.height * 2)
        }
        override func select(withFrame rect: NSRect, in view: NSView, editor: NSText,
                             delegate: Any?, start: Int, length: Int) {
            super.select(withFrame: drawingRect(forBounds: rect), in: view, editor: editor,
                         delegate: delegate, start: start, length: length)
        }
        override func edit(withFrame rect: NSRect, in view: NSView, editor: NSText,
                           delegate: Any?, event: NSEvent?) {
            super.edit(withFrame: drawingRect(forBounds: rect), in: view, editor: editor,
                       delegate: delegate, event: event)
        }
    }

    override class var cellClass: AnyClass? {
        get { Cell.self }
        set {}
    }

    private var isEditingField = false { didSet { applyStyle() } }

    override init(frame: NSRect) { super.init(frame: frame); setUp() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setUp() {
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        controlSize = .small
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        wantsLayer = true
        layer?.cornerRadius = 5
        applyStyle()
    }

    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            if isEditingField {
                layer?.borderWidth = 3
                layer?.borderColor = NSColor.keyboardFocusIndicatorColor.withAlphaComponent(0.4).cgColor
            } else {
                layer?.borderWidth = 1
                layer?.borderColor = NSColor.separatorColor.cgColor
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { isEditingField = true }
        return ok
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        isEditingField = false
    }
}


/// A single line of text drawn rotated 90° counter-clockwise. Its intrinsic size is the
/// text's size with width and height swapped.
private final class RotatedLabelView: NSView {
    private let text: NSAttributedString
    /// Space kept below the text's first letter, between it and whatever sits under the view.
    private static let bottomGap: CGFloat = 8

    init(text: String, font: NSFont, color: NSColor) {
        self.text = NSAttributedString(string: text,
                                       attributes: [.font: font, .foregroundColor: color])
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        let size = text.size()
        return NSSize(width: ceil(size.height), height: ceil(size.width) + Self.bottomGap)
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = text.size()
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: (bounds.width + size.height) / 2, yBy: Self.bottomGap)
        t.rotate(byDegrees: 90)
        t.concat()
        text.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()
    }
}


// MARK: - BaselineRowGridView

/// A grid that reports the first baseline of one of its rows, not of its first row, so a
/// label beside the grid lines up with that row (here the first row under a header row).
private final class BaselineRowGridView: NSGridView {
    var baselineRow = 0

    override var firstBaselineOffsetFromTop: CGFloat {
        guard baselineRow < numberOfRows else { return super.firstBaselineOffsetFromTop }
        layoutSubtreeIfNeeded()
        let view = cell(atColumnIndex: 0, rowIndex: baselineRow).contentView ?? self
        let top = isFlipped ? view.frame.minY : bounds.height - view.frame.maxY
        return top + view.firstBaselineOffsetFromTop
    }
}
