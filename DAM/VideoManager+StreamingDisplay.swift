//
//  VideoManager+StreamingDisplay.swift
//
//  Streaming displays: standalone virtual displays for screen-streaming or remote-desktop
//  apps (RustDesk, Sunshine, VNC, …) to capture, one per stream. DAM only creates and places
//  them; an app picks one like any other display, and its size and rate are chosen like any
//  other's.
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

    /// One of DAM's streaming displays.
    struct StreamingDisplay {
        /// The CGVirtualDisplay; dropping the last reference removes the display.
        let display: AnyObject
        /// Which of the streaming displays it is, from 0; it picks the name and serial number.
        let index: Int
        /// Its display ID once online, else 0.
        var id: CGDirectDisplayID = 0
    }

    /// Vendor and product the streaming displays carry. Their own product keeps the anchor
    /// search from taking one for an anchor.
    static let streamingProductID: UInt32 = 0x1236

    /// How many streaming displays there can be.
    static let maxStreamingDisplays = 4

    /// The serial number of streaming display `index`. Each needs its own for macOS to keep
    /// its place and resolution apart from the others'; the first keeps the one it always had.
    static func streamingSerial(_ index: Int) -> UInt32 {
        0x0004 + UInt32(index) << 8
    }

    /// The name of streaming display `index`: "DAM Streaming", then "DAM Streaming 2", ….
    static func streamingDisplayName(_ index: Int) -> String {
        index == 0 ? "\(AppIdentity.name) Streaming" : "\(AppIdentity.name) Streaming \(index + 1)"
    }

    /// The IDs of the streaming displays that are online.
    var streamingDisplayIDs: Set<CGDirectDisplayID> {
        Set(streamingDisplays.map(\.id)).subtracting([0])
    }

    /// Where a new streaming display goes: right of every display in `others`, top-aligned
    /// with the main display.
    static func streamingDisplayOrigin(others: [CGRect]) -> CGPoint {
        CGPoint(x: others.map(\.maxX).max() ?? 0, y: 0)
    }

    /// The display to make main in place of a streaming display, which nobody looks at:
    /// the one that was main before the first came if it is among `candidates`, else the
    /// first of them. Nil when there is none.
    static func displayToMakeMain(candidates: [CGDirectDisplayID],
                                  previousMain: CGDirectDisplayID?) -> CGDirectDisplayID? {
        previousMain.flatMap { candidates.contains($0) ? $0 : nil } ?? candidates.first
    }

    /// Hands the menu bar and Dock back to another display when a streaming display has
    /// become main, as one does when the display that was main is unplugged; WindowServer
    /// leaves it main when that display comes back. Not when the user made it main.
    func keepStreamingDisplayOffMain() {
        let streamingIDs = streamingDisplayIDs
        guard streamingIDs.contains(where: { CGDisplayIsMain($0) != 0 }),
              !streamingDisplayIsMainByChoice,
              // Placing one puts main back itself; the others' commits would race this one.
              !streamingChangeInFlight, !streamingReassertInFlight, !streamingMainHandBackInFlight,
              !virtualAnchorReassertInFlight else { return }
        // Displays showing their own desktop, on their own or through an anchor; a disabled
        // one stays online but has no screen.
        let candidates = (allConnectedDisplays + allAirPlayDevices).filter {
            $0.isConnected && $0.cgDisplayID != 0 && !streamingIDs.contains($0.cgDisplayID)
                && userMirrorMaster(of: $0.cgDisplayID) == nil
        }
        // An anchored display was main through its anchor.
        let previousMain = streamingArrangement.flatMap { arrangement in
            arrangement.origins.first { $0.value == .zero && arrangement.mirrorMasters[$0.key] == 0 }?.key
        }.map { anchorTarget(of: $0) ?? $0 }
        guard let id = Self.displayToMakeMain(candidates: candidates.map(\.cgDisplayID), previousMain: previousMain),
              let display = candidates.first(where: { $0.cgDisplayID == id }) else { return }
        sdLog.debug("a streaming display is main; making \(id) main")
        streamingMainHandBackInFlight = true
        setMainDisplay(display) { [weak self] _ in self?.streamingMainHandBackInFlight = false }
    }

    /// An addition or removal of a streaming display, waiting its turn.
    enum StreamingRequest: Equatable {
        case add
        case remove(index: Int)
    }

    /// How many streaming displays there will be once the requests waiting are done.
    var plannedStreamingDisplayCount: Int {
        streamingRequests.reduce(streamingDisplays.count) { $0 + ($1 == .add ? 1 : -1) }
    }

    var canCreateStreamingDisplay: Bool { plannedStreamingDisplayCount < Self.maxStreamingDisplays }

    /// Asks for one more streaming display. Additions and removals run one at a time, each
    /// once the one before has settled.
    func createStreamingDisplay() {
        guard canCreateStreamingDisplay else { return }
        streamingRequests.append(.add)
        processStreamingRequests()
    }

    /// Asks for the streaming display shown as `display` to be removed.
    func removeStreamingDisplay(_ display: DisplayInfo) {
        guard let index = streamingDisplays.first(where: { $0.id == display.cgDisplayID })?.index,
              !streamingRequests.contains(.remove(index: index)) else { return }
        streamingRequests.append(.remove(index: index))
        processStreamingRequests()
    }

    /// Starts the next request, unless a change is under way; that one calls this again
    /// when it is done.
    private func processStreamingRequests() {
        while !streamingChangeInFlight, !streamingReassertInFlight, !streamingRequests.isEmpty {
            switch streamingRequests.removeFirst() {
            case .add:                  addStreamingDisplay()
            case .remove(let index):    removeStreamingDisplay(index: index)
            }
        }
    }

    /// Ends the change under way and starts the next, if any is waiting.
    private func finishStreamingChange() {
        streamingChangeInFlight = false
        keepStreamingDisplayOffMain()
        processStreamingRequests()
    }

    /// Creates a streaming display and places it right of the other displays. The
    /// arrangement from before the first is put back when the last is removed.
    private func addStreamingDisplay() {
        let used = Set(streamingDisplays.map(\.index))
        guard let index = (0..<Self.maxStreamingDisplays).first(where: { !used.contains($0) }) else { return }
        sdLog.debug("add \(index)")

        let descriptor = CGVirtualDisplayDescriptor()
        // Must call setDispatchQueue: (see enableVirtualAnchor).
        descriptor.setDispatchQueue(.main)
        descriptor.name = Self.streamingDisplayName(index)
        descriptor.sizeInMillimeters = CGSize(width: 600, height: 340)
        descriptor.maxPixelsWide = UInt32(StreamingDisplayModes.maxPixelsWide)
        descriptor.maxPixelsHigh = UInt32(StreamingDisplayModes.maxPixelsHigh)
        descriptor.vendorID  = Self.anchorVendorID
        descriptor.productID = Self.streamingProductID
        descriptor.serialNum = Self.streamingSerial(index)
        descriptor.terminationHandler = { [weak self] _, _ in
            DispatchQueue.main.async { self?.streamingDisplayEnded(index: index) }
        }

        // Taken before the display comes, to put the others back once WindowServer has laid
        // the new set out; it holds the streaming displays already there. Right after another
        // change, the layout kept for it: WindowServer may still be changing the current one.
        let before = activeStreamingSettle ?? DisplayArrangement.current()
        // Kept for the set without the new display, which it would no longer match.
        streamingSettle = nil
        if streamingDisplays.isEmpty {
            streamingArrangement = before
            streamingDisplayIsMainByChoice = false
        }
        let vd = CGVirtualDisplay(descriptor: descriptor)
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = StreamingDisplayModes.advertised.map {
            CGVirtualDisplayMode(width: UInt($0.width), height: UInt($0.height),
                                 refreshRate: Double($0.refreshRate))
        }
        guard vd.apply(settings) else {
            sdLog.error("add: applySettings failed")
            if streamingDisplays.isEmpty { streamingArrangement = nil }
            // The additions waiting would fail the same way.
            streamingRequests.removeAll { $0 == .add }
            return
        }
        streamingDisplays.append(StreamingDisplay(display: vd, index: index))
        streamingChangeInFlight = true
        waitForStreamingDisplay(vd, index: index, before: before, attempt: 0)
    }

    /// Removes streaming display `index`, if it is still there, and puts the others back
    /// where they were: where they were before the first came once it is the last.
    private func removeStreamingDisplay(index: Int) {
        guard let i = streamingDisplays.firstIndex(where: { $0.index == index }) else { return }
        let last = streamingDisplays[i]
        sdLog.debug("remove \(last.index): \(last.id)")
        // Right after another change, the layout kept for it: WindowServer may still be
        // changing the current one.
        let arrangement = streamingDisplays.count == 1
            ? streamingArrangement
            : (activeStreamingSettle ?? DisplayArrangement.current()).excluding(last.id)
        if streamingDisplays.count == 1 || CGDisplayIsMain(last.id) != 0 {
            streamingDisplayIsMainByChoice = false
        }
        // Dropping the last reference removes the display. While the set settles without
        // it, each change puts the resolutions and positions back if WindowServer's saved
        // layout for the smaller set changed them.
        streamingDisplays.remove(at: i)
        if streamingDisplays.isEmpty { streamingArrangement = nil }
        streamingSettle = arrangement.map { ($0, Date().addingTimeInterval(5)) }
        streamingChangeInFlight = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.mergeDevices() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.reassertStreamingLayout()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.mergeDevices()
                self?.finishStreamingChange()
            }
        }
    }

    /// The layout kept after the last change, until it expires.
    private var activeStreamingSettle: DisplayArrangement? {
        streamingSettle.flatMap { $0.until > Date() ? $0.arrangement : nil }
    }

    /// Puts back the layout kept after a streaming display was added or removed, until it expires,
    /// in one commit at a time. Commits only what differs, so its own commits end the cycle.
    /// Permanently: they are the layout the set had, which WindowServer's saved one undid.
    func reassertStreamingLayout() {
        guard !streamingReassertInFlight, let settle = streamingSettle else { return }
        guard settle.until > Date() else { streamingSettle = nil; return }
        let arrangement = settle.arrangement
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return }
        // Resolutions only for the same displays, mirrored the same way (see reapplyModes).
        let sameSet = DisplayArrangement.sameSet(captured: arrangement.mirrorMasters,
                                                 online: DisplayArrangement.onlineDisplayIDs(),
                                                 mirrorOf: { CGDisplayMirrorsDisplay($0) })
        let resized = sameSet && arrangement.restoreModes(in: cfg, excluding: [])
        guard arrangement.restoreOrigins(in: cfg, excluding: []) || resized else {
            CGCancelDisplayConfiguration(cfg)
            return
        }
        streamingReassertInFlight = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let err = CGCompleteDisplayConfiguration(cfg, .permanently)
            sdLog.debug("reassert: CompleteDisplayConfiguration err=\(err.rawValue)")
            DispatchQueue.main.async {
                guard let self else { return }
                // A change that arrived meanwhile was skipped; look now.
                self.streamingReassertInFlight = false
                self.reassertStreamingLayout()
                self.processStreamingRequests()
            }
        }
    }

    /// Forgets streaming display `index` after WindowServer ended it.
    private func streamingDisplayEnded(index: Int) {
        guard let i = streamingDisplays.firstIndex(where: { $0.index == index }) else { return }
        sdLog.debug("terminationHandler: streaming display \(index) ended")
        streamingDisplays.remove(at: i)
        if streamingDisplays.isEmpty {
            streamingArrangement = nil
            streamingDisplayIsMainByChoice = false
        }
        mergeDevices()
    }

    private func isStreamingDisplay(_ vd: CGVirtualDisplay) -> Bool {
        streamingDisplays.contains { $0.display === vd }
    }

    private func waitForStreamingDisplay(_ vd: CGVirtualDisplay, index: Int, before: DisplayArrangement,
                                         attempt: Int) {
        // Ended meanwhile; nothing else finishes this change.
        guard isStreamingDisplay(vd) else { return finishStreamingChange() }
        let online = DisplayArrangement.onlineDisplayIDs()
        let serial = Self.streamingSerial(index)
        let id = vd.displayID != 0 && online.contains(vd.displayID)
            ? vd.displayID
            : online.first {
                CGDisplayVendorNumber($0) == Self.anchorVendorID
                    && CGDisplayModelNumber($0) == Self.streamingProductID
                    && CGDisplaySerialNumber($0) == serial
            } ?? 0
        if id != 0, let i = streamingDisplays.firstIndex(where: { $0.display === vd }) {
            sdLog.debug("\(index) online as \(id)")
            streamingDisplays[i].id = id
            // Let WindowServer lay out the new set first; it would undo a placement made before.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                guard self.isStreamingDisplay(vd) else { return self.finishStreamingChange() }
                self.placeStreamingDisplay(id, before: before)
            }
            return
        }
        guard attempt < 10 else {
            sdLog.error("\(index) never came online — dropping it")
            streamingDisplays.removeAll { $0.display === vd }
            if streamingDisplays.isEmpty { streamingArrangement = nil }
            return finishStreamingChange()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.waitForStreamingDisplay(vd, index: index, before: before, attempt: attempt + 1)
        }
    }

    /// Puts the other displays back as they were in `before`, switches the new display to
    /// its start mode, and sets it right of the rest.
    private func placeStreamingDisplay(_ id: CGDirectDisplayID, before: DisplayArrangement) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else {
            mergeDevices()
            finishStreamingChange()
            return
        }
        // WindowServer may have mirrored or moved the others for the new set.
        CGConfigureDisplayMirrorOfDisplay(cfg, id, CGDirectDisplayID(0))
        before.restore(in: cfg, excluding: [id])
        // It can also change their resolutions.
        before.restoreModes(in: cfg, excluding: [id])
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
        let start = StreamingDisplayModes.start
        let startMode = modes.first {
            $0.width == start.width && $0.height == start.height && $0.pixelWidth == start.width
                && Int($0.refreshRate.rounded()) == start.refreshRate
        }
        if let mode = startMode {
            CGConfigureDisplayWithDisplayMode(cfg, id, mode, nil)
        } else {
            sdLog.error("place: no \(start.width)×\(start.height) mode among \(modes.count)")
        }
        let others = before.origins.compactMap { otherID, origin -> CGRect? in
            guard otherID != id, before.mirrorMasters[otherID] == 0 else { return nil }
            // The size it is put back to, not the one WindowServer gave it.
            let size = before.modes[otherID].map { CGSize(width: $0.width, height: $0.height) }
            return CGRect(origin: origin, size: size ?? CGDisplayBounds(otherID).size)
        }
        let origin = Self.streamingDisplayOrigin(others: others)
        CGConfigureDisplayOrigin(cfg, id, Int32(origin.x), Int32(origin.y))
        let placed = before.adding(id, origin: origin, mode: startMode ?? CGDisplayCopyDisplayMode(id))
        // For the session, not the app: when another app's own changes end, WindowServer goes
        // back to the session's layout, which would undo app-only ones.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let err = CGCompleteDisplayConfiguration(cfg, .forSession)
            sdLog.debug("place: CompleteDisplayConfiguration err=\(err.rawValue)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // WindowServer can still change the others' resolutions for the new set.
                self?.streamingSettle = (placed, Date().addingTimeInterval(5))
                self?.reassertStreamingLayout()
                self?.mergeDevices()
                // The display that was main may be gone, and a commit that changes nothing
                // fires no reconfiguration to check this.
                self?.finishStreamingChange()
            }
        }
    }
}
