//
//  AppDelegate.swift
//

import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var iconAnimator: MenuBarIconAnimator!
    // Lazy, so a unit-test host, which skips launching, doesn't reach CoreAudio or SidecarCore.
    private lazy var audioManager = AudioManager()
    private lazy var videoManager = VideoManager()
    private lazy var sidecarManager = SidecarManager()
    /// How often either server's pairing prompt may come up, the two together.
    private let pairingPromptLimits = PairingPromptLimits()
    private lazy var moonlightHost = MoonlightHost(promptLimits: pairingPromptLimits)
    /// The stream for browsers and players, apart from Moonlight.
    private lazy var webStream = WebStreamServer(promptLimits: pairingPromptLimits)
    private lazy var openDisplay = OpenDisplaySender()
    /// The PIN prompt for Moonlight pairing, while it shows.
    private var moonlightPINAlert: NSAlert?
    private var autoConnector: AutoConnector?
    private var controlStrip: ControlStripPresenter!
    /// The app the Touch Bar switcher took focus from, handed back when it closes.
    private var switcherFocus = SwitcherFocus<NSRunningApplication>()
    /// Tells `switcherFocus` when the user goes on in a window of DAM's, while it holds an app.
    private var switcherFocusMonitor: Any?
    /// Whether the menu bar menu is open, so the Switcher hotkey closes it rather than
    /// opening it again once it has closed.
    private weak var openStatusMenu: NSMenu?
    private var hotkeys: [HotkeyAction: GlobalHotkey] = [:]
    private var settingsWindow: SettingsWindowController?
    private var aboutWindow: NSWindow?
    private var arrangeWindow: ArrangeDisplaysWindowController?
    private var cancellables = Set<AnyCancellable>()
    /// Remote sessions of other apps, and the socket and URLs that start and end them.
    private var sessionCoordinator: RemoteSessionCoordinator?
    private var controlHandler: ControlHandler?
    private var controlServer: ControlServer?
    private var sessionWatcher: SessionWatcher?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // dam:// URLs; as an Apple event, so SwiftUI doesn't look for a window to open them in.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The displays go with the app; the sound output would stay switched.
        sessionWatcher?.announce = nil
        sessionCoordinator?.endAll()
        sessionWatcher?.stop()
        controlServer?.stop()
    }

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
        controlStrip.onModalClose = { [weak self] in self?.switcherClosed() }
        controlStrip.onModalWatchGaveUp = { [weak self] in
            self?.switcherFocus.watchGaveUp()
            self?.watchSwitcherFocus()
        }
        // Gone to another app while the switcher is open, the user stays where they went.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.switcherFocus.userMovedOn()
            self?.watchSwitcherFocus()
        }
        setupStatusItem()
        // Name Sidecar displays after their iPad, re-reading SidecarCore on each display merge
        // so a connection made from Control Center is recognised too; before the first merge.
        videoManager.connectedSidecarNames = { [sidecarManager] in
            sidecarManager.refresh()
            return sidecarManager.devices.filter(\.isConnected).map(\.name)
        }
        videoManager.startDiscovery()
        refreshAll(nil)
        controlStrip.install()

        AirPlayQuickConnect.shared.configure(videoManager: videoManager, sidecarManager: sidecarManager)
        autoConnector = AutoConnector(sidecar: sidecarManager, video: videoManager)
        autoConnector?.start()
        moonlightHost.requestPIN = { [weak self] address, isCurrent, answer in
            self?.promptForMoonlightPIN(address: address, isCurrent: isCurrent, answer: answer)
        }
        moonlightHost.pairingAbandoned = { [weak self] in
            if self?.moonlightPINAlert != nil { NSApp.abortModal() }
        }
        moonlightHost.onChange = { [weak self] in self?.rebuild() }
        // A stream's display, made and resized at the stream's size: Moonlight's and a browser's alike.
        let makeStreamDisplay: (Int, Int, Int, @escaping (CGDirectDisplayID?) -> Void) -> Void
        makeStreamDisplay = { [weak self] width, height, fps, done in
            guard let self else { return done(nil) }
            self.videoManager.createStreamingDisplay(
                mode: StreamingDisplayModes.forStream(width: width, height: height, fps: fps), completion: done)
        }
        let removeStreamDisplay: (CGDirectDisplayID) -> Void = { [weak self] id in self?.videoManager.removeStreamingDisplay(id: id) }
        let resizeStreamDisplay: (CGDirectDisplayID, Int, Int, Int, @escaping (Bool) -> Void) -> Void
        resizeStreamDisplay = { [weak self] id, width, height, fps, done in
            guard let self else { return done(false) }
            self.videoManager.resizeStreamingDisplay(
                id: id, to: StreamingDisplayModes.forStream(width: width, height: height, fps: fps), completion: done)
        }
        moonlightHost.makeDisplay = makeStreamDisplay
        moonlightHost.removeDisplay = removeStreamDisplay
        moonlightHost.resizeDisplay = resizeStreamDisplay
        // A display made for Moonlight is listed to browsers, which may stream it too.
        moonlightHost.othersStream = { [weak self] id in self?.webStream.streams(display: id) ?? false }
        moonlightHost.handOverDisplay = { [weak self] id in self?.webStream.adopt(display: id) }
        if MoonlightHost.isEnabled && !MoonlightHost.usesExternalSunshine { moonlightHost.start() }
        startRemoteSessions()
        webStream.onChange = { [weak self] in self?.rebuild() }
        webStream.requestCode = { [weak self] address, name, isCurrent, answer in
            self?.promptForBrowserCode(name: name, isCurrent: isCurrent, answer: answer)
        }
        webStream.makeDisplay = makeStreamDisplay
        webStream.removeDisplay = removeStreamDisplay
        webStream.resizeDisplay = resizeStreamDisplay
        // A display made for a browser is listed to Moonlight, which may stream it too.
        webStream.othersStream = { [weak self] id in self?.moonlightHost.streams(display: id) ?? false }
        webStream.handOverDisplay = { [weak self] id in self?.moonlightHost.adopt(display: id) }
        if WebStreamServer.isEnabled { webStream.start() }
        openDisplay.onChange = { [weak self] in self?.settingsWindow?.openDisplayDidChange() }
        openDisplay.makeDisplay = { [weak self] mode, identity, done in
            guard let self else { return done(nil) }
            self.videoManager.createStreamingDisplay(mode: mode, identity: identity, completion: done)
        }
        openDisplay.removeDisplay = { [weak self] id in self?.videoManager.removeStreamingDisplay(id: id) }
        // Later, not from inside VideoManager's change.
        videoManager.onStreamingDisplayGone = { [weak self] id in
            DispatchQueue.main.async {
                self?.openDisplay.displayGone(id)
                self?.webStream.displayGone(id)
                self?.moonlightHost.displayGone(id)
                self?.sessionCoordinator?.displayGone(id)
            }
        }
        openDisplay.resizeDisplay = { [weak self] id, mode, done in
            guard let self else { return done(false) }
            self.videoManager.resizeStreamingDisplay(id: id, to: mode, completion: done)
        }
        openDisplay.hasOwnDisplay = { [weak self] in self?.videoManager.hasOwnDisplay() ?? true }
        if OpenDisplaySender.isEnabled { openDisplay.start() }
        WakeGuard.shared.isInUse = { [weak self] in
            guard let self else { return false }
            return !self.videoManager.streamingDisplayIDs.isEmpty || !self.moonlightHost.launches.isEmpty
                || self.webStream.viewerCount > 0 || self.sessionCoordinator?.sessions.isEmpty == false
        }
        WakeGuard.shared.start()
        AudioOutputPicker.shared.configure(audioManager: audioManager)
        MirrorPicker.shared.configure(videoManager: videoManager)
        MainDisplayPicker.shared.configure(videoManager: videoManager)
        ResolutionPicker.shared.configure(videoManager: videoManager) { [weak self] mode, display in
            if mode.isVirtual {
                self?.applyVirtualResolution(mode, for: display)
            } else {
                self?.applyResolution(mode, cgDisplayID: display.cgDisplayID)
            }
        }
        RotationPicker.shared.configure(videoManager: videoManager) { [weak self] rotation, display in
            self?.applyRotation(rotation, for: display)
        }
        for action in HotkeyAction.allCases {
            hotkeys[action] = GlobalHotkey(preference: action.shortcut) { [weak self] in self?.perform(action) }
        }

        redirectSwiftUISettingsWindow()

        // Once the menu bar item is up, and not while a debug mode drives the app.
        var debugMode = false
        #if DEBUG
        debugMode = UserDefaults.standard.string(forKey: "DAMDebugHUD") != nil
        #endif
        if !debugMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                // From the run loop, as the PIN prompt is: the alert waits for an answer, and
                // inside a main queue block it would hold every other one until then.
                RunLoop.main.perform(inModes: [.default]) { self?.offerScreenMirroringExtra() }
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
        // connection counts to show its animation. `diagnose-mirroring` runs the Screen
        // Mirroring diagnosis.
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
            case "diagnose-mirroring": // after discovery has had time to find displays
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    self?.debugDiagnoseScreenMirroring(nil)
                }
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

        // Rebuild menu and Control Strip whenever a manager publishes a change
        audioManager.objectWillChange
            .merge(with: videoManager.objectWillChange, sidecarManager.objectWillChange)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] in self?.rebuild() }
            .store(in: &cancellables)
    }

    // MARK: - Setup

    private func startRemoteSessions() {
        let displays = LiveSessionDisplays(video: videoManager, audio: audioManager)
        let coordinator = RemoteSessionCoordinator(displays: displays)
        coordinator.onChange = { [weak self] in
            self?.rebuild()
            // A detector change held for a session that has just ended; later, as this can
            // come from inside that detector.
            DispatchQueue.main.async { self?.sessionWatcher?.update() }
        }
        coordinator.onLearn = { [weak self] in self?.settingsWindow?.reloadSessions() }
        let handler = ControlHandler(coordinator: coordinator, video: videoManager, sessionDisplays: displays)
        let server = ControlServer { request, reply in handler.handle(request, reply: reply) }
        do {
            try server.start()
            controlServer = server
        } catch {
            NSLog("\(AppIdentity.name): not listening for commands: \(error)")
        }
        sessionCoordinator = coordinator
        controlHandler = handler
        SessionDetectors.displayNames = { displays.displayNames }
        SessionDetectors.adoptName = { [weak coordinator] in coordinator?.profile(for: "display").adoptName }
        let watcher = SessionWatcher(coordinator: coordinator)
        watcher.announce = { SpeechSynthesizer.shared.announce($0) }
        watcher.update()
        sessionWatcher = watcher
    }

    /// Ends the remote session of the app in the item's `representedObject`.
    @objc func endRemoteSession(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? String else { return }
        if case .success = sessionCoordinator?.end(app: app, all: true) {
            SpeechSynthesizer.shared.announce(Spoken.remoteSessionEnded(RemoteSessionApp.name(of: app)))
        }
    }

    /// Lights the Mac's screens blacked out for a session.
    @objc func liftBlackout(_ sender: Any?) {
        sessionCoordinator?.liftBlackout()
    }

    /// Opens Settings on the Remote Sessions tab.
    @objc func openSessionSettings(_ sender: Any?) {
        openSettings(nil)
        settingsWindow?.showSessions()
    }

    /// Hands Moonlight streams to an external Sunshine, turning DAM's host off so Sunshine
    /// can have its ports, or back to DAM's host.
    private func useExternalSunshine(_ external: Bool) {
        guard external != MoonlightHost.usesExternalSunshine else { return }
        MoonlightHost.usesExternalSunshine = external
        if external {
            if moonlightHost.isRunning { moonlightHost.stop() }
        } else if MoonlightHost.isEnabled {
            moonlightHost.start()
        }
        rebuild()
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text), let request = ControlHandler.request(from: url) else { return }
        // Before launch has finished, once it has.
        DispatchQueue.main.async { [weak self] in
            self?.controlHandler?.handle(request, from: .link) { response in
                if !response.ok { NSLog("\(AppIdentity.name): \(url.absoluteString): \(response.message ?? "failed")") }
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // The icon is an image only, so VoiceOver and the pointer get the app's name.
        statusItem.button?.setAccessibilityLabel(AppIdentity.name)
        statusItem.button?.toolTip = AppIdentity.name
        iconAnimator = MenuBarIconAnimator(button: statusItem.button)
        rebuild()
    }

    private func rebuild() {
        // Every display, those hidden from the menu bar and Touch Bar too, which hides no more.
        let apps = videoManager.streamingDisplays.filter { $0.standsInFor == nil }.compactMap { streaming in
            videoManager.allConnectedDisplays.first { $0.cgDisplayID == streaming.id }
                .map { MoonlightApp(id: streaming.index + 1, title: $0.label, displayID: streaming.id) }
        }
        // The Mac's own displays too, when asked for, those showing a desktop of their own.
        let connected = !MoonlightHost.listsOwnDisplays ? [] : videoManager.allConnectedDisplays
            .filter { $0.isConnected && $0.cgDisplayID != 0 && !$0.isStreaming }
        let ownDisplays = connected.filter { !$0.isMirroring }
        let ownIDs = MoonlightHost.ownDisplayAppIDs(ownDisplays.map(\.cgDisplayID),
                                                    others: connected.filter(\.isMirroring).map(\.cgDisplayID))
        let own = zip(ownDisplays, ownIDs).map { display, id in
            MoonlightApp(id: id, title: display.label, displayID: display.cgDisplayID)
        }
        moonlightHost.apps = apps + own
        webStream.apps = { apps }
        let menu = NSMenu()
        menu.delegate = self
        fill(menu)
        statusItem.menu = menu
        controlStrip.rebuild()
        iconAnimator.show(count: connectionCount)
        settingsWindow?.moonlightDidChange()
        settingsWindow?.browserStreamDidChange()
        settingsWindow?.openDisplayDidChange()
        settingsWindow?.sessionsDidChange()
        settingsWindow?.devicesDidChange()
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
            moonlight: moonlightHost,
            webStream: webStream,
            sessions: sessionCoordinator?.sessions.values.sorted { $0.started < $1.started } ?? [],
            blackedOut: sessionCoordinator?.isBlackedOut ?? false,
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
            // DAM's Touch Bar doesn't show over another app while a DAM window is on screen,
            // so DAM comes forward while the switcher is open, and hands focus back when it
            // closes. Opened again while open, DAM is active already and the app is kept.
            if NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                switcherFocus.opened(from: activateForHUDTouchBar())
                watchSwitcherFocus()
            }
            controlStrip.openModal()
        } else if let menu = openStatusMenu {
            // Pressed to close the menu: it closes, and isn't opened again once it has.
            menu.cancelTracking()
        } else {
            // From the run loop, as the PIN prompt is: the menu tracks until it closes, and
            // inside a main queue block (as a hotkey's action is) it would hold every other one.
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                guard let self, self.openStatusMenu == nil else { return }
                self.statusItem.button?.performClick(nil)
            }
        }
    }

    /// Hands focus back to the app the switcher took it from, unless the user has gone on in
    /// a window of DAM's or another app meanwhile, or an alert of DAM's is up (a pairing
    /// prompt, say), which keeps it. The switcher's close is seen while an alert is up too,
    /// as its watch ticks in the alert's run loop mode. No pick opens a window or alert.
    private func switcherClosed() {
        restoreFocus(to: switcherFocus.closed(alertUp: NSApp.modalWindow != nil))
        watchSwitcherFocus()
    }

    /// Watches for a click or key in a window of DAM's, an alert's included, while the
    /// switcher holds an app to hand focus back to, and only then.
    private func watchSwitcherFocus() {
        if switcherFocus.previous == nil {
            if let monitor = switcherFocusMonitor { NSEvent.removeMonitor(monitor) }
            switcherFocusMonitor = nil
        } else if switcherFocusMonitor == nil {
            switcherFocusMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
            ) { [weak self] event in
                // A HUD's panel, untitled, takes a picker's keys; those don't count.
                if let window = event.window, window.styleMask.contains(.titled) || window === NSApp.modalWindow {
                    self?.switcherFocus.userMovedOn()
                    DispatchQueue.main.async { self?.watchSwitcherFocus() }
                }
                return event
            }
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
    // The status menu is the only one with this delegate. Kept rather than compared with
    // `statusItem.menu`, which a rebuild while the menu is open replaces.
    func menuWillOpen(_ menu: NSMenu) {
        if menu.supermenu == nil { openStatusMenu = menu }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu.supermenu == nil { openStatusMenu = nil }
    }

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

    @objc func debugPlayResolutionPicker(_ sender: Any?) {
        ResolutionPicker.shared.playDebugPreview()
    }

    @objc func debugPreviewConnectingHUD(_ sender: Any?) {
        AirPlayQuickConnect.shared.showDebugPreview(connecting: true)
    }

    /// Announces an example status message through the normal speech and caption path.
    /// Opens Screen Mirroring and finds an AirPlay display without connecting it, then saves
    /// a report, with device names replaced, on the Desktop. The display is the first one listed that isn't
    /// connected; with none listed, a made-up name still checks that the panel opens, and the
    /// report then shows the panel's contents.
    @objc func debugDiagnoseScreenMirroring(_ sender: Any?) {
        let devices = videoManager.allAirPlayDevices
        let name = (devices.first { !$0.isConnected } ?? devices.first)?.name ?? "No AirPlay display listed"
        SpeechSynthesizer.shared.announce(Spoken.checkingScreenMirroring)
        sidecarManager.refresh()
        ScreenMirroringPanel.diagnose(deviceName: name,
                                      displays: devices.map { ($0.name, $0.isConnected) },
                                      iPads: sidecarManager.devices.map(\.name)) { report, ok in
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/\(AppIdentity.name) Screen Mirroring \(stamp).txt")
            let saved: Bool
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                saved = true
            } catch {
                NSLog("\(AppIdentity.name): writing the Screen Mirroring report failed: \(error)")
                saved = false
            }
            SpeechSynthesizer.shared.announce(Spoken.screenMirroringCheck(ok: ok, saved: saved))
        }
    }

    @objc func debugPreviewCaptionHUD(_ sender: Any?) {
        SpeechSynthesizer.shared.announce(Spoken.captionPreview)
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
        videoManager.connectAirPlay(deviceName: display.name,
                                    announcing: display.isConnected ? Spoken.deselected(display.label)
                                                                    : Spoken.selected(display.label))
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
            audioManager: audioManager,
            videoManager: videoManager,
            sidecarManager: sidecarManager,
            moonlightHost: moonlightHost,
            webStream: webStream,
            openDisplay: openDisplay,
            sessionCoordinator: sessionCoordinator
        )
        wc.onSave = { [weak self] action, pref in
            action.shortcut = pref
            self?.rebind(action, to: pref)
        }
        wc.isRegistered = { [weak self] in self?.hotkeys[$0]?.isRegistered ?? true }
        wc.onRebuild = { [weak self] in self?.rebuild() }
        wc.onToggleMoonlight = { [weak self] in self?.toggleMoonlightHost(nil) }
        wc.onForgetMoonlightClient = { [weak self] in self?.forget($0) }
        wc.onUseExternalSunshine = { [weak self] in self?.useExternalSunshine($0) }
        wc.onSessionProfilesChanged = { [weak self] in self?.sessionWatcher?.update() }
        wc.sessionWaitsToApply = { [weak self] app in self?.sessionWatcher?.waitsForSessionEnd(app) ?? false }
        wc.onToggleWebStream = { [weak self] in self?.toggleWebStream(nil) }
        settingsWindow = wc
        wc.show()
    }

    /// Moves one of the app's shortcuts to `pref`, then registers again any that couldn't be,
    /// as when this one held their keys.
    private func rebind(_ action: HotkeyAction, to pref: HotkeyPreference) {
        hotkeys[action]?.update(preference: pref)
        for other in HotkeyAction.allCases where other != action { hotkeys[other]?.registerIfNeeded() }
    }

    /// What each shortcut does.
    private func perform(_ action: HotkeyAction) {
        switch action {
        case .switcher:       openSwitcher()
        case .airPlayConnect: AirPlayQuickConnect.shared.activate()
        case .mirrorToggle:   MirrorPicker.shared.advance()
        case .audioCycle:     AudioOutputPicker.shared.advance()
        case .mainDisplay:    MainDisplayPicker.shared.advance()
        case .resolution:     ResolutionPicker.shared.advance()
        case .rotation:       RotationPicker.shared.advance()
        }
    }

    /// Opens Settings on the Moonlight tab.
    @objc func openMoonlightSettings(_ sender: Any?) {
        openSettings(nil)
        settingsWindow?.showMoonlight()
    }

    /// Opens Settings on the Browser Stream tab.
    @objc func openBrowserStreamSettings(_ sender: Any?) {
        openSettings(nil)
        settingsWindow?.showBrowserStream()
    }

    /// Opens the Arrange Displays window, one for the app's lifetime.
    @objc func openArrangeDisplays(_ sender: Any?) {
        let wc = arrangeWindow ?? ArrangeDisplaysWindowController(videoManager: videoManager)
        arrangeWindow = wc
        wc.show()
    }

    /// Adds a streaming display, for a streaming or remote-desktop app to capture.
    @objc func createStreamingDisplay(_ sender: NSMenuItem) {
        SpeechSynthesizer.shared.announce(Spoken.creatingStreamingDisplay)
        videoManager.createStreamingDisplay()
        rebuild()
    }

    /// Removes the streaming display in the item's `representedObject`.
    @objc func removeStreamingDisplay(_ sender: NSMenuItem) {
        guard let display = sender.representedObject as? DisplayInfo else { return }
        SpeechSynthesizer.shared.announce(Spoken.removing(display.label))
        // An OpenDisplay receiver still on would be dialed again and bring it back: its
        // display removed by the user turns it off, which removes the display.
        if !openDisplay.turnOff(displayID: display.cgDisplayID) { videoManager.removeStreamingDisplay(display) }
        rebuild()
    }

    /// Turns hosting for Moonlight on or off.
    @objc func toggleMoonlightHost(_ sender: Any?) {
        if moonlightHost.isRunning {
            MoonlightHost.isEnabled = false
            moonlightHost.stop()
            SpeechSynthesizer.shared.announce(Spoken.moonlightCanNoLongerConnect)
        } else {
            MoonlightHost.isEnabled = true
            // Turned on here, DAM hosts again in Sunshine's place.
            if MoonlightHost.usesExternalSunshine { MoonlightHost.usesExternalSunshine = false }
            moonlightHost.start()
            // Streaming needs it; asked now rather than when a stream starts.
            MoonlightScreenCapture.requestPermission()
            SpeechSynthesizer.shared.announce(moonlightHost.isRunning ? Spoken.moonlightCanConnect
                                              : moonlightHost.lastError ?? Spoken.moonlightCouldNotStart)
        }
        rebuild()
    }

    /// Turns the stream for browsers and players on or off.
    @objc func toggleWebStream(_ sender: Any?) {
        if webStream.isRunning {
            WebStreamServer.isEnabled = false
            webStream.stop()
            SpeechSynthesizer.shared.announce(Spoken.browsersCanNoLongerWatch)
        } else {
            WebStreamServer.isEnabled = true
            webStream.start()
            MoonlightScreenCapture.requestPermission()
            SpeechSynthesizer.shared.announce(webStream.isRunning ? Spoken.browsersCanWatch
                                              : webStream.lastError ?? Spoken.browserStreamCouldNotStart)
        }
        rebuild()
    }

    /// Opens the stream's player page in the browser.
    @objc func openWebStream(_ sender: NSMenuItem) {
        MoonlightScreenCapture.requestPermission()
        NSWorkspace.shared.open(webStream.localWatchURL)
    }

    /// Puts the player page's address on the clipboard, for a browser on another device.
    @objc func copyWebStreamAddress(_ sender: NSMenuItem) {
        let address = webStream.watchURL.absoluteString
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        SpeechSynthesizer.shared.announce(Spoken.copied(address))
    }

    /// Ends one Moonlight device's stream; Moonlight shows that the host ended it.
    @objc func endMoonlightStream(_ sender: NSMenuItem) {
        guard let certificate = sender.representedObject as? Data else { return }
        moonlightHost.endLaunch(of: certificate)
        rebuild()
    }

    /// Unpairs a Moonlight device.
    private func forget(_ client: MoonlightClient) {
        moonlightHost.forget(client)
        SpeechSynthesizer.shared.announce(Spoken.forgot(client.name))
        rebuild()
    }

    /// Asks for the PIN Moonlight shows while pairing. The answer is nil when the user
    /// declines, or when the device gave up meanwhile.
    /// Asks for the code a browser shows while pairing; nil when the user declines. The code
    /// lasts five minutes, and so does the prompt.
    private func promptForBrowserCode(name: String, isCurrent: @escaping () -> Bool,
                                      answer: @escaping (String?) -> Void) {
        RunLoop.main.perform(inModes: [.default]) {
            // Queued while a menu was open, it may be out of date by now.
            guard isCurrent() else { return answer(nil) }
            let alert = NSAlert()
            alert.messageText = "Let a browser watch?"
            alert.informativeText = "\(name) wants to watch \(AppIdentity.name)'s streaming displays. " +
                                    "Type the code it shows."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
            field.placeholderString = "Code"
            alert.accessoryView = field
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            SpeechSynthesizer.shared.announce(Spoken.browserWantsToPair)
            NSApp.activate(ignoringOtherApps: true)
            let timeout = DispatchWorkItem { NSApp.abortModal() }
            DispatchQueue.main.asyncAfter(deadline: .now() + WebStreamPairing.lifetime, execute: timeout)
            let response = alert.runModal()
            timeout.cancel()
            answer(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    private func promptForMoonlightPIN(address: String, isCurrent: @escaping () -> Bool,
                                       answer: @escaping (String?) -> Void) {
        // From the run loop rather than the main queue: a modal prompt run inside a main
        // queue block would hold every other one, the network's and the display changes',
        // until it closed.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            // Queued while a menu was open, the device may have given up meanwhile.
            guard let self, isCurrent() else { return answer(nil) }
            let alert = NSAlert()
            alert.messageText = "Pair with Moonlight?"
            alert.informativeText = "Moonlight on \(address) wants to stream from \(AppIdentity.name). " +
                                    "Type the PIN it shows."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
            field.placeholderString = "PIN"
            alert.accessoryView = field
            alert.addButton(withTitle: "Pair")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            SpeechSynthesizer.shared.announce(Spoken.moonlightWantsToPair)
            NSApp.activate(ignoringOtherApps: true)
            self.moonlightPINAlert = alert
            let response = alert.runModal()
            self.moonlightPINAlert = nil
            answer(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
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
        SpeechSynthesizer.shared.announce(device.isConnected
            ? Spoken.disconnecting(device.label) : ConnectTarget.sidecar(device).connectingAnnouncement)
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
                                       announcing: Spoken.deselected(display.label))
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
        applyResolution(sel.mode, cgDisplayID: sel.cgDisplayID)
    }

    @objc func selectRotation(_ sender: NSMenuItem) {
        guard let sel = sender.representedObject as? RotationSelection else { return }
        applyRotation(sel.rotation, for: sel.display)
    }

    /// Turns a display, picked in the menu or the rotation picker.
    private func applyRotation(_ rotation: DisplayRotation, for display: DisplayInfo) {
        videoManager.setRotation(rotation, for: display) { [weak self] done in
            if !done { SpeechSynthesizer.shared.announce(Spoken.couldNotRotate(display.label)) }
            self?.rebuild()
        }
    }

    @objc func selectVirtualResolution(_ sender: NSMenuItem) {
        guard let sel = sender.representedObject as? VirtualResolutionSelection else { return }
        applyVirtualResolution(sel.mode, for: sel.display)
    }

    /// Sets a native mode, picked in the menu or the resolution picker.
    private func applyResolution(_ mode: DisplayMode, cgDisplayID: CGDirectDisplayID) {
        // When a native resolution is chosen and a virtual anchor is active for the
        // display that owns this cgDisplayID, disable the anchor first so the display
        // is freed from mirror mode before we set the native mode.
        let matchingDisplay = (videoManager.airPlayDevices + videoManager.connectedDisplays).first {
            $0.cgDisplayID == cgDisplayID
        }
        if let ap = matchingDisplay, videoManager.hasVirtualAnchor(for: ap.name) {
            videoManager.disableVirtualAnchor(for: ap) { [weak self] in
                self?.videoManager.setMode(mode, for: cgDisplayID) { _ in self?.rebuild() }
            }
        } else {
            videoManager.setMode(mode, for: cgDisplayID) { [weak self] _ in self?.rebuild() }
        }
    }

    /// Sets a virtual mode through the display's anchor, picked in the menu or the
    /// resolution picker.
    private func applyVirtualResolution(_ mode: DisplayMode, for display: DisplayInfo) {
        videoManager.selectVirtualMode(mode, for: display)
        // Rebuild after the anchor has time to activate and the mode to settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.rebuild()
        }
    }
}
