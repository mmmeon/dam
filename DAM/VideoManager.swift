//
//  VideoManager.swift
//

import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.graphics
import Network
import os.log

private let mirrorLog = Logger(subsystem: AppIdentity.bundleID, category: "Mirror")

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

    /// Refresh rate rounded to whole Hz — identifies a row in the refresh-rate pickers,
    /// so 59.94 Hz and 60 Hz modes collapse into one "60 Hz" choice.
    var roundedRefreshRate: Int { Int(refreshRate.rounded()) }

    /// "60 Hz"-style label for the refresh-rate pickers; virtual rates get a "✦".
    var rateLabel: String { "\(roundedRefreshRate) Hz" + (isVirtual ? " ✦" : "") }

    /// "1920 × 1080"-style label for the resolution pickers, noting HiDPI.
    var resolutionLabel: String { "\(width) × \(height)" + (isHiDPI ? "  HiDPI" : "") }

    /// Compact "1080p"-style label for the Touch Bar, with "↑" for HiDPI and "✦" for virtual
    /// modes. The pickers only list sizes in the panel's own aspect ratio, so the height
    /// identifies a size.
    var shortLabel: String {
        let markers = (isHiDPI ? "↑" : "") + (isVirtual ? "✦" : "")
        return "\(height)p" + (markers.isEmpty ? "" : " " + markers)
    }
}

struct DisplayInfo: Identifiable, Hashable {
    let id: String                          // Bonjour service name / device name
    let name: String
    let isConnected: Bool                   // true = currently active (in NSScreen.screens)
    let cgDisplayID: CGDirectDisplayID      // 0 when not connected
    /// True when this display replicates another user-visible display. A display driven
    /// through one of DAM's virtual anchors is technically a mirror slave too, but it shows
    /// its own desktop, so it counts as extended here.
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
    /// The online display IDs at the last merge; nil before the first.
    private var previousOnlineIDs: Set<CGDirectDisplayID>?
    /// Displays that came online since the first merge and have not yet been matched to
    /// an AirPlay device. Bonjour may resolve a display's name only after it is connected,
    /// so a connect is recognised whenever its ID is first matched, not when the name
    /// changes state.
    private var pendingConnectIDs: Set<CGDirectDisplayID> = []
    /// All physically connected non-AirPlay screens, regardless of visibility preference.
    private(set) var allConnectedDisplays: [DisplayInfo] = []

    /// AirPlay destinations filtered by VisibilityPreferences — used by the menu and Touch Bar.
    @Published private(set) var airPlayDevices: [DisplayInfo] = []
    /// Physical displays filtered by VisibilityPreferences — used by the menu and Touch Bar.
    @Published private(set) var connectedDisplays: [DisplayInfo] = []

