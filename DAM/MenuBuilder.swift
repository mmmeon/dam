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
                title: device.name,
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
                title: display.name,
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
                    // When AirPlay is the slave (built-in is master), offer a dedicated
                    // "Optimize for this Display" item that promotes it to master without
                    // exiting mirror mode — decoupled from the mirror on/off toggle.
                    if display.isMirroring {
                        submenu.addItem(optimizeItem(for: display))
                    }
                }
                if let item = mainDisplayItem(for: display, video: video) { submenu.addItem(item) }
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
                    title: device.name,
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
            let item = NSMenuItem(title: display.name, action: nil, keyEquivalent: "")
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
                }
                if let item = mainDisplayItem(for: display, video: video) { submenu.addItem(item) }
                item.submenu = submenu
            } else {
                item.submenu = buildResolutionSubmenu(display: display, video: video)
            }
            menu.addItem(item)
        }
    }

    menu.addItem(.separator())
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
        // — Native group —
        submenu.addItem(sectionHeader("Native"))
        let nativeModes  = video.availableModesDeduped(for: display.cgDisplayID)
        let virtualModes = VideoManager.virtualModes(for: .airPlay)
        let currentIdx   = VideoManager.currentModeIndex(
            in: nativeModes + virtualModes, anchorCurrent: current.anchor, nativeCurrent: current.native)

        if nativeModes.isEmpty {
            submenu.addItem(disabledItem("No modes available"))
        } else {
            for (i, mode) in nativeModes.enumerated() {
                submenu.addItem(modeItem(title: mode.label, mode: mode, display: display,
                                         isCurrent: i == currentIdx))
            }
        }

        // — Virtual group —
        submenu.addItem(sectionHeader("Virtual"))
        for (i, mode) in virtualModes.enumerated() {
            submenu.addItem(modeItem(title: mode.label, mode: mode, display: display,
                                     isCurrent: nativeModes.count + i == currentIdx))
        }
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

        submenu.addItem(sectionHeader("Refresh Rate"))
        if let options = video.refreshRateOptions(for: display) {
            let currentIdx = VideoManager.currentModeIndex(
                in: options.modes, anchorCurrent: current.anchor, nativeCurrent: current.native)
            for (i, mode) in options.modes.enumerated() {
                submenu.addItem(modeItem(title: mode.rateLabel, mode: mode, display: display,
                                         isCurrent: i == currentIdx))
            }
        } else {
            submenu.addItem(disabledItem("No rates available"))
        }
    }
    return submenu
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

private func optimizeItem(for display: DisplayInfo) -> NSMenuItem {
    let item = NSMenuItem(
        title: "Optimize for this Display",
        action: #selector(AppDelegate.optimizeForDisplay(_:)),
        keyEquivalent: ""
    )
    item.representedObject = display
    return item
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
        let item = NSMenuItem(title: target.name,
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
