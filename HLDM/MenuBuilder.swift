//
//  MenuBuilder.swift
//  boar
//

import AppKit

func buildStatusMenu(audio: AudioManager,
                     video: VideoManager,
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
            if mirrorActive {
                let icon = video.hasVirtualAnchor(for: display.name) ? "sparkles" : "square.on.square"
                item.image = menuIcon(icon)
            }

            if display.isConnected && display.cgDisplayID != 0 {
                let submenu = buildResolutionSubmenu(display: display, video: video)
                submenu.addItem(.separator())
                if canMirrorDisplays {
                    submenu.addItem(mirrorToggleItem(for: display, isMirroring: mirrorActive))
                    // When AirPlay is the slave (built-in is master), offer a dedicated
                    // "Optimize for this Display" item that promotes it to master without
                    // exiting mirror mode — decoupled from the mirror on/off toggle.
                    if display.isMirroring {
                        submenu.addItem(optimizeItem(for: display))
                    }
                }
                submenu.addItem(disconnectItem(for: display))
                item.submenu = submenu
            }

            menu.addItem(item)
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
            // Physical displays never have a virtual anchor, so always use square.on.square.
            let mirrorActive = display.isMirroring || video.isBeingMirrored(display)
            if mirrorActive { item.image = menuIcon("square.on.square") }  // physical display

            if display.cgDisplayID != 0 {
                let submenu = buildResolutionSubmenu(display: display, video: video)
                if canMirrorDisplays {
                    submenu.addItem(.separator())
                    submenu.addItem(mirrorToggleItem(for: display, isMirroring: mirrorActive))
                }
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
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit HLDM",
                 action: #selector(NSApplication.terminate(_:)),
                 keyEquivalent: "q")

    return menu
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

private func buildResolutionSubmenu(display: DisplayInfo, video: VideoManager) -> NSMenu {
    let submenu = NSMenu()
    let isAirPlay = video.allAirPlayDevices.contains(where: { $0.id == display.id })

    if isAirPlay {
        // — Native group —
        submenu.addItem(sectionHeader("Native"))
        let nativeCGID  = display.cgDisplayID
        let nativeModes = video.availableModesDeduped(for: nativeCGID)
        let hasAnchor   = video.hasVirtualAnchor(for: display.name)
        let anchorCGID  = video.virtualAnchorCGIDs[display.name] ?? 0

        // Checkmark: native mode active only when NO virtual anchor is running.
        let nativeCurrent: DisplayMode? = hasAnchor ? nil : video.currentMode(for: nativeCGID)

        if nativeModes.isEmpty {
            submenu.addItem(disabledItem("No modes available"))
        } else {
            for mode in nativeModes {
                let item = NSMenuItem(
                    title: mode.label,
                    action: #selector(AppDelegate.selectResolution(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = ResolutionSelection(mode: mode, cgDisplayID: nativeCGID)
                item.state = (mode.ioModeID == nativeCurrent?.ioModeID) ? .on : .off
                submenu.addItem(item)
            }
        }

        // — Virtual group header —
        submenu.addItem(sectionHeader("Virtual"))

        // — Virtual mode items —
        let virtualModes = VideoManager.virtualModes()
        // Checkmark on the virtual mode matching the anchor's current mode (if anchor active).
        let anchorCurrent: DisplayMode? = hasAnchor ? video.currentMode(for: anchorCGID) : nil

        for mode in virtualModes {
            let item = NSMenuItem(
                title: mode.label,
                action: #selector(AppDelegate.selectVirtualResolution(_:)),
                keyEquivalent: ""
            )
            item.representedObject = VirtualResolutionSelection(mode: mode, display: display)
            // Match by pixel dimensions since ioModeID is 0 for our synthetic virtual modes.
            let isSelected = anchorCurrent.map {
                $0.pixelWidth == mode.width && $0.pixelHeight == mode.height
            } ?? false
            item.state = isSelected ? .on : .off
            submenu.addItem(item)
        }
    } else {
        // Physical display — simple single-group resolution list.
        let cgID    = video.resolutionControlID(for: display)
        let current = video.currentMode(for: cgID)
        let modes   = video.availableModesDeduped(for: cgID)

        if modes.isEmpty {
            submenu.addItem(disabledItem("No modes available"))
        } else {
            for mode in modes {
                let item = NSMenuItem(
                    title: mode.label,
                    action: #selector(AppDelegate.selectResolution(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = ResolutionSelection(mode: mode, cgDisplayID: cgID)
                item.state = (mode.ioModeID == current?.ioModeID) ? .on : .off
                submenu.addItem(item)
            }
        }
    }
    return submenu
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
