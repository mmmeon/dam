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
private let displayLog = Logger(subsystem: AppIdentity.bundleID, category: "Display")

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

    /// "1920 × 1080"-style label for the resolution pickers, noting HiDPI; virtual sizes get a "✦".
    var resolutionLabel: String {
        "\(width) × \(height)" + (isHiDPI ? "  HiDPI" : "") + (isVirtual ? " ✦" : "")
    }

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
    /// True for the main display: the one with the menu bar, at the origin.
    var isMain: Bool = false
    /// True for an iPad connected over Sidecar. Its `name` is the iPad's name, so the entry
    /// matches the device in the Sidecar section and shares its nickname.
    var isSidecar: Bool = false

    /// What the app shows for this display: its nickname if the user set one, else its name.
    /// `name` stays the identity used to find the display and key its settings.
    var label: String { VisibilityPreferences.nickname(isSidecar ? .sidecar : .display, for: name) ?? name }
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

/// A "Mirror on" pick for `display`: `target` is the display to bring into or take out of
/// its mirror set, or nil for every other display.
struct MirrorSelection {
    let display: DisplayInfo
    let target: DisplayInfo?
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

    /// Returns the names of the iPads currently connected over Sidecar. Asked on every merge,
    /// so a Sidecar display is named after its iPad however the connection was made.
    var connectedSidecarNames: () -> [String] = { [] }

    private var browser: NWBrowser?
    private var discoveredNames: Set<String> = []
    /// The pending re-read of the display list after a display configuration change.
    private var reconfigureWork: DispatchWorkItem?
    /// Each display's mode when the screens went to sleep, put back after they wake.
    private var modesBeforeSleep: [CGDirectDisplayID: ModeShape] = [:]
    /// Remembers the CGDirectDisplayID for each AirPlay device name the last time
    /// it appeared in NSScreen.screens (extend mode). Used to keep tracking the
    /// display when it becomes a mirror slave and drops out of NSScreen.
    var cachedAirPlayCGIDs: [String: CGDirectDisplayID] = [:]
    /// Caches IOKit-derived display names by cgID. Valid for the lifetime of a
    /// cgID — IDs are reassigned on disconnect, so stale entries are never accessed.
    private var ioKitNameCache: [CGDirectDisplayID: String] = [:]
    /// The iPad name last paired with each Sidecar display. SidecarCore can list no connected
    /// iPad for a moment while displays reconfigure; renaming the display then would orphan
    /// its anchor, which is keyed by name.
    private var sidecarNameCache: [CGDirectDisplayID: String] = [:]
    /// Retained CGVirtualDisplay objects keyed by AirPlay device name.
    /// Stored as AnyObject to avoid @available on the stored property.
    var virtualAnchorStore: [String: AnyObject] = [:]
    /// Maps AirPlay device name → the CGDirectDisplayID of its active virtual anchor.
    var virtualAnchorCGIDs: [String: CGDirectDisplayID] = [:]
    /// Display layout captured just before each anchor was created, keyed like the above.
    var virtualAnchorArrangements: [String: DisplayArrangement] = [:]
    /// The display each anchor was made for, keyed like the above.
    var virtualAnchorTargets: [String: CGDirectDisplayID] = [:]
    /// The size each anchor is meant to run at, keyed like the above.
    var virtualAnchorModes: [String: DisplayMode] = [:]
    /// Until when the layout around each newly mirrored anchor is kept, keyed like the above.
    /// WindowServer can re-lay the displays out some seconds after the mirror is committed.
    var virtualAnchorSettleDeadlines: [String: Date] = [:]
    /// Whether sizes were just put back after such a re-layout, so positions follow next.
    var virtualAnchorPositionsPending = false
    /// Whether such a put-back is being committed; later changes wait for the one it causes.
    var virtualAnchorReassertInFlight = false
    /// An iPad's own mode by display, read when its anchor was created. While it mirrors the
    /// anchor the iPad reports the anchor's size instead, so the size choices come from this.
    var sidecarNativeModes: [CGDirectDisplayID: DisplayMode] = [:]
    /// Mirror changes in flight. While any is, iPads are not given anchors: one releases an
    /// iPad's anchor before its commit lands, and re-anchoring in between breaks the new set.
    var sidecarBackingHolds = 0
    /// Displays the user set to mirror an iPad, which DAM wires to the iPad's anchor. Kept
    /// when the anchor is resized, unlike other displays WindowServer adds to its set.
    var anchorSetSlaves: Set<CGDirectDisplayID> = []
    /// Displays to mirror onto an iPad's anchor once it is up, by the iPad's name.
    var anchorPendingSlaves: [String: [CGDirectDisplayID]] = [:]
    /// A stand-in virtual display, created when Sidecar is asked to connect while the Mac has
    /// no display at all, and dropped once the iPad has a display of its own to sit with.
    var bootstrapDisplay: AnyObject?
    var bootstrapDisplayID: CGDirectDisplayID = 0

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
        observeSleepAndWake()
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

