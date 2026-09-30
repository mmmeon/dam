//
//  VideoManager+VirtualAnchor.swift
//
//  Virtual display anchor: creates a CGVirtualDisplay as a mirror master so the
//  physical display can run refresh rates not in its native mode list.
//

import CoreGraphics
import Foundation
import os.log

private let vdLog = Logger(subsystem: AppIdentity.bundleID, category: "VirtualDisplay")

/// Where each online display sat and what it mirrored, captured before an anchor is added.
///
/// When the virtual display appears, WindowServer finds no saved configuration for the new
/// set of displays and applies a default layout — on an AirPlay setup that mirrors the other
/// displays into one set and can move the main display. Anything else pulled into the
/// anchor's mirror set also follows every mode change made on the anchor. We put the rest of
/// the arrangement back whenever we reconfigure the anchor.
struct DisplayArrangement {
    let origins: [CGDirectDisplayID: CGPoint]
    let mirrorMasters: [CGDirectDisplayID: CGDirectDisplayID]

    static func current() -> DisplayArrangement {
        var origins: [CGDirectDisplayID: CGPoint] = [:]
        var masters: [CGDirectDisplayID: CGDirectDisplayID] = [:]
        for id in onlineDisplayIDs() {
            origins[id] = CGDisplayBounds(id).origin
            masters[id] = CGDisplayMirrorsDisplay(id)
        }
        return DisplayArrangement(origins: origins, mirrorMasters: masters)
    }

    static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: CGDisplayCount = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// Queues changes on `cfg` returning every still-online display — other than those in
    /// `excluded`, or mirroring one of them — to its captured mirror state and position.
    func restore(in cfg: CGDisplayConfigRef, excluding excluded: Set<CGDirectDisplayID>) {
        let online = Set(Self.onlineDisplayIDs())
        for (id, master) in mirrorMasters
        where online.contains(id) && !excluded.contains(id) && !excluded.contains(master) {
            if CGDisplayMirrorsDisplay(id) != master {
                vdLog.debug("restore: display \(id) mirror master \(CGDisplayMirrorsDisplay(id)) → \(master)")
                CGConfigureDisplayMirrorOfDisplay(cfg, id, master)
            }
        }
        for (id, origin) in origins
        where online.contains(id) && !excluded.contains(id) && mirrorMasters[id] == 0
            && CGDisplayBounds(id).origin != origin {
            vdLog.debug("restore: display \(id) origin \(CGDisplayBounds(id).origin.debugDescription) → \(origin.debugDescription)")
            CGConfigureDisplayOrigin(cfg, id, Int32(origin.x), Int32(origin.y))
        }
    }
}

extension VideoManager {

    // MARK: - Public API

    func hasVirtualAnchor(for name: String) -> Bool {
        virtualAnchorStore[name] != nil
    }

    /// Returns the CGDirectDisplayID to use for resolution queries and changes.
    /// When a virtual anchor is active for this display, returns the anchor's ID
    /// (the mirror master) so that resolution changes target the anchor rather than
    /// the physical slave.
    func resolutionControlID(for display: DisplayInfo) -> CGDirectDisplayID {
        virtualAnchorCGIDs[display.name] ?? display.cgDisplayID
    }

    /// Resolutions advertised by an AirPlay virtual anchor, largest first.
    static let virtualResolutions: [(width: Int, height: Int)] =
        [(3840, 2160), (2560, 1440), (1920, 1080), (1280, 720)]

    /// A synthetic mode for the virtual anchor. `ioModeID` is 0; callers match on size and rate.
    /// Pixel dimensions default to the logical ones; pass larger ones for a HiDPI mode.
    static func virtualMode(width: Int, height: Int, refreshRate: Int,
                            pixelWidth: Int? = nil, pixelHeight: Int? = nil) -> DisplayMode {
        let hz = Double(refreshRate)
        let pw = pixelWidth ?? width, ph = pixelHeight ?? height
        let hiDPI = pw > width
        return DisplayMode(id: "\(width)x\(height)@\(hz)\(hiDPI ? "@2x" : "")_virtual",
                           ioModeID: 0,
                           width: width, height: height,
                           pixelWidth: pw, pixelHeight: ph,
                           refreshRate: hz,
                           isHiDPI: hiDPI,
                           isVirtual: true)
    }

