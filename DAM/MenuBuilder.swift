//
//  MenuBuilder.swift
//

import AppKit

/// What the display submenus need besides the display: the managers, and whether
/// displays can mirror one another now.
private struct MenuContext {
    let video: VideoManager
    let moonlight: MoonlightHost
    let webStream: WebStreamServer
    let canMirror: Bool
}

func buildStatusMenu(audio: AudioManager,
                     video: VideoManager,
                     sidecar: SidecarManager,
                     moonlight: MoonlightHost,
                     webStream: WebStreamServer,
                     openDisplay: OpenDisplaySender? = nil,
                     sessions: [RemoteSessionCoordinator.Session] = [],
                     blackedOut: Bool = false,
                     onRefresh: @escaping () -> Void) -> NSMenu {
    let menu = NSMenu()
    let context = MenuContext(video: video, moonlight: moonlight, webStream: webStream, canMirror: canMirror(video: video))

    // — Audio section —
    menu.addItem(sectionHeader("Audio Output"))
    if audio.devices.isEmpty {
        menu.addItem(disabledItem("No output devices found"))
    } else {
        for device in audio.devices {
            let item = NSMenuItem(
                title: device.label,
                action: #selector(AppDelegate.selectAudioDevice(_:)),
                keyEquivalent: ""
            )
            item.representedObject = device
            item.state = device.id == audio.defaultDeviceID ? .on : .off
            menu.addItem(item)
        }
    }

    menu.addItem(.separator())

    // — AirPlay Display section —
    menu.addItem(sectionHeader("AirPlay Display"))
    if video.airPlayDevices.isEmpty {
        menu.addItem(disabledItem("Searching…"))
    } else {
        for display in video.airPlayDevices {
            let item = NSMenuItem(
                title: display.label,
                action: #selector(AppDelegate.selectDisplay(_:)),
                keyEquivalent: ""
            )
            item.representedObject = display
            item.state = display.isConnected ? .on : .off
            item.image = displayIcon(for: display, video: video)
            // A listed display is one found on the network; selecting it is what connects,
            // by driving Control Center's Screen Mirroring, which needs Accessibility access.
            item.toolTip = display.isConnected
                ? "Connected through Screen Mirroring"
                : "Found on the network. Select to connect through Screen Mirroring "
                  + "(needs Accessibility access)"

            if display.isConnected && display.cgDisplayID != 0 {
                item.submenu = displaySubmenu(for: display, context: context, actions: [disconnectItem(for: display)])
            }

            menu.addItem(item)
        }
    }

    // — Sidecar section — only on Macs that support it
    if sidecar.isSupported {
        menu.addItem(.separator())
        menu.addItem(sectionHeader("Sidecar"))
        if sidecar.devices.isEmpty {
            menu.addItem(disabledItem("No iPads nearby"))
        } else {
            for device in sidecar.devices {
                let item = NSMenuItem(
                    title: device.label,
                    action: #selector(AppDelegate.selectSidecarDevice(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = device
                item.state = device.isConnected ? .on : .off
                // The link the iPad is reachable over: a cable or Wi‑Fi.
                let linkIcon = device.link.flatMap { menuIcon($0.symbolName) }
                item.image = linkIcon
                item.toolTip = device.link.map { "Reachable over \($0.rawValue)" }
                    ?? "Seen over Bluetooth only"

                // A connected iPad's display controls live here, as an AirPlay display's do.
                // An item with a submenu cannot be clicked, so the submenu has Disconnect.
                if device.isConnected,
                   let display = video.connectedDisplays.first(where: { $0.isSidecar && $0.name == device.name }) {
                    item.image = displayIcon(for: display, video: video) ?? linkIcon ?? menuIcon("ipad")
                    let disconnect = NSMenuItem(
                        title: "Disconnect",
                        action: #selector(AppDelegate.selectSidecarDevice(_:)),
                        keyEquivalent: ""
                    )
                    disconnect.representedObject = device
                    item.submenu = displaySubmenu(for: display, context: context,
                                                  info: device.link.map { [connectedOverItem($0.rawValue, symbol: $0.symbolName)] } ?? [],
                                                  actions: [disconnect])
                }
                menu.addItem(item)
            }
        }
    }

    // — OpenDisplay section — while DAM sends to receivers: those found, or streaming
    let receivers = openDisplay?.isRunning == true
        ? openDisplay!.receivers.filter { !$0.transports.isEmpty || $0.isConnected } : []
    if openDisplay?.isRunning == true {
        menu.addItem(.separator())
        menu.addItem(sectionHeader("OpenDisplay"))
        if receivers.isEmpty { menu.addItem(disabledItem("No receivers found")) }
        for receiver in receivers { menu.addItem(receiverItem(receiver, context: context)) }
    }

    // — Streaming Displays section — DAM's own, for streaming or remote-desktop apps; those
    // streamed to an OpenDisplay receiver are listed with it above
    menu.addItem(.separator())
    menu.addItem(sectionHeader("Streaming Displays"))
    let receiverDisplays = Set(receivers.compactMap(\.displayID))
    for display in video.connectedDisplays where display.isStreaming && !receiverDisplays.contains(display.cgDisplayID) {
        let item = NSMenuItem(title: display.label, action: nil, keyEquivalent: "")
        item.state = .on
        item.image = displayIcon(for: display, video: video)
        let remove = NSMenuItem(title: "Remove",
                                action: #selector(AppDelegate.removeStreamingDisplay(_:)),
                                keyEquivalent: "")
        remove.representedObject = display
        item.submenu = displaySubmenu(for: display, context: context, actions: [remove] + watchItems(for: display, context: context))
        menu.addItem(item)
    }
    let create = NSMenuItem(title: "Create Streaming Display",
                            action: video.canCreateStreamingDisplay
                                ? #selector(AppDelegate.createStreamingDisplay(_:)) : nil,
                            keyEquivalent: "")
    create.toolTip = video.canCreateStreamingDisplay
        ? "A virtual display for a streaming or remote-desktop app to show, one per stream."
        : "There can be up to \(VideoManager.maxStreamingDisplays) streaming displays."
    menu.addItem(create)
    for session in sessions { menu.addItem(remoteSessionItem(session)) }
    if blackedOut {
        let light = NSMenuItem(title: "Light This Mac's Screens", action: #selector(AppDelegate.liftBlackout(_:)),
                               keyEquivalent: "")
        light.toolTip = "Lights the screens for the sessions on now. Later sessions leave them lit too, "
            + "unless blacking out is locked in Settings › Remote Sessions."
        menu.addItem(light)
    }

    // — Connected Displays section — physical displays; Sidecar iPads and streaming
    // displays are listed above
    menu.addItem(.separator())
    menu.addItem(sectionHeader("Connected Displays"))
    let physicalDisplays = video.connectedDisplays.filter { !$0.isSidecar && !$0.isStreaming }
    if physicalDisplays.isEmpty {
        menu.addItem(disabledItem("None"))
    } else {
        for display in physicalDisplays {
            let item = NSMenuItem(title: display.label, action: nil, keyEquivalent: "")
            item.state = display.isConnected ? .on : .off
            item.image = displayIcon(for: display, video: video)
            item.submenu = displaySubmenu(for: display, context: context)
            menu.addItem(item)
        }
    }

    menu.addItem(.separator())
    if video.currentLayout().displayCount >= 2 {
        let arrange = NSMenuItem(title: "Arrange Displays…",
                                 action: #selector(AppDelegate.openArrangeDisplays(_:)),
                                 keyEquivalent: "")
        arrange.toolTip = "Drag displays to arrange them. Hold a display over others, then " +
                          "release, to mirror it on them. Drag a card off the back of a mirrored stack to " +
                          "extend that display. Drag the square to a different " +
                          "display to make it the main display."
        menu.addItem(arrange)
    }
    menu.addItem(withTitle: "About \(AppIdentity.name)",
                 action: #selector(AppDelegate.openAbout(_:)),
                 keyEquivalent: "")
    menu.addItem(withTitle: "Settings…",
                 action: #selector(AppDelegate.openSettings(_:)),
                 keyEquivalent: ",")
    menu.addItem(withTitle: "Refresh",
                 action: #selector(AppDelegate.refreshAll(_:)),
                 keyEquivalent: "r")
    #if DEBUG
    menu.addItem(debugMenuItem())
    #endif
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit \(AppIdentity.name)",
                 action: #selector(NSApplication.terminate(_:)),
                 keyEquivalent: "q")

    return menu
}

