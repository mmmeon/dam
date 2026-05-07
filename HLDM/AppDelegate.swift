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
            self?.controlStrip.openModal()
        }
        airPlayConnectHotkey = GlobalHotkey(preference: HotkeyPreference.currentAirPlayConnect) {
            AirPlayQuickConnect.shared.activate()
        }
        mirrorToggleHotkey = GlobalHotkey(preference: HotkeyPreference.currentMirrorToggle) { [weak self] in
            self?.toggleAirPlayMirror()
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

    private func toggleAirPlayMirror() {
        // Find the first connected AirPlay display that has a real display ID.
        guard let display = videoManager.airPlayDevices.first(where: { $0.isConnected && $0.cgDisplayID != 0 }) else {
            SpeechSynthesizer.shared.speak("No AirPlay display connected")
            return
        }
        // Determine current state so we can announce what we're switching TO.
        let isMirroring = display.isMirroring || videoManager.isBeingMirrored(display)
        videoManager.toggleMirroring(for: display)
        SpeechSynthesizer.shared.speak(isMirroring ? "Extending \(display.name)" : "Mirroring \(display.name)")
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
            audioManager: audioManager,
            videoManager: videoManager
        )
        wc.onSave = { [weak self] pref in
            HotkeyPreference.current = pref
            self?.hotkey = GlobalHotkey(preference: pref) { [weak self] in
                self?.controlStrip.openModal()
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
        videoManager.setMode(sel.mode, for: sel.cgDisplayID)
        // Allow the display reconfiguration to settle before querying the new
        // current mode — CGDisplayCopyDisplayMode can lag the config commit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.rebuild()
        }
    }
}