    /// Every mode an AirPlay virtual anchor offers for `context`, sorted descending by
    /// resolution (HiDPI first at equal size) then rate. The anchor has HiDPI enabled, so an
    /// advertised resolution that is exactly twice another one also backs a HiDPI mode at
    /// the smaller size (e.g. 2560×1440 backs "1280×720 HiDPI").
    static func virtualModes(for context: VisibilityPreferences.DisplayContext) -> [DisplayMode] {
        let rates = VisibilityPreferences.effectiveVirtualRefreshRates(for: context)
        let advertised = Set(virtualResolutions.map { "\($0.width)x\($0.height)" })
        return virtualResolutions.flatMap { res -> [DisplayMode] in
            let hiDPI = advertised.contains("\(res.width * 2)x\(res.height * 2)")
            let hiDPIModes = hiDPI ? rates.map {
                virtualMode(width: res.width, height: res.height, refreshRate: $0,
                            pixelWidth: res.width * 2, pixelHeight: res.height * 2)
            } : []
            return hiDPIModes + rates.map { virtualMode(width: res.width, height: res.height, refreshRate: $0) }
        }
    }

    /// Which virtual-display settings apply to `display`.
    func displayContext(for display: DisplayInfo) -> VisibilityPreferences.DisplayContext {
        if allAirPlayDevices.contains(where: { $0.id == display.id }) { return .airPlay }
        return display.isBuiltIn ? .builtIn : .external
    }

    /// The display's current mode, split by what drives it. While a virtual anchor is active
    /// only `anchor` is set (nil until the anchor is registered), so native choices are never
    /// marked current; otherwise only `native` is set.
    func currentModes(for display: DisplayInfo) -> (anchor: DisplayMode?, native: DisplayMode?) {
        guard hasVirtualAnchor(for: display.name) else {
            return (nil, currentMode(for: display.cgDisplayID))
        }
        return (virtualAnchorCGIDs[display.name].flatMap { currentMode(for: $0) }, nil)
    }

    /// Index in `modes` of the one that represents the current display state.
    ///
    /// When `anchorCurrent` is provided the virtual anchor is driving the display; only
    /// virtual modes are considered (matched by logical size, HiDPI and rounded rate — the anchor may
    /// report e.g. 119.88 Hz for a 120 Hz mode). Otherwise only native modes are considered
    /// (matched by `ioModeID`). Keeping the two pools separate prevents native `ioModeID`
    /// values from colliding with the anchor's mode ID.
    static func currentModeIndex(in modes: [DisplayMode],
                                 anchorCurrent: DisplayMode?,
                                 nativeCurrent: DisplayMode?) -> Int? {
        if let cur = anchorCurrent {
            return modes.firstIndex {
                $0.isVirtual && $0.width == cur.width && $0.height == cur.height && $0.isHiDPI == cur.isHiDPI
                    && $0.roundedRefreshRate == cur.roundedRefreshRate
            }
        }
        if let cur = nativeCurrent {
            return modes.firstIndex { !$0.isVirtual && $0.ioModeID == cur.ioModeID }
        }
        return nil
    }

    /// Resolution choices for an external or built-in display: one native mode per logical
    /// size (HiDPI preferred), trimmed and ordered by `pickerResolutions`. Each is at the
    /// current refresh rate when the display supports it there, otherwise its highest rate.
    /// `currentIndex` is the entry matching the current logical size — the anchor's while
    /// one is active. `includeLarger1x` adds 1x sizes above the largest HiDPI one (the menu
    /// has room for them; the Touch Bar doesn't).
    func resolutionOptions(for display: DisplayInfo,
                           includeLarger1x: Bool = false) -> (modes: [DisplayMode], currentIndex: Int?) {
        let current = currentModes(for: display).anchor ?? currentMode(for: display.cgDisplayID)
        let all = availableModes(for: display.cgDisplayID)
        // Native size from the one-per-size list: availableModes() de-duplicates by pixel
        // size, so a 1x mode sharing pixels with a HiDPI one (3840×2160 vs 1920×1080 HiDPI)
        // is missing there, and the largest remaining 1x mode can be the wrong shape.
        let perSize = availableModesDeduped(for: display.cgDisplayID)
        var modes = Self.pickerResolutions(perSize, native: Self.nativeSize(of: perSize), current: current,
                                           includeLarger1x: includeLarger1x)
        if let rate = current?.roundedRefreshRate {
            modes = modes.map { best in
                all.first {
                    $0.width == best.width && $0.height == best.height
                        && $0.isHiDPI == best.isHiDPI && $0.roundedRefreshRate == rate
                } ?? best
            }
        }
        let currentIndex = current.flatMap { cur in
            modes.firstIndex { $0.width == cur.width && $0.height == cur.height }
        }
        return (modes, currentIndex)
    }

