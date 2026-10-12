//
//  VideoManager+StreamingDisplay.swift
//
//  Streaming display: a standalone virtual display for a screen-streaming or remote-desktop
//  app (RustDesk, Sunshine, VNC, …) to capture. DAM only creates and places it; the app
//  picks it like any other display, and its size and rate are chosen like any other's.
//

import CoreGraphics
import Foundation
import os.log

private let sdLog = Logger(subsystem: AppIdentity.bundleID, category: "StreamingDisplay")

/// The sizes and rates the streaming display offers, so it can match whatever shows it.
enum StreamingDisplayModes {
    /// Common 16:9, 16:10 and 4:3 sizes. With HiDPI on, macOS offers each one at 2x as well,
    /// even past `maxPixelsWide` × `maxPixelsHigh` (2560 × 1440 at 2x renders 5120 × 2880);
    /// `fits` keeps those out of the resolutions DAM lists.
    static let sizes: [(width: Int, height: Int)] = [
        (1280, 720), (1920, 1080), (2560, 1440), (3840, 2160),
        (1280, 800), (1440, 900), (1680, 1050), (1920, 1200), (2560, 1600),
        (1024, 768), (1600, 1200), (2048, 1536)
    ]
    static let refreshRates = [60, 30, 120]

    /// The mode it comes up in: 1920 × 1080 at 60 Hz, at 1x.
    static let start = (width: 1920, height: 1080, refreshRate: 60)

    static let maxPixelsWide = sizes.map(\.width).max() ?? 0
    static let maxPixelsHigh = sizes.map(\.height).max() ?? 0

    /// Whether `mode` renders within the largest size listed.
    static func fits(_ mode: DisplayMode) -> Bool {
        mode.pixelWidth <= maxPixelsWide && mode.pixelHeight <= maxPixelsHigh
    }

    /// Every size at every rate, the start mode first so the display comes up in it.
    static var advertised: [(width: Int, height: Int, refreshRate: Int)] {
        let all = sizes.flatMap { size in refreshRates.map { (size.width, size.height, $0) } }
        let isStart = { (m: (width: Int, height: Int, refreshRate: Int)) in
            m.width == start.width && m.height == start.height && m.refreshRate == start.refreshRate
        }
        return all.filter(isStart) + all.filter { !isStart($0) }
    }
}

extension VideoManager {

    /// Vendor and product the streaming display carries. Its own product keeps the anchor
    /// search from taking it for an anchor.
    static let streamingProductID: UInt32 = 0x1236

    var hasStreamingDisplay: Bool { streamingDisplay != nil }

    /// Where the streaming display goes: right of every display in `others`, top-aligned
    /// with the main display.
    static func streamingDisplayOrigin(others: [CGRect]) -> CGPoint {
        CGPoint(x: others.map(\.maxX).max() ?? 0, y: 0)
    }

    /// The display to make main in place of the streaming display, which nobody looks at:
    /// the one that was main before it came if it is among `candidates`, else the first of
    /// them. Nil when there is none.
    static func displayToMakeMain(candidates: [CGDirectDisplayID],
                                  previousMain: CGDirectDisplayID?) -> CGDirectDisplayID? {
        previousMain.flatMap { candidates.contains($0) ? $0 : nil } ?? candidates.first
    }

    /// Hands the menu bar and Dock back to another display when the streaming display has
    /// become main, as it does when the display that was main is unplugged; WindowServer
    /// leaves it main when that display comes back. Not when the user made it main.
    func keepStreamingDisplayOffMain() {
        guard streamingDisplayID != 0, CGDisplayIsMain(streamingDisplayID) != 0,
              !streamingDisplayIsMainByChoice,
              // Placing it puts main back itself; the others' commits would race this one.
              !streamingPlacementPending, !streamingMainHandBackInFlight,
              !virtualAnchorReassertInFlight else { return }
        // Displays showing their own desktop, on their own or through an anchor; a disabled
        // one stays online but has no screen.
        let candidates = (allConnectedDisplays + allAirPlayDevices).filter {
            $0.isConnected && $0.cgDisplayID != 0 && $0.cgDisplayID != streamingDisplayID
                && userMirrorMaster(of: $0.cgDisplayID) == nil
        }
        // An anchored display was main through its anchor.
        let previousMain = streamingArrangement.flatMap { arrangement in
            arrangement.origins.first { $0.value == .zero && arrangement.mirrorMasters[$0.key] == 0 }?.key
        }.map { anchorTarget(of: $0) ?? $0 }
        guard let id = Self.displayToMakeMain(candidates: candidates.map(\.cgDisplayID), previousMain: previousMain),
              let display = candidates.first(where: { $0.cgDisplayID == id }) else { return }
        sdLog.debug("streaming display is main; making \(id) main")
        streamingMainHandBackInFlight = true
        setMainDisplay(display) { [weak self] _ in self?.streamingMainHandBackInFlight = false }
    }