/// A display's submenu: its name with its native aspect ratio, `info` on how it is
/// connected, its actions (`actions` first, then mirroring, the main display, position),
/// the streams of it, then its resolutions and rates.
private func displaySubmenu(for display: DisplayInfo, context: MenuContext, info: [NSMenuItem] = [],
                            actions: [NSMenuItem] = []) -> NSMenu {
    let video = context.video
    let submenu = NSMenu()
    let header = sectionHeader(display.label)
    submenu.addItem(header)
    info.forEach(submenu.addItem)
    var controls = actions
    if display.cgDisplayID != 0 { controls += displayControls(for: display, video: video, canMirror: context.canMirror) }
    if !controls.isEmpty {
        if !info.isEmpty { submenu.addItem(.separator()) }
        controls.forEach(submenu.addItem)
    }
    let streams = streamItems(for: display, context: context)
    if !streams.isEmpty {
        submenu.addItem(.separator())
        submenu.addItem(sectionHeader("Streams"))
        streams.forEach(submenu.addItem)
    }
    submenu.addItem(.separator())
    for item in buildResolutionSubmenu(display: display, video: video).items {
        item.menu?.removeItem(item)
        submenu.addItem(item)
    }
    if let ratio = video.nativeAspectRatio(of: display) { setTrailing(ratio, on: header, in: submenu) }
    return submenu
}