    private var browser: NWBrowser?
    private var discoveredNames: Set<String> = []
    /// The pending re-read of the display list after a display configuration change.
    private var reconfigureWork: DispatchWorkItem?
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
    /// Display layout captured just before each anchor was created, keyed like the above.
    var virtualAnchorArrangements: [String: DisplayArrangement] = [:]

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
        observeDisplayChanges()
    }

    /// Re-check which discovered devices are currently connected.
    func refresh() {
        mergeDevices()
    }

    /// Re-reads the display list whenever the display configuration changes, so a mirror
    /// or extend made anywhere — System Settings, Control Center, a slow AirPlay
    /// reconfigure — reaches the menu and Touch Bar without waiting for them to be opened.
    private func observeDisplayChanges() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, userInfo in
            // The callback fires once before a change and once after it; act on the latter.
            guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }
            let manager = Unmanaged<VideoManager>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async { manager.scheduleMergeAfterReconfiguration() }
        }, context)
    }

    /// Coalesces the burst of callbacks one change produces into a single merge, once the
    /// configuration has had a moment to settle.
    private func scheduleMergeAfterReconfiguration() {
        reconfigureWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.mergeDevices()
            // A resolution or arrangement change leaves the display list as it was, yet the
            // menu's and Touch Bar's mode markers need rebuilding; announce a change anyway.
            self?.objectWillChange.send()
        }
        reconfigureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
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

    /// What a mirror toggle did.
    enum MirrorChange {
        case extended
        case mirrored(slave: String)
    }

    enum MirrorError: LocalizedError {
        case notConnected
        case noOtherDisplay
        case configuration(CGError)

        var errorDescription: String? {
            switch self {
            case .notConnected:   return "The display is not connected"
            case .noOtherDisplay: return "No other display to mirror"
            case .configuration:  return "The display change failed"
            }
        }
    }

    /// True if any online display is currently mirroring `display`
    /// (i.e. `display` is the master in a mirror set).
    func isBeingMirrored(_ display: DisplayInfo) -> Bool {
        guard display.cgDisplayID != 0 else { return false }
        return !slaves(of: display.cgDisplayID).isEmpty
    }

    /// Whether `display` is in a mirror set with another user-visible display right now,
    /// read live rather than from the snapshot a menu or button was built from.
    func isInMirrorSet(_ display: DisplayInfo) -> Bool {
        guard display.cgDisplayID != 0 else { return false }
        return userMirrorMaster(of: display.cgDisplayID) != nil || isBeingMirrored(display)
    }

    /// The display `cgID` mirrors, unless it mirrors nothing or one of DAM's virtual anchors.
    func userMirrorMaster(of cgID: CGDirectDisplayID) -> CGDirectDisplayID? {
        Self.userMirrorMaster(CGDisplayMirrorsDisplay(cgID), anchorIDs: Set(virtualAnchorCGIDs.values))
    }

    /// `master` as reported by CoreGraphics, unless it is nothing or one of DAM's anchors.
    static func userMirrorMaster(_ master: CGDirectDisplayID,
                                 anchorIDs: Set<CGDirectDisplayID>) -> CGDirectDisplayID? {
        master != CGDirectDisplayID(0) && !anchorIDs.contains(master) ? master : nil
    }

    private func slaves(of cgID: CGDirectDisplayID) -> [CGDirectDisplayID] {
        DisplayArrangement.onlineDisplayIDs().filter { CGDisplayMirrorsDisplay($0) == cgID }
    }

    /// What toggling mirroring does for a display, decided from the live mirror state.
    enum MirrorPlan: Equatable {
        /// The display mirrors another user display: extend it.
        case extendSelf
        /// Other displays mirror it: extend them.
        case extendSlaves([CGDirectDisplayID])
        /// Nothing user-visible mirrors it: make `target` mirror it.
        case mirror(target: DisplayInfo)
        case noOtherDisplay
    }

    /// Decides the toggle for display `id`, which mirrors `master` (0 for nothing) and is
    /// mirrored by `slaves`. `anchorIDs` are DAM's virtual anchors, which do not count as
    /// mirroring. `candidates` are the displays that may be made to mirror it, in order.
    static func mirrorPlan(for id: CGDirectDisplayID, master: CGDirectDisplayID,
                           slaves: [CGDirectDisplayID], anchorIDs: Set<CGDirectDisplayID>,
                           candidates: [DisplayInfo]) -> MirrorPlan {
        if userMirrorMaster(master, anchorIDs: anchorIDs) != nil { return .extendSelf }
        if !slaves.isEmpty { return .extendSlaves(slaves) }
        guard let target = candidates.first(where: { $0.cgDisplayID != 0 && $0.cgDisplayID != id }) else {
            return .noOtherDisplay
        }
        return .mirror(target: target)
    }

    /// The displays to extend so that none of `ids` is left in a user mirror set: each of
    /// them that mirrors a user display, and every display mirroring one of them.
    static func displaysToExtend(freeing ids: [CGDirectDisplayID],
                                 masterOf: (CGDirectDisplayID) -> CGDirectDisplayID,
                                 slavesOf: (CGDirectDisplayID) -> [CGDirectDisplayID],
                                 anchorIDs: Set<CGDirectDisplayID>) -> Set<CGDirectDisplayID> {
        var toExtend = Set<CGDirectDisplayID>()
        for id in ids {
            if userMirrorMaster(masterOf(id), anchorIDs: anchorIDs) != nil { toExtend.insert(id) }
            toExtend.formUnion(slavesOf(id))
        }
        return toExtend
    }

    /// Toggles the mirror relationship, reading the current state live:
    ///
    /// - If `display` mirrors another user-visible display: extends it to its own screen.
    /// - If other displays mirror `display`: extends them.
    /// - Otherwise: makes the first other connected display mirror `display`. A virtual
    ///   anchor on either display is released first, and any mirror set the other display
    ///   is already in is dissolved in its own transaction, since adding to an existing set
    ///   can fail silently.
    ///
    /// `completion` runs on the main queue once the change is committed and the display
    /// list re-read, or with the reason the change could not be made.
    func toggleMirroring(for display: DisplayInfo,
                         completion: ((Result<MirrorChange, MirrorError>) -> Void)? = nil) {
        let finish: (Result<MirrorChange, MirrorError>) -> Void = { result in
            if case .failure(let error) = result {
                mirrorLog.error("toggleMirroring '\(display.name)': \(String(describing: error))")
            }
            completion?(result)
        }
        guard display.cgDisplayID != 0 else { return finish(.failure(.notConnected)) }
        let id = display.cgDisplayID
        let plan = Self.mirrorPlan(for: id, master: CGDisplayMirrorsDisplay(id), slaves: slaves(of: id),
                                   anchorIDs: Set(virtualAnchorCGIDs.values),
                                   candidates: allConnectedDisplays + allAirPlayDevices)
        switch plan {
        case .extendSelf:
            mirrorLog.debug("toggleMirroring: extending slave \(id)")
            commitDisplayChange({ CGConfigureDisplayMirrorOfDisplay($0, id, CGDirectDisplayID(0)) }) {
                finish($0.map { .extended })
            }
        case .extendSlaves(let mirroringThis):
            mirrorLog.debug("toggleMirroring: extending slaves \(mirroringThis) of \(id)")
            commitDisplayChange({ cfg in
                for slave in mirroringThis { CGConfigureDisplayMirrorOfDisplay(cfg, slave, CGDirectDisplayID(0)) }
            }) { finish($0.map { .extended }) }
        case .noOtherDisplay:
            finish(.failure(.noOtherDisplay))
        case .mirror(let target):
            mirrorLog.debug("toggleMirroring: mirroring \(target.cgDisplayID) onto \(id)")
            releaseVirtualAnchors(for: [display, target]) { [weak self] in
                guard let self else { return }
                self.dissolveMirrorSets(of: [id, target.cgDisplayID]) { result in
                    if case .failure(let error) = result { return finish(.failure(error)) }
                    self.commitDisplayChange({ CGConfigureDisplayMirrorOfDisplay($0, target.cgDisplayID, id) }) {
                        finish($0.map { .mirrored(slave: target.name) })
                    }
                }
            }
        }
    }

    /// Releases the virtual anchor of each display in `displays` that has one, one after
    /// another, then calls `completion` on the main queue.
    private func releaseVirtualAnchors(for displays: [DisplayInfo], completion: @escaping () -> Void) {
        guard let next = displays.first(where: { hasVirtualAnchor(for: $0.name) }) else { return completion() }
        disableVirtualAnchor(for: next) { [weak self] in
            guard let self else { return }
            self.releaseVirtualAnchors(for: displays.filter { $0.id != next.id }, completion: completion)
        }
    }

    /// Takes each display in `ids` out of whatever user mirror set it is in, as a slave or
    /// as a master, in one transaction, then waits for the change to settle. Calls
    /// `completion` at once when none of them is in a set.
    private func dissolveMirrorSets(of ids: [CGDirectDisplayID],
                                    completion: @escaping (Result<Void, MirrorError>) -> Void) {
        let toExtend = Self.displaysToExtend(freeing: ids, masterOf: { CGDisplayMirrorsDisplay($0) },
                                             slavesOf: slaves(of:), anchorIDs: Set(virtualAnchorCGIDs.values))
        guard !toExtend.isEmpty else { return completion(.success(())) }
        mirrorLog.debug("dissolveMirrorSets: extending \(toExtend) first")
        commitDisplayChange({ cfg in
            for id in toExtend { CGConfigureDisplayMirrorOfDisplay(cfg, id, CGDirectDisplayID(0)) }
        }, settle: 1.0, completion: completion)
    }

    /// Runs `configure` in one display configuration transaction. The commit can block for
    /// seconds, so it runs off the main queue; once it is done and `settle` has passed, the
    /// display list is re-read and `completion` runs on the main queue with the result.
    private func commitDisplayChange(_ configure: (CGDisplayConfigRef) -> Void,
                                     settle: TimeInterval = 0.5,
                                     completion: @escaping (Result<Void, MirrorError>) -> Void) {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let cfg = config else { return completion(.failure(.configuration(begin))) }
        configure(cfg)
        DispatchQueue.global(qos: .userInitiated).async {
            let err = CGCompleteDisplayConfiguration(cfg, .permanently)
            if err != .success { mirrorLog.error("CompleteDisplayConfiguration err=\(err.rawValue)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
                self?.mergeDevices()
                completion(err == .success ? .success(()) : .failure(.configuration(err)))
            }
        }
    }

    // MARK: - AirPlay

    /// Clicking a connected device in the Screen Mirroring panel toggles it off.
    func disconnectAirPlay(deviceName: String, announcing announcement: String? = nil) {
        connectAirPlay(deviceName: deviceName, announcing: announcement)
    }

    /// Connects (or, for a connected device, disconnects) by driving the Screen Mirroring
    /// panel through the Accessibility API, which needs Accessibility access. A missing
    /// permission, or a panel that could not be driven, is announced rather than failing
    /// silently. `announcement` is announced only once the device was pressed in the
    /// panel and the panel closed again — never for a toggle that failed. `gate` holds
    /// the press until answered (see `ScreenMirroringPanel.Gate`), and `completion`
    /// reports whether the device was pressed.
    func connectAirPlay(deviceName: String, announcing announcement: String? = nil,
                        gate: ScreenMirroringPanel.Gate? = nil,
                        completion: ((Bool) -> Void)? = nil) {
        guard Self.hasAccessibilityAccess(prompting: true) else {
            SpeechSynthesizer.shared.announce(
                "\(AppIdentity.name) needs Accessibility access to connect AirPlay")
            completion?(false)
            return
        }
        ScreenMirroringPanel.toggle(deviceName: deviceName, gate: gate) { [weak self] result in
            switch result {
            case .success:
                if let announcement { SpeechSynthesizer.shared.announce(announcement) }
            case .failure(let error):
                NSLog("\(AppIdentity.name): connectAirPlay failed: \(error)")
                if let text = error.announcement { SpeechSynthesizer.shared.announce(text) }
            }
            if case .success = result { completion?(true) } else { completion?(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.mergeDevices()
            }
        }
    }

    /// Whether the app may script other apps' UI. With `prompting`, macOS offers to open
    /// Accessibility settings when it may not.
    static func hasAccessibilityAccess(prompting: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompting] as CFDictionary)
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
    /// No-op if the display does not mirror another user-visible display.
    func setAsOptimizedDisplay(_ display: DisplayInfo,
                               completion: ((Result<Void, MirrorError>) -> Void)? = nil) {
        guard display.cgDisplayID != 0, let master = userMirrorMaster(of: display.cgDisplayID) else {
            completion?(.success(()))
            return
        }
        commitDisplayChange({ CGConfigureDisplayMirrorOfDisplay($0, master, display.cgDisplayID) }) {
            if case .failure(let error) = $0 {
                mirrorLog.error("setAsOptimizedDisplay '\(display.name)': \(String(describing: error))")
            }
            completion?($0)
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
            guard CGDisplayIsBuiltin(cgID) == 0 else {
                // The built-in panel has no IODisplayConnect entry. It leaves NSScreen while it
                // is a mirror slave yet stays online, so it needs a name to stay listed.
                if CGDisplayMirrorsDisplay(cgID) != 0 { idToName[cgID] = "Built-in Display" }
                continue
            }
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
        if let previous = previousOnlineIDs {
            pendingConnectIDs.formUnion(onlineSet.subtracting(previous))
        }
        pendingConnectIDs.formIntersection(onlineSet)
        previousOnlineIDs = onlineSet

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
            return DisplayInfo(id: name, name: name,
                               isConnected: true, cgDisplayID: cgID,
                               isMirroring: userMirrorMaster(of: cgID) != nil, isBuiltIn: false)
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
            // A mirror slave leaves NSScreen but is still showing a desktop.
            let isConnected = liveIDs.contains(cgID) || CGDisplayMirrorsDisplay(cgID) != CGDirectDisplayID(0)
            physical.append(DisplayInfo(id: isBuiltIn ? "__builtin__" : name,
                                        name: name,
                                        isConnected: isConnected,
                                        cgDisplayID: cgID,
                                        isMirroring: userMirrorMaster(of: cgID) != nil,
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
        // 2. Mirror-slave guard: whatever the display list says, an anchor that some online
        //    display is actively mirroring is doing its job and stays.
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
            virtualAnchorArrangements.removeValue(forKey: name)
        }

        // AirPlay displays whose display came online after the app started. One already
        // connected at the first merge is left as it is.
        let justConnected = newAirPlay.filter { $0.isConnected && pendingConnectIDs.contains($0.cgDisplayID) }
        pendingConnectIDs.subtract(justConnected.map(\.cgDisplayID))

        if allAirPlayDevices    != newAirPlay   { allAirPlayDevices    = newAirPlay   }
        for display in justConnected { applyDefaultVirtualMode(to: display) }
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