    /// The panel's native size: its largest 1x mode (HiDPI modes can be backed by more pixels
    /// than the panel has, so they don't count).
    static func nativeSize(of modes: [DisplayMode]) -> (width: Int, height: Int)? {
        modes.filter { !$0.isHiDPI }
            .max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
            .map { ($0.pixelWidth, $0.pixelHeight) }
    }

    /// Trims a one-per-size resolution list for the pickers. Relative to the native panel:
    /// - sizes of a different aspect ratio (beyond 1%) are dropped;
    /// - HiDPI modes backed by more pixels than the panel has (downsampled) are dropped;
    /// - sizes narrower than a third of the panel's pixel width are dropped;
    /// - 1x modes sized between the smallest and largest remaining HiDPI modes are dropped —
    ///   they're upscaled, blurrier versions of a nearby HiDPI size;
    /// - 1x modes whose pixel size backs a HiDPI mode are dropped — the HiDPI mode shows the
    ///   same pixels at a usable UI size (1920×1080 HiDPI replaces 3840×2160) — except that
    ///   1x sizes larger than the largest remaining HiDPI one are kept when `includeLarger1x`
    ///   (and otherwise dropped), so native 4K stays reachable from the menu.
    /// The current resolution is always kept so it can be shown as selected. The result is
    /// ordered by UI size, largest first.
    static func pickerResolutions(_ modes: [DisplayMode], native: (width: Int, height: Int)?,
                                  current: DisplayMode?, includeLarger1x: Bool = false) -> [DisplayMode] {
        func fitsPanel(_ m: DisplayMode) -> Bool {
            guard let native else { return true }
            let ratio = Double(m.width) * Double(native.height) / (Double(m.height) * Double(native.width))
            return abs(ratio - 1) <= 0.01
                && m.pixelWidth <= native.width && m.pixelHeight <= native.height
                && m.width * 3 >= native.width
        }
        let hiDPI = modes.filter { $0.isHiDPI && fitsPanel($0) }
        let hiDPIAreas = hiDPI.map { $0.width * $0.height }
        let hiDPIBackings = Set(modes.filter(\.isHiDPI).map { "\($0.pixelWidth)x\($0.pixelHeight)" })

        return modes.filter { mode in
            if let cur = current, mode.width == cur.width, mode.height == cur.height { return true }
            guard fitsPanel(mode) else { return false }
            if mode.isHiDPI { return true }
            if let smallest = hiDPIAreas.min(), let largest = hiDPIAreas.max() {
                let area = mode.width * mode.height
                if area > largest { return includeLarger1x }
                if area >= smallest { return false }
            }
            return !hiDPIBackings.contains("\(mode.pixelWidth)x\(mode.pixelHeight)")
        }
        // Largest UI size first (the input is ordered by pixel count, which puts 1x modes
        // below HiDPI modes of a smaller size).
        .sorted { ($0.width, $0.height) > ($1.width, $1.height) }
    }

    /// Refresh-rate choices for an external or built-in display, whose resolution is locked
    /// to the current one. Each rate maps to the native mode at that resolution when the panel
    /// supports it, otherwise to a virtual mode routed through the anchor. Sorted highest
    /// rate first. Returns nil when the current resolution can't be read.
    func refreshRateOptions(for display: DisplayInfo)
        -> (resolution: DisplayMode, modes: [DisplayMode])? {
        // While the anchor drives the display it is the source of truth for resolution —
        // the physical display, as a mirror slave, may report a different (scaled) mode.
        let anchorCurrent = currentModes(for: display).anchor
        guard let current = anchorCurrent ?? currentMode(for: display.cgDisplayID) else { return nil }

        var nativeByRate: [Int: DisplayMode] = [:]
        for mode in availableModes(for: display.cgDisplayID)
        where mode.width == current.width && mode.height == current.height {
            if nativeByRate[mode.roundedRefreshRate] == nil { nativeByRate[mode.roundedRefreshRate] = mode }
        }

        let rates = Set(nativeByRate.keys)
            .union(VisibilityPreferences.effectiveVirtualRefreshRates(for: displayContext(for: display)))
            .sorted(by: >)
        let modes = rates.map {
            nativeByRate[$0] ?? Self.virtualMode(width: current.width, height: current.height, refreshRate: $0,
                                                 pixelWidth: current.pixelWidth, pixelHeight: current.pixelHeight)
        }
        return (current, modes)
    }