/// "Connected over USB", with the link's symbol.
private func connectedOverItem(_ link: String, symbol: String) -> NSMenuItem {
    let item = disabledItem("Connected over \(link)")
    item.image = menuIcon(symbol)
    return item
}

/// An OpenDisplay receiver: picked, it connects or stops connecting; once streaming, its
/// display's submenu, which ends the stream with Disconnect.
private func receiverItem(_ receiver: OpenDisplaySender.Receiver, context: MenuContext) -> NSMenuItem {
    let item = NSMenuItem(title: receiver.name, action: #selector(AppDelegate.toggleOpenDisplayReceiver(_:)),
                          keyEquivalent: "")
    item.representedObject = receiver.key
    // Turned on and not streaming yet: dialing, or waiting to.
    item.state = receiver.isConnected ? .on : receiver.isOn ? .mixed : .off
    let link = receiver.transport ?? (receiver.transports.contains(.usb) ? .usb : receiver.transports.first)
    item.image = link.flatMap { menuIcon($0.link.symbolName) }
    item.toolTip = receiver.isOn ? "\(receiver.status). Select to stop." : "Select to connect over "
        + receiver.transports.map(\.rawValue).joined(separator: " or ") + "."
    if receiver.isConnected, let id = receiver.displayID,
       let display = context.video.connectedDisplays.first(where: { $0.cgDisplayID == id }) {
        item.image = displayIcon(for: display, video: context.video) ?? item.image
        let disconnect = NSMenuItem(title: "Disconnect", action: #selector(AppDelegate.toggleOpenDisplayReceiver(_:)),
                                    keyEquivalent: "")
        disconnect.representedObject = receiver.key
        let over = receiver.transport.map { [connectedOverItem($0.rawValue, symbol: $0.link.symbolName)] } ?? []
        item.submenu = displaySubmenu(for: display, context: context, info: over, actions: [disconnect])
    }
    return item
}

