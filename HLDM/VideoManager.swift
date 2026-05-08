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
import os.log

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

private let vdLog = Logger(subsystem: "mmmeon.hldm", category: "VirtualDisplay")

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
    private var cachedAirPlayCGIDs: [String: CGDirectDisplayID] = [:]
    /// Caches IOKit-derived display names by cgID. Valid for the lifetime of a
    /// cgID — IDs are reassigned on disconnect, so stale entries are never accessed.
    private var ioKitNameCache: [CGDirectDisplayID: String] = [:]
    /// Retained CGVirtualDisplay objects keyed by AirPlay device name.
    /// Stored as AnyObject to avoid @available on the stored property.
    private var virtualAnchorStore: [String: AnyObject] = [:]
    /// Maps AirPlay device name → the CGDirectDisplayID of its active virtual anchor.
    private(set) var virtualAnchorCGIDs: [String: CGDirectDisplayID] = [:]

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

    // MARK: - Virtual Display Anchor

    func hasVirtualAnchor(for name: String) -> Bool {
        virtualAnchorStore[name] != nil
    }

    /// Generates one DisplayMode per combination of the 4 fixed resolutions × each selected
    /// refresh rate. Results are sorted descending by resolution, then refresh rate.
    static func virtualModes(refreshRates: Set<Int>) -> [DisplayMode] {
        let specs: [(Int, Int)] = [(3840, 2160), (2560, 1440), (1920, 1080), (1280, 720)]
        let rates = refreshRates.isEmpty ? [60] : refreshRates
        var modes: [DisplayMode] = []
        for (w, h) in specs {
            for rate in rates.sorted(by: >) {
                let hz = Double(rate)
                modes.append(DisplayMode(id: "\(w)x\(h)@\(hz)_virtual",
                                         ioModeID: 0,
                                         width: w, height: h,
                                         pixelWidth: w, pixelHeight: h,
                                         refreshRate: hz,
                                         isHiDPI: false,
                                         isVirtual: true))
            }
        }
        return modes
    }

    /// Convenience overload that reads refresh rates from `VisibilityPreferences`
    /// for the given display context (AirPlay vs external).
    static func virtualModes(for context: VisibilityPreferences.DisplayContext) -> [DisplayMode] {
        virtualModes(refreshRates: VisibilityPreferences.virtualRefreshRates(for: context))
    }

    /// Selects a virtual resolution for a display.
    ///
    /// - If the virtual anchor is already active, sets the mode directly on the anchor.
    /// - If the virtual anchor is not yet active, enables it; the user can re-select a
    ///   resolution from the menu once the anchor appears.
    func selectVirtualMode(_ mode: DisplayMode, for display: DisplayInfo) {
        if hasVirtualAnchor(for: display.name) {
            guard let anchorID = virtualAnchorCGIDs[display.name] else { return }
            setModeOnVirtualAnchor(mode, anchorID: anchorID)
        } else {
            vdLog.debug("selectVirtualMode: anchor not yet active for '\(display.name)' — enabling anchor, mode change deferred to user")
            enableVirtualAnchor(for: display)
        }
    }

    /// Sets a mode on a virtual anchor display by matching pixel dimensions at 60 Hz.
    private func setModeOnVirtualAnchor(_ mode: DisplayMode, anchorID: CGDirectDisplayID) {
        guard anchorID != 0 else { return }

        // Target the virtual display (master) directly.
        //
        // Targeting the slave instead (the physical display) is tempting but wrong:
        // the slave's mode list contains the physical panel's native modes (e.g. 60 Hz)
        // which differ from the virtual display's modes (120 Hz). Applying a 60 Hz mode
        // to the slave while the master runs at 120 Hz causes a mismatch that tears down
        // the mirror.
        //
        // CGDisplayCopyAllDisplayModes on the virtual display emits "invalid display
        // identifier" noise for the synthesized UUID, but still returns the correct list.
        // CGConfigureDisplayWithDisplayMode on the master works the same way.
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modeList = CGDisplayCopyAllDisplayModes(anchorID, options) as? [CGDisplayMode] else {
            vdLog.error("setModeOnVirtualAnchor: CGDisplayCopyAllDisplayModes returned nil for \(anchorID)")
            return
        }
        vdLog.debug("setModeOnVirtualAnchor: \(modeList.count) modes on master \(anchorID), seeking \(mode.width)×\(mode.height) @\(mode.refreshRate)Hz")
        for m in modeList { vdLog.debug("  candidate: \(m.pixelWidth)×\(m.pixelHeight) @\(m.refreshRate)Hz") }

        // Match by pixel size; also prefer the rate that matches the DisplayMode if possible.
        let cgMode: CGDisplayMode? = {
            // First: exact size + rate match.
            if let exact = modeList.first(where: {
                $0.pixelWidth == mode.width &&
                $0.pixelHeight == mode.height &&
                abs($0.refreshRate - Double(mode.refreshRate)) < 1.0
            }) { return exact }
            // Fallback: size-only match (virtual display may report a slightly different rate).
            return modeList.first(where: { $0.pixelWidth == mode.width && $0.pixelHeight == mode.height })
        }()

        guard let cgMode else {
            vdLog.error("setModeOnVirtualAnchor: no mode matching \(mode.width)×\(mode.height) on master \(anchorID)")
            return
        }
        vdLog.debug("setModeOnVirtualAnchor: applying \(cgMode.pixelWidth)×\(cgMode.pixelHeight) @\(cgMode.refreshRate)Hz on master \(anchorID)")

        var config: CGDisplayConfigRef?
        let beginErr = CGBeginDisplayConfiguration(&config)
        guard beginErr == .success, let cfg = config else {
            vdLog.error("setModeOnVirtualAnchor: BeginDisplayConfiguration err=\(beginErr.rawValue)")
            return
        }
        CGConfigureDisplayWithDisplayMode(cfg, anchorID, cgMode, nil)
        let completeErr = CGCompleteDisplayConfiguration(cfg, .forAppOnly)
        vdLog.debug("setModeOnVirtualAnchor: CompleteDisplayConfiguration err=\(completeErr.rawValue)")
    }

    /// Returns the CGDirectDisplayID to use for resolution queries and changes.
    /// When a virtual anchor is active for this display, returns the anchor's ID
    /// (the mirror master) so that resolution changes target the anchor rather than
    /// the AirPlay slave.
    func resolutionControlID(for display: DisplayInfo) -> CGDirectDisplayID {
        virtualAnchorCGIDs[display.name] ?? display.cgDisplayID
    }

    /// Creates a CGVirtualDisplay, stores it as the anchor for `display`, then
    /// configures the display as the mirror slave so it streams the virtual display's output.
    func enableVirtualAnchor(for display: DisplayInfo) {
        guard display.cgDisplayID != 0, !hasVirtualAnchor(for: display.name) else {
            vdLog.debug("enableVirtualAnchor: skipped '\(display.name)' cgID=\(display.cgDisplayID) hasAnchor=\(self.hasVirtualAnchor(for: display.name))")
            return
        }

        let context: VisibilityPreferences.DisplayContext =
            allAirPlayDevices.contains { $0.id == display.id } ? .airPlay : .external
        vdLog.debug("enableVirtualAnchor: starting for '\(display.name)' cgID=\(display.cgDisplayID) context=\(context.rawValue)")

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(.main)
        descriptor.name = "HLDM"
        descriptor.sizeInMillimeters = CGSize(width: 600, height: 340)
        descriptor.maxPixelsWide = 3840
        descriptor.maxPixelsHigh = 2160
        descriptor.vendorID  = 0x3456
        descriptor.productID = 0x1234
        descriptor.serialNum = 0x0002
        vdLog.debug("enableVirtualAnchor: descriptor configured — vendor=0x3456 product=0x1234 serial=0x0002 queue=main")

        let airPlayCGID = display.cgDisplayID
        let deviceName  = display.name
        descriptor.terminationHandler = { [weak self] _, vd in
            let assignedID = vd.displayID
            vdLog.debug("terminationHandler: virtual display for '\(deviceName)' terminated (displayID=\(assignedID))")
            DispatchQueue.main.async {
                self?.virtualAnchorStore.removeValue(forKey: deviceName)
                self?.virtualAnchorCGIDs.removeValue(forKey: deviceName)
                self?.mergeDevices()
            }
        }

        let vd = CGVirtualDisplay(descriptor: descriptor)
        vdLog.debug("enableVirtualAnchor: CGVirtualDisplay created — immediate displayID=\(vd.displayID)")

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        let resolutions: [(UInt, UInt)] = [(3840, 2160), (2560, 1440), (1920, 1080), (1280, 720)]
        let rates = VisibilityPreferences.virtualRefreshRates(for: context)
        let effectiveRates = rates.isEmpty ? [60] : rates
        settings.modes = resolutions.flatMap { w, h in
            effectiveRates.sorted(by: >).map { rate in
                CGVirtualDisplayMode(width: w, height: h, refreshRate: Double(rate))
            }
        }
        vdLog.debug("enableVirtualAnchor: applying \(settings.modes.count) modes (\(effectiveRates.sorted(by: >) as [Int]) Hz)")

        let applied = vd.apply(settings)
        vdLog.debug("enableVirtualAnchor: applySettings returned \(applied) — displayID after apply=\(vd.displayID)")
        guard applied else {
            vdLog.error("enableVirtualAnchor: applySettings FAILED — aborting")
            return
        }

        // Keep vd alive; poll until the virtual display appears, then wire up mirroring.
        virtualAnchorStore[deviceName] = vd
        vdLog.debug("enableVirtualAnchor: stored anchor, beginning poll (attempt 0)")
        waitForVirtualDisplay(vd, name: deviceName, airPlayID: airPlayCGID, context: context, attempt: 0)
    }

    private func waitForVirtualDisplay(_ vd: CGVirtualDisplay,
                                       name: String,
                                       airPlayID: CGDirectDisplayID,
                                       context: VisibilityPreferences.DisplayContext,
                                       attempt: Int) {
        // Collect both online and active lists — different macOS versions promote
        // CGVirtualDisplay to one or the other first.
        var onlineCount: CGDisplayCount = 0
        CGGetOnlineDisplayList(0, nil, &onlineCount)
        var onlineIDs = [CGDirectDisplayID](repeating: 0, count: Int(onlineCount))
        CGGetOnlineDisplayList(onlineCount, &onlineIDs, &onlineCount)

        var activeCount: CGDisplayCount = 0
        CGGetActiveDisplayList(0, nil, &activeCount)
        var activeIDs = [CGDirectDisplayID](repeating: 0, count: Int(activeCount))
        CGGetActiveDisplayList(activeCount, &activeIDs, &activeCount)

        let allIDs = Set(onlineIDs + activeIDs)
        let claimedAnchorIDs = Set(virtualAnchorCGIDs.values)
        let directID = vd.displayID

        vdLog.debug("waitForVirtualDisplay: attempt \(attempt)/10 — vd.displayID=\(directID) online=\(onlineIDs) active=\(activeIDs) claimed=\(Array(claimedAnchorIDs))")

        // Primary: trust vd.displayID if the system has assigned it.
        // Fallback: scan for a display with our synthetic vendor/product IDs that
        // isn't already claimed as an anchor — handles macOS versions where
        // displayID isn't assigned synchronously with CGVirtualDisplay init.
        let virtualID: CGDirectDisplayID? = {
            if directID != 0, allIDs.contains(directID) {
                vdLog.debug("waitForVirtualDisplay: found via directID \(directID)")
                return directID
            }
            if let heuristic = allIDs.first(where: {
                CGDisplayVendorNumber($0) == 0x3456 &&
                CGDisplayModelNumber($0) == 0x1234 &&
                !claimedAnchorIDs.contains($0)
            }) {
                vdLog.debug("waitForVirtualDisplay: found via vendor/product heuristic id=\(heuristic)")
                return heuristic
            }
            // Log every display's vendor/model to help diagnose a miss.
            for id in allIDs {
                vdLog.debug("waitForVirtualDisplay:   display \(id) vendor=\(CGDisplayVendorNumber(id)) model=\(CGDisplayModelNumber(id))")
            }
            return nil
        }()

        guard let virtualID else {
            if attempt < 10 {
                vdLog.debug("waitForVirtualDisplay: virtual display not found yet, retrying in 1 s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.waitForVirtualDisplay(vd, name: name, airPlayID: airPlayID,
                                               context: context, attempt: attempt + 1)
                }
            } else {
                vdLog.error("waitForVirtualDisplay: gave up after \(attempt) attempts — removing anchor for '\(name)'")
                virtualAnchorStore.removeValue(forKey: name)
            }
            return
        }

        virtualAnchorCGIDs[name] = virtualID
        vdLog.debug("waitForVirtualDisplay: virtual display id=\(virtualID) registered for '\(name)'")

        // Step 1: if the target display is already in a mirror set, tear it down
        // first in a separate transaction. Calling CGConfigureDisplayMirrorOfDisplay
        // on a display that is already a slave can silently fail.
        let existingMirror = CGDisplayMirrorsDisplay(airPlayID)
        vdLog.debug("step1: airPlayID=\(airPlayID) existingMirrorMaster=\(existingMirror)")
        if existingMirror != CGDirectDisplayID(0) {
            var teardown: CGDisplayConfigRef?
            let tearErr = CGBeginDisplayConfiguration(&teardown)
            vdLog.debug("step1: BeginDisplayConfiguration err=\(tearErr.rawValue)")
            if tearErr == .success, let tc = teardown {
                CGConfigureDisplayMirrorOfDisplay(tc, airPlayID, CGDirectDisplayID(0))
                let completeErr = CGCompleteDisplayConfiguration(tc, .forAppOnly)
                vdLog.debug("step1: teardown complete err=\(completeErr.rawValue) — waiting 1 s before mirror")
            }
        }

        // Step 2: mirror the target display onto the virtual anchor.
        // Wait 1 s after any teardown (or immediately if no teardown needed) so macOS
        // can settle before the next configuration transaction.
        let step2Delay: Double = existingMirror != CGDirectDisplayID(0) ? 1.0 : 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + step2Delay) { [weak self] in
            guard let self else { return }
            vdLog.debug("step2: configuring mirror airPlayID=\(airPlayID) → virtualID=\(virtualID)")
            var config: CGDisplayConfigRef?
            let beginErr = CGBeginDisplayConfiguration(&config)
            vdLog.debug("step2: BeginDisplayConfiguration err=\(beginErr.rawValue)")
            guard beginErr == .success, let cfg = config else {
                vdLog.error("step2: BeginDisplayConfiguration failed — aborting")
                return
            }
            CGConfigureDisplayMirrorOfDisplay(cfg, airPlayID, virtualID)
            // .forAppOnly (rawValue 0): config reverts automatically when the app exits.
            let mirrorErr = CGCompleteDisplayConfiguration(cfg, .forAppOnly)
            vdLog.debug("step2: CompleteDisplayConfiguration err=\(mirrorErr.rawValue)")

            // Step 3: let the system settle, then refresh the UI.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                vdLog.debug("step3: mergeDevices")
                self?.mergeDevices()
            }
        }
    }

    /// Breaks the virtual anchor: extends AirPlay back to an independent display,
    /// then releases the CGVirtualDisplay so it disappears from the system.
    func disableVirtualAnchor(for display: DisplayInfo) {
        guard hasVirtualAnchor(for: display.name) else { return }
        let airPlayCGID = display.cgDisplayID != 0
            ? display.cgDisplayID
            : (cachedAirPlayCGIDs[display.name] ?? 0)
        if airPlayCGID != 0 {
            var config: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&config) == .success, let cfg = config {
                CGConfigureDisplayMirrorOfDisplay(cfg, airPlayCGID, CGDirectDisplayID(0))
                CGCompleteDisplayConfiguration(cfg, .forAppOnly)
            }
        }
        virtualAnchorStore.removeValue(forKey: display.name)
        virtualAnchorCGIDs.removeValue(forKey: display.name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.mergeDevices()
        }
    }

    // MARK: - Private

    private func mergeDevices() {
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

        // Release virtual anchors whose display (AirPlay or physical) is no longer connected.
        // Guard: skip anchors that are still being established (waitForVirtualDisplay is
        // in progress and has not yet written virtualAnchorCGIDs). Cleaning them up during
        // the 3-second poll window would deallocate CGVirtualDisplay prematurely.
        let connectedDisplayNames = Set(
            newAirPlay.filter { $0.isConnected }.map { $0.name } +
            newPhysical.filter { $0.isConnected }.map { $0.name }
        )
        for name in Array(virtualAnchorStore.keys) where !connectedDisplayNames.contains(name) {
            guard virtualAnchorCGIDs[name] != nil else { continue }
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