    /// The default virtual resolution for `context` as a mode the anchor offers: 1x, at
    /// 60 Hz when that rate is enabled, else the highest enabled rate. Nil when none is set.
    static func defaultVirtualMode(for context: VisibilityPreferences.DisplayContext) -> DisplayMode? {
        guard let stored = VisibilityPreferences.defaultVirtualResolution(for: context) else { return nil }
        let size = stored.split(separator: "x").compactMap { Int($0) }
        guard size.count == 2,
              virtualResolutions.contains(where: { $0.width == size[0] && $0.height == size[1] })
        else { return nil }
        let rates = VisibilityPreferences.effectiveVirtualRefreshRates(for: context)
        let rate = rates.contains(60) ? 60 : (rates.first ?? 60)
        return virtualMode(width: size[0], height: size[1], refreshRate: rate)
    }

    /// Drives an AirPlay display that has just connected through a virtual anchor at the
    /// default resolution, when one is set. The display gets a moment to settle first, and
    /// is left alone if it has gone away or gained an anchor meanwhile.
    func applyDefaultVirtualMode(to display: DisplayInfo) {
        let context = displayContext(for: display)
        guard context == .airPlay, let mode = Self.defaultVirtualMode(for: context),
              !hasVirtualAnchor(for: display.name)
        else { return }
        vdLog.debug("applyDefaultVirtualMode: '\(display.name)' connected — \(mode.width)×\(mode.height) @\(mode.refreshRate)Hz in 2 s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self,
                  let current = self.allAirPlayDevices.first(where: { $0.id == display.id }),
                  current.isConnected, current.cgDisplayID != 0,
                  !self.hasVirtualAnchor(for: current.name)
            else { return }
            self.selectVirtualMode(mode, for: current)
        }
    }

    /// Selects a virtual resolution for a display.
    ///
    /// - If the virtual anchor is already active, applies the mode immediately.
    /// - If not yet active, starts the anchor and applies the mode once mirroring is set up.
    func selectVirtualMode(_ mode: DisplayMode, for display: DisplayInfo) {
        if hasVirtualAnchor(for: display.name) {
            guard let anchorID = virtualAnchorCGIDs[display.name] else { return }
            setModeOnVirtualAnchor(mode, anchorID: anchorID, name: display.name, slaveID: display.cgDisplayID)
        } else {
            vdLog.debug("selectVirtualMode: anchor not yet active for '\(display.name)' — enabling anchor, mode applied once mirrored")
            enableVirtualAnchor(for: display, initialMode: mode)
        }
    }