    /// A display can come back from sleep at another resolution (its EDID re-read, or
    /// WindowServer re-laying the displays out). Each display's mode is noted as the screens
    /// sleep and put back after they wake: once soon, and once after a later re-layout.
    private func observeSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.modesBeforeSleep = Dictionary(uniqueKeysWithValues: DisplayArrangement.onlineDisplayIDs().compactMap { id in
                CGDisplayCopyDisplayMode(id).map { (id, ModeShape($0)) }
            })
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            for delay in [3.0, 12.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.restoreModesAfterWake() }
            }
        }
    }

    private func restoreModesAfterWake() {
        guard !modesBeforeSleep.isEmpty, !virtualAnchorReassertInFlight else { return }
        var current: [CGDirectDisplayID: ModeShape] = [:]
        var available: [CGDirectDisplayID: [ModeShape: CGDisplayMode]] = [:]
        var skip = Set(virtualAnchorCGIDs.values)
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        for id in DisplayArrangement.onlineDisplayIDs() {
            current[id] = CGDisplayCopyDisplayMode(id).map(ModeShape.init)
            let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
            available[id] = Dictionary(modes.map { (ModeShape($0), $0) }) { first, _ in first }
            if CGDisplayMirrorsDisplay(id) != 0 { skip.insert(id) }
        }
        let restore = Self.modesToRestore(saved: modesBeforeSleep, current: current,
                                          available: available.mapValues { Set($0.keys) }, skip: skip)
        guard !restore.isEmpty else { return }
        displayLog.debug("restoreModesAfterWake: \(restore)")
        commitDisplayChange({ cfg in
            for (id, shape) in restore {
                if let mode = available[id]?[shape] { CGConfigureDisplayWithDisplayMode(cfg, id, mode, nil) }
            }
        }) { result in
            if case .failure(let error) = result {
                displayLog.error("restoreModesAfterWake: \(String(describing: error))")
            }
        }
    }

    /// The displays whose mode differs from the one `saved` for them, with the mode to put
    /// back: only displays still online that still offer it, and none in `skip` (anchors,
    /// whose sizes are kept elsewhere, and mirror slaves, which follow their master).
    static func modesToRestore<Mode: Hashable>(saved: [CGDirectDisplayID: Mode],
                                               current: [CGDirectDisplayID: Mode],
                                               available: [CGDirectDisplayID: Set<Mode>],
                                               skip: Set<CGDirectDisplayID>) -> [CGDirectDisplayID: Mode] {
        saved.filter { id, mode in
            guard !skip.contains(id), let now = current[id], now != mode else { return false }
            return available[id]?.contains(mode) ?? false
        }
    }

    /// What a mode is, as opposed to its ID, which a display can renumber when it comes back.
    struct ModeShape: Hashable {
        let width: Int, height: Int, pixelWidth: Int, pixelHeight: Int
        /// In hundredths of a hertz, so 59.94 and 60 stay apart but rounding noise does not.
        let refreshRate: Int

        init(_ mode: CGDisplayMode) {
            width = mode.width
            height = mode.height
            pixelWidth = mode.pixelWidth
            pixelHeight = mode.pixelHeight
            refreshRate = Int((mode.refreshRate * 100).rounded())
        }
    }

    /// Coalesces the burst of callbacks one change produces into a single merge, once the
    /// configuration has had a moment to settle.
    private func scheduleMergeAfterReconfiguration() {
        reconfigureWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reassertAnchorLayout()
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

    // MARK: - Sidecar displays

    /// The vendor and model CoreGraphics reports for an iPad over Sidecar: "aapl" and "iPad".
    /// AirPlay displays are "aapl" / "airp" (seen 2026-10-04 on an AirPlay TV). Neither has
    /// an IODisplayConnect entry.
    static let sidecarVendorNumber: UInt32 = 0x6161706c
    static let sidecarModelNumber:  UInt32 = 0x69506164
    static let airPlayModelNumber:  UInt32 = 0x61697270

    static func isSidecarDisplay(vendor: UInt32, model: UInt32) -> Bool {
        vendor == sidecarVendorNumber && model == sidecarModelNumber
    }

    static func isAirPlayDisplay(vendor: UInt32, model: UInt32) -> Bool {
        vendor == sidecarVendorNumber && model == airPlayModelNumber
    }

    static func isAirPlayDisplay(_ cgID: CGDirectDisplayID) -> Bool {
        isAirPlayDisplay(vendor: CGDisplayVendorNumber(cgID), model: CGDisplayModelNumber(cgID))
    }

    static func isSidecarDisplay(_ cgID: CGDirectDisplayID) -> Bool {
        isSidecarDisplay(vendor: CGDisplayVendorNumber(cgID), model: CGDisplayModelNumber(cgID))
    }

    /// Pairs each Sidecar display with a connected iPad's name. NSScreen calls every one
    /// "Sidecar Display", so the pairing is by order: display IDs ascending, names sorted.
    /// Exact with one iPad, the usual case. Displays beyond the names are left out.
    static func sidecarNames(displayIDs: [CGDirectDisplayID],
                             deviceNames: [String]) -> [CGDirectDisplayID: String] {
        Dictionary(uniqueKeysWithValues: zip(displayIDs.sorted(), deviceNames.sorted()))
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
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notConnected:   return "The display is not connected"
            case .noOtherDisplay: return "No other display to mirror"
            case .configuration:  return "The display change failed"
            case .timedOut:       return "The display change did not finish"
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
        Self.userMirrorMaster(mirrorMaster(of: cgID), anchorIDs: Set(virtualAnchorCGIDs.values))
    }

    /// The display `cgID` mirrors as CoreGraphics reports it, except that a display mirroring
    /// another display's anchor (the TV in a set with an anchored iPad) mirrors that display.
    func mirrorMaster(of cgID: CGDirectDisplayID) -> CGDirectDisplayID {
        let master = CGDisplayMirrorsDisplay(cgID)
        guard let target = anchorTarget(of: master), target != cgID else { return master }
        return target
    }

    /// The anchored iPad `display` mirrors through the iPad's anchor, if it does.
    func anchoredMaster(of display: DisplayInfo) -> DisplayInfo? {
        guard display.cgDisplayID != 0,
              let target = anchorTarget(of: CGDisplayMirrorsDisplay(display.cgDisplayID)),
              target != display.cgDisplayID else { return nil }
        return (allConnectedDisplays + allAirPlayDevices).first { $0.cgDisplayID == target }
    }

    /// The display the anchor `anchorID` drives, if it is one of DAM's anchors.
    func anchorTarget(of anchorID: CGDirectDisplayID) -> CGDirectDisplayID? {
        guard anchorID != 0, let name = virtualAnchorCGIDs.first(where: { $0.value == anchorID })?.key
        else { return nil }
        return virtualAnchorTargets[name]
    }

    /// The anchor driving `cgID`, if it has one.
    func anchorID(driving cgID: CGDirectDisplayID) -> CGDirectDisplayID? {
        guard cgID != 0, let name = virtualAnchorTargets.first(where: { $0.value == cgID })?.key
        else { return nil }
        return virtualAnchorCGIDs[name]
    }

    /// `master` as reported by CoreGraphics, unless it is nothing or one of DAM's anchors.
    static func userMirrorMaster(_ master: CGDirectDisplayID,
                                 anchorIDs: Set<CGDirectDisplayID>) -> CGDirectDisplayID? {
        master != CGDirectDisplayID(0) && !anchorIDs.contains(master) ? master : nil
    }

    /// The displays mirroring `cgID`, counting those that mirror its anchor.
    private func slaves(of cgID: CGDirectDisplayID) -> [CGDirectDisplayID] {
        let anchor = anchorID(driving: cgID)
        return DisplayArrangement.onlineDisplayIDs().filter {
            $0 != cgID && (CGDisplayMirrorsDisplay($0) == cgID
                || (anchor != nil && CGDisplayMirrorsDisplay($0) == anchor))
        }
    }

    /// The displays that can mirror `display`: every other connected one, built-in first,
    /// then externals by name, then AirPlay.
    func mirrorTargets(for display: DisplayInfo) -> [DisplayInfo] {
        (allConnectedDisplays + allAirPlayDevices).filter {
            $0.cgDisplayID != 0 && $0.cgDisplayID != display.cgDisplayID
        }
    }

    /// The known displays currently mirroring `display`.
    func slaveDisplays(of display: DisplayInfo) -> [DisplayInfo] {
        guard display.cgDisplayID != 0 else { return [] }
        let ids = Set(slaves(of: display.cgDisplayID))
        return mirrorTargets(for: display).filter { ids.contains($0.cgDisplayID) }
    }

    /// The user-visible display `display` mirrors, if any.
    func masterDisplay(of display: DisplayInfo) -> DisplayInfo? {
        guard display.cgDisplayID != 0, let master = userMirrorMaster(of: display.cgDisplayID) else { return nil }
        return mirrorTargets(for: display).first { $0.cgDisplayID == master }
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
        let plan = Self.mirrorPlan(for: id, master: mirrorMaster(of: id), slaves: slaves(of: id),
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
            mirror(display, on: [target]) { finish($0.map { .mirrored(slave: target.name) }) }
        }
    }

    /// Makes exactly `slaves` mirror `display`. A virtual anchor on any of them is released
    /// first, then every mirror set they are in is dissolved in its own transaction (so
    /// slaves of `display` left out of `slaves` end up extended), and the set is built in
    /// one transaction, since adding to an existing set can fail silently.
    func mirror(_ display: DisplayInfo, on slaves: [DisplayInfo],
                completion: ((Result<Void, MirrorError>) -> Void)? = nil) {
        sidecarBackingHolds += 1
        let finish: (Result<Void, MirrorError>) -> Void = { [weak self] result in
            if case .failure(let error) = result {
                mirrorLog.error("mirror '\(display.name)': \(String(describing: error))")
            }
            // WindowServer reports the new set a moment after the commit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.sidecarBackingHolds -= 1 }
            completion?(result)
        }
        guard display.cgDisplayID != 0 else { return finish(.failure(.notConnected)) }
        let id = display.cgDisplayID
        let slaves = slaves.filter { $0.cgDisplayID != 0 && $0.cgDisplayID != id }
        guard !slaves.isEmpty else { return finish(.failure(.noOtherDisplay)) }
        let slaveIDs = slaves.map(\.cgDisplayID)
        // An anchored iPad keeps its anchor, which the others mirror too: releasing it
        // would cost the iPad its sizes, and Sidecar does not hold up without one.
        let keptAnchor = display.isSidecar ? anchorID(driving: id) : nil
        mirrorLog.debug("mirror: \(slaveIDs) onto \(id)\(keptAnchor.map { " via its anchor \($0)" } ?? "")")
        releaseVirtualAnchors(for: (keptAnchor == nil ? [display] : []) + slaves) { [weak self] in
            guard let self else { return }
            self.dissolveMirrorSets(of: [id] + slaveIDs) { result in
                if case .failure(let error) = result { return finish(.failure(error)) }
                let masterID = keptAnchor ?? id
                self.anchorSetSlaves.subtract([id] + slaveIDs)
                if keptAnchor != nil { self.anchorSetSlaves.formUnion(slaveIDs) }
                self.commitDisplayChange({ cfg in
                    for slave in slaveIDs { CGConfigureDisplayMirrorOfDisplay(cfg, slave, masterID) }
                }, completion: finish)
            }
        }
    }

    /// Gives `display` its own desktop: frees it if it mirrors another display, frees its
    /// slaves if others mirror it, and does nothing when it is already extended.
    func extend(_ display: DisplayInfo, completion: ((Result<Void, MirrorError>) -> Void)? = nil) {
        guard display.cgDisplayID != 0 else { completion?(.failure(.notConnected)); return }
        let toExtend = Self.displaysToExtend(freeing: [display.cgDisplayID],
                                             masterOf: { self.mirrorMaster(of: $0) },
                                             slavesOf: slaves(of:), anchorIDs: Set(virtualAnchorCGIDs.values))
        guard !toExtend.isEmpty else { completion?(.success(())); return }
        mirrorLog.debug("extend: freeing \(toExtend)")
        anchorSetSlaves.subtract(toExtend)
        commitDisplayChange({ cfg in
            for id in toExtend { CGConfigureDisplayMirrorOfDisplay(cfg, id, CGDirectDisplayID(0)) }
        }) { completion?($0) }
    }

    // MARK: - Main display

    /// Whether `display` can be made the main display: it shows its own desktop, on its
    /// own or through an anchor, and another display does too.
    func canBeMain(_ display: DisplayInfo) -> Bool {
        guard display.cgDisplayID != 0, userMirrorMaster(of: display.cgDisplayID) == nil else { return false }
        let independent = DisplayArrangement.onlineDisplayIDs().filter { CGDisplayMirrorsDisplay($0) == 0 }
        return independent.count >= 2
    }

    /// The displays that can be made main, as listed: built-in, externals, then AirPlay.
    func mainDisplayCandidates() -> [DisplayInfo] {
        (connectedDisplays + airPlayDevices).filter { canBeMain($0) }
    }

    /// Makes `display` the main display (menu bar, Dock, window origin) by sliding the whole
    /// arrangement so its top-left corner is the origin. A display driven by an anchor is
    /// positioned through the anchor, which owns its set's origin, and the arrangement each
    /// anchor will restore on release is re-based on the display too, so the change outlives it.
    func setMainDisplay(_ display: DisplayInfo, completion: ((Result<Void, MirrorError>) -> Void)? = nil) {
        guard display.cgDisplayID != 0 else { completion?(.failure(.notConnected)); return }
        let master = CGDisplayMirrorsDisplay(display.cgDisplayID)
        let mainID = master != CGDirectDisplayID(0) ? master : display.cgDisplayID
        // An anchor's default layout can have made the display main already; the captured
        // arrangements still need re-basing, or releasing the anchor would undo it.
        let rebase = { [weak self] in
            guard let self else { return }
            for (name, arrangement) in self.virtualAnchorArrangements {
                self.virtualAnchorArrangements[name] = arrangement.makingMain(display.cgDisplayID)
            }
        }
        guard CGDisplayIsMain(mainID) == 0 else { rebase(); completion?(.success(())); return }
        let online  = DisplayArrangement.onlineDisplayIDs()
        let bounds  = Dictionary(uniqueKeysWithValues: online.map { ($0, CGDisplayBounds($0)) })
        let slaves  = Set(online.filter { CGDisplayMirrorsDisplay($0) != CGDirectDisplayID(0) })
        let origins = Self.origins(makingMain: mainID, bounds: bounds, slaves: slaves)
        guard !origins.isEmpty else { completion?(.failure(.notConnected)); return }
        mirrorLog.debug("setMainDisplay: \(mainID) for '\(display.name)'")
        commitDisplayChange({ cfg in
            for (id, origin) in origins {
                CGConfigureDisplayOrigin(cfg, id, Int32(origin.x), Int32(origin.y))
            }
        }) { result in
            if case .failure(let error) = result {
                mirrorLog.error("setMainDisplay '\(display.name)': \(String(describing: error))")
            } else {
                rebase()
            }
            completion?(result)
        }
    }

    /// The origin every display that shows its own desktop gets so that `main` sits at the
    /// origin and the arrangement keeps its shape. Mirror slaves follow their master.
    static func origins(makingMain main: CGDirectDisplayID, bounds: [CGDirectDisplayID: CGRect],
                        slaves: Set<CGDirectDisplayID>) -> [CGDirectDisplayID: CGPoint] {
        guard let shift = bounds[main]?.origin else { return [:] }
        var origins: [CGDirectDisplayID: CGPoint] = [:]
        for (id, rect) in bounds where !slaves.contains(id) {
            origins[id] = CGPoint(x: rect.origin.x - shift.x, y: rect.origin.y - shift.y)
        }
        return origins
    }

    /// Applies a "Mirror on" pick: a target already mirroring the display is taken out of
    /// the set, another is brought in alongside the current slaves, and no target means
    /// every other display.
    func applyMirrorSelection(_ selection: MirrorSelection,
                              completion: ((Result<Void, MirrorError>) -> Void)? = nil) {
        let display = selection.display
        let current = slaveDisplays(of: display)
        guard let target = selection.target else {
            return mirror(display, on: mirrorTargets(for: display), completion: completion)
        }
        if current.contains(where: { $0.id == target.id }) {
            extend(target, completion: completion)
        } else {
            mirror(display, on: current + [target], completion: completion)
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
        let toExtend = Self.displaysToExtend(freeing: ids, masterOf: { self.mirrorMaster(of: $0) },
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
    /// A commit WindowServer has not finished after `timeout` is reported as `.timedOut`
    /// so callers waiting on it carry on; should it finish later, the list is re-read then.
    func commitDisplayChange(_ configure: (CGDisplayConfigRef) -> Void,
                                     settle: TimeInterval = 0.5,
                                     timeout: TimeInterval = 10,
                                     completion: @escaping (Result<Void, MirrorError>) -> Void) {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let cfg = config else { return completion(.failure(.configuration(begin))) }
        configure(cfg)
        // Touched on the main queue only: whichever of the commit and the timeout comes first
        // reports, and the other one does not.
        var reported = false
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard !reported else { return }
            reported = true
            mirrorLog.error("CompleteDisplayConfiguration still running after \(timeout) s")
            completion(.failure(.timedOut))
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let err = CGCompleteDisplayConfiguration(cfg, .permanently)
            if err != .success { mirrorLog.error("CompleteDisplayConfiguration err=\(err.rawValue)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
                self?.mergeDevices()
                guard !reported else { return }
                reported = true
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
        let panelRate = Self.panelRefreshRate(of: cgDisplayID)
        return modeList
            .compactMap { cgMode -> DisplayMode? in
                let w = cgMode.width, h = cgMode.height
                guard w > 1, h > 1 else { return nil }
                let hz = cgMode.refreshRate == 0 ? panelRate : cgMode.refreshRate
                let pw = cgMode.pixelWidth, ph = cgMode.pixelHeight
                let hiDPI = pw > w
                // Logical size too: a 1x 3840×2160 and a 1920×1080 HiDPI share pixels.
                let dedupeKey = "\(w)x\(h)@\(pw)x\(ph)@\(hz)"
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
        let panelRate = Self.panelRefreshRate(of: cgDisplayID)
        for cgMode in modeList {
            let w = cgMode.width, h = cgMode.height
            guard w > 1, h > 1 else { continue }
            let hz = cgMode.refreshRate == 0 ? panelRate : cgMode.refreshRate
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

    /// Each panel's refresh rate, as last seen while it was on screen.
    private static var panelRefreshRates: [CGDirectDisplayID: Double] = [:]

    /// The refresh rate of a display whose modes report none, as built-in panels' do: the
    /// most frames its screen shows a second (120 on a ProMotion panel). A mirror slave
    /// leaves NSScreen, so the rate seen last is kept; 60 when it was never seen.
    static func panelRefreshRate(of cgDisplayID: CGDirectDisplayID) -> Double {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == cgDisplayID
        }
        if let rate = screen?.maximumFramesPerSecond, rate > 0 { panelRefreshRates[cgDisplayID] = Double(rate) }
        return panelRefreshRates[cgDisplayID] ?? 60
    }

    func currentMode(for cgDisplayID: CGDirectDisplayID) -> DisplayMode? {
        guard cgDisplayID != 0,
              let cgMode = CGDisplayCopyDisplayMode(cgDisplayID) else { return nil }
        let w = cgMode.width, h = cgMode.height
        let hz = cgMode.refreshRate == 0 ? Self.panelRefreshRate(of: cgDisplayID) : cgMode.refreshRate
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
        // An iPad without an anchor gets one first, and the set mirrors that, so the iPad
        // keeps its sizes (see anchorPendingSlaves).
        if display.isSidecar, VisibilityPreferences.backsSidecarWithVirtualDisplay,
           !hasVirtualAnchor(for: display.name) {
            let members = [master] + slaves(of: master).filter { $0 != display.cgDisplayID }
            mirrorLog.debug("setAsOptimizedDisplay: anchoring \(display.cgDisplayID) for \(members)")
            // The set is reshaped onto the anchor in the anchor's own mirror transaction,
            // without taking it apart first, so the screens change as few times as possible.
            anchorPendingSlaves[display.name] = members
            enableVirtualAnchor(for: display)
            completion?(.success(()))
            return
        }
        // An anchored iPad's set is wired through its anchor; mirror() takes that apart.
        if anchorID(driving: master) != nil {
            let members = ([master] + slaves(of: master)).filter { $0 != display.cgDisplayID }
            mirrorLog.debug("setAsOptimizedDisplay: \(display.cgDisplayID) replaces anchored \(master)")
            return mirror(display, on: (allConnectedDisplays + allAirPlayDevices).filter {
                members.contains($0.cgDisplayID)
            }, completion: completion)
        }
        // The old master and every other member of the set come to mirror the new master.
        let others = slaves(of: master).filter { $0 != display.cgDisplayID }
        mirrorLog.debug("setAsOptimizedDisplay: \(display.cgDisplayID) replaces \(master); others \(others)")
        commitDisplayChange({ cfg in
            CGConfigureDisplayMirrorOfDisplay(cfg, master, display.cgDisplayID)
            for other in others { CGConfigureDisplayMirrorOfDisplay(cfg, other, display.cgDisplayID) }
        }) {
            if case .failure(let error) = $0 {
                mirrorLog.error("setAsOptimizedDisplay '\(display.name)': \(String(describing: error))")
            }
            completion?($0)
        }
    }

    /// The displays in the user mirror set `display` belongs to, the optimized (master) one
    /// first, or none when it is not in one.
    func mirrorSetMembers(of display: DisplayInfo) -> [DisplayInfo] {
        guard display.cgDisplayID != 0 else { return [] }
        let ids = Self.mirrorSetIDs(of: display.cgDisplayID, masterOf: { self.mirrorMaster(of: $0) },
                                    slavesOf: slaves(of:), anchorIDs: Set(virtualAnchorCGIDs.values))
        let known = allConnectedDisplays + allAirPlayDevices
        return ids.compactMap { id in known.first { $0.cgDisplayID == id } }
    }

    /// The IDs of the user mirror set `id` is in, master first, or none: a set whose master
    /// is one of DAM's anchors is not a user set.
    static func mirrorSetIDs(of id: CGDirectDisplayID,
                             masterOf: (CGDirectDisplayID) -> CGDirectDisplayID,
                             slavesOf: (CGDirectDisplayID) -> [CGDirectDisplayID],
                             anchorIDs: Set<CGDirectDisplayID>) -> [CGDirectDisplayID] {
        let master = userMirrorMaster(masterOf(id), anchorIDs: anchorIDs) ?? id
        let slaves = slavesOf(master)
        guard !slaves.isEmpty else { return [] }
        return [master] + slaves
    }

    /// Sets `mode` on the display. The commit runs off the main queue; `completion` runs on
    /// the main queue once the change has settled.
    func setMode(_ mode: DisplayMode, for cgDisplayID: CGDirectDisplayID,
                 completion: ((Result<Void, MirrorError>) -> Void)? = nil) {
        guard cgDisplayID != 0 else { completion?(.failure(.notConnected)); return }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modeList = CGDisplayCopyAllDisplayModes(cgDisplayID, options) as? [CGDisplayMode],
              let cgMode = modeList.first(where: { $0.ioDisplayModeID == mode.ioModeID }) else {
            completion?(.failure(.configuration(.illegalArgument)))
            return
        }

        // Keep the choice should an anchor's layout be put back afterwards.
        for name in virtualAnchorArrangements.keys { virtualAnchorArrangements[name]?.modes[cgDisplayID] = cgMode }
        commitDisplayChange({ cfg in
            // If this display is currently a mirror slave, promote it to master first
            // ("Optimize for this display") so the resolution change applies to it.
            let masterID = CGDisplayMirrorsDisplay(cgDisplayID)
            if masterID != CGDirectDisplayID(0) {
                CGConfigureDisplayMirrorOfDisplay(cfg, masterID, cgDisplayID)
            }
            CGConfigureDisplayWithDisplayMode(cfg, cgDisplayID, cgMode, nil)
        }, settle: 0.3) { result in
            if case .failure(let error) = result {
                mirrorLog.error("setMode \(cgDisplayID): \(String(describing: error))")
            }
            completion?(result)
        }
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

        // Build a full id → name map, falling back to IOKit for external displays not in NSScreen:
        // their IODisplayConnect service on Intel, their framebuffer on Apple silicon.
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
            } else if let name = displayNameFromIOKit(cgID) ?? DisplayRegistry.productName(for: cgID) {
                ioKitNameCache[cgID] = name
                idToName[cgID] = name
            }
        }

        // Sidecar: NSScreen names an iPad "Sidecar Display", and a mirror slave leaves
        // NSScreen altogether. Name each after its iPad so the entry matches the Sidecar
        // section, falling back to the generic name when SidecarCore lists no iPad for it.
        let sidecarIDs = onlineIDs.filter { Self.isSidecarDisplay($0) }
        if !sidecarIDs.isEmpty {
            let names = Self.sidecarNames(displayIDs: sidecarIDs, deviceNames: connectedSidecarNames())
            for cgID in sidecarIDs {
                if let name = names[cgID] { sidecarNameCache[cgID] = name }
                idToName[cgID] = sidecarNameCache[cgID] ?? idToName[cgID] ?? "Sidecar Display"
            }
        }

        // AirPlay: resolve each Bonjour-discovered name to a CGDirectDisplayID.
        //
        // Strategy (in priority order):
        //  1. NSScreen name match — reliable in extend mode and software-mirror mode.
        //  2. Cached ID from a prior extend-mode observation, still online — handles the
        //     hardware-mirror-slave case where NSScreen drops the display.
        //  3. Unnamed AirPlay displays — online displays with no name, reporting vendor
        //     "aapl" and product "airp". Match unresolved Bonjour names to these displays.
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

        // Pass 2: match unresolved names to unnamed AirPlay displays, which slipped past
        // NSScreen and the cache. Only displays reporting AirPlay's vendor and model count,
        // so a monitor left without a name is never taken for one.
        if !unresolvedNames.isEmpty {
            let resolvedSet = Set(resolvedIDs.values)
            let virtualIDs = onlineIDs.filter {
                Self.isAirPlayDisplay($0) && idToName[$0] == nil && !resolvedSet.contains($0)
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
                               isMirroring: userMirrorMaster(of: cgID) != nil, isBuiltIn: false,
                               isMain: CGDisplayIsMain(cgID) != 0)
        }

        // Physical: all online displays not in the Bonjour list.
        // Includes the built-in panel when the lid is open (it appears in NSScreen
        // and therefore idToName). Absent in clamshell mode, which is correct.
        let airPlayIDs = Set(newAirPlay.map(\.cgDisplayID))
        var anchorIDs  = Set(virtualAnchorCGIDs.values)
        if bootstrapDisplayID != 0 { anchorIDs.insert(bootstrapDisplayID) }

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
                                        isBuiltIn: isBuiltIn,
                                        isMain: CGDisplayIsMain(cgID) != 0,
                                        isSidecar: sidecarIDs.contains(cgID)))
        }
        // Built-in first, then external sorted by name.
        let newPhysical = physical.sorted { l, r in
            if l.isBuiltIn != r.isBuiltIn { return l.isBuiltIn }
            return l.name < r.name
        }

        // Release virtual anchors whose display is no longer connected.
        //
        // Three guards protect live anchors from being prematurely torn down (the third is
        // below):
        //
        // 1. Poll-in-progress guard: if waitForVirtualDisplay hasn't yet written
        //    virtualAnchorCGIDs[name], the anchor is still being established — skip it.
        //
        // 2. Mirror-slave guard: whatever the display list says, an anchor that some online
        //    display is actively mirroring is doing its job and stays.
        renameSidecarAnchors(for: newPhysical)
        let connectedDisplayNames = Set(
            newAirPlay.filter { $0.isConnected }.map { $0.name } +
            newPhysical.filter { $0.isConnected }.map { $0.name }
        )
        for name in Array(virtualAnchorStore.keys) where !connectedDisplayNames.contains(name) {
            guard let anchorID = virtualAnchorCGIDs[name] else { continue }   // guard 1: still polling
            // Guard 2: keep the anchor alive while a physical slave is mirroring it.
            if onlineIDs.contains(where: { CGDisplayMirrorsDisplay($0) == anchorID }) { continue }
            // Guard 3: or while the display it was made for is online. While the mirror is
            // being wired that display can drop out of NSScreen before it shows as a slave.
            if let target = virtualAnchorTargets[name], onlineIDs.contains(target) { continue }
            virtualAnchorTargets.removeValue(forKey: name)
            virtualAnchorStore.removeValue(forKey: name)
            virtualAnchorCGIDs.removeValue(forKey: name)
            virtualAnchorArrangements.removeValue(forKey: name)
            virtualAnchorModes.removeValue(forKey: name)
            virtualAnchorSettleDeadlines.removeValue(forKey: name)
        }

        // AirPlay displays whose display came online after the app started. One already
        // connected at the first merge is left as it is.
        let justConnected = newAirPlay.filter { $0.isConnected && pendingConnectIDs.contains($0.cgDisplayID) }
        pendingConnectIDs.subtract(justConnected.map(\.cgDisplayID))
        pendingConnectIDs.subtract(newPhysical.filter(\.isSidecar).map(\.cgDisplayID))

        if allAirPlayDevices    != newAirPlay   { allAirPlayDevices    = newAirPlay   }
        for display in justConnected { applyDefaultVirtualMode(to: display) }
        if allConnectedDisplays != newPhysical  { allConnectedDisplays = newPhysical  }
        // Every iPad on Sidecar without an anchor, not only one that has just come up: one
        // already connected when the app started, or whose anchor a mirror change released,
        // would otherwise shut off once the other displays go.
        for display in newPhysical where display.isSidecar && display.isConnected { backSidecarDisplay(display) }
        releaseBootstrapDisplayIfDone(displays: newPhysical)
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
