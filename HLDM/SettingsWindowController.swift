//
//  SettingsWindowController.swift
//  boar
//

import AppKit

final class SettingsWindowController: NSWindowController {

    private let recorder: KeyRecorderView
    private let recorderAirPlay: KeyRecorderView
    private let recorderMirrorToggle: KeyRecorderView
    private let audioManager: AudioManager
    private let videoManager: VideoManager

    var onSave: ((HotkeyPreference) -> Void)?
    var onSaveAirPlayConnect: ((HotkeyPreference) -> Void)?
    var onSaveMirrorToggle: ((HotkeyPreference) -> Void)?
    /// Called whenever a visibility checkbox is toggled so the menu/Touch Bar rebuild.
    var onRebuild: (() -> Void)?

    // Tab content views — built once, reused on every tab switch.
    private lazy var hotkeyContent:  NSView = buildHotkeysTab()
    private lazy var generalContent: NSView = buildGeneralTab()
    private lazy var devicesContent: NSView = buildDevicesTab()
    private lazy var virtualContent: NSView = buildVirtualTab()

    // MARK: - Toolbar identifiers

    private enum TabID {
        static let hotkeys = NSToolbarItem.Identifier("hldm.settings.hotkeys")
        static let general = NSToolbarItem.Identifier("hldm.settings.general")
        static let devices = NSToolbarItem.Identifier("hldm.settings.devices")
        static let virtual = NSToolbarItem.Identifier("hldm.settings.virtual")
        static let all: [NSToolbarItem.Identifier] = [general, hotkeys, devices, virtual]
    }

    // MARK: - Init

    init(current: HotkeyPreference,
         currentAirPlayConnect: HotkeyPreference,
         currentMirrorToggle: HotkeyPreference,
         audioManager: AudioManager,
         videoManager: VideoManager) {
        recorder              = KeyRecorderView(preference: current)
        recorderAirPlay       = KeyRecorderView(preference: currentAirPlayConnect)
        recorderMirrorToggle  = KeyRecorderView(preference: currentMirrorToggle)
        self.audioManager     = audioManager
        self.videoManager     = videoManager

        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 440),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate    = false
        win.minSize              = NSSize(width: 340, height: 280)

        super.init(window: win)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI

    private func buildUI() {
        guard let win = window else { return }

        let toolbar = NSToolbar(identifier: "hldm.settings.toolbar")
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
    }

    @objc private func toolbarItemTapped(_ item: NSToolbarItem) {
        selectTab(item.itemIdentifier)
    }

    // MARK: - Hotkeys tab

