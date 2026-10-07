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
/// the arrangement back whenever we reconfigure the anchor. The default layout can also
/// change other displays' resolutions; those are put back once, when the anchor is wired up.
struct DisplayArrangement {
    let origins: [CGDirectDisplayID: CGPoint]
    let mirrorMasters: [CGDirectDisplayID: CGDirectDisplayID]
    var modes: [CGDirectDisplayID: CGDisplayMode] = [:]

    static func current() -> DisplayArrangement {
        var origins: [CGDirectDisplayID: CGPoint] = [:]
        var masters: [CGDirectDisplayID: CGDirectDisplayID] = [:]
        var modes: [CGDirectDisplayID: CGDisplayMode] = [:]
        for id in onlineDisplayIDs() {
            origins[id] = CGDisplayBounds(id).origin
            masters[id] = CGDisplayMirrorsDisplay(id)
            modes[id] = CGDisplayCopyDisplayMode(id)
        }
        return DisplayArrangement(origins: origins, mirrorMasters: masters, modes: modes)
    }

    /// The same arrangement with display `id` (or, if it was a mirror slave, its master) at
    /// the origin, so that restoring it keeps a change of main display made meanwhile.
    func makingMain(_ id: CGDirectDisplayID) -> DisplayArrangement {
        let master = mirrorMasters[id] ?? 0
        guard let origin = origins[master != 0 ? master : id] else { return self }
        return DisplayArrangement(origins: origins.mapValues { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) },
                                  mirrorMasters: mirrorMasters, modes: modes)
    }

    /// The same arrangement with the displays in `new` at those origins, so that restoring
    /// it keeps an arrangement made meanwhile.
    func replacingOrigins(_ new: [CGDirectDisplayID: CGPoint]) -> DisplayArrangement {
        DisplayArrangement(origins: origins.merging(new.filter { origins[$0.key] != nil }) { $1 },
                           mirrorMasters: mirrorMasters, modes: modes)
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
    /// Returns whether anything was out of place.
    @discardableResult
    func restore(in cfg: CGDisplayConfigRef, excluding excluded: Set<CGDirectDisplayID>) -> Bool {
        let online = Set(Self.onlineDisplayIDs())
        var changed = false
        for (id, master) in mirrorMasters
        where online.contains(id) && !excluded.contains(id) && !excluded.contains(master) {
            if CGDisplayMirrorsDisplay(id) != master {
                vdLog.debug("restore: display \(id) mirror master \(CGDisplayMirrorsDisplay(id)) → \(master)")
                CGConfigureDisplayMirrorOfDisplay(cfg, id, master)
                changed = true
            }
        }
        return restoreOrigins(in: cfg, excluding: excluded) || changed
    }

    /// Queues changes on `cfg` returning every still-online display that showed its own
    /// desktop — other than those in `excluded` — to its captured resolution. Returns whether
    /// any display had another one.
    @discardableResult
    func restoreModes(in cfg: CGDisplayConfigRef, excluding excluded: Set<CGDirectDisplayID>) -> Bool {
        let online = Set(Self.onlineDisplayIDs())
        var changed = false
        for (id, mode) in modes
        where online.contains(id) && !excluded.contains(id) && mirrorMasters[id] == 0
            && CGDisplayCopyDisplayMode(id)?.ioDisplayModeID != mode.ioDisplayModeID {
            vdLog.debug("restore: display \(id) mode → \(mode.width)×\(mode.height)")
            CGConfigureDisplayWithDisplayMode(cfg, id, mode, nil)
            changed = true
        }
        return changed
    }

    /// Queues changes on `cfg` returning every still-online display that showed its own
    /// desktop — other than those in `excluded` — to its captured position. Returns whether
    /// any display was out of place.
    @discardableResult
    func restoreOrigins(in cfg: CGDisplayConfigRef, excluding excluded: Set<CGDirectDisplayID>) -> Bool {
        let online = Set(Self.onlineDisplayIDs())
        var moved = false
        for (id, origin) in origins
        where online.contains(id) && !excluded.contains(id) && mirrorMasters[id] == 0
            && CGDisplayBounds(id).origin != origin {
            vdLog.debug("restore: display \(id) origin \(CGDisplayBounds(id).origin.debugDescription) → \(origin.debugDescription)")
            CGConfigureDisplayOrigin(cfg, id, Int32(origin.x), Int32(origin.y))
            moved = true
        }
        return moved
    }

    /// Puts the captured positions back once more, permanently, after the display set has
    /// changed. Releasing an anchor shrinks the set, and WindowServer then applies the layout
    /// it last saved for that smaller set, which can undo a main display chosen meanwhile.
    func reapplyOriginsPermanently() {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return }
        guard restoreOrigins(in: cfg, excluding: []) else {
            CGCancelDisplayConfiguration(cfg)
            return
        }
        vdLog.debug("reapply: positions differ from the captured arrangement; committing them")
        DispatchQueue.global(qos: .userInitiated).async {
            let err = CGCompleteDisplayConfiguration(cfg, .permanently)
            vdLog.debug("reapply: CompleteDisplayConfiguration err=\(err.rawValue)")
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
        // Native size from every mode: a one-per-size list that prefers HiDPI loses the 1x
        // mode at a size that also has a downsampled HiDPI one (a 1080p panel offering
        // 1920×1080 HiDPI backed by 3840×2160), and the largest remaining 1x mode can be
        // the wrong shape.
        // An iPad in a mirror set also lists the set's size as a 1x mode, which can be larger
        // than the iPad and the wrong shape; its own mode gives the native size instead.
        let native = display.isSidecar
            ? sidecarNativeMode(for: display.cgDisplayID).map { ($0.pixelWidth, $0.pixelHeight) }
            : Self.nativeSize(of: all)
        let perSize = Self.onePerSize(all, native: native)
        var modes = Self.pickerResolutions(perSize, native: native, current: current,
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

    /// One mode per logical size, at its highest rate: HiDPI when the panel has the pixels
    /// for it, else 1x, else a downsampled HiDPI mode. Ordered by pixel count, largest first.
    static func onePerSize(_ modes: [DisplayMode], native: (width: Int, height: Int)?) -> [DisplayMode] {
        func rank(_ m: DisplayMode) -> Int {
            guard m.isHiDPI else { return 1 }
            guard let native else { return 2 }
            return m.pixelWidth <= native.width && m.pixelHeight <= native.height ? 2 : 0
        }
        var best: [String: DisplayMode] = [:]
        for mode in modes {
            let key = "\(mode.width)x\(mode.height)"
            if let existing = best[key],
               (rank(existing), existing.refreshRate) >= (rank(mode), mode.refreshRate) { continue }
            best[key] = mode
        }
        return best.values.sorted { ($0.pixelWidth, $0.pixelHeight) > ($1.pixelWidth, $1.pixelHeight) }
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
        where mode.width == current.width && mode.height == current.height
            && mode.pixelWidth == current.pixelWidth && mode.pixelHeight == current.pixelHeight {
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

    /// Resolution choices for an AirPlay display, native and virtual kept apart, each
    /// size listed once at the current refresh rate when it has one there. `current` gives
    /// the index of the size in effect, in the pool that drives the display.
    func airPlayResolutionOptions(for display: DisplayInfo)
        -> (native: [DisplayMode], virtual: [DisplayMode], current: (native: Int?, virtual: Int?)) {
        let current = currentModes(for: display)
        return Self.airPlayResolutionOptions(nativePerSize: availableModesDeduped(for: display.cgDisplayID),
                                             nativeAll: availableModes(for: display.cgDisplayID),
                                             virtual: Self.virtualModes(for: .airPlay),
                                             anchorCurrent: current.anchor, nativeCurrent: current.native)
    }

    /// Pure core of `airPlayResolutionOptions(for:)`. A native size takes the current rate
    /// when the display offers it at that size, else its highest; a virtual size takes the
    /// current rate when enabled, else 60 Hz, else its highest.
    static func airPlayResolutionOptions(nativePerSize: [DisplayMode], nativeAll: [DisplayMode],
                                         virtual: [DisplayMode],
                                         anchorCurrent: DisplayMode?, nativeCurrent: DisplayMode?)
        -> (native: [DisplayMode], virtual: [DisplayMode], current: (native: Int?, virtual: Int?)) {
        func sameSize(_ a: DisplayMode, _ b: DisplayMode) -> Bool {
            a.width == b.width && a.height == b.height && a.isHiDPI == b.isHiDPI
        }
        let rate = (anchorCurrent ?? nativeCurrent)?.roundedRefreshRate

        let native = nativePerSize.map { best in
            nativeAll.first { sameSize($0, best) && $0.roundedRefreshRate == rate } ?? best
        }

        var sizes: [DisplayMode] = []
        for mode in virtual where !sizes.contains(where: { sameSize($0, mode) }) { sizes.append(mode) }
        let virtualSizes = sizes.map { size in
            let atSize = virtual.filter { sameSize($0, size) }
            return atSize.first { $0.roundedRefreshRate == rate }
                ?? atSize.first { $0.roundedRefreshRate == 60 }
                ?? size
        }

        let nativeIdx = nativeCurrent.flatMap { cur in
            native.firstIndex { $0.width == cur.width && $0.height == cur.height }
        }
        let virtualIdx = anchorCurrent.flatMap { cur in virtualSizes.firstIndex { sameSize($0, cur) } }
        return (native, virtualSizes, (nativeIdx, virtualIdx))
    }

    /// Refresh-rate choices for an AirPlay display at its current resolution: the native
    /// modes at that size and the virtual ones when the anchor offers it. Where both have a
    /// rate, the pool driving the display wins, so changing rate doesn't switch pools.
    /// Sorted highest rate first; empty when the current mode can't be read.
    func airPlayRateOptions(for display: DisplayInfo) -> [DisplayMode] {
        let current = currentModes(for: display)
        return Self.airPlayRateOptions(nativeAll: availableModes(for: display.cgDisplayID),
                                       virtual: Self.virtualModes(for: .airPlay),
                                       anchorCurrent: current.anchor, nativeCurrent: current.native)
    }

    static func airPlayRateOptions(nativeAll: [DisplayMode], virtual: [DisplayMode],
                                   anchorCurrent: DisplayMode?, nativeCurrent: DisplayMode?) -> [DisplayMode] {
        guard let cur = anchorCurrent ?? nativeCurrent else { return [] }
        func atCurrentSize(_ m: DisplayMode) -> Bool {
            m.width == cur.width && m.height == cur.height && m.isHiDPI == cur.isHiDPI
        }
        var nativeByRate: [Int: DisplayMode] = [:]
        // The current native mode first, so a 59.94 Hz mode in use isn't hidden by a 60 Hz one.
        if let nativeCurrent { nativeByRate[nativeCurrent.roundedRefreshRate] = nativeCurrent }
        for mode in nativeAll where atCurrentSize(mode) && nativeByRate[mode.roundedRefreshRate] == nil {
            nativeByRate[mode.roundedRefreshRate] = mode
        }
        var virtualByRate: [Int: DisplayMode] = [:]
        for mode in virtual where atCurrentSize(mode) && virtualByRate[mode.roundedRefreshRate] == nil {
            virtualByRate[mode.roundedRefreshRate] = mode
        }
        let (preferred, other) = anchorCurrent != nil ? (virtualByRate, nativeByRate) : (nativeByRate, virtualByRate)
        return Set(preferred.keys).union(other.keys).sorted(by: >).compactMap { preferred[$0] ?? other[$0] }
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
        if display.isSidecar,
           sidecarResolutionOptions(for: display).modes.contains(where: { $0.width == mode.width && $0.height == mode.height }) {
            VisibilityPreferences.setSidecarResolution("\(mode.width)x\(mode.height)", for: display.name)
        }
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
        // An iPad's anchor instead offers a range of sizes in the iPad's shape, scaled onto it.
        // An iPad in a mirror set runs at the set's size, not its own; its own mode then
        // comes from its mode list (see sidecarNativeMode(for:)).
        if display.isSidecar, CGDisplayMirrorsDisplay(display.cgDisplayID) == 0, let locked {
            sidecarNativeModes[display.cgDisplayID] = locked
        }
        let sidecarModes = display.isSidecar
            ? sidecarNativeMode(for: display.cgDisplayID).map(Self.sidecarVirtualModes(native:)) : nil
        let resolutions: [(width: Int, height: Int)]
        if let sidecarModes {
            var sizes: [(width: Int, height: Int)] = []
            for m in sidecarModes {
                for size in [(m.pixelWidth, m.pixelHeight), (m.width, m.height)]
                where !sizes.contains(where: { $0 == size }) { sizes.append(size) }
            }
            resolutions = sizes
        } else if let cur = locked {
            // A HiDPI lock advertises both the backing and the logical size, so the anchor offers
            // the logical size at 2x backing however the system derives HiDPI variants.
            resolutions = cur.isHiDPI
                ? [(cur.pixelWidth, cur.pixelHeight), (cur.width, cur.height)]
                : [(cur.width, cur.height)]
            vdLog.debug("enableVirtualAnchor: \(context.rawValue) — locking to current resolution \(cur.width)×\(cur.height) (pixels \(cur.pixelWidth)×\(cur.pixelHeight))")
        } else {
            resolutions = Self.virtualResolutions
        }

        let descriptor = CGVirtualDisplayDescriptor()
        // Must call setDispatchQueue: — the `queue` property writes a different ivar
        // that the system ignores, causing the virtual display to terminate immediately.
        descriptor.setDispatchQueue(.main)
        descriptor.name = AppIdentity.name
        descriptor.sizeInMillimeters = CGSize(width: 600, height: 340)
        descriptor.maxPixelsWide = UInt32(max(3840, resolutions.map(\.width).max() ?? 0))
        descriptor.maxPixelsHigh = UInt32(max(2160, resolutions.map(\.height).max() ?? 0))
        descriptor.vendorID  = Self.anchorVendorID
        descriptor.productID = Self.anchorProductID
        descriptor.serialNum = 0x0002
        vdLog.debug("enableVirtualAnchor: descriptor configured — vendor=0x3456 product=0x1234 serial=0x0002 queue=main")

        let airPlayCGID = display.cgDisplayID
        let deviceName  = display.name
        descriptor.terminationHandler = { [weak self] _, vd in
            let assignedID = vd.displayID
            vdLog.debug("terminationHandler: virtual display for '\(deviceName)' terminated (displayID=\(assignedID))")
            DispatchQueue.main.async {
                guard let self else { return }
                // The anchor may have moved to a new name since (see renameSidecarAnchors).
                let name = self.virtualAnchorStore.first(where: { $0.value === vd })?.key ?? deviceName
                self.virtualAnchorStore.removeValue(forKey: name)
                self.virtualAnchorCGIDs.removeValue(forKey: name)
                self.virtualAnchorArrangements.removeValue(forKey: name)
                self.virtualAnchorTargets.removeValue(forKey: name)
                self.virtualAnchorModes.removeValue(forKey: name)
                self.virtualAnchorSettleDeadlines.removeValue(forKey: name)
                self.mergeDevices()
            }
        }

        virtualAnchorArrangements[deviceName] = DisplayArrangement.current()
        virtualAnchorTargets[deviceName] = airPlayCGID
        // The size the anchor will run at, listed first so it comes up at it (or at its backing
        // size, for a HiDPI one) rather than at a size it is switched away from once mirrored.
        let startMode = initialMode ?? (display.isSidecar ? sidecarStartMode(for: airPlayCGID) : nil)
        let isStart = { (r: (width: Int, height: Int)) in
            r.width == startMode?.pixelWidth && r.height == startMode?.pixelHeight
        }
        let orderedResolutions = resolutions.filter(isStart) + resolutions.filter { !isStart($0) }
        let vd = CGVirtualDisplay(descriptor: descriptor)
        vdLog.debug("enableVirtualAnchor: CGVirtualDisplay created — immediate displayID=\(vd.displayID)")

        let settings = CGVirtualDisplaySettings()
        // AirPlay anchors always offer HiDPI variants (see virtualModes(for:)); locked anchors
        // match the display's current mode.
        settings.hiDPI = (sidecarModes != nil || (locked?.isHiDPI ?? true)) ? 1 : 0
        // Sidecar runs at 60 Hz whatever the anchor offers.
        let allRates = sidecarModes != nil ? [60] : VisibilityPreferences.effectiveVirtualRefreshRates(for: context)
        let startRate = startMode?.roundedRefreshRate
        let orderedRates = allRates.filter { $0 == startRate } + allRates.filter { $0 != startRate }
        settings.modes = orderedResolutions.flatMap { res in
            orderedRates.map { rate in
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
    /// CGVirtualDisplay for `display`. `completion` runs on the main queue once the display
    /// list has been re-read afterwards, or at once when there was no anchor.
    func disableVirtualAnchor(for display: DisplayInfo, completion: (() -> Void)? = nil) {
        guard hasVirtualAnchor(for: display.name) else { completion?(); return }
        let airPlayCGID = display.cgDisplayID != 0
            ? display.cgDisplayID
            : (cachedAirPlayCGIDs[display.name] ?? 0)
        let anchorID    = virtualAnchorCGIDs.removeValue(forKey: display.name) ?? 0
        let arrangement = virtualAnchorArrangements.removeValue(forKey: display.name)
        virtualAnchorModes.removeValue(forKey: display.name)
        virtualAnchorSettleDeadlines.removeValue(forKey: display.name)
        // Keep the virtual display alive until the mirror is torn down: destroying the master
        // first leaves its slaves orphaned and lets WindowServer pick a new layout.
        let vd = virtualAnchorStore.removeValue(forKey: display.name)

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.mergeDevices()
                completion?()
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
                    completion?()
                }
                // Once the set has settled without the anchor, put the positions back if
                // WindowServer's saved layout for that set moved them.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    arrangement?.reapplyOriginsPermanently()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.mergeDevices() }
                }
            }
        }
    }

    // MARK: - Sidecar

    /// Vendor and product the anchors and the stand-in display carry. The stand-in has its
    /// own product so the anchor search never mistakes it for a new anchor.
    static let anchorVendorID:      UInt32 = 0x3456
    static let anchorProductID:     UInt32 = 0x1234
    static let bootstrapProductID:  UInt32 = 0x1235

    /// Gives an iPad connected over Sidecar a virtual anchor in its own shape, mirrored onto
    /// it, which also lets it run at other sizes. The Mac then always has a display besides it, so the iPad can be the only one: Sidecar does not come up, or stay
    /// up, as the sole display. Off through Settings.
    /// An iPad the user has put in a mirror set is left alone: the anchor would take it out.
    func backSidecarDisplay(_ display: DisplayInfo) {
        guard VisibilityPreferences.backsSidecarWithVirtualDisplay, display.isSidecar,
              !hasVirtualAnchor(for: display.name), canBack(display.cgDisplayID) else { return }
        vdLog.debug("backSidecarDisplay: '\(display.name)' has no anchor — anchoring in 2 s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, VisibilityPreferences.backsSidecarWithVirtualDisplay,
                  let current = self.allConnectedDisplays.first(where: { $0.isSidecar && $0.name == display.name }),
                  current.cgDisplayID != 0, !self.hasVirtualAnchor(for: current.name),
                  self.canBack(current.cgDisplayID)
            else { return }
            // Its size is chosen once the mirror is wired (see sidecarStartMode(for:)).
            self.enableVirtualAnchor(for: current)
        }
    }

    /// Sizes an iPad's anchor offers, largest UI first: steps of a sixth of the iPad's own
    /// logical width from five sixths (larger text) to ten (more space), in the iPad's shape
    /// and at its scale, at 60 Hz. Sizes whose backing would be wider than 4K are left out.
    static func sidecarVirtualModes(native: DisplayMode) -> [DisplayMode] {
        let scale = max(1, native.pixelWidth / max(1, native.width))
        func even(_ x: Double) -> Int { Int((x / 2).rounded()) * 2 }
        return (5...10).reversed().compactMap { n -> DisplayMode? in
            if n == 6 {
                return virtualMode(width: native.width, height: native.height, refreshRate: 60,
                                   pixelWidth: native.pixelWidth, pixelHeight: native.pixelHeight)
            }
            let w = even(Double(native.width * n) / 6), h = even(Double(native.height * n) / 6)
            guard w * scale <= max(3840, native.pixelWidth) else { return nil }
            return virtualMode(width: w, height: h, refreshRate: 60, pixelWidth: w * scale, pixelHeight: h * scale)
        }
    }

    /// The size an iPad's new anchor starts at: the one last picked for the iPad, else its own.
    /// Looked up by the name the anchor has by then, as the iPad may only have been named
    /// "Sidecar Display" when it was anchored.
    func sidecarStartMode(for cgID: CGDirectDisplayID) -> DisplayMode? {
        guard let native = sidecarNativeMode(for: cgID) else { return nil }
        let modes = Self.sidecarVirtualModes(native: native)
        let name = virtualAnchorTargets.first { $0.value == cgID }?.key
        let stored = name.flatMap(VisibilityPreferences.sidecarResolution(for:))
        return modes.first { "\($0.width)x\($0.height)" == stored }
            ?? modes.first { $0.width == native.width && $0.height == native.height }
    }

    /// An iPad's own mode: the one recorded when DAM anchored it, else the iPad's largest
    /// HiDPI mode as CoreGraphics lists it (an iPad anchored before DAM ran, or whose
    /// display ID changed, has none recorded). Recorded once found.
    func sidecarNativeMode(for cgID: CGDirectDisplayID) -> DisplayMode? {
        if let known = sidecarNativeModes[cgID] { return known }
        let modes = availableModes(for: cgID)
        guard let native = modes.first(where: \.isHiDPI) ?? modes.first else { return nil }
        sidecarNativeModes[cgID] = native
        return native
    }

    /// Resolution choices for an iPad driven by its anchor, and the index of the one in effect.
    func sidecarResolutionOptions(for display: DisplayInfo) -> (modes: [DisplayMode], currentIndex: Int?) {
        let modes = sidecarNativeMode(for: display.cgDisplayID).map(Self.sidecarVirtualModes(native:)) ?? []
        let current = currentModes(for: display).anchor
        let index = current.flatMap { cur in modes.firstIndex { $0.width == cur.width && $0.height == cur.height } }
        return (modes, index)
    }

    /// Files each iPad's anchor under the iPad's current name. A Sidecar display is named
    /// "Sidecar Display" until SidecarCore lists its iPad, which can be after it was anchored.
    func renameSidecarAnchors(for displays: [DisplayInfo]) {
        for display in displays where display.isSidecar && virtualAnchorStore[display.name] == nil {
            guard let old = virtualAnchorTargets.first(where: {
                $0.value == display.cgDisplayID && $0.key != display.name
            })?.key,
                  // Not while it is being set up: that still writes under the old name.
                  virtualAnchorCGIDs[old] != nil
            else { continue }
            vdLog.debug("renameSidecarAnchors: anchor follows the iPad's new name")
            virtualAnchorStore[display.name]        = virtualAnchorStore.removeValue(forKey: old)
            virtualAnchorCGIDs[display.name]        = virtualAnchorCGIDs.removeValue(forKey: old)
            virtualAnchorArrangements[display.name] = virtualAnchorArrangements.removeValue(forKey: old)
            virtualAnchorTargets[display.name]      = virtualAnchorTargets.removeValue(forKey: old)
            virtualAnchorModes[display.name]        = virtualAnchorModes.removeValue(forKey: old)
            virtualAnchorSettleDeadlines[display.name] = virtualAnchorSettleDeadlines.removeValue(forKey: old)
        }
    }

    /// Whether an iPad can be given an anchor now: no mirror change is in flight, it is in no mirror set (one the user made,
    /// or an anchor's own — it already has one, whatever it is called), and no anchor is still
    /// being set up, since that one may be for this iPad. A later merge tries again.
    private func canBack(_ cgID: CGDirectDisplayID) -> Bool {
        sidecarBackingHolds == 0
            && CGDisplayMirrorsDisplay(cgID) == 0
            && !DisplayArrangement.onlineDisplayIDs().contains { CGDisplayMirrorsDisplay($0) == cgID }
            && !virtualAnchorStore.keys.contains { virtualAnchorCGIDs[$0] == nil }
    }

    /// The vendor and model of the display macOS puts up when nothing is attached: "unkn",
    /// "virt".
    static let placeholderVendorNumber: UInt32 = 0x756e6b6e
    static let placeholderModelNumber:  UInt32 = 0x76697274

    /// Whether any of `displays` is one of the Mac's own: not macOS's placeholder, not an iPad
    /// over Sidecar, and not one of DAM's virtual displays.
    static func hasOwnDisplay(_ displays: [(vendor: UInt32, model: UInt32)]) -> Bool {
        displays.contains { d in
            !(d.vendor == placeholderVendorNumber && d.model == placeholderModelNumber)
                && !isSidecarDisplay(vendor: d.vendor, model: d.model)
                && d.vendor != anchorVendorID
        }
    }

    /// Whether the Mac has a display of its own online (see `hasOwnDisplay(_:)`).
    func hasOwnDisplay() -> Bool {
        Self.hasOwnDisplay(DisplayArrangement.onlineDisplayIDs().map {
            (CGDisplayVendorNumber($0), CGDisplayModelNumber($0))
        })
    }

    /// Whether the Mac has no display to show a desktop on, apart from the given virtual ones.
    static func needsBootstrapDisplay(onlineIDs: [CGDirectDisplayID],
                                      virtualIDs: Set<CGDirectDisplayID>) -> Bool {
        !onlineIDs.contains { !virtualIDs.contains($0) }
    }

    /// Makes sure a display exists before Sidecar connects, creating a stand-in virtual one
    /// when the Mac has none. `completion` runs on the main queue once a display is online,
    /// or straight away when one already is; also when the stand-in could not be made, so a
    /// connection is still attempted.
    func ensureDisplayForSidecar(completion: @escaping () -> Void) {
        var virtualIDs = Set(virtualAnchorCGIDs.values)
        if bootstrapDisplayID != 0 { virtualIDs.insert(bootstrapDisplayID) }
        let needed = Self.needsBootstrapDisplay(onlineIDs: DisplayArrangement.onlineDisplayIDs(),
                                                virtualIDs: virtualIDs)
        guard needed, bootstrapDisplay == nil else { return completion() }
        vdLog.debug("ensureDisplayForSidecar: no display online — creating a stand-in")

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(.main)
        descriptor.name = "\(AppIdentity.name) Stand-in"
        descriptor.sizeInMillimeters = CGSize(width: 600, height: 340)
        descriptor.maxPixelsWide = 1920
        descriptor.maxPixelsHigh = 1080
        descriptor.vendorID  = Self.anchorVendorID
        descriptor.productID = Self.bootstrapProductID
        descriptor.serialNum = 0x0003
        descriptor.terminationHandler = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.bootstrapDisplay = nil
                self?.bootstrapDisplayID = 0
                self?.mergeDevices()
            }
        }
        let vd = CGVirtualDisplay(descriptor: descriptor)
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [CGVirtualDisplayMode(width: 1920, height: 1080, refreshRate: 60)]
        guard vd.apply(settings) else {
            vdLog.error("ensureDisplayForSidecar: applySettings failed — connecting without a stand-in")
            return completion()
        }
        bootstrapDisplay = vd
        waitForBootstrapDisplay(vd, attempt: 0, completion: completion)
    }

    private func waitForBootstrapDisplay(_ vd: CGVirtualDisplay, attempt: Int,
                                         completion: @escaping () -> Void) {
        let online = DisplayArrangement.onlineDisplayIDs()
        let id = vd.displayID != 0 && online.contains(vd.displayID)
            ? vd.displayID
            : online.first {
                CGDisplayVendorNumber($0) == Self.anchorVendorID
                    && CGDisplayModelNumber($0) == Self.bootstrapProductID
            } ?? 0
        if id != 0 {
            vdLog.debug("ensureDisplayForSidecar: stand-in online as \(id)")
            bootstrapDisplayID = id
            mergeDevices()
            // Let WindowServer settle on the new display before Sidecar adds another.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: completion)
            return
        }
        guard attempt < 10 else {
            vdLog.error("ensureDisplayForSidecar: stand-in never came online — dropping it")
            bootstrapDisplay = nil
            return completion()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.waitForBootstrapDisplay(vd, attempt: attempt + 1, completion: completion)
        }
    }

    /// Drops the stand-in once the iPad is up and, when it is to be backed, has its anchor;
    /// or when the iPad will not be backed at all.
    func releaseBootstrapDisplayIfDone(displays: [DisplayInfo]) {
        guard bootstrapDisplay != nil else { return }
        let backing = VisibilityPreferences.backsSidecarWithVirtualDisplay
        let settled = displays.contains { display in
            display.isSidecar && display.isConnected
                && (!backing || virtualAnchorCGIDs[display.name] != nil)
        }
        if settled { releaseBootstrapDisplay() }
    }

    /// Drops the stand-in display. The display list is re-read once it has gone.
    func releaseBootstrapDisplay() {
        guard bootstrapDisplay != nil else { return }
        vdLog.debug("releaseBootstrapDisplay: dropping stand-in \(self.bootstrapDisplayID)")
        bootstrapDisplay = nil
        bootstrapDisplayID = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.mergeDevices() }
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
                CGDisplayVendorNumber($0) == Self.anchorVendorID &&
                CGDisplayModelNumber($0) == Self.anchorProductID &&
                !claimedAnchorIDs.contains($0) && $0 != bootstrapDisplayID
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
        // Not when other displays wait to join: step 2 reshapes the whole set onto the
        // anchor in one transaction (see anchorPendingSlaves).
        let hadExistingMirror = existingMirror != CGDirectDisplayID(0) && anchorPendingSlaves[name] == nil
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

    /// The size an anchor is to run at: the one asked for, else for an iPad the one it
    /// starts at. Nil leaves the anchor at its own choice.
    private func anchorStartMode(_ initialMode: DisplayMode?, slaveID: CGDirectDisplayID) -> DisplayMode? {
        initialMode ?? (Self.isSidecarDisplay(slaveID) ? sidecarStartMode(for: slaveID) : nil)
    }

    /// Applies the mirror relationship (airPlay → virtual) and chains step 3.
    /// Called from both the no-prior-mirror path and the post-teardown background path.
    ///
    /// The anchor is set to its starting size in the same transaction, before the target
    /// display follows it, so the target is reconfigured once rather than mirrored at one
    /// size and then switched to another.
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
        // Displays waiting to join the iPad's set mirror the anchor in this same transaction,
        // so the screens are reconfigured once, and are left out of the layout put back.
        let online = Set(DisplayArrangement.onlineDisplayIDs())
        let joining = (anchorPendingSlaves.removeValue(forKey: name) ?? []).filter(online.contains)
        anchorSetSlaves.formUnion(joining)
        let excluded = Set([airPlayID, virtualID] + joining)
        // Undo the default layout WindowServer applied when the virtual display appeared,
        // and put the new mirror set where the target display used to be.
        let arrangement = virtualAnchorArrangements[name]
        arrangement?.restore(in: cfg, excluding: excluded)
        if let origin = arrangement?.origins[airPlayID] {
            CGConfigureDisplayOrigin(cfg, virtualID, Int32(origin.x), Int32(origin.y))
        }
        // The default layout can make the virtual display a slave of the target; it must be
        // the master.
        if CGDisplayMirrorsDisplay(virtualID) != 0 {
            CGConfigureDisplayMirrorOfDisplay(cfg, virtualID, CGDirectDisplayID(0))
        }
        if let startMode = anchorStartMode(initialMode, slaveID: airPlayID) {
            virtualAnchorModes[name] = startMode
        }
        if let startMode = virtualAnchorModes[name],
           !anchorRuns(startMode, anchorID: virtualID),
           let cgMode = anchorDisplayMode(startMode, anchorID: virtualID) {
            vdLog.debug("step2: anchor starts at \(cgMode.width)×\(cgMode.height) (pixels \(cgMode.pixelWidth)×\(cgMode.pixelHeight)) @\(cgMode.refreshRate)Hz")
            CGConfigureDisplayWithDisplayMode(cfg, virtualID, cgMode, nil)
        }
        CGConfigureDisplayMirrorOfDisplay(cfg, airPlayID, virtualID)
        if !joining.isEmpty { vdLog.debug("step2: \(joining) join the set on the anchor") }
        for id in joining { CGConfigureDisplayMirrorOfDisplay(cfg, id, virtualID) }
        // CGCompleteDisplayConfiguration can block for ~10 s on some systems while the
        // display config settles — run on a background queue to keep the UI responsive.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // .forAppOnly: config reverts automatically when the app exits.
            let mirrorErr = CGCompleteDisplayConfiguration(cfg, .forAppOnly)
            vdLog.debug("step2: CompleteDisplayConfiguration err=\(mirrorErr.rawValue)")
            DispatchQueue.main.async {
                self?.virtualAnchorSettleDeadlines[name] = Date().addingTimeInterval(Self.anchorSettleWindow)
            }
            // Step 3: let the system settle, then refresh the UI on the main queue.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.restoreArrangementAfterMirror(name: name, excluding: excluded)
                // Normally set with the mirror already; this catches an iPad renamed meanwhile
                // (its remembered size is filed under the new name) or a mode the commit lost.
                if let self, let mode = self.anchorStartMode(initialMode, slaveID: airPlayID),
                   !self.anchorRuns(mode, anchorID: virtualID) {
                    vdLog.debug("step3: anchor not at \(mode.width)×\(mode.height) @\(mode.refreshRate)Hz — applying it")
                    self.setModeOnVirtualAnchor(mode, anchorID: virtualID, name: name, slaveID: airPlayID)
                }
                vdLog.debug("step3: mergeDevices")
                self?.mergeDevices()
            }
        }
    }

    /// Once the mirror is in place WindowServer can lay the other displays out again, with
    /// another resolution and position; put back what they had before the anchor came.
    private func restoreArrangementAfterMirror(name: String, excluding excluded: Set<CGDirectDisplayID>) {
        guard let arrangement = virtualAnchorArrangements[name] else { return }
        // Positions go back in a second transaction: a resolution change moves the display.
        let commit = { (label: String, queue: (CGDisplayConfigRef) -> Void, then: (() -> Void)?) in
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return }
            queue(cfg)
            DispatchQueue.global(qos: .userInitiated).async {
                let err = CGCompleteDisplayConfiguration(cfg, .forAppOnly)
                vdLog.debug("step3: \(label) restored err=\(err.rawValue)")
                if let then { DispatchQueue.main.async(execute: then) }
            }
        }
        commit("modes", { arrangement.restoreModes(in: $0, excluding: excluded) }) {
            commit("arrangement", { arrangement.restore(in: $0, excluding: excluded) }, nil)
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
        guard anchorID != 0, let cgMode = anchorDisplayMode(mode, anchorID: anchorID) else { return }
        virtualAnchorModes[name] = mode
        vdLog.debug("setModeOnVirtualAnchor: applying \(cgMode.pixelWidth)×\(cgMode.pixelHeight) @\(cgMode.refreshRate)Hz on master \(anchorID)")

        var config: CGDisplayConfigRef?
        let beginErr = CGBeginDisplayConfiguration(&config)
        guard beginErr == .success, let cfg = config else {
            vdLog.error("setModeOnVirtualAnchor: BeginDisplayConfiguration err=\(beginErr.rawValue)")
            return
        }
        let strays = DisplayArrangement.onlineDisplayIDs().filter {
            $0 != slaveID && CGDisplayMirrorsDisplay($0) == anchorID && !anchorSetSlaves.contains($0)
        }
        for id in strays {
            vdLog.debug("setModeOnVirtualAnchor: releasing display \(id) from the anchor's mirror set")
            CGConfigureDisplayMirrorOfDisplay(cfg, id, CGDirectDisplayID(0))
        }
        virtualAnchorArrangements[name]?.restore(in: cfg, excluding: [anchorID, slaveID])
        CGConfigureDisplayWithDisplayMode(cfg, anchorID, cgMode, nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let completeErr = CGCompleteDisplayConfiguration(cfg, .forAppOnly)
            vdLog.debug("setModeOnVirtualAnchor: CompleteDisplayConfiguration err=\(completeErr.rawValue)")
            // A larger anchor can come to overlap a display WindowServer did not move.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.separateOverlappingDisplays() }
        }
    }

    /// The anchor's own mode for `mode`: exact size and rate, else size only (the virtual
    /// display may report a slightly different rate), else — for a HiDPI mode the anchor
    /// didn't derive — the logical size at 1x.
    private func anchorDisplayMode(_ mode: DisplayMode, anchorID: CGDirectDisplayID) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modeList = CGDisplayCopyAllDisplayModes(anchorID, options) as? [CGDisplayMode] else {
            vdLog.error("anchorDisplayMode: CGDisplayCopyAllDisplayModes returned nil for \(anchorID)")
            return nil
        }
        vdLog.debug("anchorDisplayMode: \(modeList.count) modes on master \(anchorID), seeking \(mode.width)×\(mode.height) (pixels \(mode.pixelWidth)×\(mode.pixelHeight)) @\(mode.refreshRate)Hz")
        for m in modeList { vdLog.debug("  candidate: \(m.width)×\(m.height) (pixels \(m.pixelWidth)×\(m.pixelHeight)) @\(m.refreshRate)Hz") }

        let cgMode = modeList.first { Self.matches($0, mode) && abs($0.refreshRate - mode.refreshRate) < 1.0 }
            ?? modeList.first { Self.matches($0, mode) }
            ?? modeList.first {
                $0.pixelWidth == mode.width && $0.pixelHeight == mode.height
                    && abs($0.refreshRate - mode.refreshRate) < 1.0
            }
        if let cgMode, mode.isHiDPI, cgMode.pixelWidth == cgMode.width {
            vdLog.error("anchorDisplayMode: anchor offers no HiDPI \(mode.width)×\(mode.height) — falling back to 1x")
        }
        if cgMode == nil {
            vdLog.error("anchorDisplayMode: no mode matching \(mode.width)×\(mode.height) on master \(anchorID)")
        }
        return cgMode
    }

    /// Whether the anchor already runs at the mode it would be given for `mode` — which, when
    /// it lacks that exact one, is the nearest it has.
    private func anchorRuns(_ mode: DisplayMode, anchorID: CGDirectDisplayID) -> Bool {
        guard let current = CGDisplayCopyDisplayMode(anchorID),
              let wanted = anchorDisplayMode(mode, anchorID: anchorID) else { return false }
        return current.width == wanted.width && current.height == wanted.height
            && current.pixelWidth == wanted.pixelWidth && current.pixelHeight == wanted.pixelHeight
            && abs(current.refreshRate - wanted.refreshRate) < 1.0
    }

    /// How long after an anchor is mirrored DAM keeps the layout around it. WindowServer has
    /// been seen to re-lay the displays out some ten seconds after the commit, resizing the
    /// anchors and the other displays.
    static let anchorSettleWindow: TimeInterval = 30

    /// After a display change while an anchor is settling, puts back what WindowServer moved:
    /// each anchor's size and mirror, and the other displays' sizes as captured before the
    /// anchor came; then, on the change that commit causes, their positions. Positions are
    /// left alone otherwise: an anchor larger than its device makes the captured ones
    /// overlap, and WindowServer would shift them straight back. Commits only when something
    /// differs, so its own commits end the cycle.
    func reassertAnchorLayout() {
        // The commit in progress fires another change once it lands; look again then.
        guard !virtualAnchorReassertInFlight else { return }
        let now = Date()
        virtualAnchorSettleDeadlines = virtualAnchorSettleDeadlines.filter {
            $0.value > now && virtualAnchorCGIDs[$0.key] != nil
        }
        guard !virtualAnchorSettleDeadlines.isEmpty else {
            virtualAnchorPositionsPending = false
            return
        }
        let arrangements = virtualAnchorSettleDeadlines.keys.compactMap { virtualAnchorArrangements[$0] }
        let excluded = Set(virtualAnchorCGIDs.values).union(virtualAnchorTargets.values).union(anchorSetSlaves)
        let online = Set(DisplayArrangement.onlineDisplayIDs())

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return }
        var changed = false
        for (name, anchorID) in virtualAnchorCGIDs where online.contains(anchorID) {
            // Not a display others now mirror: the user made it the master of a set.
            if let target = virtualAnchorTargets[name], online.contains(target),
               CGDisplayMirrorsDisplay(target) != anchorID,
               !online.contains(where: { CGDisplayMirrorsDisplay($0) == target }) {
                vdLog.debug("reassert: display \(target) back onto its anchor \(anchorID)")
                CGConfigureDisplayMirrorOfDisplay(cfg, target, anchorID)
                changed = true
            }
            if let mode = virtualAnchorModes[name], !anchorRuns(mode, anchorID: anchorID),
               let cgMode = anchorDisplayMode(mode, anchorID: anchorID) {
                vdLog.debug("reassert: anchor \(anchorID) back to \(cgMode.width)×\(cgMode.height) (pixels \(cgMode.pixelWidth)×\(cgMode.pixelHeight))")
                CGConfigureDisplayWithDisplayMode(cfg, anchorID, cgMode, nil)
                changed = true
            }
        }
        for arrangement in arrangements where arrangement.restoreModes(in: cfg, excluding: excluded) {
            changed = true
        }
        guard changed else {
            CGCancelDisplayConfiguration(cfg)
            if virtualAnchorPositionsPending {
                virtualAnchorPositionsPending = false
                commitIfChanged { cfg in arrangements.reduce(false) { $1.restore(in: cfg, excluding: excluded) || $0 } }
            }
            return
        }
        virtualAnchorPositionsPending = true
        virtualAnchorReassertInFlight = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let err = CGCompleteDisplayConfiguration(cfg, .forAppOnly)
            vdLog.debug("reassert: sizes restored err=\(err.rawValue)")
            // Positions go in a later pass: the size change moves the displays and fires
            // another reconfiguration, which lands back here.
            DispatchQueue.main.async {
                // A change that arrived meanwhile was skipped; look now.
                self?.virtualAnchorReassertInFlight = false
                self?.reassertAnchorLayout()
            }
        }
    }

    /// Begins a configuration, lets `queue` fill it, and commits it only when `queue` reports
    /// a change.
    private func commitIfChanged(_ queue: (CGDisplayConfigRef) -> Bool) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return }
        guard queue(cfg) else { CGCancelDisplayConfiguration(cfg); return }
        virtualAnchorReassertInFlight = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let err = CGCompleteDisplayConfiguration(cfg, .forAppOnly)
            vdLog.debug("reassert: positions restored err=\(err.rawValue)")
            DispatchQueue.main.async {
                // A change that arrived meanwhile was skipped; look now.
                self?.virtualAnchorReassertInFlight = false
                self?.reassertAnchorLayout()
            }
        }
    }

    private static func matches(_ cgMode: CGDisplayMode, _ mode: DisplayMode) -> Bool {
        cgMode.width == mode.width && cgMode.height == mode.height
            && cgMode.pixelWidth == mode.pixelWidth && cgMode.pixelHeight == mode.pixelHeight
    }
}
