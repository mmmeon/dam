//
//  VideoManager+VirtualAnchor.swift
//  boar
//
//  Virtual display anchor: creates a CGVirtualDisplay as a mirror master so the
//  physical display can run refresh rates not in its native mode list.
//

import CoreGraphics
import Foundation
import os.log

private let vdLog = Logger(subsystem: "mmmeon.hldm", category: "VirtualDisplay")

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

    /// Generates one DisplayMode per combination of the 4 fixed resolutions × each
    /// selected refresh rate, sorted descending by resolution then rate.
    static func virtualModes(refreshRates: Set<Int>) -> [DisplayMode] {
        let specs: [(Int, Int)] = [(3840, 2160), (2560, 1440), (1920, 1080), (1280, 720)]
        // Mirror enableVirtualAnchor: always include 60 Hz alongside configured rates
        // so the menu/Touch Bar reflect every mode the virtual display actually advertises.
        let configured = refreshRates.isEmpty ? [60] : refreshRates
        let allRates = configured.union([60])
        var modes: [DisplayMode] = []
        for (w, h) in specs {
            for rate in allRates.sorted(by: >) {
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

    /// Convenience overload that reads refresh rates from `VisibilityPreferences`.
    static func virtualModes(for context: VisibilityPreferences.DisplayContext) -> [DisplayMode] {
        virtualModes(refreshRates: VisibilityPreferences.virtualRefreshRates(for: context))
    }

    /// Selects a virtual resolution for a display.
    ///
    /// - If the virtual anchor is already active, applies the mode immediately.
    /// - If not yet active, starts the anchor; the user can re-select once it appears.
    func selectVirtualMode(_ mode: DisplayMode, for display: DisplayInfo) {
        if hasVirtualAnchor(for: display.name) {
            guard let anchorID = virtualAnchorCGIDs[display.name] else { return }
            setModeOnVirtualAnchor(mode, anchorID: anchorID)
        } else {
            vdLog.debug("selectVirtualMode: anchor not yet active for '\(display.name)' — enabling anchor, mode change deferred to user")
            enableVirtualAnchor(for: display)
        }
    }

    /// Creates a CGVirtualDisplay as a mirror master for `display`, then polls until
    /// it appears in the system display list and wires up the mirror relationship.
    func enableVirtualAnchor(for display: DisplayInfo) {
        guard display.cgDisplayID != 0, !hasVirtualAnchor(for: display.name) else {
            vdLog.debug("enableVirtualAnchor: skipped '\(display.name)' cgID=\(display.cgDisplayID) hasAnchor=\(self.hasVirtualAnchor(for: display.name))")
            return
        }

        let context: VisibilityPreferences.DisplayContext =
            allAirPlayDevices.contains { $0.id == display.id } ? .airPlay : .external
        vdLog.debug("enableVirtualAnchor: starting for '\(display.name)' cgID=\(display.cgDisplayID) context=\(context.rawValue)")

        let descriptor = CGVirtualDisplayDescriptor()
        // Must call setDispatchQueue: — the `queue` property writes a different ivar
        // that the system ignores, causing the virtual display to terminate immediately.
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
        let configuredRates = rates.isEmpty ? [60] : rates
        // Always include 60 Hz alongside any custom rates.
        // The System Settings "Refresh Rate" dropdown only appears when at least two
        // rates exist for the same resolution — mirroring the reference implementation
        // which advertises both the target rate and 60 Hz for every mode.
        let allRates = configuredRates.union([60])
        settings.modes = resolutions.flatMap { w, h in
            allRates.sorted(by: >).map { rate in
                CGVirtualDisplayMode(width: w, height: h, refreshRate: Double(rate))
            }
        }
        vdLog.debug("enableVirtualAnchor: applying \(settings.modes.count) modes (\(allRates.sorted(by: >) as [Int]) Hz)")

        let applied = vd.apply(settings)
        vdLog.debug("enableVirtualAnchor: applySettings returned \(applied) — displayID after apply=\(vd.displayID)")
        guard applied else {
            vdLog.error("enableVirtualAnchor: applySettings FAILED — aborting")
            return
        }

        // Retain vd so it isn't released before mirroring is wired up.
        virtualAnchorStore[deviceName] = vd
        vdLog.debug("enableVirtualAnchor: stored anchor, beginning poll (attempt 0)")
        waitForVirtualDisplay(vd, name: deviceName, airPlayID: airPlayCGID, context: context, attempt: 0)
    }

    /// Tears down the mirror and releases the CGVirtualDisplay for `display`.
    func disableVirtualAnchor(for display: DisplayInfo) {
        guard hasVirtualAnchor(for: display.name) else { return }
        let airPlayCGID = display.cgDisplayID != 0
            ? display.cgDisplayID
            : (cachedAirPlayCGIDs[display.name] ?? 0)
        virtualAnchorStore.removeValue(forKey: display.name)
        virtualAnchorCGIDs.removeValue(forKey: display.name)
        if airPlayCGID != 0 {
            var config: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&config) == .success, let cfg = config {
                CGConfigureDisplayMirrorOfDisplay(cfg, airPlayCGID, CGDirectDisplayID(0))
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    CGCompleteDisplayConfiguration(cfg, .forAppOnly)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.mergeDevices()
                    }
                }
                return
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.mergeDevices()
        }
    }

    // MARK: - Private

    /// Polls until the virtual display appears in the system display list, then
    /// wires up the mirror configuration in two steps.
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
                        self?.applyMirror(airPlayID: airPlayID, virtualID: virtualID)
                    }
                }
                return   // step2 will be chained from the background completion above
            }
        }

        // Step 2 (no prior mirror to tear down): short settle delay then apply.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.applyMirror(airPlayID: airPlayID, virtualID: virtualID)
        }
    }

    /// Applies the mirror relationship (airPlay → virtual) and chains step 3.
    /// Called from both the no-prior-mirror path and the post-teardown background path.
    private func applyMirror(airPlayID: CGDirectDisplayID, virtualID: CGDirectDisplayID) {
        vdLog.debug("step2: configuring mirror airPlayID=\(airPlayID) → virtualID=\(virtualID)")
        var config: CGDisplayConfigRef?
        let beginErr = CGBeginDisplayConfiguration(&config)
        vdLog.debug("step2: BeginDisplayConfiguration err=\(beginErr.rawValue)")
        guard beginErr == .success, let cfg = config else {
            vdLog.error("step2: BeginDisplayConfiguration failed — aborting")
            return
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
    private func setModeOnVirtualAnchor(_ mode: DisplayMode, anchorID: CGDirectDisplayID) {
        guard anchorID != 0 else { return }

        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modeList = CGDisplayCopyAllDisplayModes(anchorID, options) as? [CGDisplayMode] else {
            vdLog.error("setModeOnVirtualAnchor: CGDisplayCopyAllDisplayModes returned nil for \(anchorID)")
            return
        }
        vdLog.debug("setModeOnVirtualAnchor: \(modeList.count) modes on master \(anchorID), seeking \(mode.width)×\(mode.height) @\(mode.refreshRate)Hz")
        for m in modeList { vdLog.debug("  candidate: \(m.pixelWidth)×\(m.pixelHeight) @\(m.refreshRate)Hz") }

        let cgMode: CGDisplayMode? = {
            // Prefer exact size + rate match.
            if let exact = modeList.first(where: {
                $0.pixelWidth == mode.width &&
                $0.pixelHeight == mode.height &&
                abs($0.refreshRate - Double(mode.refreshRate)) < 1.0
            }) { return exact }
            // Fallback: size-only (virtual display may report a slightly different rate).
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
        DispatchQueue.global(qos: .userInitiated).async {
            let completeErr = CGCompleteDisplayConfiguration(cfg, .forAppOnly)
            vdLog.debug("setModeOnVirtualAnchor: CompleteDisplayConfiguration err=\(completeErr.rawValue)")
        }
    }
}
