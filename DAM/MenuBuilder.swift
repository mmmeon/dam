//
//  MenuBuilder.swift
//

import AppKit

func buildStatusMenu(audio: AudioManager,
                     video: VideoManager,
                     sidecar: SidecarManager,
                     onRefresh: @escaping () -> Void) -> NSMenu {
    let menu = NSMenu()

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
    let canMirrorDisplays = canMirror(video: video)
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
            let mirrorActive = display.isMirroring || video.isBeingMirrored(display)
            if video.hasVirtualAnchor(for: display.name) {
                item.image = menuIcon("sparkles")
            } else if mirrorActive {
                item.image = menuIcon("square.on.square")
            }

            if display.isConnected && display.cgDisplayID != 0 {
                let submenu = buildResolutionSubmenu(display: display, video: video)
                submenu.addItem(.separator())
                if canMirrorDisplays {
                    addMirrorItems(to: submenu, for: display, video: video)
                    if let item = optimizeItem(for: display, video: video) { submenu.addItem(item) }
                }
                if let item = mainDisplayItem(for: display, video: video) { submenu.addItem(item) }
                if let item = positionItem(for: display, video: video) { submenu.addItem(item) }
                submenu.addItem(disconnectItem(for: display))
                item.submenu = submenu
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
                menu.addItem(item)
            }
        }
    }

    // — Connected Displays section —
    menu.addItem(.separator())
    menu.addItem(sectionHeader("Connected Displays"))
    if video.connectedDisplays.isEmpty {
        menu.addItem(disabledItem("None"))
    } else {
        for display in video.connectedDisplays {
            let item = NSMenuItem(title: display.label, action: nil, keyEquivalent: "")
            item.state = display.isConnected ? .on : .off

            // Mirror icon whether this display is the slave OR the master in a set.
            // Sparkles when a virtual anchor is driving the display (same as AirPlay).
            let mirrorActive = display.isMirroring || video.isBeingMirrored(display)
            if video.hasVirtualAnchor(for: display.name) {
                item.image = menuIcon("sparkles")
            } else if mirrorActive {
                item.image = menuIcon("square.on.square")
            }

            if display.cgDisplayID != 0 {
                let submenu = buildResolutionSubmenu(display: display, video: video)
                if canMirrorDisplays {
                    submenu.addItem(.separator())
                    addMirrorItems(to: submenu, for: display, video: video)
                    if let item = optimizeItem(for: display, video: video) { submenu.addItem(item) }
                }
                if let item = mainDisplayItem(for: display, video: video) { submenu.addItem(item) }
                if let item = positionItem(for: display, video: video) { submenu.addItem(item) }
                item.submenu = submenu
            } else {
                item.submenu = buildResolutionSubmenu(display: display, video: video)
            }
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
    submenu.addItem(withTitle: "Preview Connecting HUD",
                    action: #selector(AppDelegate.debugPreviewConnectingHUD(_:)),
                    keyEquivalent: "")
    submenu.addItem(withTitle: "Play Caption Example",
                    action: #selector(AppDelegate.debugPreviewCaptionHUD(_:)),
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

private func buildResolutionSubmenu(display: DisplayInfo, video: VideoManager) -> NSMenu {
    let submenu = NSMenu()
    let current = video.currentModes(for: display)

    if video.displayContext(for: display) == .airPlay {
        // Resolutions in a native and a virtual group, each picked at the current rate where
        // it can be; then the rates at the current resolution, split the same way.
        let resolutions = video.airPlayResolutionOptions(for: display)
        submenu.addItem(sectionHeader("Resolution"))
        if resolutions.native.isEmpty {
            submenu.addItem(disabledItem("No modes available"))
        } else {
            for (i, mode) in resolutions.native.enumerated() {
                submenu.addItem(modeItem(title: mode.resolutionLabel, mode: mode, display: display,
                                         isCurrent: i == resolutions.current.native))
            }
        }

        submenu.addItem(sectionHeader("Virtual Resolution"))
        for (i, mode) in resolutions.virtual.enumerated() {
            submenu.addItem(modeItem(title: mode.resolutionLabel, mode: mode, display: display,
                                     isCurrent: i == resolutions.current.virtual))
        }

        addRateSections(to: submenu, rates: video.airPlayRateOptions(for: display),
                        display: display, current: current)
    } else {
        // External or built-in — Resolution picker + Refresh Rate picker for the current
        // resolution. Native rates use native mode settings; non-native rates activate the
        // virtual anchor.
        submenu.addItem(sectionHeader("Resolution"))
        let resolutions = video.resolutionOptions(for: display, includeLarger1x: true)
        if resolutions.modes.isEmpty {
            submenu.addItem(disabledItem("No modes available"))
        } else {
            for (i, mode) in resolutions.modes.enumerated() {
                submenu.addItem(modeItem(title: mode.resolutionLabel, mode: mode, display: display,
                                         isCurrent: i == resolutions.currentIndex))
            }
        }

        addRateSections(to: submenu, rates: video.refreshRateOptions(for: display)?.modes ?? [],
                        display: display, current: current)
    }
    return submenu
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

/// True when at least two displays are online — required for mirror/extend to make sense.
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

/// "Optimize for", listing the displays in the mirror set `display` belongs to with the
/// optimized one checked; picking another makes the set run at that display's resolution
/// without leaving mirror mode. Nil when the display is not in a set.
private func optimizeItem(for display: DisplayInfo, video: VideoManager) -> NSMenuItem? {
    let members = video.mirrorSetMembers(of: display)
    guard members.count >= 2 else { return nil }
    let submenu = NSMenu()
    for (i, member) in members.enumerated() {
        let item = NSMenuItem(title: member.label,
                              action: #selector(AppDelegate.optimizeForDisplay(_:)),
                              keyEquivalent: "")
        item.representedObject = member
        item.state = i == 0 ? .on : .off
        submenu.addItem(item)
    }
    let parent = NSMenuItem(title: "Optimize for", action: nil, keyEquivalent: "")
    parent.submenu = submenu
    return parent
}

/// The mirror items of a display's submenu. With one other display, a single toggle. With
/// several, a display that mirrors another keeps the toggle (it can only be freed), while
/// any other gets a "Mirror on" submenu listing the displays that can mirror it, the ones
/// doing so checked, plus "All Displays", and "Use as Separate Display" when it has slaves.
private func addMirrorItems(to submenu: NSMenu, for display: DisplayInfo, video: VideoManager) {
    let targets = video.mirrorTargets(for: display)
    let inSet   = display.isMirroring || video.isBeingMirrored(display)
    if targets.count < 2 || display.isMirroring {
        submenu.addItem(mirrorToggleItem(for: display, isMirroring: inSet))
        return
    }
    if inSet { submenu.addItem(mirrorToggleItem(for: display, isMirroring: true)) }

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
    submenu.addItem(parent)
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