/// Watching a streaming display in this Mac's browser, or on another device from its
/// address, while the HTTP stream is on.
private func watchItems(for display: DisplayInfo, context: MenuContext) -> [NSMenuItem] {
    guard context.webStream.isRunning,
          let app = context.webStream.apps().first(where: { $0.displayID == display.cgDisplayID }) else { return [] }
    let open = NSMenuItem(title: "Watch in Browser", action: #selector(AppDelegate.openWebStream(_:)), keyEquivalent: "")
    open.representedObject = app.id
    open.toolTip = "Plays this display in this Mac's browser, as any browser on the network can with the address " +
                   "Copy Watch Address gives."
    let copy = NSMenuItem(title: "Copy Watch Address", action: #selector(AppDelegate.copyWebStreamAddress(_:)),
                          keyEquivalent: "")
    copy.representedObject = app.id
    copy.toolTip = "Copies the address of this display's player page. A browser that opens it pairs with a code typed " +
                   "on this Mac. Players need a link of their own, from Settings › Streaming › HTTP Stream."
    return [open, copy]
}

/// Who streams `display`: each Moonlight device, with its settings and a way to end its
/// stream, and each browser or player watching, all with the link they stream over.
private func streamItems(for display: DisplayInfo, context: MenuContext) -> [NSMenuItem] {
    guard display.cgDisplayID != 0 else { return [] }
    var items: [NSMenuItem] = []
    for (client, link) in context.moonlight.streams(on: display.cgDisplayID) {
        let item = NSMenuItem(title: client.label, action: nil, keyEquivalent: "")
        item.attributedTitle = streamTitle(client.label, kind: "Moonlight", link: link)
        item.image = link.flatMap { menuIcon($0.symbolName) }
        let submenu = NSMenu()
        let input = NSMenuItem(title: "Allow Input", action: #selector(AppDelegate.toggleMoonlightInput(_:)),
                               keyEquivalent: "")
        input.representedObject = client.certificate
        input.state = client.allowsInput ? .on : .off
        input.toolTip = "Lets \(client.label) use the Mac's pointer and keyboard on this display. Takes effect at once."
        submenu.addItem(input)
        let lowLatency = NSMenuItem(title: "Low-Latency Encoding",
                                    action: #selector(AppDelegate.toggleMoonlightLowLatency(_:)), keyEquivalent: "")
        lowLatency.representedObject = client.certificate
        lowLatency.state = client.lowLatency ? .on : .off
        lowLatency.toolTip = "Sends each frame the moment it is encoded, about a frame sooner. Takes effect from the next stream."
        submenu.addItem(lowLatency)
        submenu.addItem(.separator())
        let end = NSMenuItem(title: "End Stream", action: #selector(AppDelegate.endMoonlightStream(_:)), keyEquivalent: "")
        end.representedObject = client.certificate
        end.toolTip = "Ends what \(client.label) launched, and removes the display made for it. Other devices go on streaming."
        submenu.addItem(end)
        item.submenu = submenu
        items.append(item)
    }
    for viewer in context.webStream.viewers(on: display.cgDisplayID) {
        let item = NSMenuItem(title: viewer.name, action: nil, keyEquivalent: "")
        item.attributedTitle = streamTitle(viewer.name, kind: "HTTP", link: viewer.link)
        item.image = viewer.link.flatMap { menuIcon($0.symbolName) }
        item.toolTip = "Watching in a browser or player. Forget it in Settings › Streaming › HTTP Stream to cut it off."
        items.append(item)
    }
    return items
}

/// "iPad  Moonlight · USB": the device's name, then what it streams with and over, dimmed.
private func streamTitle(_ name: String, kind: String, link: StreamLink?) -> NSAttributedString {
    let title = NSMutableAttributedString(string: name, attributes: [.font: NSFont.menuFont(ofSize: 0)])
    let detail = [kind, link?.rawValue].compactMap { $0 }.joined(separator: " · ")
    title.append(NSAttributedString(string: "  " + detail, attributes: [
        .font: NSFont.menuFont(ofSize: 0),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]))
    return title
}

#if DEBUG
private func debugMenuItem() -> NSMenuItem {
    let submenu = NSMenu()
    submenu.addItem(withTitle: "Preview Quick-Connect HUD",
                    action: #selector(AppDelegate.debugPreviewQuickConnectHUD(_:)),
                    keyEquivalent: "")
    submenu.addItem(withTitle: "Play Select Animation",
                    action: #selector(AppDelegate.debugPlaySelectAnimation(_:)),
                    keyEquivalent: "")
    submenu.addItem(withTitle: "Play Audio Output Picker",
                    action: #selector(AppDelegate.debugPlayAudioPicker(_:)),
                    keyEquivalent: "")
    submenu.addItem(withTitle: "Play Mirror Picker",
                    action: #selector(AppDelegate.debugPlayMirrorPicker(_:)),
                    keyEquivalent: "")
    submenu.addItem(withTitle: "Play Main Display Picker",
                    action: #selector(AppDelegate.debugPlayMainDisplayPicker(_:)),
                    keyEquivalent: "")
    submenu.addItem(withTitle: "Play Resolution Picker",
                    action: #selector(AppDelegate.debugPlayResolutionPicker(_:)),
                    keyEquivalent: "")
    submenu.addItem(withTitle: "Diagnose Screen Mirroring",
                    action: #selector(AppDelegate.debugDiagnoseScreenMirroring(_:)),
                    keyEquivalent: "")
    submenu.addItem(withTitle: "Preview Connecting HUD",
                    action: #selector(AppDelegate.debugPreviewConnectingHUD(_:)),
                    keyEquivalent: "")
    submenu.addItem(withTitle: "Play Caption Example",
                    action: #selector(AppDelegate.debugPreviewCaptionHUD(_:)),
                    keyEquivalent: "")
    submenu.addItem(withTitle: "Play Menu Bar Icon Animation",
                    action: #selector(AppDelegate.debugPlayMenuBarIcon(_:)),
                    keyEquivalent: "")
    // Unlike the main menu's item, there with a single display too.
    submenu.addItem(withTitle: "Open Arrange Displays",
                    action: #selector(AppDelegate.openArrangeDisplays(_:)),
                    keyEquivalent: "")
    submenu.addItem(withTitle: "Hide HUD Previews",
                    action: #selector(AppDelegate.debugHideHUDPreviews(_:)),
                    keyEquivalent: "")
    let item = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
    item.submenu = submenu
    return item
}
#endif

/// Another app's remote session, and a way to end it and put things back.
private func remoteSessionItem(_ session: RemoteSessionCoordinator.Session) -> NSMenuItem {
    let title = "\(RemoteSessionApp.name(of: session.app)) Session" + (session.client.map { " (\($0))" } ?? "")
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.state = .on
    let submenu = NSMenu()
    if session.count > 1 { submenu.addItem(disabledItem("\(session.count) connections")) }
    let end = NSMenuItem(title: "End and Put Back", action: #selector(AppDelegate.endRemoteSession(_:)), keyEquivalent: "")
    end.representedObject = session.app
    if session.followsApp {
        // Its display and stream are the app's, so it ends with them; ending it here is for
        // when their end goes unseen, as when the app crashes.
        submenu.addItem(disabledItem("Ends when \(RemoteSessionApp.name(of: session.app)) stops"))
        end.toolTip = "Puts the sound output back and lights the screens, as when it ends. " +
                      "The other app's display and stream stay."
    } else {
        end.toolTip = "Removes the session's display and puts the sound output back, as when it ends. " +
                      "The other app's connection stays open."
    }
    submenu.addItem(end)
    submenu.addItem(.separator())
    submenu.addItem(withTitle: "Remote Sessions Settings…", action: #selector(AppDelegate.openSessionSettings(_:)),
                    keyEquivalent: "")
    item.submenu = submenu
    return item
}

private func sectionHeader(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    item.attributedTitle = NSAttributedString(
        string: title,
        attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
    )
    return item
}

/// Sets `trailing` flush right on header `item`'s line, as a display's aspect ratio by its
/// name: a right tab stop where the menu's other titles end, so the header doesn't widen it.
/// Call once the menu is built.
private func setTrailing(_ trailing: String, on item: NSMenuItem, in menu: NSMenu) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]
    let own = (item.title as NSString).size(withAttributes: attributes).width
        + 16 + (trailing as NSString).size(withAttributes: attributes).width
    // A menu is its titles' width and 29 points, and 31 more for submenu arrows when any item
    // has a submenu; an item's title as wide as a tab stop's place (measured on macOS 13).
    let arrows: CGFloat = menu.items.contains(where: \.hasSubmenu) ? 31 : 0
    let style = NSMutableParagraphStyle()
    style.tabStops = [NSTextTab(textAlignment: .right, location: max(ceil(own), floor(menu.size.width - 29 - arrows)))]
    var styled = attributes
    styled[.paragraphStyle] = style
    item.attributedTitle = NSAttributedString(string: item.title + "\t" + trailing, attributes: styled)
    item.setAccessibilityLabel("\(item.title), \(trailing)")
}

private func buildResolutionSubmenu(display: DisplayInfo, video: VideoManager) -> NSMenu {
    let submenu = NSMenu()
    let current = video.currentModes(for: display)

    // A display mirroring an iPad through the iPad's anchor runs at whatever the anchor
    // does; what it reports itself is a scaled mode WindowServer made up.
    if let master = video.anchoredMaster(of: display) {
        submenu.addItem(sectionHeader("Resolution"))
        let size = video.currentModes(for: master).anchor.map { " · \($0.resolutionLabel)" } ?? ""
        submenu.addItem(disabledItem("Follows \(master.label)\(size)"))
        return submenu
    }

    switch video.resolutionChoices(for: display, includeLarger1x: true) {
    case let .sidecar(modes, currentIndex):
        // The anchor's sizes, scaled onto the iPad. Sidecar runs at 60 Hz only.
        submenu.addItem(sectionHeader("Resolution"))
        for (i, mode) in modes.enumerated() {
            submenu.addItem(modeItem(title: mode.resolutionLabel, mode: mode, display: display,
                                     isCurrent: i == currentIndex))
        }
    case let .airPlay(native, virtual, currentIndex):
        // Resolutions in a native and a virtual group, each picked at the current rate where
        // it can be; then the rates at the current resolution, split the same way.
        submenu.addItem(sectionHeader("Resolution"))
        if native.isEmpty {
            submenu.addItem(disabledItem("No modes available"))
        } else {
            for (i, mode) in native.enumerated() {
                submenu.addItem(modeItem(title: mode.resolutionLabel, mode: mode, display: display,
                                         isCurrent: i == currentIndex.native))
            }
        }

        submenu.addItem(sectionHeader("Virtual Resolution"))
        for (i, mode) in virtual.enumerated() {
            submenu.addItem(modeItem(title: mode.resolutionLabel, mode: mode, display: display,
                                     isCurrent: i == currentIndex.virtual))
        }

        addRateSections(to: submenu, rates: video.airPlayRateOptions(for: display),
                        display: display, current: current)
    case let .panel(modes, currentIndex):
        // External or built-in — Resolution picker + Refresh Rate picker for the current
        // resolution. Native rates use native mode settings; non-native rates activate the
        // virtual anchor.
        submenu.addItem(sectionHeader("Resolution"))
        if modes.isEmpty {
            submenu.addItem(disabledItem("No modes available"))
        } else {
            for (i, mode) in modes.enumerated() {
                submenu.addItem(modeItem(title: mode.resolutionLabel, mode: mode, display: display,
                                         isCurrent: i == currentIndex))
            }
        }

        addRateSections(to: submenu, rates: video.refreshRateOptions(for: display)?.modes ?? [],
                        display: display, current: current)
    }
    if let item = rotationItem(for: display, video: video) {
        submenu.addItem(.separator())
        submenu.addItem(item)
    }
    return submenu
}

/// "Rotation" with a submenu of the four ways up, the current one checked; nil when the
/// display can't be turned.
private func rotationItem(for display: DisplayInfo, video: VideoManager) -> NSMenuItem? {
    guard let current = video.rotation(of: display) else { return nil }
    let item = NSMenuItem(title: "Rotation", action: nil, keyEquivalent: "")
    item.image = menuIcon("rotate.right")
    if display.isStreaming {
        item.toolTip = "Turns the display on its side or upside down. Streams of it keep their shape, "
                     + "with the picture turned, for a device held the other way."
    }
    let submenu = NSMenu()
    for rotation in DisplayRotation.allCases {
        let choice = NSMenuItem(title: rotation.label, action: #selector(AppDelegate.selectRotation(_:)),
                                keyEquivalent: "")
        choice.representedObject = RotationSelection(rotation: rotation, display: display)
        choice.state = rotation == current ? .on : .off
        submenu.addItem(choice)
    }
    item.submenu = submenu
    return item
}

/// "Refresh Rate" with the native rates, then "Virtual Refresh Rate" with the virtual ones
/// when there are any — the same split as the resolutions.
private func addRateSections(to submenu: NSMenu, rates: [DisplayMode], display: DisplayInfo,
                             current: (anchor: DisplayMode?, native: DisplayMode?)) {
    let currentIdx = VideoManager.currentModeIndex(
        in: rates, anchorCurrent: current.anchor, nativeCurrent: current.native)
    let indexed = Array(rates.enumerated())
    let native = indexed.filter { !$0.element.isVirtual }
    let virtual = indexed.filter { $0.element.isVirtual }

    submenu.addItem(sectionHeader("Refresh Rate"))
    if rates.isEmpty {
        submenu.addItem(disabledItem("No rates available"))
    } else if native.isEmpty {
        submenu.addItem(disabledItem("None"))
    }
    for (i, mode) in native {
        submenu.addItem(modeItem(title: mode.rateLabel, mode: mode, display: display, isCurrent: i == currentIdx))
    }
    guard !virtual.isEmpty else { return }
    submenu.addItem(sectionHeader("Virtual Refresh Rate"))
    for (i, mode) in virtual {
        submenu.addItem(modeItem(title: mode.rateLabel, mode: mode, display: display, isCurrent: i == currentIdx))
    }
}

/// A selectable mode row: native modes go through `selectResolution`, virtual modes
/// through `selectVirtualResolution` (which activates the anchor).
private func modeItem(title: String, mode: DisplayMode, display: DisplayInfo, isCurrent: Bool) -> NSMenuItem {
    let item = NSMenuItem(
        title: title,
        action: mode.isVirtual
            ? #selector(AppDelegate.selectVirtualResolution(_:))
            : #selector(AppDelegate.selectResolution(_:)),
        keyEquivalent: ""
    )
    item.representedObject = mode.isVirtual
        ? VirtualResolutionSelection(mode: mode, display: display) as Any
        : ResolutionSelection(mode: mode, cgDisplayID: display.cgDisplayID)
    item.state = isCurrent ? .on : .off
    return item
}

/// The symbol of a display's state, for its menu item and its Touch Bar button: sparkles
/// while a virtual anchor drives the display, the mirror symbol while it is in a mirror set
/// as slave or master; nil otherwise.
func displayStateSymbol(for display: DisplayInfo, video: VideoManager) -> String? {
    if video.hasVirtualAnchor(for: display.name) { return "sparkles" }
    if video.isInMirrorSet(display) { return "square.on.square" }
    return nil
}

private func displayIcon(for display: DisplayInfo, video: VideoManager) -> NSImage? {
    displayStateSymbol(for: display, video: video).flatMap { menuIcon($0) }
}

/// The mirror, optimize, main-display and position items for a connected display.
private func displayControls(for display: DisplayInfo, video: VideoManager, canMirror: Bool) -> [NSMenuItem] {
    var items: [NSMenuItem] = []
    if canMirror {
        items += mirrorItems(for: display, video: video)
        if let item = optimizeItem(for: display, video: video) { items.append(item) }
    }
    if let item = mainDisplayItem(for: display, video: video) { items.append(item) }
    if let item = positionItem(for: display, video: video) { items.append(item) }
    return items
}

private func canMirror(video: VideoManager) -> Bool {
    let active = (video.allAirPlayDevices + video.allConnectedDisplays)
        .filter { $0.cgDisplayID != 0 }
    return active.count >= 2
}

private func disconnectItem(for display: DisplayInfo) -> NSMenuItem {
    let item = NSMenuItem(
        title: "Disconnect",
        action: #selector(AppDelegate.disconnectAirPlayDevice(_:)),
        keyEquivalent: ""
    )
    item.representedObject = display
    return item
}

/// "Optimize for This Display", checked when `display` is the optimized (master) one of its
/// mirror set; picking it makes the set run at this display's resolution without leaving
/// mirror mode. Nil when the display is not in a set.
private func optimizeItem(for display: DisplayInfo, video: VideoManager) -> NSMenuItem? {
    let members = video.mirrorSetMembers(of: display)
    guard members.count >= 2 else { return nil }
    let isOptimized = members.first?.cgDisplayID == display.cgDisplayID
    let item = NSMenuItem(title: "Optimize for This Display",
                          action: isOptimized ? nil : #selector(AppDelegate.optimizeForDisplay(_:)),
                          keyEquivalent: "")
    item.representedObject = display
    item.state = isOptimized ? .on : .off
    return item
}

/// The mirror items of a display's submenu. With one other display, a single toggle. With
/// several, a display that mirrors another keeps the toggle (it can only be freed), while
/// any other gets a "Mirror on" submenu listing the displays that can mirror it, the ones
/// doing so checked, plus "All Displays", and "Use as Separate Display" when it has slaves.
private func mirrorItems(for display: DisplayInfo, video: VideoManager) -> [NSMenuItem] {
    let targets = video.mirrorTargets(for: display)
    let inSet   = video.isInMirrorSet(display)
    if targets.count < 2 || display.isMirroring {
        return [mirrorToggleItem(for: display, isMirroring: inSet)]
    }
    var items = inSet ? [mirrorToggleItem(for: display, isMirroring: true)] : []

    let slaves   = Set(video.slaveDisplays(of: display).map(\.id))
    let mirrorOn = NSMenu()
    for target in targets {
        let item = NSMenuItem(title: target.label,
                              action: #selector(AppDelegate.mirrorOnDisplay(_:)),
                              keyEquivalent: "")
        item.representedObject = MirrorSelection(display: display, target: target)
        item.state = slaves.contains(target.id) ? .on : .off
        mirrorOn.addItem(item)
    }
    mirrorOn.addItem(.separator())
    let all = NSMenuItem(title: "All Displays",
                         action: #selector(AppDelegate.mirrorOnDisplay(_:)),
                         keyEquivalent: "")
    all.representedObject = MirrorSelection(display: display, target: nil)
    all.state = slaves.count == targets.count ? .on : .off
    mirrorOn.addItem(all)

    let parent = NSMenuItem(title: "Mirror on", action: nil, keyEquivalent: "")
    parent.submenu = mirrorOn
    items.append(parent)
    return items
}

/// "Use as Main Display", checked while the display is the main one; nil when it cannot be
/// (it mirrors another display, or nothing else shows its own desktop).
private func mainDisplayItem(for display: DisplayInfo, video: VideoManager) -> NSMenuItem? {
    guard video.canBeMain(display) else { return nil }
    let item = NSMenuItem(title: "Use as Main Display",
                          action: #selector(AppDelegate.useAsMainDisplay(_:)),
                          keyEquivalent: "")
    item.representedObject = display
    item.state = display.isMain ? .on : .off
    return item
}

/// "Position", listing for each other desktop the four sides of it the display can be put
/// on, with where it sits now checked; nil when there is no other desktop. A display in a
/// mirror set is positioned with its set.
private func positionItem(for display: DisplayInfo, video: VideoManager) -> NSMenuItem? {
    let layout = video.currentLayout()
    guard let id = video.placementID(for: display) else { return nil }
    let others = layout.placements.filter { $0.id != id }
    guard !others.isEmpty else { return nil }
    let submenu = NSMenu()
    for (i, other) in others.enumerated() {
        if i > 0 { submenu.addItem(.separator()) }
        let current = layout.side(of: id, relativeTo: other.id)
        for side in PlacementSide.allCases {
            let item = NSMenuItem(title: "\(side.label) \(other.name)",
                                  action: #selector(AppDelegate.positionDisplay(_:)),
                                  keyEquivalent: "")
            item.representedObject = PositionSelection(id: id, other: other.id, side: side)
            item.state = current == side ? .on : .off
            submenu.addItem(item)
        }
    }
    let parent = NSMenuItem(title: "Position", action: nil, keyEquivalent: "")
    parent.submenu = submenu
    return parent
}

private func mirrorToggleItem(for display: DisplayInfo, isMirroring: Bool) -> NSMenuItem {
    let title = isMirroring ? "Use as Separate Display" : "Mirror Display"
    let item = NSMenuItem(
        title: title,
        action: #selector(AppDelegate.toggleDisplayMirror(_:)),
        keyEquivalent: ""
    )
    item.representedObject = display
    return item
}

/// Returns a template image compositing one or more SF Symbols side by side.
private func menuIcon(_ symbolNames: String...) -> NSImage? {
    let images = symbolNames.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    guard !images.isEmpty else { return nil }
    if images.count == 1 {
        images[0].isTemplate = true
        return images[0]
    }
    let size: CGFloat = 16
    let gap:  CGFloat = 4
    let total = CGFloat(images.count) * size + CGFloat(images.count - 1) * gap
    let composite = NSImage(size: NSSize(width: total, height: size), flipped: false) { _ in
        for (i, img) in images.enumerated() {
            img.draw(in: NSRect(x: CGFloat(i) * (size + gap), y: 0, width: size, height: size))
        }
        return true
    }
    composite.isTemplate = true
    return composite
}

private func disabledItem(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
}