    private func buildHotkeysTab() -> NSView {
        let scrollView = makeScrollView()
        let stack = scrollStack(in: scrollView)

        // — Switcher —
        stack.addArrangedSubview(sectionHeader("Switcher"))

        recorder.onChanged = { [weak self] pref in self?.onSave?(pref) }
        let resetBtn = NSButton(title: "Reset", target: self, action: #selector(resetToDefault))
        resetBtn.bezelStyle = .rounded
        stack.addArrangedSubview(
            settingGroup(
                control: hotkeyRow(label: "Hotkey:", recorder: recorder, resetBtn: resetBtn),
                description: "Opens the Touch Bar switcher panel for changing the audio " +
                             "output device or AirPlay display."
            )
        )

        stack.addArrangedSubview(separator())

        // — AirPlay Quick Connect —
        stack.addArrangedSubview(sectionHeader("AirPlay Quick Connect"))

        recorderAirPlay.onChanged = { [weak self] pref in self?.onSaveAirPlayConnect?(pref) }
        let resetAirPlayBtn = NSButton(title: "Reset", target: self,
                                       action: #selector(resetAirPlayConnectToDefault))
        resetAirPlayBtn.bezelStyle = .rounded
        stack.addArrangedSubview(
            settingGroup(
                control: hotkeyRow(label: "Hotkey:", recorder: recorderAirPlay,
                                   resetBtn: resetAirPlayBtn),
                description: "Connects to an AirPlay display from any application. " +
                             "Announces the target display via speech."
            )
        )

        stack.addArrangedSubview(separator())

        // — Mirror / Extend Toggle —
        stack.addArrangedSubview(sectionHeader("Mirror / Extend Toggle"))

        recorderMirrorToggle.onChanged = { [weak self] pref in self?.onSaveMirrorToggle?(pref) }
        let resetMirrorBtn = NSButton(title: "Reset", target: self,
                                      action: #selector(resetMirrorToggleToDefault))
        resetMirrorBtn.bezelStyle = .rounded
        stack.addArrangedSubview(
            settingGroup(
                control: hotkeyRow(label: "Hotkey:", recorder: recorderMirrorToggle,
                                   resetBtn: resetMirrorBtn),
                description: "Toggles the connected AirPlay display between mirror and " +
                             "extend mode. Announces the new mode via speech."
            )
        )

        return scrollView
    }

    // MARK: - General tab

    private func buildGeneralTab() -> NSView {
        let scrollView = makeScrollView()
        let stack = scrollStack(in: scrollView)

        // — Behaviour —
        stack.addArrangedSubview(sectionHeader("Behaviour"))

        stack.addArrangedSubview(
            settingGroup(
                control: checkbox(
                    title: "Auto-connect when one AirPlay display is available",
                    isOn: VisibilityPreferences.autoConnectSingleDisplay,
                    action: { VisibilityPreferences.autoConnectSingleDisplay = $0 }
                ),
                description: "When only one AirPlay display is visible, skip the selection " +
                             "list and connect immediately."
            )
        )

        stack.addArrangedSubview(
            settingGroup(
                control: checkbox(
                    title: "Announce actions via speech",
                    isOn: VisibilityPreferences.speechEnabled,
                    action: { VisibilityPreferences.speechEnabled = $0 }
                ),
                description: "Speaks the target device name when connecting to AirPlay and " +
                             "when toggling mirror / extend mode."
            )
        )

        stack.addArrangedSubview(
            settingGroup(
                control: checkbox(
                    title: "Auto-hide virtual audio devices on first discovery",
                    isOn: VisibilityPreferences.autoHideVirtualAudio,
                    action: { VisibilityPreferences.autoHideVirtualAudio = $0 }
                ),
                description: "Hides virtual audio devices such as Teams, Zoom, BlackHole, " +
                             "and Loopback when they are first detected. They can be re-enabled " +
                             "in the Devices tab."
            )
        )

        stack.addArrangedSubview(separator())

        // — System —
        stack.addArrangedSubview(sectionHeader("System"))

        stack.addArrangedSubview(
            checkbox(
                title: "Launch at login",
                isOn: VisibilityPreferences.launchAtLogin,
                action: { VisibilityPreferences.launchAtLogin = $0 }
            )
        )

        return scrollView
    }

    // MARK: - Devices tab

    private func buildDevicesTab() -> NSView {
        let scrollView = makeScrollView()
        let stack = scrollStack(in: scrollView)

        stack.addArrangedSubview(
            descriptionLabel(
                "Unchecked devices are hidden from the menu bar and Touch Bar. " +
                "They remain available system-wide."
            )
        )

        stack.addArrangedSubview(separator())

        // — Audio Output —
        stack.addArrangedSubview(sectionHeader("Audio Output"))
        let audioDevices = audioManager.allOutputDevices
        if audioDevices.isEmpty {
            stack.addArrangedSubview(placeholderLabel("No output devices found"))
        } else {
            for device in audioDevices {
                stack.addArrangedSubview(
                    checkbox(
                        title: device.name,
                        isOn: VisibilityPreferences.isVisible(audioDevice: device.name),
                        action: { [weak self] visible in
                            VisibilityPreferences.setVisible(visible, audioDevice: device.name)
                            self?.audioManager.applyVisibility()
                            self?.onRebuild?()
                        }
                    )
                )
            }
        }

        stack.addArrangedSubview(separator())

        // — AirPlay Displays —
        stack.addArrangedSubview(sectionHeader("AirPlay Displays"))
        let airPlayDevices = videoManager.allAirPlayDevices
        if airPlayDevices.isEmpty {
            stack.addArrangedSubview(placeholderLabel("No AirPlay devices discovered yet"))
        } else {
            for device in airPlayDevices {
                stack.addArrangedSubview(
                    checkbox(
                        title: device.name,
                        isOn: VisibilityPreferences.isVisible(airPlayDevice: device.name),
                        action: { [weak self] visible in
                            VisibilityPreferences.setVisible(visible, airPlayDevice: device.name)
                            self?.videoManager.applyVisibility()
                            self?.onRebuild?()
                        }
                    )
                )
            }
        }

        stack.addArrangedSubview(separator())

        // — Connected Displays —
        stack.addArrangedSubview(sectionHeader("Connected Displays"))
        let physicalDisplays = videoManager.allConnectedDisplays
        if physicalDisplays.isEmpty {
            stack.addArrangedSubview(placeholderLabel("No external displays connected"))
        } else {
            for display in physicalDisplays {
                stack.addArrangedSubview(
                    checkbox(
                        title: display.name,
                        isOn: VisibilityPreferences.isVisible(display: display.name),
                        action: { [weak self] visible in
                            VisibilityPreferences.setVisible(visible, display: display.name)
                            self?.videoManager.applyVisibility()
                            self?.onRebuild?()
                        }
                    )
                )
            }
        }

        return scrollView
    }

    // MARK: - Virtual Display tab

    private func buildVirtualTab() -> NSView {
        let scrollView = makeScrollView()
        let stack = scrollStack(in: scrollView)

        // — Touch Bar Labels —
        stack.addArrangedSubview(sectionHeader("Touch Bar Labels"))
        stack.addArrangedSubview(
            settingGroup(
                control: buildAspectRatioRow(),
                description: "Resolutions matching this ratio use compact \"1080p\" labels in the Touch Bar."
            )
        )

        stack.addArrangedSubview(separator())

        // — AirPlay —
        stack.addArrangedSubview(sectionHeader("AirPlay"))
        buildVirtualDisplayControls(for: .airPlay, into: stack)

        stack.addArrangedSubview(separator())

        // — External —
        stack.addArrangedSubview(sectionHeader("External"))
        buildVirtualDisplayControls(for: .external, into: stack)

        stack.addArrangedSubview(separator())

        // — Built-in —
        stack.addArrangedSubview(sectionHeader("Built-in"))
        buildVirtualDisplayControls(for: .builtIn, into: stack)

        return scrollView
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

    private func scrollStack(in scrollView: NSScrollView) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 8
        stack.edgeInsets  = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])
        return stack
    }

    private func settingGroup(control: NSView, description: String) -> NSView {
        let desc = descriptionLabel(description)
        let group = NSStackView(views: [control, desc])
        group.orientation = .vertical
        group.alignment   = .leading
        group.spacing     = 3
        return group
    }

    private func hotkeyRow(label: String,
                            recorder: KeyRecorderView,
                            resetBtn: NSButton) -> NSView {
        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: NSFont.systemFontSize)
        let row = NSStackView(views: [lbl, recorder, resetBtn])
        row.orientation = .horizontal
        row.spacing     = 10
        NSLayoutConstraint.activate([
            recorder.widthAnchor.constraint(equalToConstant: 160),
            recorder.heightAnchor.constraint(equalToConstant: 22),
        ])
        return row
    }