    /// Creates the streaming display and places it right of the other displays. The
    /// arrangement before it is put back when it is removed.
    func enableStreamingDisplay() {
        guard streamingDisplay == nil else { return }
        sdLog.debug("enable")
        streamingDisplayIsMainByChoice = false

        let descriptor = CGVirtualDisplayDescriptor()
        // Must call setDispatchQueue: (see enableVirtualAnchor).
        descriptor.setDispatchQueue(.main)
        descriptor.name = "\(AppIdentity.name) Streaming"
        descriptor.sizeInMillimeters = CGSize(width: 600, height: 340)
        descriptor.maxPixelsWide = UInt32(StreamingDisplayModes.maxPixelsWide)
        descriptor.maxPixelsHigh = UInt32(StreamingDisplayModes.maxPixelsHigh)
        descriptor.vendorID  = Self.anchorVendorID
        descriptor.productID = Self.streamingProductID
        descriptor.serialNum = 0x0004
        descriptor.terminationHandler = { [weak self] _, _ in
            DispatchQueue.main.async {
                sdLog.debug("terminationHandler: streaming display ended")
                self?.streamingDisplay = nil
                self?.streamingDisplayID = 0
                self?.streamingArrangement = nil
                self?.streamingPlacementPending = false
                self?.streamingDisplayIsMainByChoice = false
                self?.mergeDevices()
            }
        }

        streamingArrangement = DisplayArrangement.current()
        let vd = CGVirtualDisplay(descriptor: descriptor)
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = StreamingDisplayModes.advertised.map {
            CGVirtualDisplayMode(width: UInt($0.width), height: UInt($0.height),
                                 refreshRate: Double($0.refreshRate))
        }
        guard vd.apply(settings) else {
            sdLog.error("enable: applySettings failed")
            streamingArrangement = nil
            return
        }
        streamingDisplay = vd
        streamingPlacementPending = true
        waitForStreamingDisplay(vd, attempt: 0)
    }

    /// Removes the streaming display and puts the arrangement from before it back.
    func disableStreamingDisplay() {
        guard streamingDisplay != nil else { return }
        let id = streamingDisplayID
        let arrangement = streamingArrangement
        sdLog.debug("disable: removing \(id)")
        streamingDisplay = nil
        streamingDisplayID = 0
        streamingArrangement = nil
        streamingPlacementPending = false
        streamingDisplayIsMainByChoice = false
        // Dropping the last reference above removes the display. Once the set has settled
        // without it, put the positions back if WindowServer's saved layout moved them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.mergeDevices() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            arrangement?.reapplyModes()
            arrangement?.reapplyOriginsPermanently()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.mergeDevices() }
        }
    }

    private func waitForStreamingDisplay(_ vd: CGVirtualDisplay, attempt: Int) {
        guard streamingDisplay === vd else { return }
        let online = DisplayArrangement.onlineDisplayIDs()
        let id = vd.displayID != 0 && online.contains(vd.displayID)
            ? vd.displayID
            : online.first {
                CGDisplayVendorNumber($0) == Self.anchorVendorID
                    && CGDisplayModelNumber($0) == Self.streamingProductID
            } ?? 0
        if id != 0 {
            sdLog.debug("online as \(id)")
            streamingDisplayID = id
            // Let WindowServer lay out the new set first; it would undo a placement made before.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard self?.streamingDisplay === vd else { return }
                self?.placeStreamingDisplay(id)
            }
            return
        }
        guard attempt < 10 else {
            sdLog.error("never came online — dropping it")
            streamingDisplay = nil
            streamingArrangement = nil
            streamingPlacementPending = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.waitForStreamingDisplay(vd, attempt: attempt + 1)
        }
    }

    /// Puts the other displays back where they were, switches the new display to its start
    /// mode, and sets it right of the rest.
    private func placeStreamingDisplay(_ id: CGDirectDisplayID) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else {
            streamingPlacementPending = false
            mergeDevices()
            keepStreamingDisplayOffMain()
            return
        }
        // WindowServer may have mirrored or moved the others for the new set.
        CGConfigureDisplayMirrorOfDisplay(cfg, id, CGDirectDisplayID(0))
        streamingArrangement?.restore(in: cfg, excluding: [id])
        // It can also change their resolutions.
        streamingArrangement?.restoreModes(in: cfg, excluding: [id])
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
        let start = StreamingDisplayModes.start
        if let mode = modes.first(where: {
            $0.width == start.width && $0.height == start.height && $0.pixelWidth == start.width
                && Int($0.refreshRate.rounded()) == start.refreshRate
        }) {
            CGConfigureDisplayWithDisplayMode(cfg, id, mode, nil)
        } else {
            sdLog.error("place: no \(start.width)×\(start.height) mode among \(modes.count)")
        }
        let others = (streamingArrangement?.origins ?? [:]).compactMap { otherID, origin -> CGRect? in
            guard otherID != id, streamingArrangement?.mirrorMasters[otherID] == 0 else { return nil }
            // The size it is put back to, not the one WindowServer gave it.
            let size = streamingArrangement?.modes[otherID].map { CGSize(width: $0.width, height: $0.height) }
            return CGRect(origin: origin, size: size ?? CGDisplayBounds(otherID).size)
        }
        let origin = Self.streamingDisplayOrigin(others: others)
        CGConfigureDisplayOrigin(cfg, id, Int32(origin.x), Int32(origin.y))
        // For the session, not the app: when another app's own changes end, WindowServer goes
        // back to the session's layout, which would undo app-only ones.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let err = CGCompleteDisplayConfiguration(cfg, .forSession)
            sdLog.debug("place: CompleteDisplayConfiguration err=\(err.rawValue)")
            DispatchQueue.main.async { self?.streamingPlacementPending = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.mergeDevices()
                // The display that was main may be gone, and a commit that changes nothing
                // fires no reconfiguration to check this.
                self?.keepStreamingDisplayOffMain()
            }
        }
    }
}
