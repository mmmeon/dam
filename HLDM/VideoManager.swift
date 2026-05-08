//
//  VideoManager.swift
//  boar
//

import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.graphics
import Network

struct DisplayMode: Identifiable, Hashable {
    let id: String              // "WIDTHxHEIGHT@RATE" or "WIDTHxHEIGHT@RATE@2x" for HiDPI
    let ioModeID: Int32
    let width: Int              // logical (point) width
    let height: Int             // logical (point) height
    let pixelWidth: Int         // actual rendered pixel width
    let pixelHeight: Int        // actual rendered pixel height
    let refreshRate: Double
    let isHiDPI: Bool
    /// True for the four fixed virtual-anchor modes (720p / 1080p / 1440p / 4K).
    let isVirtual: Bool

    init(id: String, ioModeID: Int32, width: Int, height: Int,
         pixelWidth: Int, pixelHeight: Int, refreshRate: Double,
         isHiDPI: Bool, isVirtual: Bool = false) {
        self.id = id
        self.ioModeID = ioModeID
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.isHiDPI = isHiDPI
        self.isVirtual = isVirtual
    }

    /// Full label for menus: "3840 × 2160 — 60 Hz" / "1920 × 1080 — 60 Hz  HiDPI"
    var label: String {
        let hz = refreshRate.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f Hz", refreshRate)
            : String(format: "%.1f Hz", refreshRate)
        let base = "\(width) × \(height) — \(hz)"
        return isHiDPI ? base + "  HiDPI" : base
    }

    /// Compact label for Touch Bar.
    /// Uses "HEIGHTp" when the resolution matches the configured default aspect ratio and
    /// that representation is shorter; otherwise "WIDTHxHEIGHT". Appends "✦" for virtual
    /// modes and "↑" for HiDPI.
    var shortLabel: String {
        let suffix = isVirtual ? "✦" : (isHiDPI ? "↑" : "")
        let ar = VisibilityPreferences.defaultAspectRatio
        if width * ar.h == height * ar.w {
            let pLabel = "\(height)p\(suffix)"
            let wLabel = "\(width)×\(height)\(suffix)"
            return pLabel.count <= wLabel.count ? pLabel : wLabel
        }
        return "\(width)×\(height)\(suffix)"
    }
}

struct DisplayInfo: Identifiable, Hashable {
    let id: String                          // Bonjour service name / device name
    let name: String
    let isConnected: Bool                   // true = currently active (in NSScreen.screens)
    let cgDisplayID: CGDirectDisplayID      // 0 when not connected
    /// True when this display is the slave in a mirror set (it replicates another display).
    let isMirroring: Bool
    /// True for the Mac's own built-in panel.
    let isBuiltIn: Bool
}

struct ResolutionSelection: Hashable {
    let mode: DisplayMode
    let cgDisplayID: CGDirectDisplayID
}

/// Carries the chosen virtual resolution and its target AirPlay display so the action
/// handler can route through `VideoManager.selectVirtualMode`.
struct VirtualResolutionSelection {
    let mode: DisplayMode
    let display: DisplayInfo
}

final class VideoManager: ObservableObject {
    /// All Bonjour-discovered AirPlay destinations, regardless of visibility preference.
    private(set) var allAirPlayDevices: [DisplayInfo] = []
    /// All physically connected non-AirPlay screens, regardless of visibility preference.
    private(set) var allConnectedDisplays: [DisplayInfo] = []

    /// AirPlay destinations filtered by VisibilityPreferences — used by the menu and Touch Bar.
    @Published private(set) var airPlayDevices: [DisplayInfo] = []
    /// Physical displays filtered by VisibilityPreferences — used by the menu and Touch Bar.
    @Published private(set) var connectedDisplays: [DisplayInfo] = []