    // MARK: - Virtual Display helpers

    /// Adds refresh-rate checkboxes and the default-resolution popup for one virtual-display context.
    private func buildVirtualDisplayControls(for context: VisibilityPreferences.DisplayContext,
                                             into stack: NSStackView) {
        let availableRates = [30, 60, 120, 240]
        for rate in availableRates {
            stack.addArrangedSubview(
                checkbox(
                    title: "\(rate) Hz",
                    isOn: VisibilityPreferences.virtualRefreshRates(for: context).contains(rate),
                    action: { [weak self] isOn in
                        var rates = VisibilityPreferences.virtualRefreshRates(for: context)
                        if isOn { rates.insert(rate) } else { rates.remove(rate) }
                        if rates.isEmpty { rates = [60] }
                        VisibilityPreferences.setVirtualRefreshRates(rates, for: context)
                        self?.onRebuild?()
                    }
                )
            )
        }
        stack.addArrangedSubview(buildDefaultResolutionRow(for: context))
    }

    /// Label + popup for choosing the aspect ratio used for compact Touch Bar labels.
    private func buildAspectRatioRow() -> NSView {
        let label = NSTextField(labelWithString: "Compact label ratio:")
        label.font = .systemFont(ofSize: NSFont.systemFontSize)

        let popup = AspectRatioPopup(onSelect: { [weak self] key in
            let parts = key.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2 {
                VisibilityPreferences.defaultAspectRatio = (parts[0], parts[1])
                self?.onRebuild?()
            }
        })
        popup.font = .systemFont(ofSize: NSFont.systemFontSize)

        let options = ["16:9", "16:10", "4:3", "21:9"]
        for key in options {
            let item = NSMenuItem(title: key, action: nil, keyEquivalent: "")
            item.representedObject = key
            popup.menu?.addItem(item)
        }

        let ar = VisibilityPreferences.defaultAspectRatio
        let stored = "\(ar.w):\(ar.h)"
        popup.selectItem(at: options.firstIndex(of: stored) ?? 0)

        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 10
        return row
    }