    /// Creates a CGVirtualDisplay as a mirror master for `display`, then polls until
    /// it appears in the system display list and wires up the mirror relationship.
    /// `initialMode`, if given, is applied to the anchor once mirroring is in place.
    func enableVirtualAnchor(for display: DisplayInfo, initialMode: DisplayMode? = nil) {
        guard display.cgDisplayID != 0, !hasVirtualAnchor(for: display.name) else {
            vdLog.debug("enableVirtualAnchor: skipped '\(display.name)' cgID=\(display.cgDisplayID) hasAnchor=\(self.hasVirtualAnchor(for: display.name))")
            return
        }

        let context = displayContext(for: display)
        vdLog.debug("enableVirtualAnchor: starting for '\(display.name)' cgID=\(display.cgDisplayID) context=\(context.rawValue)")

        // For external and built-in displays, lock the virtual anchor to the display's current
        // resolution (including HiDPI backing) so only refresh rate changes are exposed.
        let locked: DisplayMode? = context == .airPlay ? nil : currentMode(for: display.cgDisplayID)

        let descriptor = CGVirtualDisplayDescriptor()
        // Must call setDispatchQueue: — the `queue` property writes a different ivar
        // that the system ignores, causing the virtual display to terminate immediately.
        descriptor.setDispatchQueue(.main)
        descriptor.name = AppIdentity.name
        descriptor.sizeInMillimeters = CGSize(width: 600, height: 340)
        descriptor.maxPixelsWide = UInt32(max(3840, locked?.pixelWidth ?? 0))
        descriptor.maxPixelsHigh = UInt32(max(2160, locked?.pixelHeight ?? 0))
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
                self?.virtualAnchorArrangements.removeValue(forKey: deviceName)
                self?.mergeDevices()
            }
        }

        virtualAnchorArrangements[deviceName] = DisplayArrangement.current()
        let vd = CGVirtualDisplay(descriptor: descriptor)
        vdLog.debug("enableVirtualAnchor: CGVirtualDisplay created — immediate displayID=\(vd.displayID)")

        let settings = CGVirtualDisplaySettings()
        // AirPlay anchors always offer HiDPI variants (see virtualModes(for:)); locked anchors
        // match the display's current mode.
        settings.hiDPI = (locked?.isHiDPI ?? true) ? 1 : 0
        let resolutions: [(width: Int, height: Int)]
        if let cur = locked {
            // A HiDPI lock advertises both the backing and the logical size, so the anchor offers
            // the logical size at 2x backing however the system derives HiDPI variants.
            resolutions = cur.isHiDPI
                ? [(cur.pixelWidth, cur.pixelHeight), (cur.width, cur.height)]
                : [(cur.width, cur.height)]
            vdLog.debug("enableVirtualAnchor: \(context.rawValue) — locking to current resolution \(cur.width)×\(cur.height) (pixels \(cur.pixelWidth)×\(cur.pixelHeight))")
        } else {
            resolutions = Self.virtualResolutions
        }
        let allRates = VisibilityPreferences.effectiveVirtualRefreshRates(for: context)
        settings.modes = resolutions.flatMap { res in
            allRates.map { rate in
                CGVirtualDisplayMode(width: UInt(res.width), height: UInt(res.height), refreshRate: Double(rate))
            }
        }
        vdLog.debug("enableVirtualAnchor: applying \(settings.modes.count) modes (\(allRates) Hz)")

        let applied = vd.apply(settings)
        vdLog.debug("enableVirtualAnchor: applySettings returned \(applied) — displayID after apply=\(vd.displayID)")
        guard applied else {
            vdLog.error("enableVirtualAnchor: applySettings FAILED — aborting")
            return
        }

        // Retain vd so it isn't released before mirroring is wired up.
        virtualAnchorStore[deviceName] = vd
        vdLog.debug("enableVirtualAnchor: stored anchor, beginning poll (attempt 0)")
        waitForVirtualDisplay(vd, name: deviceName, airPlayID: airPlayCGID, context: context,
                              initialMode: initialMode, attempt: 0)
    }

    /// Tears down the mirror, restores the pre-anchor arrangement, and releases the
    /// CGVirtualDisplay for `display`.
    func disableVirtualAnchor(for display: DisplayInfo) {
        guard hasVirtualAnchor(for: display.name) else { return }
        let airPlayCGID = display.cgDisplayID != 0
            ? display.cgDisplayID
            : (cachedAirPlayCGIDs[display.name] ?? 0)
        let anchorID    = virtualAnchorCGIDs.removeValue(forKey: display.name) ?? 0
        let arrangement = virtualAnchorArrangements.removeValue(forKey: display.name)
        // Keep the virtual display alive until the mirror is torn down: destroying the master
        // first leaves its slaves orphaned and lets WindowServer pick a new layout.
        let vd = virtualAnchorStore.removeValue(forKey: display.name)

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.mergeDevices()
            }
            return
        }
        if airPlayCGID != 0 {
            CGConfigureDisplayMirrorOfDisplay(cfg, airPlayCGID, CGDirectDisplayID(0))
        }
        arrangement?.restore(in: cfg, excluding: [anchorID])
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let err = CGCompleteDisplayConfiguration(cfg, .forAppOnly)
            vdLog.debug("disableVirtualAnchor: teardown complete err=\(err.rawValue)")
            DispatchQueue.main.async {
                withExtendedLifetime(vd) {}
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.mergeDevices()
                }
            }
        }
    }

    // MARK: - Private

    /// Polls until the virtual display appears in the system display list, then
    /// wires up the mirror configuration in two steps.
    private func waitForVirtualDisplay(_ vd: CGVirtualDisplay,
                                       name: String,
                                       airPlayID: CGDirectDisplayID,
                                       context: VisibilityPreferences.DisplayContext,
                                       initialMode: DisplayMode?,
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

        // Primary: trust vd.displayID once the system has assigned it.
        // Fallback: vendor/product scan — handles macOS versions where displayID
        // isn't assigned synchronously with CGVirtualDisplay init.
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
                                               context: context, initialMode: initialMode,
                                               attempt: attempt + 1)
                }
            } else {
                vdLog.error("waitForVirtualDisplay: gave up after \(attempt) attempts — removing anchor for '\(name)'")
                virtualAnchorStore.removeValue(forKey: name)
                virtualAnchorArrangements.removeValue(forKey: name)
            }
            return
        }

        virtualAnchorCGIDs[name] = virtualID
        vdLog.debug("waitForVirtualDisplay: virtual display id=\(virtualID) registered for '\(name)'")

        // Step 1: if the target display is already in a mirror set, tear it down first
        // in a separate transaction — adding a slave to an existing set can silently fail.
        // CGCompleteDisplayConfiguration can block for several seconds; run it on a
        // background queue so the Touch Bar and UI stay responsive.
        let existingMirror = CGDisplayMirrorsDisplay(airPlayID)
        vdLog.debug("step1: airPlayID=\(airPlayID) existingMirrorMaster=\(existingMirror)")
        let hadExistingMirror = existingMirror != CGDirectDisplayID(0)
        if hadExistingMirror {
            var teardown: CGDisplayConfigRef?
            let tearErr = CGBeginDisplayConfiguration(&teardown)
            vdLog.debug("step1: BeginDisplayConfiguration err=\(tearErr.rawValue)")
            if tearErr == .success, let tc = teardown {
                CGConfigureDisplayMirrorOfDisplay(tc, airPlayID, CGDirectDisplayID(0))
                DispatchQueue.global(qos: .userInitiated).async {
                    let completeErr = CGCompleteDisplayConfiguration(tc, .forAppOnly)
                    vdLog.debug("step1: teardown complete err=\(completeErr.rawValue) — waiting 1 s before mirror")
                    // Step 2 runs after teardown settles.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        self?.applyMirror(name: name, airPlayID: airPlayID, virtualID: virtualID, initialMode: initialMode)
                    }
                }
                return   // step2 will be chained from the background completion above
            }
        }

        // Step 2 (no prior mirror to tear down): short settle delay then apply.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.applyMirror(name: name, airPlayID: airPlayID, virtualID: virtualID, initialMode: initialMode)
        }
    }

    /// Applies the mirror relationship (airPlay → virtual) and chains step 3.
    /// Called from both the no-prior-mirror path and the post-teardown background path.
    private func applyMirror(name: String, airPlayID: CGDirectDisplayID, virtualID: CGDirectDisplayID,
                             initialMode: DisplayMode?) {
        vdLog.debug("step2: configuring mirror airPlayID=\(airPlayID) → virtualID=\(virtualID)")
        var config: CGDisplayConfigRef?
        let beginErr = CGBeginDisplayConfiguration(&config)
        vdLog.debug("step2: BeginDisplayConfiguration err=\(beginErr.rawValue)")
        guard beginErr == .success, let cfg = config else {
            vdLog.error("step2: BeginDisplayConfiguration failed — aborting")
            return
        }
        // Undo the default layout WindowServer applied when the virtual display appeared,
        // and put the new mirror set where the target display used to be.
        let arrangement = virtualAnchorArrangements[name]
        arrangement?.restore(in: cfg, excluding: [airPlayID, virtualID])
        if let origin = arrangement?.origins[airPlayID] {
            CGConfigureDisplayOrigin(cfg, virtualID, Int32(origin.x), Int32(origin.y))
        }
        // The default layout can make the virtual display a slave of the target; it must be
        // the master.
        if CGDisplayMirrorsDisplay(virtualID) != 0 {
            CGConfigureDisplayMirrorOfDisplay(cfg, virtualID, CGDirectDisplayID(0))
        }
        CGConfigureDisplayMirrorOfDisplay(cfg, airPlayID, virtualID)
        // CGCompleteDisplayConfiguration can block for ~10 s on some systems while the
        // display config settles — run on a background queue to keep the UI responsive.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // .forAppOnly: config reverts automatically when the app exits.
            let mirrorErr = CGCompleteDisplayConfiguration(cfg, .forAppOnly)
            vdLog.debug("step2: CompleteDisplayConfiguration err=\(mirrorErr.rawValue)")
            // Step 3: let the system settle, then refresh the UI on the main queue.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if let initialMode {
                    vdLog.debug("step3: applying initial mode \(initialMode.width)×\(initialMode.height) @\(initialMode.refreshRate)Hz")
                    self?.setModeOnVirtualAnchor(initialMode, anchorID: virtualID, name: name, slaveID: airPlayID)
                }
                vdLog.debug("step3: mergeDevices")
                self?.mergeDevices()
            }
        }
    }

    /// Changes the active mode on the virtual anchor (mirror master).
    ///
    /// Must target the master directly — targeting the slave applies a mode from the
    /// physical panel's native list (e.g. 60 Hz) which mismatches the virtual master's
    /// rate and tears down the mirror.  The "invalid display identifier" noise emitted
    /// by CoreGraphics for the synthetic UUID is cosmetic; the APIs still work.
    ///
    /// Every display in the anchor's mirror set follows the mode change, so any display other
    /// than `slaveID` that ended up mirroring the anchor is first returned to its captured
    /// arrangement (or extended, if there's none) in the same transaction.
    private func setModeOnVirtualAnchor(_ mode: DisplayMode, anchorID: CGDirectDisplayID,
                                        name: String, slaveID: CGDirectDisplayID) {
        guard anchorID != 0 else { return }

        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modeList = CGDisplayCopyAllDisplayModes(anchorID, options) as? [CGDisplayMode] else {
            vdLog.error("setModeOnVirtualAnchor: CGDisplayCopyAllDisplayModes returned nil for \(anchorID)")
            return
        }
        vdLog.debug("setModeOnVirtualAnchor: \(modeList.count) modes on master \(anchorID), seeking \(mode.width)×\(mode.height) (pixels \(mode.pixelWidth)×\(mode.pixelHeight)) @\(mode.refreshRate)Hz")
        for m in modeList { vdLog.debug("  candidate: \(m.width)×\(m.height) (pixels \(m.pixelWidth)×\(m.pixelHeight)) @\(m.refreshRate)Hz") }

        let sameSize: (CGDisplayMode) -> Bool = {
            $0.width == mode.width && $0.height == mode.height
                && $0.pixelWidth == mode.pixelWidth && $0.pixelHeight == mode.pixelHeight
        }
        // Prefer exact size + rate; fall back to size only (the virtual display may report a
        // slightly different rate); last resort for a HiDPI mode the anchor didn't derive is
        // the logical size at 1x.
        let cgMode = modeList.first { sameSize($0) && abs($0.refreshRate - mode.refreshRate) < 1.0 }
            ?? modeList.first(where: sameSize)
            ?? modeList.first {
                $0.pixelWidth == mode.width && $0.pixelHeight == mode.height
                    && abs($0.refreshRate - mode.refreshRate) < 1.0
            }
        if let cgMode, mode.isHiDPI, cgMode.pixelWidth == cgMode.width {
            vdLog.error("setModeOnVirtualAnchor: anchor offers no HiDPI \(mode.width)×\(mode.height) — falling back to 1x")
        }

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
        let strays = DisplayArrangement.onlineDisplayIDs().filter {
            $0 != slaveID && CGDisplayMirrorsDisplay($0) == anchorID
        }
        for id in strays {
            vdLog.debug("setModeOnVirtualAnchor: releasing display \(id) from the anchor's mirror set")
            CGConfigureDisplayMirrorOfDisplay(cfg, id, CGDirectDisplayID(0))
        }
        virtualAnchorArrangements[name]?.restore(in: cfg, excluding: [anchorID, slaveID])
        CGConfigureDisplayWithDisplayMode(cfg, anchorID, cgMode, nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let completeErr = CGCompleteDisplayConfiguration(cfg, .forAppOnly)
            vdLog.debug("setModeOnVirtualAnchor: CompleteDisplayConfiguration err=\(completeErr.rawValue)")
        }
    }
}
