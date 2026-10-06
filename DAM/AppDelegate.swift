//
//  AppDelegate.swift
//

import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var iconAnimator: MenuBarIconAnimator!
    private let audioManager = AudioManager()
    private let videoManager = VideoManager()
    private let sidecarManager = SidecarManager()
    private var sidecarAutoConnector: SidecarAutoConnector?
    private var controlStrip: ControlStripPresenter!
    private var hotkey: GlobalHotkey!
    private var airPlayConnectHotkey: GlobalHotkey!
    private var mirrorToggleHotkey: GlobalHotkey!
    private var audioCycleHotkey: GlobalHotkey!
    private var mainDisplayHotkey: GlobalHotkey!
    private var settingsWindow: SettingsWindowController?
    private var aboutWindow: NSWindow?
    private var arrangeWindow: ArrangeDisplaysWindowController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Skip all initialisation when the process is a unit-test host.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        // Keep the app out of the Dock and app switcher
        NSApp.setActivationPolicy(.accessory)

        controlStrip = ControlStripPresenter(
            audioManager: audioManager,
            videoManager: videoManager,
            sidecarManager: sidecarManager
        )
        setupStatusItem()
        videoManager.startDiscovery()
        refreshAll(nil)
        controlStrip.install()

        AirPlayQuickConnect.shared.configure(videoManager: videoManager, sidecarManager: sidecarManager)
        sidecarAutoConnector = SidecarAutoConnector(sidecar: sidecarManager, video: videoManager)
        sidecarAutoConnector?.start()
        AudioOutputPicker.shared.configure(audioManager: audioManager)
        MirrorPicker.shared.configure(videoManager: videoManager)
        MainDisplayPicker.shared.configure(videoManager: videoManager)
        hotkey = GlobalHotkey(preference: HotkeyPreference.current) { [weak self] in
            self?.openSwitcher()
        }
        airPlayConnectHotkey = GlobalHotkey(preference: HotkeyPreference.currentAirPlayConnect) {
            AirPlayQuickConnect.shared.activate()
        }
        mirrorToggleHotkey = GlobalHotkey(preference: HotkeyPreference.currentMirrorToggle) {
            MirrorPicker.shared.advance()
        }
        audioCycleHotkey = GlobalHotkey(preference: HotkeyPreference.currentAudioCycle) {
            AudioOutputPicker.shared.advance()
        }
        mainDisplayHotkey = GlobalHotkey(preference: HotkeyPreference.currentMainDisplay) {
            MainDisplayPicker.shared.advance()
        }

        redirectSwiftUISettingsWindow()

        // Once the menu bar item is up, and not while a debug mode drives the app.
        var debugMode = false
        #if DEBUG
        debugMode = UserDefaults.standard.string(forKey: "DAMDebugHUD") != nil
        #endif
        if !debugMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.offerScreenMirroringExtra()
            }
        }

        #if DEBUG
        // `-DAMDebugHUD YES` on launch shows the quick-connect HUD preview; `connecting`
        // shows the connecting HUD instead, `select` plays the select animation, `audio`
        // plays the audio output picker, `mirror` the mirror picker, `main` the main display
        // picker, `caption` announces an example message, `arrange` opens the Arrange
        // Displays window, `settings` opens Settings, and `switcher` and `airplay` act as their hotkeys do; `connect-airplay` connects the
        // first available AirPlay display without the HUD, and `disconnect-airplay`
        // disconnects the connected one. `icon` steps the menu bar icon through
        // connection counts to show its animation.
        if let mode = UserDefaults.standard.string(forKey: "DAMDebugHUD") {
            switch mode {
            case "connecting": debugPreviewConnectingHUD(nil)
            case "select":     debugPlaySelectAnimation(nil)
            case "audio":      debugPlayAudioPicker(nil)
            case "mirror":     debugPlayMirrorPicker(nil)
            case "main":       debugPlayMainDisplayPicker(nil)
            case "caption":    debugPreviewCaptionHUD(nil)
            case "icon":       debugPlayMenuBarIcon(nil)
            case "arrange":    DispatchQueue.main.async { self.openArrangeDisplays(nil) }
            case "settings":   DispatchQueue.main.async { self.openSettings(nil) }
            case "switcher":   DispatchQueue.main.async { self.openSwitcher() }
            case "airplay":    // after discovery has had time to find displays
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    AirPlayQuickConnect.shared.activate()
                }
            case "connect-airplay":
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    guard let vm = self?.videoManager,
                          let display = vm.airPlayDevices.first(where: { !$0.isConnected }) else { return }
                    vm.connectAirPlay(deviceName: display.name)
                }
            case "disconnect-airplay":
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    guard let vm = self?.videoManager,
                          let display = vm.airPlayDevices.first(where: \.isConnected) else { return }
                    vm.disconnectAirPlay(deviceName: display.name)
                }
            default:           debugPreviewQuickConnectHUD(nil)
            }
        }
        #endif

        // Name Sidecar displays after their iPad, re-reading SidecarCore on each display merge
        // so a connection made from Control Center is recognised too.
        videoManager.connectedSidecarNames = { [sidecarManager] in
            sidecarManager.refresh()
            return sidecarManager.devices.filter(\.isConnected).map(\.name)
        }

        // Rebuild menu and Control Strip whenever a manager publishes a change
        audioManager.objectWillChange
            .merge(with: videoManager.objectWillChange, sidecarManager.objectWillChange)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] in self?.rebuild() }
            .store(in: &cancellables)
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        iconAnimator = MenuBarIconAnimator(button: statusItem.button)
        rebuild()
    }

    private func rebuild() {
        let menu = NSMenu()
        menu.delegate = self
        fill(menu)
        statusItem.menu = menu
        controlStrip.rebuild()
        iconAnimator.show(count: connectionCount)
    }

    /// Connections running through the app, shown by the menu bar icon's outflow: AirPlay
    /// displays and Sidecar iPads in use.
    private var connectionCount: Int {
        videoManager.allAirPlayDevices.filter(\.isConnected).count
            + sidecarManager.devices.filter(\.isConnected).count
    }

    /// Replaces `menu`'s items with ones built from the managers' current state.
    private func fill(_ menu: NSMenu) {
        let fresh = buildStatusMenu(
            audio: audioManager,
            video: videoManager,
            sidecar: sidecarManager,
            onRefresh: { [weak self] in self?.refreshAll(nil) }
        )
        menu.removeAllItems()
        for item in fresh.items {
            fresh.removeItem(item)
            menu.addItem(item)
        }
    }

    // MARK: - Actions

    /// Opens the switcher on the Touch Bar when one is available and enabled, and otherwise
    /// falls back to the menu bar menu, which tracks modally until it closes.
    private func openSwitcher() {
        if Feedback.touchBar {
            controlStrip.openModal()
        } else {
            statusItem.button?.performClick(nil)
        }
    }

    /// SwiftUI's `Settings` scene owns ⌘, and the app menu's "Settings…" item, and opens
    /// an empty hosting window for them. When that window comes up, it is closed and the
    /// settings window shown instead.
    private func redirectSwiftUISettingsWindow() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow,
                  window !== self.settingsWindow?.window,
                  let content = window.contentView,
                  String(describing: type(of: content)).contains("Hosting")
            else { return }
            // After SwiftUI has finished showing it, or the close does not stick.
            DispatchQueue.main.async {
                window.close()
                self.openSettings(nil)
            }
        }
    }

    /// Offers, once, to show Control Center's Screen Mirroring item in the menu bar, which
    /// is the quickest path for connecting an AirPlay display.
    private func offerScreenMirroringExtra() {
        guard !VisibilityPreferences.screenMirroringExtraOfferDismissed,
              !ScreenMirroringPanel.isExtraVisible else { return }
        let alert = NSAlert()
        alert.messageText = "Show Screen Mirroring in the menu bar?"
        alert.informativeText =
            "\(AppIdentity.name) connects AirPlay displays fastest through Control Center's " +
            "Screen Mirroring menu bar item. In Control Center settings, set Screen Mirroring " +
            "to “Always Show in Menu Bar”."
        alert.addButton(withTitle: "Open Control Center Settings")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Don't Ask Again")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: ScreenMirroringPanel.openControlCenterSettings()
        case .alertThirdButtonReturn: VisibilityPreferences.screenMirroringExtraOfferDismissed = true
        default: break
        }
    }

    @objc func refreshAll(_ sender: Any?) {
        audioManager.refresh()
        videoManager.refresh()
        sidecarManager.refresh()
        rebuild()
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    /// Fills the menu that is about to open from the current state, in place. Assigning a
    /// freshly built menu to the status item here would not change the one already opening,
    /// which is what made the menu run one open behind the display state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        audioManager.refresh()
        videoManager.refresh()
        sidecarManager.refresh()
        fill(menu)
        controlStrip.rebuild()
        iconAnimator.show(count: connectionCount)
    }

    #if DEBUG
    @objc func debugPreviewQuickConnectHUD(_ sender: Any?) {
        AirPlayQuickConnect.shared.showDebugPreview()
    }

    @objc func debugPlaySelectAnimation(_ sender: Any?) {
        AirPlayQuickConnect.shared.playDebugSelect()
    }

    @objc func debugPlayAudioPicker(_ sender: Any?) {
        AudioOutputPicker.shared.playDebugPreview()
    }

    @objc func debugPlayMirrorPicker(_ sender: Any?) {
        MirrorPicker.shared.playDebugPreview()
    }

    @objc func debugPlayMainDisplayPicker(_ sender: Any?) {
        MainDisplayPicker.shared.playDebugPreview()
    }

    @objc func debugPreviewConnectingHUD(_ sender: Any?) {
        AirPlayQuickConnect.shared.showDebugPreview(connecting: true)
    }

    /// Announces an example status message through the normal speech and caption path.
    @objc func debugPreviewCaptionHUD(_ sender: Any?) {
        SpeechSynthesizer.shared.announce("Mirroring Living Room TV")
    }

    /// Steps the menu bar icon through connection counts, one change every 2.5 seconds, then
    /// back to the real count, animating even with Reduce Motion on. A real connection
    /// change in the meantime shows the real count early.
    @objc func debugPlayMenuBarIcon(_ sender: Any?) {
        let counts: [Int?] = [3, 8, 1, 0, 2, nil]
        for (step, count) in counts.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + 2.5 * Double(step)) { [weak self] in
                guard let self else { return }
                self.iconAnimator.show(count: count ?? self.connectionCount, ignoringReduceMotion: true)
            }
        }
    }

    @objc func debugHideHUDPreviews(_ sender: Any?) {
        AirPlayQuickConnect.shared.hideDebugPreview()
        SpeechSynthesizer.shared.stop()
    }
    #endif

    @objc func selectAudioDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AudioDevice else { return }
        audioManager.setDefaultDevice(device)
    }

    /// Toggles the display: a connected one is deselected in the Screen Mirroring panel.
    @objc func selectDisplay(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? DisplayInfo else { return }
        let verb = display.isConnected ? "Deselected" : "Selected"
        videoManager.connectAirPlay(deviceName: display.name,
                                    announcing: "\(verb) \(display.label)")
    }

    /// An About window in two panes: the icon over the bundled ABOUT.txt on the left, the
    /// bundled README's feature list on the right, both as plain text.
    @objc func openAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = aboutWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 128).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 128).isActive = true

        // ABOUT.txt as written, each line centred under the icon, with {name}, {version},
        // {build} (the commit it was built from) and {copyright} filled in from the bundle.
        let info = Bundle.main.infoDictionary
        var about = bundledText("ABOUT")
        for (key, value) in [("name", AppIdentity.name),
                             ("version", info?["CFBundleShortVersionString"] as? String ?? "?"),
                             ("build", info?["DAMCommit"] as? String ?? info?["CFBundleVersion"] as? String ?? "?"),
                             ("copyright", info?["NSHumanReadableCopyright"] as? String ?? "")] {
            about = about.replacingOccurrences(of: "{\(key)}", with: value)
        }
        let identityText = NSTextField(labelWithString: about)
        identityText.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        identityText.alignment = .center
        identityText.setContentCompressionResistancePriority(.required, for: .vertical)
        identityText.setContentCompressionResistancePriority(.required, for: .horizontal)

        // The README as written, in a fixed-width font so its ASCII layout lines up. Its
        // first line, the name, duplicates the one above.
        let body = bundledText("README").split(separator: "\n", omittingEmptySubsequences: false)
            .dropFirst().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let features = NSTextField(labelWithString: body)
        features.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        features.setContentCompressionResistancePriority(.required, for: .vertical)
        features.setContentCompressionResistancePriority(.required, for: .horizontal)

        let identity = NSStackView(views: [icon, identityText])
        identity.orientation = .vertical
        identity.alignment = .centerX
        identity.spacing = 12
        identity.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        let divider = NSBox()
        divider.boxType = .separator

        let panes = NSStackView(views: [identity, divider, features])
        panes.orientation = .horizontal
        panes.alignment = .top
        panes.spacing = 24
        panes.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(panes)
        NSLayoutConstraint.activate([
            divider.heightAnchor.constraint(equalTo: panes.heightAnchor),
            panes.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            panes.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            panes.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            panes.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24)
        ])

        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "About \(AppIdentity.name)"
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        aboutWindow = window
    }

    /// A text file bundled with the app, or "" when it is missing.
    private func bundledText(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    @objc func openSettings(_ sender: Any?) {
        // Reuse the existing window if it was already created — only one settings
        // panel should exist at a time, and it persists across focus changes.
        if let existing = settingsWindow {
            existing.show()
            return
        }

        let wc = SettingsWindowController(
            current: HotkeyPreference.current,
            currentAirPlayConnect: HotkeyPreference.currentAirPlayConnect,
            currentMirrorToggle: HotkeyPreference.currentMirrorToggle,
            currentAudioCycle: HotkeyPreference.currentAudioCycle,
            currentMainDisplay: HotkeyPreference.currentMainDisplay,
            audioManager: audioManager,
            videoManager: videoManager,
            sidecarManager: sidecarManager
        )
        wc.onSave = { [weak self] pref in
            HotkeyPreference.current = pref
            self?.hotkey = GlobalHotkey(preference: pref) { [weak self] in
                self?.openSwitcher()
            }
        }
        wc.onSaveAirPlayConnect = { [weak self] pref in
            HotkeyPreference.currentAirPlayConnect = pref
            self?.airPlayConnectHotkey = GlobalHotkey(preference: pref) {
                AirPlayQuickConnect.shared.activate()
            }
        }
        wc.onSaveMirrorToggle = { [weak self] pref in
            HotkeyPreference.currentMirrorToggle = pref
            self?.mirrorToggleHotkey = GlobalHotkey(preference: pref) {
                MirrorPicker.shared.advance()
            }
        }
        wc.onSaveAudioCycle = { [weak self] pref in
            HotkeyPreference.currentAudioCycle = pref
            self?.audioCycleHotkey = GlobalHotkey(preference: pref) {
                AudioOutputPicker.shared.advance()
            }
        }
        wc.onSaveMainDisplay = { [weak self] pref in
            HotkeyPreference.currentMainDisplay = pref
            self?.mainDisplayHotkey = GlobalHotkey(preference: pref) {
                MainDisplayPicker.shared.advance()
            }
        }
        wc.onRebuild = { [weak self] in self?.rebuild() }
        settingsWindow = wc
        wc.show()
    }

    /// Opens the Arrange Displays window, one for the app's lifetime.
    @objc func openArrangeDisplays(_ sender: Any?) {
        let wc = arrangeWindow ?? ArrangeDisplaysWindowController(videoManager: videoManager)
        arrangeWindow = wc
        wc.show()
    }

    /// A "Position" pick: puts the display on the chosen side of another one.
    @objc func positionDisplay(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? PositionSelection else { return }
        videoManager.applyPositionSelection(selection) { [weak self] result in
            if case .failure(let error) = result {
                SpeechSynthesizer.shared.announce(error.localizedDescription)
            }
            self?.rebuild()
        }
    }

    @objc func optimizeForDisplay(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? DisplayInfo else { return }
        videoManager.setAsOptimizedDisplay(display) { [weak self] result in
            if case .failure(let error) = result {
                SpeechSynthesizer.shared.announce(error.localizedDescription)
            }
            self?.rebuild()
        }
    }

    @objc func selectSidecarDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? SidecarDevice else { return }
        let over = device.link.map { " over \($0.rawValue)" } ?? ""
        SpeechSynthesizer.shared.announce(device.isConnected
            ? "Disconnecting \(device.label)" : "Connecting to \(device.label)\(over)")
        guard !device.isConnected else {
            sidecarManager.toggle(device) { [weak self] error in
                if let error { SpeechSynthesizer.shared.announce(error.localizedDescription) }
                self?.rebuild()
            }
            return
        }
        sidecarManager.connect(device, videoManager: videoManager) { [weak self] _ in self?.rebuild() }
    }

    @objc func disconnectAirPlayDevice(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? DisplayInfo else { return }
        videoManager.disconnectAirPlay(deviceName: display.name,
                                       announcing: "Deselected \(display.label)")
    }

    /// A "Mirror on" pick: a checked display leaves the set, an unchecked one joins it, and
    /// "All Displays" brings every other display in.
    @objc func mirrorOnDisplay(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? MirrorSelection else { return }
        videoManager.applyMirrorSelection(selection) { [weak self] result in
            if case .failure(let error) = result {
                SpeechSynthesizer.shared.announce(error.localizedDescription)
            }
            self?.rebuild()
        }
    }

    @objc func useAsMainDisplay(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? DisplayInfo else { return }
        videoManager.setMainDisplay(display) { [weak self] result in
            if case .failure(let error) = result {
                SpeechSynthesizer.shared.announce(error.localizedDescription)
            }
            self?.rebuild()
        }
    }

    @objc func toggleDisplayMirror(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? DisplayInfo else { return }
        videoManager.toggleMirroring(for: display) { [weak self] result in
            if case .failure(let error) = result {
                SpeechSynthesizer.shared.announce(error.localizedDescription)
            }
            self?.rebuild()
        }
    }

    @objc func selectResolution(_ sender: NSMenuItem) {
        guard let sel = sender.representedObject as? ResolutionSelection else { return }
        // When a native resolution is chosen and a virtual anchor is active for the
        // display that owns this cgDisplayID, disable the anchor first so the display
        // is freed from mirror mode before we set the native mode.
        let matchingDisplay = (videoManager.airPlayDevices + videoManager.connectedDisplays).first {
            $0.cgDisplayID == sel.cgDisplayID
        }
        if let ap = matchingDisplay, videoManager.hasVirtualAnchor(for: ap.name) {
            videoManager.disableVirtualAnchor(for: ap)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.videoManager.setMode(sel.mode, for: sel.cgDisplayID) { _ in self?.rebuild() }
            }
        } else {
            videoManager.setMode(sel.mode, for: sel.cgDisplayID) { [weak self] _ in self?.rebuild() }
        }
    }

    @objc func selectVirtualResolution(_ sender: NSMenuItem) {
        guard let sel = sender.representedObject as? VirtualResolutionSelection else { return }
        videoManager.selectVirtualMode(sel.mode, for: sel.display)
        // Rebuild after the anchor has time to activate and the mode to settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.rebuild()
        }
    }
}