    /// Label + popup for choosing the default virtual resolution for a given context.
    private func buildDefaultResolutionRow(for context: VisibilityPreferences.DisplayContext) -> NSView {
        let label = NSTextField(labelWithString: "Default resolution:")
        label.font = .systemFont(ofSize: NSFont.systemFontSize)

        let popup = DefaultResolutionPopup(onSelect: { [weak self] key in
            VisibilityPreferences.setDefaultVirtualResolution(key, for: context)
            self?.onRebuild?()
        })
        popup.font = .systemFont(ofSize: NSFont.systemFontSize)

        // Options: (title, stored key or nil)
        let options: [(String, String?)] = [
            ("None",  nil),
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

        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing     = 10
        return row
    }

    // MARK: - View factories

    private func sectionHeader(_ title: String) -> NSView {
        let tf = NSTextField(labelWithString: title)
        tf.font      = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        tf.textColor = .secondaryLabelColor
        return tf
    }

    private func descriptionLabel(_ text: String) -> NSView {
        let tf = NSTextField(labelWithString: text)
        tf.font                    = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tf.textColor               = .secondaryLabelColor
        tf.lineBreakMode           = .byWordWrapping
        tf.maximumNumberOfLines    = 0
        tf.preferredMaxLayoutWidth = 360
        return tf
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func placeholderLabel(_ text: String) -> NSView {
        let tf = NSTextField(labelWithString: text)
        tf.font      = .systemFont(ofSize: NSFont.systemFontSize)
        tf.textColor = .tertiaryLabelColor
        return tf
    }

    private func checkbox(title: String,
                          isOn: Bool,
                          action: @escaping (Bool) -> Void) -> NSView {
        let cb = ClosureButton(title: title, action: action)
        cb.setButtonType(.switch)
        cb.state = isOn ? .on : .off
        cb.font  = .systemFont(ofSize: NSFont.systemFontSize)
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

// MARK: - FlippedClipView

/// NSClipView with a flipped coordinate system so scroll views display their
/// document from the top-left rather than the bottom-left.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

// MARK: - AspectRatioPopup

/// NSPopUpButton that fires a closure with the selected "W:H" string.
private final class AspectRatioPopup: NSPopUpButton {
    private let handler: (String) -> Void

    init(onSelect: @escaping (String) -> Void) {
        handler = onSelect
        super.init(frame: .zero, pullsDown: false)
        target = self
        action = #selector(selectionChanged)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func selectionChanged() {
        if let key = selectedItem?.representedObject as? String { handler(key) }
    }
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
