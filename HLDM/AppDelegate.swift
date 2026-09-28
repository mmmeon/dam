//
//  AppDelegate.swift
//  boar
//

import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let audioManager = AudioManager()
    private let videoManager = VideoManager()
    private var controlStrip: ControlStripPresenter!
    private var hotkey: GlobalHotkey!
    private var airPlayConnectHotkey: GlobalHotkey!
    private var mirrorToggleHotkey: GlobalHotkey!
    private var audioCycleHotkey: GlobalHotkey!
    private var settingsWindow: SettingsWindowController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Skip all initialisation when the process is a unit-test host.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        // Keep the app out of the Dock and app switcher
        NSApp.setActivationPolicy(.accessory)

        controlStrip = ControlStripPresenter(
            audioManager: audioManager,
            videoManager: videoManager
        )
        setupStatusItem()
        videoManager.startDiscovery()
        refreshAll(nil)
        controlStrip.install()

        AirPlayQuickConnect.shared.configure(videoManager: videoManager)
        hotkey = GlobalHotkey(preference: HotkeyPreference.current) { [weak self] in
            self?.openSwitcher()
        }
        airPlayConnectHotkey = GlobalHotkey(preference: HotkeyPreference.currentAirPlayConnect) {
            AirPlayQuickConnect.shared.activate()
        }
        mirrorToggleHotkey = GlobalHotkey(preference: HotkeyPreference.currentMirrorToggle) { [weak self] in
            self?.toggleAirPlayMirror()
        }
        audioCycleHotkey = GlobalHotkey(preference: HotkeyPreference.currentAudioCycle) { [weak self] in
            self?.cycleAudioOutput()
        }

        // Rebuild menu and Control Strip whenever either manager publishes a change
        audioManager.objectWillChange
            .merge(with: videoManager.objectWillChange)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] in self?.rebuild() }
            .store(in: &cancellables)
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(named: "MenuBarIcon")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        rebuild()
    }

    private func rebuild() {
        let menu = buildStatusMenu(
            audio: audioManager,
            video: videoManager,
            onRefresh: { [weak self] in self?.refreshAll(nil) }
        )
        menu.delegate = self
        statusItem.menu = menu
        controlStrip.rebuild()
    }

    // MARK: - Actions

    /// Opens the Touch Bar switcher, or the menu bar menu when no Touch Bar is available
    /// (a Mac without one, or with the lid closed).
    private func openSwitcher() {
        if ControlStripPresenter.isTouchBarAvailable {
            controlStrip.openModal()
        } else {
            statusItem.button?.performClick(nil)
        }
    }

    /// Switches to the next enabled audio output and announces it.
    private func cycleAudioOutput() {
        guard let device = audioManager.cycleDefaultDevice() else {
            SpeechSynthesizer.shared.announce("No audio outputs enabled")
            return
        }
        SpeechSynthesizer.shared.announce(device.name)
    }

    private func toggleAirPlayMirror() {
        // Find the first connected AirPlay display that has a real display ID.
        guard let display = videoManager.airPlayDevices.first(where: { $0.isConnected && $0.cgDisplayID != 0 }) else {
            SpeechSynthesizer.shared.announce("No AirPlay display connected")
            return
        }
        // Determine current state so we can announce what we're switching TO.
        let isMirroring = display.isMirroring || videoManager.isBeingMirrored(display)
        videoManager.toggleMirroring(for: display)
        SpeechSynthesizer.shared.announce(isMirroring ? "Extending \(display.name)" : "Mirroring \(display.name)")
    }

    @objc func refreshAll(_ sender: Any?) {
        audioManager.refresh()
        videoManager.refresh()
        rebuild()
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        audioManager.refresh()
        videoManager.refresh()
        rebuild()
    }

    @objc func selectAudioDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AudioDevice else { return }
        audioManager.setDefaultDevice(device)
    }

    @objc func selectDisplay(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? DisplayInfo else { return }
        videoManager.connectAirPlay(deviceName: display.name)
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
            audioManager: audioManager,
            videoManager: videoManager
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
            self?.mirrorToggleHotkey = GlobalHotkey(preference: pref) { [weak self] in
                self?.toggleAirPlayMirror()
            }
        }
        wc.onSaveAudioCycle = { [weak self] pref in
            HotkeyPreference.currentAudioCycle = pref
            self?.audioCycleHotkey = GlobalHotkey(preference: pref) { [weak self] in
                self?.cycleAudioOutput()
            }
        }
        wc.onRebuild = { [weak self] in self?.rebuild() }
        settingsWindow = wc
        wc.show()
    }

    @objc func optimizeForDisplay(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? DisplayInfo else { return }
        videoManager.setAsOptimizedDisplay(display)
    }

    @objc func disconnectAirPlayDevice(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? DisplayInfo else { return }
        videoManager.disconnectAirPlay(deviceName: display.name)
    }

    @objc func toggleDisplayMirror(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? DisplayInfo else { return }
        videoManager.toggleMirroring(for: display)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
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
                self?.videoManager.setMode(sel.mode, for: sel.cgDisplayID)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self?.rebuild()
                }
            }
        } else {
            videoManager.setMode(sel.mode, for: sel.cgDisplayID)
            // Allow the display reconfiguration to settle before querying the new
            // current mode — CGDisplayCopyDisplayMode can lag the config commit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.rebuild()
            }
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