    private var browser: NWBrowser?
    private var discoveredNames: Set<String> = []
    /// Remembers the CGDirectDisplayID for each AirPlay device name the last time
    /// it appeared in NSScreen.screens (extend mode). Used to keep tracking the
    /// display when it becomes a mirror slave and drops out of NSScreen.
    var cachedAirPlayCGIDs: [String: CGDirectDisplayID] = [:]
    /// Caches IOKit-derived display names by cgID. Valid for the lifetime of a
    /// cgID — IDs are reassigned on disconnect, so stale entries are never accessed.
    private var ioKitNameCache: [CGDirectDisplayID: String] = [:]
    /// Retained CGVirtualDisplay objects keyed by AirPlay device name.
    /// Stored as AnyObject to avoid @available on the stored property.
    var virtualAnchorStore: [String: AnyObject] = [:]
    /// Maps AirPlay device name → the CGDirectDisplayID of its active virtual anchor.
    var virtualAnchorCGIDs: [String: CGDirectDisplayID] = [:]

    /// Start continuous Bonjour discovery. Call once on launch; runs until the app quits.
    func startDiscovery() {
        let browser = NWBrowser(for: .bonjour(type: "_airplay._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                self?.discoveredNames = Set(results.compactMap { result -> String? in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    return name
                })
                self?.mergeDevices()
            }
        }
        browser.start(queue: .global(qos: .utility))
        self.browser = browser
    }

    /// Re-check which discovered devices are currently connected.
    func refresh() {
        mergeDevices()
    }

    /// Re-applies the current visibility preferences without re-querying displays.
    func applyVisibility() {
        let fa = VideoManager.filter(airPlayDevices: allAirPlayDevices, hidden: VisibilityPreferences.hiddenAirPlayDevices)
        let fc = VideoManager.filter(connectedDisplays: allConnectedDisplays, hidden: VisibilityPreferences.hiddenDisplays)
        if airPlayDevices    != fa { airPlayDevices    = fa }
        if connectedDisplays != fc { connectedDisplays = fc }
    }

    static func filter(airPlayDevices: [DisplayInfo], hidden: Set<String>) -> [DisplayInfo] {
        airPlayDevices.filter { !hidden.contains($0.name) }
    }

    static func filter(connectedDisplays: [DisplayInfo], hidden: Set<String>) -> [DisplayInfo] {
        connectedDisplays.filter { !hidden.contains($0.name) }
    }

    // MARK: - Mirror / Extend

    /// True if any known connected display is currently mirroring `display`
    /// (i.e. `display` is the master in a mirror set).
    func isBeingMirrored(_ display: DisplayInfo) -> Bool {
        guard display.cgDisplayID != 0 else { return false }
        return (allConnectedDisplays + allAirPlayDevices).contains {
            $0.cgDisplayID != 0 &&
            CGDisplayMirrorsDisplay($0.cgDisplayID) == display.cgDisplayID
        }
    }

    /// Toggles the mirror relationship.
    ///
    /// - If `display` is the **slave** (isMirroring == true): extends it to its own screen.
    /// - If `display` is the **master** (something is mirroring it): extends the slave.
    /// - If no mirroring is active: finds the first other connected display and makes
    ///   it mirror `display`.
    func toggleMirroring(for display: DisplayInfo) {
        guard display.cgDisplayID != 0 else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return }

        let allKnown = allConnectedDisplays + allAirPlayDevices
        // Find a slave that is currently mirroring this display.
        let slave = allKnown.first {
            $0.cgDisplayID != 0 &&
            CGDisplayMirrorsDisplay($0.cgDisplayID) == display.cgDisplayID
        }

        if display.isMirroring {
            // This display is itself a slave — extend it.
            CGConfigureDisplayMirrorOfDisplay(cfg, display.cgDisplayID, CGDirectDisplayID(0))
        } else if let slave = slave {
            // Something is mirroring this display — extend the slave.
            CGConfigureDisplayMirrorOfDisplay(cfg, slave.cgDisplayID, CGDirectDisplayID(0))
        } else {
            // No mirroring active — mirror the first other connected display onto this one.
            let target = allKnown.first { $0.cgDisplayID != 0 && $0.cgDisplayID != display.cgDisplayID }
            guard let target = target else { CGCancelDisplayConfiguration(cfg); return }
            CGConfigureDisplayMirrorOfDisplay(cfg, target.cgDisplayID, display.cgDisplayID)
        }

        CGCompleteDisplayConfiguration(cfg, .permanently)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.mergeDevices()
        }
    }

    // MARK: - AirPlay

    /// Clicking a connected device in the Screen Mirroring panel toggles it off.
    func disconnectAirPlay(deviceName: String) {
        connectAirPlay(deviceName: deviceName)
    }

    func connectAirPlay(deviceName: String) {
        let safe = deviceName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let src = """
            tell application "System Events"
                tell its application process "ControlCenter"

                    -- Step 1: open the Screen Mirroring popover.
                    -- Capture the target window title immediately after opening so
                    -- Step 2 can reference the exact same window — mirroring tv.scpt.
                    if exists (first UI element of menu bar 1 whose value of attribute "AXIdentifier" contains "screen-mirroring") then
                        click (first UI element of menu bar 1 whose value of attribute "AXIdentifier" contains "screen-mirroring")
                        delay 1
                        set window_ to title of (first window) as text
                    else
                        click (first UI element of menu bar 1 whose value of attribute "AXIdentifier" contains "controlcenter")
                        delay 1
                        set window_ to title of (first window) as text
                        -- "click" does not work on the Screen Mirroring tile inside
                        -- Control Center — only "perform action 1" works on Ventura.
                        tell window window_
                            repeat with anItem in (UI elements of group 1)
                                try
                                    if value of attribute "AXIdentifier" of anItem contains "screen-mirroring" then
                                        perform action 1 of anItem
                                        exit repeat
                                    end if
                                end try
                            end repeat
                        end tell
                    end if

                    set frontmost to true
                    delay 1

                    -- Step 2: exact tv.scpt logic for Ventura.
                    -- Everything runs inside tell window window_ just like the original.
                    -- Uses "ends with" and AXChildren traversal verbatim from tv.scpt.
                    try
                        tell window window_
                            set screenMirroringDropDown to UI elements of group 1
                            repeat with anItem in screenMirroringDropDown
                                try
                                    set itemsOfScreenMirroringMenu to value of attribute "AXChildren" of anItem
                                    repeat with childItem in itemsOfScreenMirroringMenu
                                        if (exists attribute "AXIdentifier" of childItem) then
                                            set aScreenMirroringItem to value of attribute "AXIdentifier" of childItem
                                        else
                                            set aScreenMirroringItem to title of childItem
                                        end if
                                        if aScreenMirroringItem ends with "\(safe)" then
                                            click childItem
                                            return
                                        end if
                                    end repeat
                                on error
                                end try
                            end repeat
                        end tell
                    on error
                    end try

                end tell
            end tell
            """

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var errors: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&errors)
            if let errors = errors {
                NSLog("HLDM: connectAirPlay error: %@", errors.description)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.mergeDevices()
            }
        }
    }

    // MARK: - Resolution

    func availableModes(for cgDisplayID: CGDirectDisplayID) -> [DisplayMode] {
        guard cgDisplayID != 0 else { return [] }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modeList = CGDisplayCopyAllDisplayModes(cgDisplayID, options) as? [CGDisplayMode] else { return [] }

        var seen = Set<String>()
        return modeList
            .compactMap { cgMode -> DisplayMode? in
                let w = cgMode.width, h = cgMode.height
                guard w > 1, h > 1 else { return nil }
                let hz = cgMode.refreshRate == 0 ? 60.0 : cgMode.refreshRate
                let pw = cgMode.pixelWidth, ph = cgMode.pixelHeight
                let hiDPI = pw > w
                let dedupeKey = "\(pw)x\(ph)@\(hz)"
                guard seen.insert(dedupeKey).inserted else { return nil }
                let id = hiDPI ? "\(w)x\(h)@\(hz)@2x" : "\(w)x\(h)@\(hz)"
                return DisplayMode(id: id, ioModeID: cgMode.ioDisplayModeID,
                                   width: w, height: h, pixelWidth: pw, pixelHeight: ph,
                                   refreshRate: hz, isHiDPI: hiDPI)
            }
            .sorted { ($0.pixelWidth, $0.pixelHeight, $0.refreshRate) > ($1.pixelWidth, $1.pixelHeight, $1.refreshRate) }
    }

    /// One mode per logical resolution, preferring HiDPI over non-HiDPI, then highest refresh rate.
    /// Single pass over CGDisplayCopyAllDisplayModes — does not call availableModes().
    func availableModesDeduped(for cgDisplayID: CGDirectDisplayID) -> [DisplayMode] {
        guard cgDisplayID != 0 else { return [] }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modeList = CGDisplayCopyAllDisplayModes(cgDisplayID, options) as? [CGDisplayMode] else { return [] }
        var best: [String: DisplayMode] = [:]
        for cgMode in modeList {
            let w = cgMode.width, h = cgMode.height
            guard w > 1, h > 1 else { continue }
            let hz = cgMode.refreshRate == 0 ? 60.0 : cgMode.refreshRate
            let pw = cgMode.pixelWidth, ph = cgMode.pixelHeight
            let hiDPI = pw > w
            let key = "\(w)x\(h)"
            if let existing = best[key] {
                // HiDPI always wins over non-HiDPI at the same logical resolution.
                // Among equal HiDPI status, keep the higher refresh rate.
                if existing.isHiDPI && !hiDPI { continue }
                if existing.isHiDPI == hiDPI && hz <= existing.refreshRate { continue }
            }
            let id = hiDPI ? "\(w)x\(h)@\(hz)@2x" : "\(w)x\(h)@\(hz)"
            best[key] = DisplayMode(id: id, ioModeID: cgMode.ioDisplayModeID,
                                    width: w, height: h, pixelWidth: pw, pixelHeight: ph,
                                    refreshRate: hz, isHiDPI: hiDPI)
        }
        return best.values.sorted { ($0.pixelWidth, $0.pixelHeight) > ($1.pixelWidth, $1.pixelHeight) }
    }

    func currentMode(for cgDisplayID: CGDirectDisplayID) -> DisplayMode? {
        guard cgDisplayID != 0,
              let cgMode = CGDisplayCopyDisplayMode(cgDisplayID) else { return nil }
        let w = cgMode.width, h = cgMode.height
        let hz = cgMode.refreshRate == 0 ? 60.0 : cgMode.refreshRate
        let pw = cgMode.pixelWidth, ph = cgMode.pixelHeight
        let hiDPI = pw > w
        let id = hiDPI ? "\(w)x\(h)@\(hz)@2x" : "\(w)x\(h)@\(hz)"
        return DisplayMode(id: id, ioModeID: cgMode.ioDisplayModeID,
                           width: w, height: h, pixelWidth: pw, pixelHeight: ph,
                           refreshRate: hz, isHiDPI: hiDPI)
    }

    /// Promotes `display` from mirror slave to mirror master ("Optimize for this Display").
    /// No-op if the display is already the master or not in a mirror set at all.
    func setAsOptimizedDisplay(_ display: DisplayInfo) {
        guard display.cgDisplayID != 0 else { return }
        let masterID = CGDisplayMirrorsDisplay(display.cgDisplayID)
        guard masterID != CGDirectDisplayID(0) else { return }  // already master or not mirroring

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return }
        CGConfigureDisplayMirrorOfDisplay(cfg, masterID, display.cgDisplayID)
        CGCompleteDisplayConfiguration(cfg, .permanently)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.mergeDevices()
        }
    }

    func setMode(_ mode: DisplayMode, for cgDisplayID: CGDirectDisplayID) {
        guard cgDisplayID != 0 else { return }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modeList = CGDisplayCopyAllDisplayModes(cgDisplayID, options) as? [CGDisplayMode],
              let cgMode = modeList.first(where: { $0.ioDisplayModeID == mode.ioModeID }) else { return }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return }

        // If this display is currently a mirror slave, promote it to master first
        // ("Optimize for this display") so the resolution change applies to it.
        let masterID = CGDisplayMirrorsDisplay(cgDisplayID)
        if masterID != CGDirectDisplayID(0) {
            CGConfigureDisplayMirrorOfDisplay(cfg, masterID, cgDisplayID)
        }

        CGConfigureDisplayWithDisplayMode(cfg, cgDisplayID, cgMode, nil)
        CGCompleteDisplayConfiguration(cfg, .permanently)
    }

    // MARK: - Private

    func mergeDevices() {
        // Build a cgID → name map from active NSScreen entries.
        // Include the built-in panel — it disappears from NSScreen in clamshell
        // mode, which naturally removes it from connectedDisplays when inactive.
        var idToScreenName: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let cgID = num.map { CGDirectDisplayID($0.uint32Value) } ?? 0
            guard cgID != 0 else { continue }
            idToScreenName[cgID] = screen.localizedName
        }
        let liveIDs  = Set(idToScreenName.keys)


        // Use CGGetOnlineDisplayList to capture ALL connected displays, including
        // those hidden in a mirror set (which NSScreen.screens omits).
        var onlineCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &onlineCount)
        var onlineIDs = [CGDirectDisplayID](repeating: 0, count: Int(onlineCount))
        CGGetOnlineDisplayList(onlineCount, &onlineIDs, &onlineCount)

        // Build a full id → name map, falling back to IOKit for external displays not in NSScreen.
        // Built-in panels and AirPlay virtual displays have no IODisplayConnect entry — they
        // are already resolved via NSScreen (built-in) or left absent (AirPlay virtual).
        var idToName: [CGDirectDisplayID: String] = idToScreenName
        for cgID in onlineIDs {
            guard idToName[cgID] == nil else { continue }
            guard CGDisplayIsBuiltin(cgID) == 0 else { continue }   // built-in has no IODisplayConnect
            if let name = ioKitNameCache[cgID] {
                idToName[cgID] = name
            } else if let name = displayNameFromIOKit(cgID) {
                ioKitNameCache[cgID] = name
                idToName[cgID] = name
            }
        }

        // AirPlay: resolve each Bonjour-discovered name to a CGDirectDisplayID.
        //
        // Strategy (in priority order):
        //  1. NSScreen name match — reliable in extend mode and software-mirror mode.
        //  2. Cached ID from a prior extend-mode observation, still online — handles the
        //     hardware-mirror-slave case where NSScreen drops the display.
        //  3. "No IOKit entry" heuristic — AirPlay virtual displays are the only online
        //     non-builtin displays with no IODisplayConnect service (vendor "aapl",
        //     product "airp"). Match unresolved Bonjour names to these displays.
        let onlineSet = Set(onlineIDs)

        // Pass 1: resolve via NSScreen or cache.
        var resolvedIDs: [String: CGDirectDisplayID] = [:]
        var unresolvedNames: [String] = []
        for name in discoveredNames.sorted() {
            if let cgID = idToScreenName.first(where: { $0.value == name })?.key {
                cachedAirPlayCGIDs[name] = cgID
                resolvedIDs[name] = cgID
            } else if let cgID = cachedAirPlayCGIDs[name], onlineSet.contains(cgID) {
                resolvedIDs[name] = cgID
            } else {
                unresolvedNames.append(name)
            }
        }

        // Pass 2: match unresolved names to online displays with no IOKit entry.
        // These are virtual (AirPlay) displays that slipped past NSScreen and the cache.
        if !unresolvedNames.isEmpty {
            let resolvedSet = Set(resolvedIDs.values)
            let virtualIDs = onlineIDs.filter {
                CGDisplayIsBuiltin($0) == 0 && idToName[$0] == nil && !resolvedSet.contains($0)
            }
            // Pair by sorted order — deterministic when counts match.
            for (name, cgID) in zip(unresolvedNames, virtualIDs) {
                cachedAirPlayCGIDs[name] = cgID
                resolvedIDs[name] = cgID
            }
        }

        let newAirPlay = discoveredNames.sorted().map { name in
            guard let cgID = resolvedIDs[name], onlineSet.contains(cgID) else {
                return DisplayInfo(id: name, name: name,
                                   isConnected: false, cgDisplayID: 0,
                                   isMirroring: false, isBuiltIn: false)
            }
            let isMirroring = CGDisplayMirrorsDisplay(cgID) != CGDirectDisplayID(0)
            return DisplayInfo(id: name, name: name,
                               isConnected: true, cgDisplayID: cgID,
                               isMirroring: isMirroring, isBuiltIn: false)
        }

        // Physical: all online displays not in the Bonjour list.
        // Includes the built-in panel when the lid is open (it appears in NSScreen
        // and therefore idToName). Absent in clamshell mode, which is correct.
        let airPlayIDs = Set(newAirPlay.map(\.cgDisplayID))
        let anchorIDs  = Set(virtualAnchorCGIDs.values)

        var physical: [DisplayInfo] = []
        for cgID in onlineIDs {
            guard !airPlayIDs.contains(cgID) else { continue }
            guard !anchorIDs.contains(cgID)  else { continue }   // hide virtual anchors from display list
            guard let name = idToName[cgID] else { continue }
            let isBuiltIn   = CGDisplayIsBuiltin(cgID) != 0
            let isMirroring = CGDisplayMirrorsDisplay(cgID) != CGDirectDisplayID(0)
            physical.append(DisplayInfo(id: isBuiltIn ? "__builtin__" : name,
                                        name: name,
                                        isConnected: liveIDs.contains(cgID),
                                        cgDisplayID: cgID,
                                        isMirroring: isMirroring,
                                        isBuiltIn: isBuiltIn))
        }
        // Built-in first, then external sorted by name.
        let newPhysical = physical.sorted { l, r in
            if l.isBuiltIn != r.isBuiltIn { return l.isBuiltIn }
            return l.name < r.name
        }

        // Release virtual anchors whose display is no longer connected.
        //
        // Two guards protect live anchors from being prematurely torn down:
        //
        // 1. Poll-in-progress guard: if waitForVirtualDisplay hasn't yet written
        //    virtualAnchorCGIDs[name], the anchor is still being established — skip it.
        //
        // 2. Mirror-slave guard: a physical display that is the mirror slave of a virtual
        //    anchor is HIDDEN from NSScreen.screens (macOS omits slaves), so its
        //    isConnected is false even though the mirror is running correctly.
        //    AirPlay displays avoid this because their isConnected is based on
        //    CGGetOnlineDisplayList rather than NSScreen — but physical displays use
        //    NSScreen. Check whether any online display is actively mirroring the
        //    anchor before tearing it down.
        let connectedDisplayNames = Set(
            newAirPlay.filter { $0.isConnected }.map { $0.name } +
            newPhysical.filter { $0.isConnected }.map { $0.name }
        )
        for name in Array(virtualAnchorStore.keys) where !connectedDisplayNames.contains(name) {
            guard let anchorID = virtualAnchorCGIDs[name] else { continue }   // guard 1: still polling
            // Guard 2: keep the anchor alive while a physical slave is mirroring it.
            if onlineIDs.contains(where: { CGDisplayMirrorsDisplay($0) == anchorID }) { continue }
            virtualAnchorStore.removeValue(forKey: name)
            virtualAnchorCGIDs.removeValue(forKey: name)
        }

        if allAirPlayDevices    != newAirPlay   { allAirPlayDevices    = newAirPlay   }
        if allConnectedDisplays != newPhysical  { allConnectedDisplays = newPhysical  }
        applyVisibility()
    }

    /// Gets a display's human-readable name via IOKit without CGDisplayIOServicePort
    /// (removed in macOS 14). Matches by vendor / product / serial against all
    /// IODisplayConnect services, then extracts the localised product name.
    private func displayNameFromIOKit(_ cgID: CGDirectDisplayID) -> String? {
        let vendorID  = CGDisplayVendorNumber(cgID)
        let productID = CGDisplayModelNumber(cgID)
        let serialNum = CGDisplaySerialNumber(cgID)

        var iter: io_iterator_t = 0
        // Port 0 == kIOMainPortDefault (replaces deprecated kIOMasterPortDefault)
        guard IOServiceGetMatchingServices(0, IOServiceMatching("IODisplayConnect"), &iter)
                == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var service: io_service_t = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }

            // kIODisplayOnlyPreferredName = 0x200
            guard let cfDict = IODisplayCreateInfoDictionary(service, IOOptionBits(0x200)) else { continue }
            let info = cfDict.takeRetainedValue() as NSDictionary

            func u32(_ key: String) -> UInt32 {
                (info[key] as? UInt32) ?? (info[key] as? Int).map(UInt32.init) ?? 0
            }

            guard u32("DisplayVendorID") == vendorID,
                  u32("DisplayProductID") == productID else { continue }
            if serialNum != 0 { guard u32("DisplaySerialNumber") == serialNum else { continue } }

            if let names = info["DisplayProductName"] as? [String: String] {
                return names["en"] ?? names.values.first
            }
        }
        return nil
    }
}
