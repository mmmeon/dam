//
//  SettingsWindowController.swift
//

import AppKit
import CoreImage
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController {

    /// A shortcut recorder per action.
    private let recorders: [HotkeyAction: KeyRecorderView]
    private let audioManager: AudioManager
    private let videoManager: VideoManager
    private let sidecarManager: SidecarManager
    private let moonlightHost: MoonlightHost
    private let sessionCoordinator: RemoteSessionCoordinator?
    private let webStream: WebStreamServer
    private let openDisplay: OpenDisplaySender?

    /// Called when a shortcut is recorded or reset, to store and register it.
    var onSave: ((HotkeyAction, HotkeyPreference) -> Void)?
    /// Whether an action's shortcut is registered, which it isn't while another app has its keys.
    var isRegistered: ((HotkeyAction) -> Bool)?
    /// Called whenever a visibility checkbox is toggled so the menu/Touch Bar rebuild.
    var onRebuild: (() -> Void)?
    /// Turns Moonlight hosting on or off, as the menu does.
    var onToggleMoonlight: (() -> Void)?
    /// Unpairs a Moonlight device, as the menu did.
    var onForgetMoonlightClient: ((MoonlightClient) -> Void)?
    /// Hands streaming to an external Sunshine, or back to DAM's own host.
    var onUseExternalSunshine: ((Bool) -> Void)?
    /// Called when a remote-session profile changes, so the watching follows it.
    var onSessionProfilesChanged: (() -> Void)?
    /// Whether an app's changed detection waits for its session to end.
    var sessionWaitsToApply: ((String) -> Bool)?
    /// Turns the browser stream on or off, as the menu does.
    var onToggleWebStream: (() -> Void)?

    // Tab content views — built once, reused on every tab switch.
    private lazy var hotkeyContent:  NSView = buildHotkeysTab()
    /// Rebuilt when the audio outputs or the Screen Mirroring item change.
    private lazy var generalContent: NSView = buildGeneralTab()
    private var generalShown = GeneralState()
    /// Rebuilt when the devices listed change.
    private lazy var devicesContent: NSView = buildDevicesTab()
    private var devicesShown = DevicesState()
    private lazy var virtualContent: NSView = buildVirtualTab()
    /// Rebuilt when hosting starts or stops or the paired devices change.
    private lazy var moonlightContent: NSView = buildMoonlightTab()
    private lazy var sessionsContent: NSView = buildSessionsTab()
    /// What the Moonlight tab was built from, to tell when it is out of date.
    private var moonlightShown = MoonlightState(host: nil)
    /// Rebuilt when the browser stream starts or stops.
    private lazy var browserContent: NSView = buildBrowserTab()
    private var browserShown = BrowserState(server: nil)
    /// Rebuilt when the receivers found or their sessions change.
    private lazy var openDisplayContent: NSView = buildOpenDisplayTab()
    private var openDisplayShown: [OpenDisplaySender.Receiver] = []
    private var openDisplayRunning = false
    /// The Streaming tab, holding the Moonlight, Browser Stream and Remote Sessions pages.
    private lazy var streamingContent = StreamingTabView(titles: TabID.streamingPages.map(Self.title)) {
        [weak self] index in self?.selectTab(TabID.streamingPages[index])
    }
    /// The page or tab shown; a Streaming page stands for the Streaming tab.
    private var selectedTab = TabID.general
    /// The app whose page the Remote Sessions page shows, or nil for the list of apps.
    private var sessionsApp: String?
    /// What the Remote Sessions page was built showing of each app, to tell when it is out of date.
    private var sessionsShown: [String: String] = [:]
    /// The app's row atop its page, to show its status as it changes.
    private weak var sessionSummary: ListRowView?
    /// The Streaming page last shown, which the Streaming tab opens on.
    private var streamingPage = TabID.moonlight

    // MARK: - Toolbar identifiers

    private enum TabID {
        static let hotkeys = NSToolbarItem.Identifier("\(AppIdentity.shortID).settings.hotkeys")
        static let general = NSToolbarItem.Identifier("\(AppIdentity.shortID).settings.general")
        static let devices = NSToolbarItem.Identifier("\(AppIdentity.shortID).settings.devices")
        static let virtual = NSToolbarItem.Identifier("\(AppIdentity.shortID).settings.virtual")
        static let moonlight = NSToolbarItem.Identifier("\(AppIdentity.shortID).settings.moonlight")
        static let sessions = NSToolbarItem.Identifier("\(AppIdentity.shortID).settings.sessions")
        static let browser = NSToolbarItem.Identifier("\(AppIdentity.shortID).settings.browser")
        static let opendisplay = NSToolbarItem.Identifier("\(AppIdentity.shortID).settings.opendisplay")
        static let streaming = NSToolbarItem.Identifier("\(AppIdentity.shortID).settings.streaming")
        /// The toolbar's tabs.
        static let all: [NSToolbarItem.Identifier] = [general, hotkeys, devices, virtual, streaming]
        /// The Streaming tab's pages, in the order its bar shows them.
        static let streamingPages: [NSToolbarItem.Identifier] = [moonlight, browser, opendisplay, sessions]
    }

    // MARK: - Init

    init(audioManager: AudioManager,
         videoManager: VideoManager,
         sidecarManager: SidecarManager,
         moonlightHost: MoonlightHost,
         webStream: WebStreamServer,
         openDisplay: OpenDisplaySender? = nil,
         sessionCoordinator: RemoteSessionCoordinator? = nil) {
        recorders = Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.map {
            ($0, KeyRecorderView(preference: $0.shortcut))
        })
        self.audioManager     = audioManager
        self.videoManager     = videoManager
        self.sidecarManager   = sidecarManager
        self.moonlightHost    = moonlightHost
        self.sessionCoordinator = sessionCoordinator
        self.webStream        = webStream
        self.openDisplay      = openDisplay

        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
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

        fixWidth()
        selectTab(TabID.general)
    }

    // MARK: - Tab switching

    private static func title(_ id: NSToolbarItem.Identifier) -> String {
        switch id {
        case TabID.general:   return "General"
        case TabID.devices:   return "Devices"
        case TabID.virtual:   return "Virtual Display"
        case TabID.moonlight: return "Moonlight"
        case TabID.sessions:  return "Remote Sessions"
        case TabID.browser:   return "Browser Stream"
        case TabID.opendisplay: return "OpenDisplay"
        case TabID.streaming: return "Streaming"
        default:              return "Hotkeys"
        }
    }

    /// Shows a tab, or a Streaming page within the Streaming tab.
    private func selectTab(_ id: NSToolbarItem.Identifier) {
        let id = id == TabID.streaming ? streamingPage : id
        let page: NSView
        switch id {
        case TabID.general:   page = generalContent
        case TabID.devices:   page = devicesContent
        case TabID.virtual:   page = virtualContent
        case TabID.moonlight: page = moonlightContent
        case TabID.sessions:  page = sessionsContent
        case TabID.browser:   page = browserContent
        case TabID.opendisplay: page = openDisplayContent
        default:              page = hotkeyContent
        }
        var tab = id, content = page, above: CGFloat = 0
        if let index = TabID.streamingPages.firstIndex(of: id) {
            streamingContent.show(page, at: index)
            streamingPage = id
            tab     = TabID.streaming
            content = streamingContent
            above   = streamingContent.barHeight
        }
        selectedTab = id
        if window?.contentView !== content { window?.contentView = content }
        window?.toolbar?.selectedItemIdentifier = tab
        window?.title                           = Self.title(tab)
        fitHeight(to: page, above: above)
    }

    /// Wide enough for the toolbar's items and the Streaming tab's bar.
    private static let minContentWidth: CGFloat = 520

    /// The window's content width, the same on every tab.
    private var contentWidth = minContentWidth

    /// Sets the width once, to fit the widest tab, so switching tabs never changes it.
    private func fixWidth() {
        var pages = [generalContent, hotkeyContent, devicesContent, virtualContent, moonlightContent,
                     sessionsContent, browserContent]
        // An app's page, which the Remote Sessions page opens to.
        if let coordinator = sessionCoordinator { pages.append(buildSessionApp("rustdesk", coordinator: coordinator)) }
        // A stack is as wide as its window; what is in it has its own width.
        let widths = pages.compactMap { ($0 as? NSScrollView)?.documentView as? NSStackView }.map { stack in
            stack.layoutSubtreeIfNeeded()
            return (stack.arrangedSubviews.map(\.fittingSize.width).max() ?? 0) + stack.edgeInsets.left + stack.edgeInsets.right
        }
        contentWidth = max(Self.minContentWidth, widths.max() ?? 0)
    }

    /// Makes the window as tall as the tab's content, and `above` it, keeping its top where
    /// it is. A tab taller than the screen stops at the screen's height and scrolls.
    private func fitHeight(to content: NSView, above: CGFloat = 0) {
        guard let win = window, let stack = (content as? NSScrollView)?.documentView else { return }
        stack.layoutSubtreeIfNeeded()
        var height = stack.fittingSize.height + above
        if let screen = win.screen ?? NSScreen.main {
            let chrome = win.frame.height - win.contentLayoutRect.height
            height = min(height, screen.visibleFrame.height - chrome - 40)
        }
        var frame = win.frameRect(forContentRect: NSRect(x: 0, y: 0, width: contentWidth, height: height))
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
        for (action, recorder) in recorders {
            recorder.onChanged = { [weak self] pref in self?.save(pref, for: action) }
        }

        markClashes()

        return formTab(HotkeyAction.allCases.map { ("\($0.title):", [hotkeyRow($0)]) }, centered: true)
    }

    private func buildGeneralTab() -> NSView {
        generalShown = generalState()
        let extraShown = ScreenMirroringPanel.isExtraVisible
        let extraStatus = NSTextField(labelWithString:
            extraShown ? "Menu bar item shown" : "Menu bar item hidden")
        extraStatus.font = .systemFont(ofSize: NSFont.systemFontSize)
        let openCC = small(NSButton(title: "Control Center…", target: self,
                                    action: #selector(openControlCenterSettings)))
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
                speechOutputRow(),
            ]),
            ("Pickers:", [
                checkbox(title: "Open on the current choice",
                         isOn: VisibilityPreferences.pickerStartsOnCurrent,
                         help: "The audio, mirror, main display, resolution and rotation pickers " +
                               "open on what is current. Unchecked, they open on the next choice, so a single " +
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
                checkbox(title: "Switch to a display's audio when it is connected",
                         isOn: VisibilityPreferences.followNewDisplayAudio,
                         help: "macOS switches the sound output to a newly connected HDMI or " +
                               "DisplayPort display. Unchecked, the previous output is restored.",
                         action: { VisibilityPreferences.followNewDisplayAudio = $0 }),
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
        devicesShown = devicesState()
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
        // The nickname fields line up, across the groups too: each name takes the longest's width.
        let names = (sidecar + airPlay + displays).compactMap { ($0 as? NSStackView)?.arrangedSubviews.first }
        let nameWidth = names.map(\.fittingSize.width).max() ?? 0
        for name in names { name.widthAnchor.constraint(equalToConstant: nameWidth).isActive = true }
        return formTab([
            ("Audio Output:",       audio.isEmpty    ? [placeholderLabel("No output devices found")] : audio),
            ("AirPlay Displays:",   airPlay.isEmpty  ? [placeholderLabel("None discovered yet")] : airPlay),
            ("Sidecar:",            sidecar.isEmpty  ? [placeholderLabel("No Sidecar devices found")] : sidecar),
            ("Connected Displays:", displays.isEmpty ? [placeholderLabel("No external displays")] : displays),
        ])
    }

    /// What the General tab shows that changes outside it: the outputs to speak through, by
    /// label, and whether the Screen Mirroring item is shown.
    private func generalState() -> GeneralState {
        GeneralState(outputs: audioManager.allOutputDevices.map { "\($0.id) \($0.label)" },
                     extraShown: ScreenMirroringPanel.isExtraVisible)
    }

    /// The devices the Devices tab lists. Their checkboxes and nicknames change only there.
    private func devicesState() -> DevicesState {
        DevicesState(audio: audioManager.allOutputDevices.map(\.name),
                     airPlay: videoManager.allAirPlayDevices.map(\.name),
                     sidecar: sidecarManager.devices.map(\.name),
                     displays: videoManager.allConnectedDisplays.filter { !$0.isSidecar }.map(\.name))
    }

    /// Rebuilds the General and Devices tabs if what they list has changed, as when a device
    /// comes or goes.
    func devicesDidChange() {
        if generalState() != generalShown {
            generalContent = buildGeneralTab()
            if selectedTab == TabID.general { selectTab(TabID.general) }
        }
        if devicesState() != devicesShown {
            devicesContent = buildDevicesTab()
            if selectedTab == TabID.devices { selectTab(TabID.devices) }
        }
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
        let airPlayDefault = buildClosurePopup(for: .airPlay)
        airPlayDefault.toolTip = "When an AirPlay display connects, drive it through the virtual " +
                                 "display at this resolution. “Display's own” leaves it as it is."
        let sidecarBacking = checkbox(title: "Back a connected iPad with a virtual display",
                                      isOn: VisibilityPreferences.backsSidecarWithVirtualDisplay,
                                      help: "The iPad mirrors a virtual display in its own shape, " +
                                            "so it can be the Mac's only display and can run at " +
                                            "other resolutions. " +
                                            "Applies on the next Sidecar connection.",
                                      action: { VisibilityPreferences.backsSidecarWithVirtualDisplay = $0 })
        let sidecarAutoConnect = checkbox(title: "Connect a plugged-in iPad when there is no other display",
                                          isOn: VisibilityPreferences.autoConnectsSidecarWithoutDisplay,
                                          help: "When an iPad is plugged in over USB and the Mac has no " +
                                                "display of its own, connect it over Sidecar. Also " +
                                                "applies at login with the iPad already plugged in.",
                                          action: { VisibilityPreferences.autoConnectsSidecarWithoutDisplay = $0 })
        return formTab([
            ("Refresh Rates:", [rates]),
            ("On AirPlay Connect:", [airPlayDefault]),
            ("On Sidecar Connect:", [sidecarBacking, sidecarAutoConnect]),
        ], leftAligned: true)
    }

    /// Hosting, how streams are made, and the devices paired.
    private func buildMoonlightTab() -> NSView {
        let host = moonlightHost
        moonlightShown = MoonlightState(host: host)
        let hostChoice = popup([("\(AppIdentity.name)", "dam"), ("Sunshine", "sunshine")],
                               selected: MoonlightHost.usesExternalSunshine ? "sunshine" : "dam") { [weak self] raw in
            self?.onUseExternalSunshine?(raw == "sunshine")
        }
        hostChoice.toolTip = "Who Moonlight connects to: \(AppIdentity.name)'s own host, or Sunshine " +
                             "running on this Mac, for which \(AppIdentity.name) makes and places the displays."
        guard !MoonlightHost.usesExternalSunshine else {
            return formTab([("Host:", [hostChoice])] + sunshineGroups(), leftAligned: true)
        }
        var hosting: [NSView] = []
        // Hosting may fail to start, leaving nothing changed for the tab to be rebuilt by.
        weak var allowButton: NSButton?
        let allow = checkbox(title: "Allow Moonlight to connect", isOn: host.isRunning,
                             help: "Lets Moonlight on another device find this Mac and pair with it. " +
                                   "Each streaming display is listed in Moonlight as an app.",
                             action: { [weak self, weak host] _ in
                                 self?.onToggleMoonlight?()
                                 allowButton?.state = host?.isRunning == true ? .on : .off
                             })
        allowButton = allow as? NSButton
        hosting.append(allow)
        if let error = host.lastError { hosting.append(placeholderLabel(error)) }
        hosting.append(checkbox(title: "Allow new devices to pair",
                                isOn: MoonlightHost.allowsPairing,
                                help: "Unchecked, a device that isn't paired yet is turned away without " +
                                      "asking for a PIN; paired devices still connect.",
                                action: { MoonlightHost.allowsPairing = $0 }))
        hosting.append(checkbox(title: "Show this Mac to Moonlight on the network",
                                isOn: MoonlightHost.isAdvertised,
                                help: "Unchecked, Moonlight doesn't list this Mac by itself; add it in " +
                                      "Moonlight by its address. Streams carry on either way.",
                                action: { [weak host] in
                                    MoonlightHost.isAdvertised = $0
                                    host?.updateAdvertising()
                                }))

        let streams = [
            checkbox(title: "Adapt the bitrate to the network",
                     isOn: MoonlightStream.adaptsBitrate,
                     help: "Lowers the bitrate when Moonlight loses packets, and raises it back to " +
                           "Moonlight's own when they stop. Unchecked, streams keep Moonlight's " +
                           "bitrate throughout. Takes effect from the next stream.",
                     action: { MoonlightStream.adaptsBitrate = $0 }),
            checkbox(title: "Speed up the mouse as this Mac does",
                     isOn: MoonlightInputInjector.acceleratesPointer,
                     help: "Moves from a mouse Moonlight has captured go faster the faster the mouse " +
                           "moves, at the tracking speed set for mice in System Settings, as if the " +
                           "mouse were plugged into this Mac. Unchecked, each step the mouse reports " +
                           "moves the pointer a point. Takes effect at once.",
                     action: { MoonlightInputInjector.acceleratesPointer = $0 }),
            checkbox(title: "Show the pointer",
                     isOn: MoonlightStream.showsPointer,
                     help: "Draws the Mac's pointer into Moonlight streams. Takes effect from the " +
                           "next stream.",
                     action: { MoonlightStream.showsPointer = $0 }),
            hevcCheckbox(),
        ]

        let encryption = popup(choosing: MoonlightStream.videoEncryption, title: \.title, tip: \.summary) {
            MoonlightStream.videoEncryption = $0
        }
        encryption.toolTip = "When Moonlight's video is encrypted; the controls and sound always are. " +
                             "Moonlight on a Mac, PC, iPhone or iPad takes it whenever it is offered. " +
                             "Takes effect from the next launch."

        let devices: [[NSView]] = host.clients.map { client in
            let lowLatency = checkbox(title: "Low-latency encoding", isOn: client.lowLatency,
                                      help: "Sends each frame the moment it is encoded, about a frame " +
                                            "sooner. Takes effect from the next stream.",
                                      action: { [weak host] in host?.setLowLatency($0, for: client) })
            let input = checkbox(title: "Allow input", isOn: client.allowsInput,
                                 help: "Lets the device use the Mac's pointer and keyboard on the display it " +
                                       "streams. \(AppIdentity.name) also needs Accessibility access for it. " +
                                       "Takes effect at once.",
                                 action: { [weak host] allows in
                                     host?.setAllowsInput(allows, for: client)
                                     if allows { _ = VideoManager.hasAccessibilityAccess(prompting: true) }
                                 })
            let forget = small(ClosureButton(title: "Forget") { [weak self] _ in self?.onForgetMoonlightClient?(client) })
            forget.toolTip     = "Unpairs \(client.name): it has to pair again to connect."
            let name = rowLabel(client.name)
            name.toolTip = "Paired \(client.paired.formatted(date: .abbreviated, time: .shortened))"
            return [name, lowLatency, input, forget]
        }
        let deviceGrid = rowGrid(devices)

        return formTab([
            ("Host:", [hostChoice]),
            ("Hosting:", hosting),
            ("Streams:", streams),
            ("Encrypt Video:", [encryption]),
            ("Paired Devices:", [devices.isEmpty ? placeholderLabel("None yet") : deviceGrid]),
        ], leftAligned: true)
    }

    /// The browser stream: on or off, where from, pairing, the devices that may watch, how
    /// streams are made, and its HTTPS certificate.
    private func buildBrowserTab() -> NSView {
        let server = webStream
        browserShown = BrowserState(server: server)
        var serving: [NSView] = []
        weak var allowButton: NSButton?
        let allow = checkbox(title: "Allow browsers to watch", isOn: server.isRunning,
                             help: "Lets a paired browser, or a player with a link, play a streaming display: " +
                                   "HTTP on port \(server.port.rawValue), HTTPS on \(server.securePort.rawValue). " +
                                   "Apart from Moonlight.",
                             action: { [weak self, weak server] _ in
                                 self?.onToggleWebStream?()
                                 allowButton?.state = server?.isRunning == true ? .on : .off
                             })
        allowButton = allow as? NSButton
        serving.append(allow)
        if let error = server.lastError { serving.append(placeholderLabel(error)) }

        let reach = popup(choosing: WebStreamReach.current, title: \.title, tip: \.summary) {
            WebStreamReach.current = $0
        }
        reach.toolTip = "Where browsers and players may watch from, paired or not."

        let allowPairing = checkbox(title: "Allow new browsers to pair", isOn: WebStreamServer.allowsPairing,
                                    help: "A browser that opens the address shows a code; typed on this Mac, it lets " +
                                          "that browser watch from then on. Unchecked, only paired browsers and links work.",
                                    action: { WebStreamServer.allowsPairing = $0 })
        let qr = ClosureButton(title: "Pair with a QR Code…") { [weak self] _ in self?.showPairingQRCode() }
        qr.bezelStyle = .rounded
        qr.toolTip = "Shows a QR code a phone or tablet scans to pair, with nothing to type. It works once, for five minutes."

        let devices: [[NSView]] = server.devices.all.map { device in
            let name = rowLabel(device.name)
            name.toolTip = "\(device.kind == .link ? "Link" : "Paired") \(device.added.formatted(date: .abbreviated, time: .shortened))"
            let kind = placeholderLabel(device.kind == .link ? "Link" : "Browser")
            var row: [NSView] = [name, kind]
            if device.kind == .link {
                let copy = ClosureButton(title: "Copy Link") { [weak server] _ in
                    guard let server else { return }
                    let link = server.links(for: device).stream.absoluteString
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                    SpeechSynthesizer.shared.announce(Spoken.copiedLink)
                }
                copy.toolTip = "Copies the stream's address for mpv, IINA or VLC. The same address with watch in " +
                               "place of stream.mp4 opens the player page."
                row.append(small(copy))
            } else {
                row.append(NSView())
            }
            let forget = ClosureButton(title: "Forget") { [weak server] _ in server?.forget(device) }
            forget.toolTip = "\(device.name) can no longer watch; if it is watching, it is cut off."
            row.append(small(forget))
            return row
        }
        let deviceGrid = rowGrid(devices)
        let newLink = ClosureButton(title: "New Player Link…") { [weak self] _ in self?.makePlayerLink() }
        newLink.bezelStyle = .rounded
        newLink.toolTip = "Makes a link for a player such as mpv, IINA or VLC, which can't pair, and copies it."

        let pointer = checkbox(title: "Show the pointer", isOn: WebStreamServer.showsPointer,
                               help: "Draws the Mac's pointer into browser streams. Takes effect from the next stream.",
                               action: { WebStreamServer.showsPointer = $0 })

        let profile = popup(choosing: StreamProfile.preferred, title: \.title, tip: \.summary) { [weak self] in
            StreamProfile.preferred = $0
            self?.onRebuild?()
        }
        profile.toolTip = "The profile a browser or player gets unless its address asks for " +
                          "another. Hover over each for what it trades."

        var https: [NSView] = [placeholderLabel(server.secureWatchURL.absoluteString)]
        if let summary = Self.certificateSummary(server) { https.append(placeholderLabel(summary)) }
        if let certificates = server.certificates {
            let fingerprint = placeholderLabel("SHA-256 " + certificates.fingerprint.prefix(23) + "…")
            fingerprint.toolTip = certificates.fingerprint
            https.append(fingerprint)
        }
        let export = ClosureButton(title: "Export Certificate…") { [weak self] _ in self?.exportCertificate() }
        export.bezelStyle = .rounded
        export.toolTip = "Saves the certificate authority HTTPS is signed with, for mpv's --tls-ca-file or to trust. " +
                         "An iPhone or iPad installs it from \(server.authorityURL.absoluteString)."
        export.isEnabled = server.certificates?.authority != nil
        let importButton = ClosureButton(title: "Import Certificate…") { [weak self] _ in self?.importCertificate() }
        importButton.bezelStyle = .rounded
        importButton.toolTip = "Uses a certificate and its private key, from PEM files or a .p12 file. A certificate " +
                               "authority signs \(AppIdentity.name)'s server certificate in place of its own, so devices " +
                               "that already trust it need nothing more; any other certificate is served as it is."
        https += [export, importButton]
        if server.importedCertificate != nil {
            let own = ClosureButton(title: "Use \(AppIdentity.name)'s Own") { [weak self] _ in
                self?.webStream.useOwnCertificate()
            }
            own.bezelStyle = .rounded
            own.toolTip = "Goes back to \(AppIdentity.name)'s own certificate authority. Devices that trusted it still do."
            https.append(own)
        }

        return formTab([
            ("Serving:", serving),
            ("Reach:", [reach]),
            ("Pairing:", [allowPairing, qr]),
            ("Devices:", [devices.isEmpty ? placeholderLabel("None yet") : deviceGrid, newLink]),
            ("Streams:", [pointer]),
            ("Profile:", [profile]),
            ("HTTPS:", https),
        ], leftAligned: true)
    }

    private func buildOpenDisplayTab() -> NSView {
        guard let sender = openDisplay else { return formTab([]) }
        openDisplayShown = sender.receivers
        openDisplayRunning = sender.isRunning
        let send = checkbox(title: "Send to OpenDisplay receivers", isOn: OpenDisplaySender.isEnabled,
                            help: "Streams a display of its own to each receiver turned on below: the OpenDisplay " +
                                  "app on an iPhone, iPad or Mac, over Wi-Fi or a USB cable. The display is made " +
                                  "at the size the receiver asks for before any video goes out.",
                            action: { [weak self, weak sender] on in
                                OpenDisplaySender.isEnabled = on
                                if on { sender?.start() } else { sender?.stop() }
                                self?.openDisplayDidChange()
                            })
        let rows: [[NSView]] = openDisplayShown.map { receiver in
            let toggle = ClosureButton(title: receiver.name) { [weak sender] on in
                sender?.setOn(on, key: receiver.key)
            }
            toggle.setButtonType(.switch)
            toggle.state = receiver.isOn ? .on : .off
            toggle.toolTip = receiver.key.hasPrefix("usb:") ? "On a cable; its ID comes with its first connection."
                                                            : "Receiver ID \(receiver.key)"
            let via = placeholderLabel(receiver.transports.map(\.rawValue).joined(separator: ", "))
            let status = placeholderLabel(receiver.status)
            // The page's width is set before receivers turn up, so a long status may not fit.
            (status as? NSTextField)?.lineBreakMode = .byTruncatingTail
            status.toolTip = receiver.status
            var row: [NSView] = [toggle, via, status]
            if receiver.transports.isEmpty {
                let forget = ClosureButton(title: "Forget") { [weak sender] _ in sender?.forget(key: receiver.key) }
                forget.toolTip = "Takes \(receiver.name) off the list until it is found again."
                row.append(small(forget))
            } else {
                row.append(NSView())
            }
            return row
        }
        let grid = rowGrid(rows)
        let receivers: NSView = rows.isEmpty
            ? placeholderLabel(sender.isRunning ? "None found. Open OpenDisplay on the device." : "Turn sending on to look for them.")
            : grid
        let bitrate = ClosurePopup(onSelect: { [weak sender] value in
            guard let kbps = value.flatMap(Int.init) else { return }
            sender?.setBitrate(kbps: kbps)
        })
        bitrate.controlSize = .small
        bitrate.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        var choices = OpenDisplaySender.bitrateChoices
        if !choices.contains(OpenDisplaySender.bitrateKbps) { choices = (choices + [OpenDisplaySender.bitrateKbps]).sorted() }
        for kbps in choices {
            let item = NSMenuItem(title: Self.mbitText(kbps), action: nil, keyEquivalent: "")
            item.representedObject = String(kbps)
            bitrate.menu?.addItem(item)
            if kbps == OpenDisplaySender.bitrateKbps { bitrate.select(item) }
        }
        bitrate.toolTip = "The video's bitrate to each receiver. Higher is sharper in motion, and needs " +
                          "more of the Wi-Fi; a cable has room for any of them. Takes effect at once."
        return formTab([
            ("Sending:", [send]),
            ("Bitrate:", [bitrate]),
            ("Receivers:", [receivers,
                            smallNote("A receiver takes the newest sender, so DAM dials only those turned on. " +
                                      "Turning one on takes it from the OpenDisplay Mac app if that is streaming to it.")]),
        ], leftAligned: true)
    }

    /// "20 Mbit/s", or "12.5 Mbit/s" for a rate set outside Settings.
    private static func mbitText(_ kbps: Int) -> String {
        let mbit = Double(kbps) / 1000
        return (mbit == mbit.rounded() ? String(Int(mbit)) : String(format: "%.1f", mbit)) + " Mbit/s"
    }

    /// Rebuilds the OpenDisplay page if what it shows of the receivers has changed.
    func openDisplayDidChange() {
        guard let sender = openDisplay,
              sender.receivers != openDisplayShown || sender.isRunning != openDisplayRunning else { return }
        openDisplayContent = buildOpenDisplayTab()
        if selectedTab == TabID.opendisplay { selectTab(TabID.opendisplay) }
    }

    private func small<Button: NSButton>(_ button: Button) -> Button {
        button.bezelStyle  = .rounded
        button.controlSize = .small
        button.font        = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return button
    }

    /// A grid of rows of controls, lined up on their text, so each row's controls line up
    /// whatever the length of its name.
    private func rowGrid(_ rows: [[NSView]]) -> NSGridView {
        let grid = BaselineRowGridView(views: rows)
        grid.rowSpacing    = 6
        grid.columnSpacing = 8
        grid.rowAlignment  = .firstBaseline
        return grid
    }

    /// Asks for a name, makes a link for a player, and copies its stream address.
    private func makePlayerLink() {
        let alert = NSAlert()
        alert.messageText = "New player link"
        alert.informativeText = "A name for the player or device it is for. The link is copied once made."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "mpv on the living room Mac"
        alert.accessoryView = field
        alert.addButton(withTitle: "Make Link")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        let device = webStream.addLink(named: name.isEmpty ? "Player" : name)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(webStream.links(for: device).stream.absoluteString, forType: .string)
        SpeechSynthesizer.shared.announce(Spoken.copiedLink)
    }

    /// Shows a QR code that pairs whoever scans it, once, for five minutes.
    private func showPairingQRCode() {
        let link = webStream.makeQRLink()
        let alert = NSAlert()
        alert.messageText = "Scan to pair"
        alert.informativeText = "Scan with the camera of the phone or tablet that is to watch. The code works " +
                                "once, for five minutes."
        if let image = Self.qrImage(link.absoluteString, size: 240) {
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
            view.image = image
            alert.accessoryView = view
        }
        alert.addButton(withTitle: "Done")
        alert.runModal()
    }

    static func qrImage(_ text: String, size: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

    /// Saves the certificate authority as PEM.
    private func exportCertificate() {
        guard let pem = webStream.certificates?.authorityPEM else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(AppIdentity.name) Browser Stream.pem"
        panel.allowedContentTypes = [.init(filenameExtension: "pem") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(pem.utf8).write(to: url, options: .atomic)
    }

    /// What HTTPS is signed with, in a line; nil while it has not started with no import.
    static func certificateSummary(_ server: WebStreamServer) -> String? {
        func until(_ date: Date?) -> String {
            date.map { ", until " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
        }
        switch server.certificates?.source {
        case .own:
            return "Signed by \(AppIdentity.name)'s own certificate authority"
        case .importedAuthority(let name, let ends):
            return "Signed by \(name), imported\(until(ends))"
        case .importedServer(let names, let ends):
            return "Imported certificate for \(names.prefix(3).joined(separator: ", "))\(until(ends))"
        case nil:
            guard let imported = server.importedCertificate,
                  let name = WebStreamCertificates.commonName(of: imported.certificates[0]) else { return nil }
            return imported.kind == .authority ? "Signed by \(name), imported" : "Imported certificate for \(name)"
        }
    }

    /// Imports a certificate and its key for HTTPS from files the user picks, asking for the
    /// password of a .p12 file.
    private func importCertificate() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose a certificate and its private key: PEM files (one or two, with any chain), or a .p12 file."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        var password: String?
        if panel.urls.contains(where: { ["p12", "pfx"].contains($0.pathExtension.lowercased()) }) {
            guard let typed = askCertificatePassword(wrong: false) else { return }
            password = typed
        }
        while true {
            do {
                try webStream.useCertificate(try ImportedCertificate.read(files: panel.urls, password: password))
                return
            } catch let error as CertificateImportError where error == .needsPassword || error == .wrongPassword {
                guard let typed = askCertificatePassword(wrong: error == .wrongPassword) else { return }
                password = typed
            } catch {
                let alert = NSAlert()
                alert.messageText = "The certificate wasn't imported"
                alert.informativeText = error.localizedDescription
                alert.runModal()
                return
            }
        }
    }

    private func askCertificatePassword(wrong: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = wrong ? "That password doesn't open the file" : "Password for the .p12 file"
        alert.informativeText = "The password it was exported with."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// Rebuilds the Browser Stream tab if what it shows of the server has changed.
    func browserStreamDidChange() {
        guard BrowserState(server: webStream) != browserShown else { return }
        browserContent = buildBrowserTab()
        if selectedTab == TabID.browser { selectTab(TabID.browser) }
    }

    /// What to set up in Sunshine for it to stream the displays DAM makes.
    private func sunshineGroups() -> [(label: String, controls: [NSView])] {
        let installed = SessionDetectors.isInstalled("sunshine")
        let running = RunningProcesses.isRunning("sunshine")
        let status = placeholderLabel(running ? "Running" : installed ? "Installed, not running" : "Not found on this Mac")
        let command = Bundle.main.executablePath ?? "/Applications/\(AppIdentity.name).app/Contents/MacOS/\(AppIdentity.name)"
        let start = "\(command) session start --app sunshine"
        let end = "\(command) session end --app sunshine"
        let copy = small(ClosureButton(title: "Copy") { _ in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("do: \(start)\nundo: \(end)", forType: .string)
        })
        return [
            ("Sunshine:", [status, smallNote("\(AppIdentity.name)'s own host is off, so Sunshine can use the ports.")]),
            ("Prep Command:", [selectableLabel("Do: \(start)"), selectableLabel("Undo: \(end)"), copy,
                               smallNote("Add these in Sunshine › Configuration › General › Command Preparations. " +
                                         "Each stream then gets a display at the client's size, set up as " +
                                         "Remote Sessions › Sunshine says. The start command prints the " +
                                         "display's ID; set Sunshine's output_name to it.")]),
        ]
    }

    /// What DAM does while each app's session is on.
    /// The Remote Sessions page: the list of apps, or, once one is clicked, that app's page.
    private func buildSessionsTab() -> NSView {
        guard let coordinator = sessionCoordinator else { return formTab([]) }
        if let app = sessionsApp { return buildSessionApp(app, coordinator: coordinator) }
        return buildSessionsList(coordinator: coordinator)
    }

    /// The apps DAM knows, then those added, as in System Settings' Network pane.
    private func sessionApps(_ coordinator: RemoteSessionCoordinator) -> [String] {
        let known = RemoteSessionApp.known.map(\.id)
        // Once each, even if a hand-edited profile marks a known app as added.
        return known + coordinator.addedApps.filter { !known.contains($0) }
    }

    private func buildSessionsList(coordinator: RemoteSessionCoordinator) -> NSView {
        let list = GroupedListView(rows: sessionApps(coordinator).map { app in
            let status = sessionStatus(app, coordinator)
            return ListRowView(icon: sessionIcon(app, coordinator), title: RemoteSessionApp.name(of: app),
                               status: status.text, dot: status.color) { [weak self] in self?.openSessionApp(app) }
        })
        let add = ClosureButton(title: "Add App…") { [weak self] _ in self?.addSessionApp() }
        add.bezelStyle = .rounded
        add.toolTip = "Adds a streaming app DAM doesn't know, told by its log, a process or a display it makes."
        let addRow = NSStackView(views: [NSView(), add])
        addRow.orientation = .horizontal
        let changes = smallNote("What is changed through \(AppIdentity.name) during a session (where its display " +
                                "is, its size, the sound output, the blackout) is kept for the app's next session, " +
                                "and the Mac still goes back as it was when the session ends. A setting picked in an " +
                                "app's page is locked against those changes; click its lock to let it follow them again.")
        return scrollingPage([list, addRow, changes], leftAligned: true, filling: [list, addRow, changes])
    }

    /// What an app's row says of it, and the colour of its dot.
    private func sessionStatus(_ app: String, _ coordinator: RemoteSessionCoordinator) -> (text: String, color: NSColor) {
        let profile = coordinator.profile(for: app)
        if let session = coordinator.sessions[app] {
            let waits = sessionWaitsToApply?(app) == true ? "; changes apply when it ends" : ""
            return ("Session on" + (session.client.map { " with \($0)" } ?? "") + waits, .systemGreen)
        }
        if app == "sunshine" {
            return profile.enabled ? ("Started by Sunshine's prep commands", .systemBlue) : ("Off", .systemGray)
        }
        guard profile.enabled, profile.watch else { return ("Off", .systemGray) }
        if let detection = profile.detection {
            if detection.problem(adoptName: profile.adoptName) != nil { return ("Not set up", .systemOrange) }
            if detection.kind == .log, !FileManager.default.fileExists(atPath: detection.logURL.path) {
                return ("No log file yet", .systemOrange)
            }
        } else if app == "display", profile.adoptName?.isEmpty ?? true {
            return ("Not set up", .systemOrange)
        } else if !SessionDetectors.isInstalled(app) {
            return ("Not installed", .systemGray)
        }
        return ("Watching for sessions", .systemBlue)
    }

    /// The app's own icon when it is on this Mac, else a symbol for it.
    private func sessionIcon(_ app: String, _ coordinator: RemoteSessionCoordinator) -> NSImage? {
        let paths = ["sunshine": "/Applications/Sunshine.app", "rustdesk": "/Applications/RustDesk.app",
                     "parsec": "/Applications/Parsec.app",
                     "screensharing": "/System/Library/CoreServices/Applications/Screen Sharing.app",
                     "teamviewer": "/Applications/TeamViewer.app", "opendisplay": "/Applications/OpenDisplay.app"]
        if let path = paths[app], FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        let symbol: String
        switch coordinator.profile(for: app).detection?.kind {
        case .log?: symbol = "doc.text"
        case .process?: symbol = "gearshape.2"
        case .display?: symbol = "display"
        case nil:
            symbol = ["sunshine": "sun.max", "chromeremotedesktop": "globe", "display": "rectangle.on.rectangle"][app]
                ?? "dot.radiowaves.left.and.right"
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    private func openSessionApp(_ app: String?) {
        sessionsApp = app
        reloadSessions()
    }

    private func addSessionApp() {
        guard let coordinator = sessionCoordinator else { return }
        let alert = NSAlert()
        alert.messageText = "Add an app"
        alert.informativeText = "\(AppIdentity.name) starts a session for it when it sees one start, and puts " +
                                "the Mac back when it ends. Its page then says how to tell."
        let field = NSTextField(frame: NSRect(x: 0, y: 30, width: 240, height: 24))
        field.placeholderString = "Its name, e.g. Jump Desktop"
        let kinds: [(String, SessionDetection.Kind)] = [("By its log file", .log), ("By a process it runs", .process),
                                                        ("By a display it makes", .display)]
        let kind = NSPopUpButton(frame: NSRect(x: -2, y: 0, width: 244, height: 26), pullsDown: false)
        kind.addItems(withTitles: kinds.map(\.0))
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 56))
        accessory.addSubview(field)
        accessory.addSubview(kind)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        let app = coordinator.addApp(named: name.isEmpty ? "New App" : name, kind: kinds[kind.indexOfSelectedItem].1)
        onSessionProfilesChanged?()
        openSessionApp(app)
    }

    private func deleteSessionApp(_ app: String) {
        guard let coordinator = sessionCoordinator else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(RemoteSessionApp.name(of: app))?"
        alert.informativeText = "\(AppIdentity.name) stops watching for its sessions, and ends the one on, if any."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        coordinator.removeApp(app)
        onSessionProfilesChanged?()
        openSessionApp(nil)
    }

    /// One app's page, like a service's in System Settings' Network pane: a way back, the app
    /// and how it is, and its settings.
    private func buildSessionApp(_ app: String, coordinator: RemoteSessionCoordinator) -> NSView {
        let name = RemoteSessionApp.name(of: app)
        let back = ClosureButton(title: "") { [weak self] _ in self?.openSessionApp(nil) }
        back.isBordered = false
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        back.imagePosition = .imageOnly
        back.toolTip = "Back to the apps"
        let title = NSTextField(labelWithString: name)
        title.font = .boldSystemFont(ofSize: 15)
        let header = NSStackView(views: [back, title])
        header.orientation = .horizontal
        header.spacing = 6

        let status = sessionStatus(app, coordinator)
        let row = ListRowView(icon: sessionIcon(app, coordinator), title: name,
                              status: status.text, dot: status.color, onClick: nil)
        sessionSummary = row
        let summary = GroupedListView(rows: [row])
        let form = RoundedBoxView(formGrid(sessionGroups(for: app, coordinator: coordinator)), centered: false)
        var views: [NSView] = [header, summary, form]
        if coordinator.profile(for: app).isAdded {
            let delete = ClosureButton(title: "Delete App…") { [weak self] _ in self?.deleteSessionApp(app) }
            delete.bezelStyle = .rounded
            views.append(delete)
        }
        return scrollingPage(views, leftAligned: true, filling: [summary, form])
    }

    /// An app's settings: how its sessions start, then what DAM does during them.
    private func sessionGroups(for app: String, coordinator: RemoteSessionCoordinator) -> [(label: String, controls: [NSView])] {
        var profile = coordinator.profile(for: app)
        let save: (SessionProfile) -> Void = { [weak self] new in
            profile = new
            coordinator.setProfile(new, for: app)
            self?.onSessionProfilesChanged?()
            // The page stays, for the next field; only its status changes.
            guard let self, self.sessionsApp == app else { return }
            let status = self.sessionStatus(app, coordinator)
            self.sessionSummary?.show(status: status.text, dot: status.color)
            self.sessionsShown = self.sessionStatuses()
        }
        var groups: [(label: String, controls: [NSView])] = []
        let name = RemoteSessionApp.name(of: app)
        if profile.isAdded {
            let field = ClosureTextField(text: profile.name ?? "", placeholder: "Its name") { [weak self] text in
                guard !text.isEmpty, text != profile.name else { return }
                profile.name = text
                save(profile)
                self?.reloadSessions()
            }
            field.widthAnchor.constraint(equalToConstant: 200).isActive = true
            groups.append(("Name:", [field]))
        }
        if app == "display" {
            let watch = checkbox(title: "Watch for a display another app makes", isOn: profile.watch,
                                 help: "For apps that make a display of their own for each session, such as " +
                                       "Jump Desktop, Splashtop or Duet: a session lasts while " +
                                       "a display with this name is online.",
                                 action: { profile.watch = $0; save(profile) })
            let field = ClosureTextField(text: profile.adoptName ?? "", placeholder: "Part of its name, e.g. Jump") {
                profile.adoptName = $0.isEmpty ? nil : $0
                save(profile)
            }
            field.widthAnchor.constraint(equalToConstant: 200).isActive = true
            groups.append(("Sessions:", [watch, field]))
        } else if profile.isAdded || SessionDetectors.watchable.contains(app) {
            let installed = profile.isAdded || SessionDetectors.isInstalled(app)
            groups.append(("Sessions:", [checkbox(title: "Watch for \(name) sessions" + (installed ? "" : " (not installed)"),
                                                  isOn: profile.watch,
                                                  help: "Starts a session when someone connects through \(name), and ends it " +
                                                        "when the last one leaves.",
                                                  action: { profile.watch = $0; save(profile) })]))
        } else {
            groups.append(("Sessions:", [checkbox(title: "Start sessions from Sunshine's prep commands", isOn: profile.enabled,
                                                  help: "Unchecked, the prep commands are turned away and Sunshine streams " +
                                                        "the displays as they are.",
                                                  action: { profile.enabled = $0; save(profile) })]))
        }
        if profile.detection != nil {
            groups += detectionGroups(for: app, profile: { profile }, save: { profile = $0; save($0) })
        }

        var controls: [NSView] = []
        // A setting picked here is locked: a session's changes leave it. Open, it follows them.
        var locks: [SessionProfile.Setting: NSButton] = [:]
        for setting in SessionProfile.Setting.allCases {
            locks[setting] = lockButton(locked: profile.locked.contains(setting)) { locked in
                if locked { profile.locked.insert(setting) } else { profile.locked.remove(setting) }
                save(profile)
            }
        }
        let pick: (SessionProfile.Setting) -> Void = { setting in
            profile.locked.insert(setting)
            locks[setting]?.state = .on
        }

        weak var sizeRef: NSPopUpButton?
        weak var placementRef: NSPopUpButton?
        let displayOptions = app == "display"
            ? [("Its display", SessionProfile.DisplayChoice.adopt.rawValue)]
            : [("Make a display", SessionProfile.DisplayChoice.create.rawValue),
               // Not by the app's name, which would make the pop-up, and the window, as wide as it.
               ("Use the app's display", SessionProfile.DisplayChoice.adopt.rawValue),
               ("Leave the displays", SessionProfile.DisplayChoice.none.rawValue)]
        let display = popup(displayOptions, selected: profile.display.rawValue) { raw in
            profile.display = raw.flatMap(SessionProfile.DisplayChoice.init(rawValue:)) ?? .create
            sizeRef?.isEnabled = profile.display == .create
            placementRef?.isEnabled = profile.display != .none
            save(profile)
        }
        display.toolTip = "Make a display for the session, use the one \(name) makes itself (found by its " +
                          "name), or leave the displays as they are."
        let sizes = [("Client's size", nil as String?)] + StreamingDisplayModes.sizes.map {
            ("\($0.width) × \($0.height)", "\($0.width)x\($0.height)" as String?)
        }
        let size = popup(sizes, selected: profile.width.flatMap { w in profile.height.map { "\(w)x\($0)" } }) { raw in
            let parts = raw?.split(separator: "x").compactMap { Int($0) } ?? []
            profile.width = parts.count == 2 ? parts[0] : nil
            profile.height = parts.count == 2 ? parts[1] : nil
            pick(.size)
            save(profile)
        }
        size.toolTip = app == "sunshine" ? "The client's size comes from Moonlight." :
            "\(name) doesn't say the client's size, so its display is 1920 × 1080 unless set here."
        let placement = popup([("Extended", SessionProfile.Placement.extend.rawValue),
                               ("As main display", SessionProfile.Placement.main.rawValue),
                               ("Mirrored by the others", SessionProfile.Placement.mirror.rawValue)],
                              selected: profile.placement.rawValue) { raw in
            profile.placement = raw.flatMap(SessionProfile.Placement.init(rawValue:)) ?? .extend
            pick(.placement)
            save(profile)
        }
        sizeRef = size
        placementRef = placement
        size.isEnabled = profile.display == .create
        placement.isEnabled = profile.display != .none
        let row = BaselineRowGridView(views: [[display, size, locks[.size]!, placement, locks[.placement]!]])
        row.columnSpacing = 8
        row.rowAlignment  = .firstBaseline
        controls.append(row)

        let outputs = [("Leave the sound output", nil as String?)] + audioManager.allOutputDevices.compactMap { device in
            AudioManager.uid(of: device.id).map { ("Sound to \(device.label)", $0 as String?) }
        }
        var outputOptions = outputs
        if let uid = profile.audioOutputUID, !outputs.contains(where: { $0.1 == uid }) {
            outputOptions.append(("Sound to a device not connected", uid))
        }
        let output = popup(outputOptions, selected: profile.audioOutputUID) { raw in
            profile.audioOutputUID = raw
            pick(.audio)
            save(profile)
        }
        controls.append(lockedRow(output, locks[.audio]!))
        let ownPrivacy = ["rustdesk": "RustDesk's privacy mode", "parsec": "Parsec's privacy mode"][app]
        controls.append(lockedRow(checkbox(title: "Black out this Mac's screens", isOn: profile.blackout,
                                 help: "Turns this Mac's own screens black while the session is on, so whoever is " +
                                       "at the Mac doesn't see it; the session's display and the stream stay as " +
                                       "they are. The menu lights them again." +
                                       (ownPrivacy.map { " Leave it off if \($0) is on: the two would fight." } ?? ""),
                                 action: { profile.blackout = $0; pick(.blackout); save(profile) }), locks[.blackout]!))
        let command = Bundle.main.executablePath ?? AppIdentity.name
        groups.append(("Display:", [controls[0]]))
        groups.append(("Sound:", [controls[1]]))
        groups.append(("Privacy:", [controls[2]]))
        groups.append(("Command Line:", [
            selectableLabel("\(command) session start --app \(app)"),
            smallNote("Starts a session from the app's own scripts; `session end --app \(app)` ends it. " +
                      "Run with `help` for the rest."),
        ]))
        return groups
    }

    /// How an added app's sessions are told: by its log, a process, or a display it makes.
    private func detectionGroups(for app: String, profile: @escaping () -> SessionProfile,
                                 save: @escaping (SessionProfile) -> Void) -> [(label: String, controls: [NSView])] {
        guard var detection = profile().detection else { return [] }
        let problem = NSTextField(wrappingLabelWithString: "")
        problem.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        problem.textColor = .systemOrange
        problem.preferredMaxLayoutWidth = 360
        let tried = NSTextField(wrappingLabelWithString: "")
        tried.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tried.textColor = .secondaryLabelColor
        tried.preferredMaxLayoutWidth = 360
        var line = ""
        let refresh = { [weak problem, weak tried] in
            let message = detection.problem(adoptName: profile().adoptName)
            problem?.stringValue = message ?? ""
            problem?.isHidden = message == nil
            tried?.stringValue = line.isEmpty ? "Says what the patterns make of a line pasted here."
                : Self.describe(line, opened: detection.opened, closed: detection.closed)
        }
        let store = { (edit: (inout SessionDetection) -> Void) in
            edit(&detection)
            var next = profile()
            next.detection = detection
            save(next)
            refresh()
        }

        let kinds: [(String, String?)] = [("Its log file", SessionDetection.Kind.log.rawValue),
                                          ("A process it runs", SessionDetection.Kind.process.rawValue),
                                          ("A display it makes", SessionDetection.Kind.display.rawValue)]
        let kind = popup(kinds, selected: detection.kind.rawValue) { [weak self] raw in
            guard let kind = raw.flatMap(SessionDetection.Kind.init(rawValue:)), kind != detection.kind else { return }
            let wasDisplay = detection.kind == .display
            store { $0.kind = kind }
            // A display it makes is placed, not made; one told otherwise gets a display made
            // again, as when added.
            if kind == .display || wasDisplay {
                var next = profile()
                next.display = kind == .display ? .adopt : SessionProfile().display
                save(next)
            }
            self?.reloadSessions()
        }
        kind.toolTip = "What tells \(AppIdentity.name) a session started and ended."
        var groups: [(label: String, controls: [NSView])] = [("Told By:", [kind])]

        switch detection.kind {
        case .log:
            let path = ClosureTextField(text: detection.logPath, placeholder: "~/Library/Logs/App/app.log") { text in
                store { $0.logPath = text }
            }
            path.widthAnchor.constraint(equalToConstant: 260).isActive = true
            let choose = ClosureButton(title: "Choose…") { [weak self, weak path] _ in
                guard let url = self?.chooseLogFile(current: detection.logURL) else { return }
                let text = (url.path as NSString).abbreviatingWithTildeInPath
                path?.stringValue = text
                store { $0.logPath = text }
            }
            choose.bezelStyle = .rounded
            let fileRow = BaselineRowGridView(views: [[path, choose]])
            fileRow.columnSpacing = 8
            fileRow.rowAlignment = .firstBaseline
            let opened = ClosureTextField(text: detection.opened, placeholder: #"#(?<id>\d+) Connection opened from (?<client>[\d.]+)"#) {
                text in store { $0.opened = text }
            }
            let closed = ClosureTextField(text: detection.closed, placeholder: #"#(?<id>\d+) Connection closed"#) {
                text in store { $0.closed = text }
            }
            for field in [opened, closed] {
                field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                field.widthAnchor.constraint(equalToConstant: 340).isActive = true
            }
            let tryField = ClosureTextField(text: "", placeholder: "Paste a line from the log") { _ in }
            tryField.onChange = { line = $0; refresh() }
            tryField.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            tryField.widthAnchor.constraint(equalToConstant: 340).isActive = true
            groups.append(("Log File:", [fileRow, smallNote("New lines are read as they come; the file can be " +
                                                             "moved aside and started again, as logs are.")]))
            groups.append(("Opened:", [opened]))
            groups.append(("Closed:", [closed, smallNote(
                "Regular expressions, matched anywhere in a line. A line matching Opened starts a connection, one " +
                "matching Closed ends it. Name a group id in both, as (?<id>\\d+), for connections that overlap, " +
                "and one client in Opened to name the display after the client.")]))
            groups.append(("Try a Line:", [tryField, tried]))
        case .process:
            let process = ClosureTextField(text: detection.processName, placeholder: "e.g. screensharingd") { text in
                store { $0.processName = text }
            }
            process.widthAnchor.constraint(equalToConstant: 200).isActive = true
            groups.append(("Process:", [process, smallNote(
                "A session lasts while a process with this name runs, as Activity Monitor shows it; it ends a " +
                "few seconds after the process goes. Names are matched to their first 16 characters.")]))
        case .display:
            let field = ClosureTextField(text: profile().adoptName ?? "", placeholder: "Part of its name, e.g. Jump") { text in
                var next = profile()
                next.adoptName = text.isEmpty ? nil : text
                save(next)
                refresh()
            }
            field.widthAnchor.constraint(equalToConstant: 200).isActive = true
            groups.append(("Display Name:", [field, smallNote(
                "A session lasts while a display whose name has this in it is online, as the app's own display " +
                "for the session.")]))
        }
        groups[groups.count - 1].controls += [problem]
        refresh()
        return groups
    }

    /// What an added app's patterns make of `line`.
    private static func describe(_ line: String, opened: String, closed: String) -> String {
        guard let parse = SessionLogLines.custom(opened: opened, closed: closed) else {
            return "Give both patterns first."
        }
        switch parse(line) {
        case .opened(let key, let client, _)?:
            return "Opens a connection" + (key.isEmpty ? "" : " (\(key))") + (client.map { " from \($0)" } ?? "") + "."
        case .closed(let key)?:
            return "Closes " + (key.isEmpty ? "the connection." : "connection \(key).")
        case nil:
            return "Matches neither pattern."
        }
    }

    private func chooseLogFile(current: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the app's log file."
        panel.directoryURL = FileManager.default.fileExists(atPath: current.deletingLastPathComponent().path)
            ? current.deletingLastPathComponent()
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// A lock beside a session setting: closed while the setting is kept as picked here,
    /// open while it follows the changes made during sessions.
    private func lockButton(locked: Bool, action: @escaping (Bool) -> Void) -> NSButton {
        let button = ClosureButton(title: "", action: action)
        button.setButtonType(.toggle)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: "lock.open", accessibilityDescription: "Follows sessions")
        button.alternateImage = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Kept as picked")
        button.state = locked ? .on : .off
        button.toolTip = "Locked, the setting stays as picked here. Open, it follows what is changed through " +
                         "\(AppIdentity.name) during a session, for the next one."
        return button
    }

    /// `control` with its lock after it, on one line.
    private func lockedRow(_ control: NSView, _ lock: NSView) -> NSView {
        let row = BaselineRowGridView(views: [[control, lock]])
        row.columnSpacing = 4
        row.rowAlignment  = .firstBaseline
        return row
    }

    /// A pop-up of `options` (title, stored value) with `selected` chosen.
    private func popup(_ options: [(String, String?)], selected: String?,
                       onSelect: @escaping (String?) -> Void) -> NSPopUpButton {
        let popup = ClosurePopup(onSelect: onSelect)
        popup.font = .systemFont(ofSize: NSFont.systemFontSize)
        for (title, key) in options {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = key
            popup.menu?.addItem(item)
        }
        popup.selectItem(at: options.firstIndex { $0.1 == selected } ?? 0)
        return popup
    }

    /// A pop-up of every case of an enum stored by its raw value, each item with its title and
    /// tooltip, `current` chosen.
    private func popup<Option>(choosing current: Option, title: KeyPath<Option, String>,
                               tip: KeyPath<Option, String>,
                               onSelect: @escaping (Option) -> Void) -> NSPopUpButton
        where Option: CaseIterable & RawRepresentable, Option.RawValue == String {
        let options = Array(Option.allCases)
        let popup = popup(options.map { ($0[keyPath: title], $0.rawValue) }, selected: current.rawValue) { raw in
            if let option = raw.flatMap(Option.init(rawValue:)) { onSelect(option) }
        }
        for (item, option) in zip(popup.itemArray, options) { item.toolTip = option[keyPath: tip] }
        return popup
    }

    private func selectableLabel(_ text: String) -> NSView {
        let tf = NSTextField(labelWithString: text)
        tf.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        tf.isSelectable = true
        tf.lineBreakMode = .byCharWrapping
        tf.preferredMaxLayoutWidth = 420
        return tf
    }

    private func smallNote(_ text: String) -> NSView {
        let tf = NSTextField(wrappingLabelWithString: text)
        tf.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tf.textColor = .secondaryLabelColor
        tf.preferredMaxLayoutWidth = 420
        return tf
    }

    /// Rebuilds the Moonlight tab if what it shows of the host, or which host, has changed.
    func moonlightDidChange() {
        guard MoonlightState(host: moonlightHost) != moonlightShown else { return }
        moonlightContent = buildMoonlightTab()
        if selectedTab == TabID.moonlight { selectTab(TabID.moonlight) }
    }

    // MARK: - Actions

    /// Stores and registers `action`'s new shortcut.
    private func save(_ pref: HotkeyPreference, for action: HotkeyAction) {
        onSave?(action, pref)
        markClashes()
    }

    /// Puts `action`'s shortcut back to its default.
    private func reset(_ action: HotkeyAction) {
        let pref = action.defaultShortcut
        recorders[action]?.preference = pref
        save(pref, for: action)
    }

    /// Marks each shortcut set to the same keys as another, as only one of them can work, and
    /// each that another app has, which then doesn't work.
    private func markClashes() {
        let actions = HotkeyAction.allCases
        let clashes = HotkeyPreference.clashes(among: actions.compactMap { recorders[$0]?.preference })
        for (action, others) in zip(actions, clashes) {
            recorders[action]?.clash = others.isEmpty ? nil : others.map { actions[$0].title }.joined(separator: ", ")
            recorders[action]?.isTakenElsewhere = others.isEmpty && isRegistered?(action) == false
        }
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

    /// A scrolling tab holding one form (see formGrid).
    private func formTab(_ groups: [(label: String, controls: [NSView])], leftAligned: Bool = false,
                         centered: Bool = false) -> NSView {
        let box = RoundedBoxView(formGrid(groups, centered: centered), centered: !leftAligned)
        return scrollingPage([box], leftAligned: true, filling: [box])
    }

    /// One form: each group is a label and the controls listed under it, one per row; the
    /// label sits on the group's first row. Rows line up on their text's baseline, or,
    /// `centered`, on their middle, for controls with no text of their own to line up (the
    /// hotkey recorders).
    private func formGrid(_ groups: [(label: String, controls: [NSView])], centered: Bool = false) -> NSGridView {
        let grid = NSGridView()
        grid.rowSpacing    = 6
        grid.columnSpacing = 8
        grid.rowAlignment  = centered ? .none : .firstBaseline
        for (g, group) in groups.enumerated() {
            for (i, control) in group.controls.enumerated() {
                let label = i == 0 ? formLabel(group.label) : NSGridCell.emptyContentView
                // The grid stretches a cell's view to the column's width; wrapped, a pop-up, a
                // grid or a field of a set width keeps its own. The rest look the same stretched.
                let keepsWidth = control is NSPopUpButton || control is NSGridView || control is ClosureTextField
                let row = grid.addRow(with: [label, keepsWidth ? NaturalWidthView(control) : control])
                row.cell(at: 1).xPlacement = .leading
                if centered { row.yPlacement = .center }
                if i == 0 && g > 0 { row.topPadding = 10 }
            }
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        // Keep the grid at its natural width; stretched, its trailing-placed label column
        // would push the whole form to the right.
        grid.setContentHuggingPriority(.required, for: .horizontal)
        // The grid has no width of its own to hug; this keeps it to its rows' widths, over
        // the stack's pull to widen it (low) and under the grid's own fitting of its cells.
        let narrowest = grid.widthAnchor.constraint(equalToConstant: 0)
        narrowest.priority = NSLayoutConstraint.Priority(500)
        narrowest.isActive = true

        return grid
    }

    /// A scrolling tab holding `views` one under another; those in `filling` take its width.
    private func scrollingPage(_ views: [NSView], leftAligned: Bool = false, filling: [NSView] = []) -> NSView {
        let scrollView = makeScrollView()
        let stack = SettingsStack()
        stack.orientation = .vertical
        stack.alignment   = leftAligned ? .leading : .centerX
        stack.spacing     = 12
        stack.edgeInsets  = Self.formInsets
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stack
        for view in views { stack.addArrangedSubview(view) }
        for view in filling {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                        constant: -Self.formInsets.left - Self.formInsets.right).isActive = true
        }
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

    /// `action`'s recorder with a button that puts its default back.
    private func hotkeyRow(_ action: HotkeyAction) -> NSView {
        let recorder = recorders[action]!   // there is one for every action
        let resetBtn = small(ClosureButton(title: "Reset") { [weak self] _ in self?.reset(action) })
        let row = NSStackView(views: [recorder, resetBtn])
        row.orientation = .horizontal
        row.spacing     = 8
        row.toolTip     = action.help
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
                weak var box: NSButton?
                let view = checkbox(title: "", isOn: enabled.contains(rate)) { [weak self] isOn in
                    var rates = VisibilityPreferences.virtualRefreshRates(for: entry.context)
                    if isOn { rates.insert(rate) } else { rates.remove(rate) }
                    // The last rate stays: unchecking it leaves it checked.
                    if rates.isEmpty {
                        rates = [rate]
                        box?.state = .on
                    }
                    VisibilityPreferences.setVirtualRefreshRates(rates, for: entry.context)
                    self?.onRebuild?()
                }
                box = view as? NSButton
                row.append(view)
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
    private func buildClosurePopup(for context: VisibilityPreferences.DisplayContext) -> NSView {
        // Options: (title, stored key or nil)
        let options: [(String, String?)] = [
            ("Display's own", nil),
            ("720p",  "1280x720"),
            ("1080p", "1920x1080"),
            ("1440p", "2560x1440"),
            ("4K",    "3840x2160"),
        ]
        return popup(options, selected: VisibilityPreferences.defaultVirtualResolution(for: context)) { [weak self] key in
            VisibilityPreferences.setDefaultVirtualResolution(key, for: context)
            self?.onRebuild?()
        }
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

    /// "Speak through [Sound Output]": the audio device spoken feedback plays on.
    private func speechOutputRow() -> NSView {
        let devices = audioManager.allOutputDevices.compactMap { device in
            AudioManager.uid(of: device.id).map { (uid: $0, device: device) }
        }
        let popup = ClosurePopup(onSelect: { uid in
            let connected = devices.first { $0.uid == uid }?.device.name
            // Picking the disconnected choice again keeps the name it was stored with.
            if connected != nil || uid != VisibilityPreferences.speechOutputUID {
                VisibilityPreferences.speechOutputName = connected
            }
            VisibilityPreferences.speechOutputUID = uid
        })
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        popup.menu?.addItem(NSMenuItem(title: "Sound Output", action: nil, keyEquivalent: ""))
        popup.menu?.addItem(.separator())
        for entry in devices {
            let item = NSMenuItem(title: entry.device.label, action: nil, keyEquivalent: "")
            item.representedObject = entry.uid
            popup.menu?.addItem(item)
        }
        if let stored = VisibilityPreferences.speechOutputUID {
            if let index = devices.firstIndex(where: { $0.uid == stored }) {
                popup.selectItem(at: index + 2)
            } else {
                // Keep a disconnected choice selectable rather than silently dropping it.
                let name = VisibilityPreferences.speechOutputName ?? "Unknown device"
                let item = NSMenuItem(title: "\(name) (not connected)", action: nil, keyEquivalent: "")
                item.representedObject = stored
                popup.menu?.addItem(item)
                popup.select(item)
            }
        }
        let row = NSStackView(views: [smallLabel("Speak through"), popup])
        row.orientation = .horizontal
        row.spacing = 4
        row.toolTip = "The audio device spoken feedback plays on. Sound Output follows the " +
                      "current output; a chosen device that isn't connected falls back to it."
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

    /// Offer HEVC, with what this Mac's encoder makes of it; off where it has none in hardware.
    private func hevcCheckbox() -> NSView {
        let support = VideoCodec.support[.hevc]
        var help = "Moonlight then streams HEVC to devices that decode it in hardware: a sharper picture " +
                   "at the same bitrate. Takes effect from the next launch."
        if support?.hardware != true {
            help += " This Mac has no hardware HEVC encoder."
        } else if support?.lowLatency != true {
            help += " This Mac's HEVC encoder has no low-latency mode and may be slower than its H.264 one."
        }
        let box = checkbox(title: "Offer HEVC", isOn: MoonlightHost.offersHEVC && support?.hardware == true,
                           help: help, action: { MoonlightHost.offersHEVC = $0 })
        (box as? NSButton)?.isEnabled = support?.hardware == true
        return box
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

    /// Builds the Remote Sessions tab again from the profiles, as when a session changed one.
    func reloadSessions() {
        if let app = sessionsApp, let coordinator = sessionCoordinator,
           !sessionApps(coordinator).contains(app) { sessionsApp = nil }
        sessionsShown = sessionStatuses()
        sessionsContent = buildSessionsTab()
        if selectedTab == TabID.sessions { selectTab(TabID.sessions) }
    }

    /// Rebuilds the Remote Sessions page if what it shows of the apps has changed, as when
    /// a session starts or ends.
    func sessionsDidChange() {
        let statuses = sessionStatuses()
        guard statuses != sessionsShown else { return }
        // An app's page stays, so a field being typed in isn't rebuilt from under the user;
        // only its status changes, as when it saves.
        if let app = sessionsApp, let coordinator = sessionCoordinator, let summary = sessionSummary,
           Set(statuses.keys) == Set(sessionsShown.keys) {
            let status = sessionStatus(app, coordinator)
            summary.show(status: status.text, dot: status.color)
            sessionsShown = statuses
        } else {
            reloadSessions()
        }
    }

    private func sessionStatuses() -> [String: String] {
        guard let coordinator = sessionCoordinator else { return [:] }
        return Dictionary(uniqueKeysWithValues: sessionApps(coordinator).map { ($0, sessionStatus($0, coordinator).text) })
    }

    /// Shows the window on the Remote Sessions tab, at its list of apps.
    func showSessions() {
        if sessionsApp != nil { openSessionApp(nil) }
        selectTab(TabID.sessions)
        show()
    }

    /// Shows the window on the Browser Stream tab.
    func showBrowserStream() {
        selectTab(TabID.browser)
        show()
    }

    /// Shows the window on the Moonlight tab.
    func showMoonlight() {
        selectTab(TabID.moonlight)
        show()
    }

    func show() {
        // The Screen Mirroring item may have been changed in Control Center meanwhile.
        devicesDidChange()
        // So may which shortcuts another app has.
        markClashes()
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
        case TabID.streaming:
            item.label = "Streaming"
            item.image = NSImage(systemSymbolName: "dot.radiowaves.left.and.right",
                                 accessibilityDescription: "Streaming")
        default:
            return nil
        }
        return item
    }
}

// MARK: - StreamingTabView

/// The Streaming tab: a bar choosing a service, over that service's page.
private final class StreamingTabView: NSView {
    private let bar: NSSegmentedControl
    private let onSelect: (Int) -> Void
    private var page: NSView?
    private static let barInsets = NSEdgeInsets(top: 12, left: 0, bottom: 4, right: 0)

    /// Calls `onSelect` with the index of the service chosen in the bar.
    init(titles: [String], onSelect: @escaping (Int) -> Void) {
        self.onSelect = onSelect
        bar = NSSegmentedControl(labels: titles, trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: .zero)
        bar.target = self
        bar.action = #selector(barChanged)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: Self.barInsets.top),
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The height the bar takes above a page.
    var barHeight: CGFloat {
        Self.barInsets.top + bar.fittingSize.height + Self.barInsets.bottom
    }

    /// Shows a page below the bar, and selects its service there.
    func show(_ newPage: NSView, at index: Int) {
        bar.selectedSegment = index
        guard newPage !== page else { return }
        page?.removeFromSuperview()
        page = newPage
        newPage.translatesAutoresizingMaskIntoConstraints = false
        addSubview(newPage)
        NSLayoutConstraint.activate([
            newPage.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: Self.barInsets.bottom),
            newPage.leadingAnchor.constraint(equalTo: leadingAnchor),
            newPage.trailingAnchor.constraint(equalTo: trailingAnchor),
            newPage.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func barChanged() { onSelect(bar.selectedSegment) }
}

// MARK: - GroupedListView

/// Rows in a rounded box, divided by lines, as lists are in System Settings.
private final class GroupedListView: NSView {
    init(rows: [NSView]) {
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for (i, row) in rows.enumerated() {
            if i > 0 {
                let line = NSBox()
                line.boxType = .separator
                stack.addArrangedSubview(line)
                // Under the text, past the icon.
                line.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: ListRowView.textInset).isActive = true
                line.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -10).isActive = true
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) { RoundedBoxView.drawBox(in: bounds) }
}

// MARK: - RoundedBoxView

/// A view in a rounded box with a border, as the lists and forms are in System Settings.
private final class RoundedBoxView: NSView {
    private static let insets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

    /// Holds `content` at the box's leading edge, or, `centered`, in its middle.
    init(_ content: NSView, centered: Bool) {
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let i = Self.insets
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: i.top),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -i.bottom),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: i.left),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -i.right),
            centered ? content.centerXAnchor.constraint(equalTo: centerXAnchor)
                     : content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: i.left),
        ])
        // As narrow as what it holds, so the page keeps to its natural width.
        let hug = widthAnchor.constraint(equalTo: content.widthAnchor, constant: i.left + i.right)
        hug.priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue - 2)
        hug.isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) { Self.drawBox(in: bounds) }

    static func drawBox(in bounds: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        // Barely off the window's background, as in System Settings.
        NSColor.labelColor.withAlphaComponent(0.04).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
    }
}

// MARK: - ListRowView

/// A row of a GroupedListView: an icon, a name with a status under it after a coloured dot,
/// and, when it opens something, a chevron; clicking it calls `onClick`.
private final class ListRowView: NSView {
    /// Where the text starts, past the icon.
    static let textInset: CGFloat = 52

    private let onClick: (() -> Void)?
    private var pressed = false { didSet { needsDisplay = true } }
    private let title: String
    private let light: DotView
    private let state: NSTextField

    init(icon: NSImage?, title: String, status: String, dot: NSColor, onClick: (() -> Void)?) {
        self.onClick = onClick
        self.title = title
        light = DotView(color: dot)
        state = NSTextField(labelWithString: status)
        super.init(frame: .zero)
        let image = NSImageView()
        image.image = icon
        image.imageScaling = .scaleProportionallyUpOrDown
        image.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        image.contentTintColor = .secondaryLabelColor
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: NSFont.systemFontSize)
        state.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        state.textColor = .secondaryLabelColor
        state.lineBreakMode = .byTruncatingTail
        state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let statusRow = NSStackView(views: [light, state])
        statusRow.spacing = 4
        let text = NSStackView(views: [name, statusRow])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        for view in [image, text] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 32),
            image.heightAnchor.constraint(equalToConstant: 32),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textInset),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
        if onClick != nil {
            let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
            chevron.contentTintColor = .tertiaryLabelColor
            chevron.translatesAutoresizingMaskIntoConstraints = false
            addSubview(chevron)
            NSLayoutConstraint.activate([
                chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
                text.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            ])
        } else {
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12).isActive = true
        }
        setAccessibilityElement(true)
        setAccessibilityRole(onClick == nil ? .group : .button)
        setAccessibilityLabel("\(title), \(status)")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows another status, as when what it says of has changed.
    func show(status: String, dot: NSColor) {
        state.stringValue = status
        light.color = dot
        setAccessibilityLabel("\(title), \(status)")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard pressed else { return }
        NSColor.quaternaryLabelColor.setFill()
        bounds.fill()
    }

    override func mouseDown(with event: NSEvent) {
        if onClick != nil { pressed = true }
    }

    override func mouseDragged(with event: NSEvent) {
        guard onClick != nil else { return }
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return onClick != nil
    }
}

/// A small filled circle, as by a service's status in System Settings.
private final class DotView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 7).isActive = true
        heightAnchor.constraint(equalToConstant: 7).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

// MARK: - NaturalWidthView

/// Holds a view at its own width, at the leading edge, however wide it is made itself, and
/// reports the view's baselines as its own so a row still lines up on them.
private final class NaturalWidthView: NSView {
    private let content: NSView

    init(_ content: NSView) {
        self.content = content
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        // As narrow as the view, so the form keeps to its natural width; weaker than any
        // view's hugging, so a stretched holder never stretches the view.
        let hug = widthAnchor.constraint(equalTo: content.widthAnchor)
        hug.priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue - 1)
        hug.isActive = true
        // A grid has no width of its own to hug: this keeps it to its cells', over the hug
        // above, which would otherwise stretch it once its holder is stretched.
        if content is NSGridView {
            let narrowest = content.widthAnchor.constraint(equalToConstant: 0)
            narrowest.priority = .defaultLow
            narrowest.isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var firstBaselineOffsetFromTop: CGFloat { content.firstBaselineOffsetFromTop }
    override var lastBaselineOffsetFromBottom: CGFloat { content.lastBaselineOffsetFromBottom }
}

// MARK: - MoonlightState

/// What the Moonlight tab shows of the host and does not change itself.
private struct MoonlightState: Equatable {
    var usesExternalSunshine = false
    var isRunning = false
    var lastError: String?
    var clients: [Data] = []

    init(host: MoonlightHost?) {
        guard let host else { return }
        usesExternalSunshine = MoonlightHost.usesExternalSunshine
        isRunning = host.isRunning
        lastError = host.lastError
        clients = host.clients.map(\.certificate)
    }
}

/// What the General tab shows that changes outside it, to tell when it must be rebuilt.
private struct GeneralState: Equatable {
    var outputs: [String] = []
    var extraShown = false
}

/// The devices the Devices tab lists, to tell when it must be rebuilt.
private struct DevicesState: Equatable {
    var audio: [String] = []
    var airPlay: [String] = []
    var sidecar: [String] = []
    var displays: [String] = []
}

/// What the Browser Stream tab shows of the server, to tell when it must be rebuilt.
private struct BrowserState: Equatable {
    var isRunning = false
    var lastError: String?
    var devices: [WebStreamDevice] = []
    var hasCertificates = false
    var certificate: String?

    init(server: WebStreamServer?) {
        guard let server else { return }
        isRunning = server.isRunning
        lastError = server.lastError
        devices = server.devices.all
        hasCertificates = server.certificates != nil
        certificate = SettingsWindowController.certificateSummary(server)
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

// MARK: - ClosurePopup

/// NSPopUpButton subclass that fires a closure when the selection changes, carrying
/// the `representedObject` of the chosen item as a `String?` (e.g. a resolution key or device UID).
private final class ClosurePopup: NSPopUpButton {
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

// MARK: - ClosureTextField

/// A text field that hands its text to a closure when editing ends.
private final class ClosureTextField: NSTextField, NSTextFieldDelegate {
    private let handler: (String) -> Void

    init(text: String, placeholder: String, onEnd: @escaping (String) -> Void) {
        handler = onEnd
        super.init(frame: .zero)
        stringValue = text
        placeholderString = placeholder
        font = .systemFont(ofSize: NSFont.systemFontSize)
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Called with the text as it is typed.
    var onChange: ((String) -> Void)?

    func controlTextDidEndEditing(_ obj: Notification) {
        handler(stringValue.trimmingCharacters(in: .whitespaces))
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange?(stringValue)
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
