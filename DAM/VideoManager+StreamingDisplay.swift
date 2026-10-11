//
//  VideoManager+StreamingDisplay.swift
//
//  Streaming display: a standalone virtual display, sized like the device it is streamed
//  to, for a screen-streaming app (RustDesk, Sunshine) to capture. DAM only creates and
//  places it; the streaming app picks it like any other display.
//

import CoreGraphics
import Foundation
import os.log

private let sdLog = Logger(subsystem: AppIdentity.bundleID, category: "StreamingDisplay")

/// A device a streaming display can be sized for: its panel in pixels, shown at 2x.
struct StreamingDisplayPreset: Equatable {
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Int

    /// iPad Pro 9.7-inch (iPad6,3): 2048 × 1536 at 60 Hz, looks like 1024 × 768.
    static let iPadPro9_7 = StreamingDisplayPreset(name: "iPad Pro 9.7-inch",
                                                   pixelWidth: 2048, pixelHeight: 1536, refreshRate: 60)

    /// The size the display looks like: half the panel, as it runs HiDPI.
    var width: Int { pixelWidth / 2 }
    var height: Int { pixelHeight / 2 }

    /// The sizes the virtual display advertises: the backing and the logical size, so it
    /// offers the logical size at 2x however the system derives HiDPI variants.
    var advertisedSizes: [(width: Int, height: Int)] {
        [(pixelWidth, pixelHeight), (width, height)]
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

    /// Creates the streaming display for `preset` and places it right of the other displays.
    /// The arrangement before it is put back when it is removed.
    func enableStreamingDisplay(_ preset: StreamingDisplayPreset = .iPadPro9_7) {
        guard streamingDisplay == nil else { return }
        sdLog.debug("enable: \(preset.name) \(preset.pixelWidth)×\(preset.pixelHeight) @\(preset.refreshRate)Hz")

        let descriptor = CGVirtualDisplayDescriptor()
        // Must call setDispatchQueue: (see enableVirtualAnchor).
        descriptor.setDispatchQueue(.main)
        descriptor.name = "\(AppIdentity.name) Streaming"
        descriptor.sizeInMillimeters = CGSize(width: 197, height: 148)
        descriptor.maxPixelsWide = UInt32(preset.pixelWidth)
        descriptor.maxPixelsHigh = UInt32(preset.pixelHeight)
        descriptor.vendorID  = Self.anchorVendorID
        descriptor.productID = Self.streamingProductID
        descriptor.serialNum = 0x0004
        descriptor.terminationHandler = { [weak self] _, _ in
            DispatchQueue.main.async {
                sdLog.debug("terminationHandler: streaming display ended")
                self?.streamingDisplay = nil
                self?.streamingDisplayID = 0
                self?.streamingArrangement = nil
                self?.mergeDevices()
            }
        }

        streamingArrangement = DisplayArrangement.current()
        let vd = CGVirtualDisplay(descriptor: descriptor)
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = preset.advertisedSizes.map {
            CGVirtualDisplayMode(width: UInt($0.width), height: UInt($0.height),
                                 refreshRate: Double(preset.refreshRate))
        }
        guard vd.apply(settings) else {
            sdLog.error("enable: applySettings failed")
            streamingArrangement = nil
            return
        }
        streamingDisplay = vd
        waitForStreamingDisplay(vd, preset: preset, attempt: 0)
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
        // Dropping the last reference above removes the display. Once the set has settled
        // without it, put the positions back if WindowServer's saved layout moved them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.mergeDevices() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            arrangement?.reapplyModes()
            arrangement?.reapplyOriginsPermanently()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.mergeDevices() }
        }
    }

    private func waitForStreamingDisplay(_ vd: CGVirtualDisplay, preset: StreamingDisplayPreset,
                                         attempt: Int) {
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
                self?.placeStreamingDisplay(id, preset: preset)
            }
            return
        }
        guard attempt < 10 else {
            sdLog.error("never came online — dropping it")
            streamingDisplay = nil
            streamingArrangement = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.waitForStreamingDisplay(vd, preset: preset, attempt: attempt + 1)
        }
    }

    /// Puts the other displays back where they were, switches the new display to the
    /// preset's HiDPI mode, and sets it right of the rest.
    private func placeStreamingDisplay(_ id: CGDirectDisplayID, preset: StreamingDisplayPreset) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else {
            mergeDevices()
            return
        }
        // WindowServer may have mirrored or moved the others for the new set.
        CGConfigureDisplayMirrorOfDisplay(cfg, id, CGDirectDisplayID(0))
        streamingArrangement?.restore(in: cfg, excluding: [id])
        // It can also change their resolutions.
        streamingArrangement?.restoreModes(in: cfg, excluding: [id])
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
        if let mode = modes.first(where: {
            $0.width == preset.width && $0.height == preset.height && $0.pixelWidth == preset.pixelWidth
        }) {
            CGConfigureDisplayWithDisplayMode(cfg, id, mode, nil)
        } else {
            sdLog.error("place: no \(preset.width)×\(preset.height) HiDPI mode among \(modes.count)")
        }
        let others = (streamingArrangement?.origins ?? [:]).compactMap { otherID, origin -> CGRect? in
            guard otherID != id, streamingArrangement?.mirrorMasters[otherID] == 0 else { return nil }
            // The size it is put back to, not the one WindowServer gave it.
            let size = streamingArrangement?.modes[otherID].map { CGSize(width: $0.width, height: $0.height) }
            return CGRect(origin: origin, size: size ?? CGDisplayBounds(otherID).size)
        }
        let origin = Self.streamingDisplayOrigin(others: others)
        CGConfigureDisplayOrigin(cfg, id, Int32(origin.x), Int32(origin.y))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let err = CGCompleteDisplayConfiguration(cfg, .forAppOnly)
            sdLog.debug("place: CompleteDisplayConfiguration err=\(err.rawValue)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.mergeDevices() }
        }
    }
}
