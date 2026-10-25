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

extension StreamingDisplayModes.Mode {
    /// The mode a display runs, as a streaming display's mode.
    init(_ mode: CGDisplayMode) {
        self.init(width: mode.width, height: mode.height, refreshRate: Int(mode.refreshRate.rounded()),
                  hiDPI: mode.pixelWidth > mode.width)
    }
}

extension VideoManager {

    /// One of DAM's streaming displays.
    struct StreamingDisplay {
        /// The CGVirtualDisplay; dropping the last reference removes the display.
        let display: AnyObject
        /// Which of the streaming displays it is, from 0; it picks the name and serial number
        /// unless the display was made for someone in particular (see `StreamingIdentity`).
        let index: Int
        /// Its name, which its rotation is kept by.
        let name: String
        /// Its serial number, which it is found by once online.
        let serial: UInt32
        /// The mode it comes up in, or was last resized to, turned by `rotation`.
        var start: StreamingDisplayModes.Mode
        /// How far its picture is turned; captures turn their frames back by as much.
        var rotation: DisplayRotation = .standard
        /// The name of the display it stands in for, showing it turned (see
        /// RotatedPresentation.swift); nil for a streaming display of its own.
        var standsInFor: String?
        /// Its display ID once online, else 0.
        var id: CGDirectDisplayID = 0
    }

    /// Vendor and product the streaming displays carry. Their own product keeps the anchor
    /// search from taking one for an anchor.
    static let streamingProductID: UInt32 = StreamingDisplayIdentity.productID

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

    /// The serial number of a streaming display made for `seed`: the same for the same seed,
    /// so macOS keeps its place and resolution from one session to the next, and never one
    /// of `streamingSerial(_:)`'s.
    static func streamingSerial(seed: String) -> UInt32 { StreamingDisplayIdentity.serial(seed: seed) }

    /// The name of a stand-in for the display named `name`: "tv (Rotated)".
    static func standInDisplayName(for name: String) -> String { "\(name) (Rotated)" }

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
        // A stand-in may be main: it is the display it stands in for.
        let streamingIDs = streamingDisplayIDs.subtracting(standInDisplayIDs)
        guard streamingIDs.contains(where: { CGDisplayIsMain($0) != 0 }),
              !streamingDisplayIsMainByChoice,
              // Placing one puts main back itself; the others' commits would race this one.
              !displayChangeInFlight else { return }
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

    /// Notes a display DAM didn't make joining or leaving (a TV connected or disconnected):
    /// WindowServer then lays the new set out from a layout it saved for it, mirrors included,
    /// over the next seconds, or hands a mirror set the leaver was in to another of its members;
    /// an anchor made for a newcomer keeps a layout for its first 30. While the set is settled,
    /// notes where each display is.
    func noteDisplaySetChanged() {
        // DAM's own come and go through it, which lays them out.
        let online = Set(DisplayArrangement.onlineDisplayIDs().filter { CGDisplayVendorNumber($0) != Self.anchorVendorID })
        defer { onlineAtLastMerge = online }
        guard let before = onlineAtLastMerge, online != before else {
            onlineAtLastMerge = online
            return noteSettledFrames()
        }
        displaySetChangedUntil = Date().addingTimeInterval(45)
        // Noted again once the set has settled, with any streaming display placed meanwhile.
        DispatchQueue.main.asyncAfter(deadline: .now() + 46) { [weak self] in self?.noteSettledFrames() }
    }

    /// Notes where each display is while the set is settled, once a change of DAM's own (a
    /// streaming display being placed, say) has landed: until then they are on the way.
    private func noteSettledFrames() {
        guard displaySetChangedUntil <= Date() else { return }
        guard !displayChangeInFlight else {
            guard !settledFramesPending else { return }
            settledFramesPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.settledFramesPending = false
                self?.noteSettledFrames()
            }
            return
        }
        let all = DisplayArrangement.onlineDisplayIDs()
        // Not if one came or went meanwhile: the next re-read sees to that.
        guard Set(all.filter { CGDisplayVendorNumber($0) != Self.anchorVendorID }) == onlineAtLastMerge else { return }
        framesBeforeSetChange = Dictionary(uniqueKeysWithValues: all.map { ($0, CGDisplayBounds($0)) })
    }

    /// Where to move each of `streaming` so it is where it was in `before` beside the others,
    /// going by `main` (or another display neither streaming nor mirroring, in both): none
    /// that mirrors, and nothing when a move would overlap another display.
    static func originsBack(before: [CGDirectDisplayID: CGRect], now: [CGDirectDisplayID: CGRect],
                            streaming: Set<CGDirectDisplayID>, mirroring: Set<CGDirectDisplayID>,
                            main: CGDirectDisplayID) -> [CGDirectDisplayID: CGPoint] {
        let fixed = { (id: CGDirectDisplayID) in !streaming.contains(id) && !mirroring.contains(id) }
        guard let reference = ([main] + now.keys.sorted()).first(where: { fixed($0) && before[$0] != nil }),
              let then = before[reference], let present = now[reference] else { return [:] }
        let dx = present.minX - then.minX, dy = present.minY - then.minY
        var moves: [CGDirectDisplayID: CGPoint] = [:]
        for id in streaming where !mirroring.contains(id) {
            guard let old = before[id], let current = now[id] else { continue }
            let target = CGPoint(x: old.minX + dx, y: old.minY + dy)
            if target != current.origin { moves[id] = target }
        }
        guard !moves.isEmpty else { return [:] }
        let frames = now.filter { !mirroring.contains($0.key) }.map { id, frame in
            moves[id].map { CGRect(origin: $0, size: frame.size) } ?? frame
        }
        for (i, a) in frames.enumerated() {
            for b in frames[(i + 1)...] {
                let overlap = a.intersection(b)
                if !overlap.isNull, overlap.width > 0, overlap.height > 0 { return [:] }
            }
        }
        return moves
    }

    /// The displays to give their own desktop again: each of `streaming` mirroring a display
    /// though not set to through DAM, and each display mirroring one of `streaming` the user
    /// didn't mirror onto it through DAM; none an anchor's set holds.
    static func mirrorsToRelease(streaming: Set<CGDirectDisplayID>, online: [CGDirectDisplayID],
                                 masterOf: (CGDirectDisplayID) -> CGDirectDisplayID,
                                 mirroringByChoice: Set<CGDirectDisplayID>,
                                 mirroredByChoice: Set<CGDirectDisplayID>,
                                 anchorManaged: Set<CGDirectDisplayID>) -> [CGDirectDisplayID] {
        online.filter { id in
            let master = masterOf(id)
            guard master != 0, !anchorManaged.contains(id) else { return false }
            if streaming.contains(id) { return !mirroringByChoice.contains(id) }
            return streaming.contains(master) && !mirroredByChoice.contains(master)
        }
    }

    /// Undoes what WindowServer does to the streaming displays while laying out a set a display
    /// joined or left, from a layout it saved for it: frees those it put in a mirror set (one
    /// mirroring another can't be captured, so its stream stops, and one mirrored takes the
    /// others' screens, main with them), gives each the mode it was made in or set to (a
    /// HiDPI one, say, for a stream of its pixel size) and puts it back where it was. Only
    /// then, so a change made in System Settings later stays; a mirror the user made through
    /// DAM stays too.
    func keepStreamingDisplaysAsMade() {
        guard displaySetChangedUntil > Date(), !streamingDisplays.isEmpty else { return }
        guard !displayChangeInFlight else {
            // Looked at again once the change has landed.
            guard !streamingMirrorCheckPending else { return }
            streamingMirrorCheckPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.streamingMirrorCheckPending = false
                self?.keepStreamingDisplaysAsMade()
            }
            return
        }
        let streaming = streamingDisplayIDs.subtracting(standInDisplayIDs)
        let free = Self.mirrorsToRelease(streaming: streaming,
                                         online: DisplayArrangement.onlineDisplayIDs(),
                                         masterOf: { CGDisplayMirrorsDisplay($0) },
                                         mirroringByChoice: streamingDisplaysMirroringByChoice,
                                         mirroredByChoice: displaysMirroredByChoice,
                                         anchorManaged: anchorManagedDisplayIDs)
        // Not one left in a mirror set made through DAM: the set runs one mode on all of them.
        let modes: [(CGDirectDisplayID, CGDisplayMode)] = streamingDisplays.compactMap { display in
            let id = display.id
            guard streaming.contains(id), CGDisplayMirrorsDisplay(id) == 0 || free.contains(id),
                  !displaysMirroredByChoice.contains(id),
                  let wanted = Self.displayMode(display.start, of: id),
                  !(CGDisplayCopyDisplayMode(id).map { DisplayArrangement.sameMode($0, wanted) } ?? false)
            else { return nil }
            return (id, wanted)
        }
        // Where they were, once main is off them (`keepStreamingDisplayOffMain` hands it back)
        // and none is freed: WindowServer moves them about a display that came or went.
        let online = DisplayArrangement.onlineDisplayIDs()
        let mainID = CGMainDisplayID()
        let origins = !free.isEmpty || (streaming.contains(mainID) && !streamingDisplayIsMainByChoice) ? [:]
            : Self.originsBack(before: framesBeforeSetChange,
                               now: Dictionary(uniqueKeysWithValues: online.map { ($0, CGDisplayBounds($0)) }),
                               streaming: streaming, mirroring: Set(online.filter { CGDisplayMirrorsDisplay($0) != 0 }),
                               main: mainID)
        guard !free.isEmpty || !modes.isEmpty || !origins.isEmpty else { return }
        sdLog.debug("the display set changed; freeing \(free) from mirrors, modes back on \(modes.map(\.0)), moving \(Array(origins.keys))")
        // So no layout DAM puts back (an anchor's, the streaming one) mirrors or moves them again.
        if !free.isEmpty { keepUserMirror(free, on: 0) }
        if !origins.isEmpty {
            streamingSettle = streamingSettle.map { ($0.arrangement.replacingOrigins(origins), $0.until) }
            for (name, arrangement) in virtualAnchorArrangements {
                virtualAnchorArrangements[name] = arrangement.replacingOrigins(origins)
            }
        }
        streamingMirrorReleaseInFlight = true
        commitDisplayChange({ cfg in
            for id in free { VideoManager.configureMirror(cfg, id, CGDirectDisplayID(0)) }
            for (id, mode) in modes { CGConfigureDisplayWithDisplayMode(cfg, id, mode, nil) }
            for (id, origin) in origins {
                CGConfigureDisplayOrigin(cfg, id, Int32(origin.x.rounded()), Int32(origin.y.rounded()))
            }
        }) { [weak self] _ in self?.streamingMirrorReleaseInFlight = false }
    }

    /// An addition, removal, resize or rotation of a streaming display, waiting its turn. An
    /// addition says when its display is placed, with its ID, or that none could be made,
    /// with nil; a resize or rotation whether it was done. The modes asked for are the
    /// stream's, before the display's rotation.
    enum StreamingRequest {
        case add(StreamingDisplayModes.Mode, standIn: StandIn? = nil, identity: StreamingIdentity? = nil,
                 main: Bool = false, completion: ((CGDirectDisplayID?) -> Void)?)
        /// The display to remove, by its CGVirtualDisplay: its slot can go to a newer one
        /// while the removal waits.
        case remove(display: AnyObject)
        case resize(id: CGDirectDisplayID, StreamingDisplayModes.Mode, completion: (Bool) -> Void)
        case rotate(id: CGDirectDisplayID, DisplayRotation, completion: (Bool) -> Void)
        /// A stand-in and the screen it covers trading places (see `swapPlaces`).
        case swap(standIn: CGDirectDisplayID, screen: CGDirectDisplayID)

        var isAddition: Bool {
            if case .add = self { return true }
            return false
        }

        /// How many displays it adds: 1, -1, or 0 for a resize.
        var countChange: Int {
            switch self {
            case .add: return 1
            case .remove: return -1
            case .resize, .rotate, .swap: return 0
            }
        }
    }

    typealias StreamingIdentity = StreamingDisplayIdentity

    /// A streaming display made to stand in for another display: turned as asked, and not
    /// kept as the rotation of its place.
    struct StandIn {
        let name: String
        let rotation: DisplayRotation
    }

    /// How many streaming displays there will be once the requests waiting are done.
    var plannedStreamingDisplayCount: Int {
        streamingRequests.reduce(streamingDisplays.count) { $0 + $1.countChange }
    }

    var canCreateStreamingDisplay: Bool { plannedStreamingDisplayCount < Self.maxStreamingDisplays }

    /// Asks for one more streaming display, in `mode`, called and known as `identity` says if
    /// given, and made main as it is placed when `main`, in the same commit rather than one
    /// after; `completion` gets its ID once it is placed, or nil if none could be made.
    /// Additions and removals run one at a time, each once the one before has settled.
    func createStreamingDisplay(mode: StreamingDisplayModes.Mode = StreamingDisplayModes.start,
                                identity: StreamingIdentity? = nil, main: Bool = false,
                                completion: ((CGDirectDisplayID?) -> Void)? = nil) {
        guard canCreateStreamingDisplay else { completion?(nil); return }
        streamingRequests.append(.add(mode, identity: identity, main: main, completion: completion))
        processStreamingRequests()
    }

    /// Asks for the streaming display shown as `display` to be removed.
    func removeStreamingDisplay(_ display: DisplayInfo) {
        removeStreamingDisplay(id: display.cgDisplayID)
    }

    /// Asks for the streaming display `id` to be removed.
    func removeStreamingDisplay(id: CGDirectDisplayID) {
        guard id != 0, let display = streamingDisplays.first(where: { $0.id == id })?.display,
              !streamingRequests.contains(where: {
                  if case .remove(let waiting) = $0 { return waiting === display } else { return false }
              })
        else { return }
        streamingRequests.append(.remove(display: display))
        processStreamingRequests()
    }

    /// Asks for streaming display `id` to change to `mode` where it is, as a display made for
    /// a stream does when the stream comes back at another size. It keeps its ID and windows,
    /// and takes well under a second where a new display takes several. `completion` gets
    /// false when it can't be done, as when `mode` is bigger than the display was made for.
    func resizeStreamingDisplay(id: CGDirectDisplayID, to mode: StreamingDisplayModes.Mode,
                                completion: @escaping (Bool) -> Void) {
        streamingRequests.append(.resize(id: id, mode, completion: completion))
        processStreamingRequests()
    }

    /// Asks for a streaming display to stand in for the display named `standIn.name`, turned
    /// by `standIn.rotation`; `completion` gets its ID once placed, or nil.
    func createStandInDisplay(mode: StreamingDisplayModes.Mode, standIn: StandIn,
                              completion: @escaping (CGDirectDisplayID?) -> Void) {
        guard canCreateStreamingDisplay else { return completion(nil) }
        streamingRequests.append(.add(mode, standIn: standIn, completion: completion))
        processStreamingRequests()
    }

    /// The IDs of the online streaming displays that stand in for another display.
    var standInDisplayIDs: Set<CGDirectDisplayID> {
        Set(streamingDisplays.filter { $0.standsInFor != nil }.map(\.id)).subtracting([0])
    }

    /// Asks for streaming display `id` to be turned to `rotation` where it is: on its side,
    /// it trades its width and height, and streams of it turn their frames back, so they
    /// keep their shape. Kept for the next display in its place.
    func rotateStreamingDisplay(id: CGDirectDisplayID, to rotation: DisplayRotation,
                                completion: @escaping (Bool) -> Void) {
        streamingRequests.append(.rotate(id: id, rotation, completion: completion))
        processStreamingRequests()
    }

    /// The rotation of the streaming display `id`, or nil if it is none.
    func streamingRotation(of id: CGDirectDisplayID) -> DisplayRotation? {
        guard id != 0 else { return nil }
        return streamingDisplays.first { $0.id == id }?.rotation
    }

    /// Tells the capture threads how far each streaming display is turned.
    func publishStreamRotations() {
        StreamRotations.shared.update(Dictionary(
            streamingDisplays.filter { $0.id != 0 }.map { ($0.id, $0.rotation) }, uniquingKeysWith: { a, _ in a }))
    }

    /// Starts the next request, unless a change is under way; that one calls this again
    /// when it is done.
    func processStreamingRequests() {
        while !streamingChangeInFlight, !streamingReassertInFlight, !wakeRestoreInFlight, !streamingRequests.isEmpty {
            switch streamingRequests.removeFirst() {
            case .add(let mode, let standIn, let identity, let main, let completion):
                addStreamingDisplay(mode, standIn: standIn, identity: identity, main: main, completion: completion)
            case .remove(let display):              removeStreamingDisplay(display)
            case .resize(let id, let mode, let completion):
                let rotation = streamingRotation(of: id) ?? .standard
                resizeStreamingDisplay(id: id, mode: mode.rotated(rotation), completion: completion)
            case .rotate(let id, let rotation, let completion):
                rotateStreamingDisplay(id: id, rotation: rotation, completion: completion)
            case .swap(let standIn, let screen):
                commitSwap(standIn, screen)
            }
        }
    }

    /// Ends the change under way and starts the next, if any is waiting. `placed` is the
    /// display an addition placed, nil when it made none.
    private func finishStreamingChange(placed: CGDirectDisplayID? = nil) {
        streamingChangeInFlight = false
        streamingChangeLayout = nil
        publishStreamRotations()
        let completion = streamingAddCompletion
        streamingAddCompletion = nil
        completion?(placed)
        keepStreamingDisplayOffMain()
        processStreamingRequests()
    }

    /// Creates a streaming display in `mode` and places it right of the other displays. The
    /// arrangement from before the first is put back when the last is removed.
    private func addStreamingDisplay(_ mode: StreamingDisplayModes.Mode, standIn: StandIn?,
                                     identity: StreamingIdentity?, main: Bool,
                                     completion: ((CGDirectDisplayID?) -> Void)?) {
        let used = Set(streamingDisplays.map(\.index))
        guard mode.isValid, let index = (0..<Self.maxStreamingDisplays).first(where: { !used.contains($0) }) else {
            if !mode.isValid { sdLog.error("add: no display can be made at \(mode.width)×\(mode.height)@\(mode.refreshRate)") }
            completion?(nil)
            return
        }
        // Two at once for the same seed would be one display to macOS; the second takes its slot's.
        let ownSerial = identity.map { Self.streamingSerial(seed: $0.seed) }
            .flatMap { serial in streamingDisplays.contains { $0.serial == serial } ? nil : serial }
        let serial = ownSerial ?? Self.streamingSerial(index)
        // Named after the display it stands in for, which System Settings shows it as.
        let name = standIn.map { Self.standInDisplayName(for: $0.name) }
            ?? identity.map { ownSerial != nil ? $0.name : "\($0.name) \(index + 1)" }
            ?? Self.streamingDisplayName(index)
        let rotation = standIn?.rotation ?? StreamingRotationPreferences.rotation(for: name)
        let mode = mode.rotated(rotation)
        sdLog.debug("add \(index) at \(mode.width)×\(mode.height)@\(mode.refreshRate)\(mode.hiDPI ? " HiDPI" : "")")

        let descriptor = CGVirtualDisplayDescriptor()
        // Must call setDispatchQueue: (see enableVirtualAnchor).
        descriptor.setDispatchQueue(.main)
        descriptor.name = name
        descriptor.sizeInMillimeters = CGSize(width: 600, height: 340)
        // As much either way, so it can be turned on its side where it is.
        let side = max(StreamingDisplayModes.maxPixelsSide, mode.pixelWidth, mode.pixelHeight)
        descriptor.maxPixelsWide = UInt32(side)
        descriptor.maxPixelsHigh = UInt32(side)
        descriptor.vendorID  = Self.anchorVendorID
        descriptor.productID = Self.streamingProductID
        descriptor.serialNum = serial
        // By the display, not its slot: one DAM removed can end once its slot holds another.
        descriptor.terminationHandler = { [weak self] _, vd in
            DispatchQueue.main.async { self?.streamingDisplayEnded(vd) }
        }

        // Taken before the display comes, to put the others back once WindowServer has laid
        // the new set out; it holds the streaming displays already there. Right after another
        // change, the layout kept for it: WindowServer may still be changing the current one.
        let before = activeStreamingSettle ?? DisplayArrangement.current()
        // Kept for the set without the new display, which it would no longer match.
        streamingSettle = nil
        streamingSettleAwaitsRemoval = nil
        if streamingDisplays.isEmpty {
            streamingArrangement = before
            streamingDisplayIsMainByChoice = false
        }
        let vd = CGVirtualDisplay(descriptor: descriptor)
        guard vd.apply(StreamingDisplayModes.settings(startingIn: mode)) else {
            sdLog.error("add: applySettings failed")
            if streamingDisplays.isEmpty { streamingArrangement = nil }
            completion?(nil)
            // The additions waiting would fail the same way.
            for case .add(_, _, _, _, let waiting) in streamingRequests { waiting?(nil) }
            streamingRequests.removeAll(where: \.isAddition)
            return
        }
        streamingDisplays.append(StreamingDisplay(display: vd, index: index, name: name, serial: serial,
                                                  start: mode, rotation: rotation, standsInFor: standIn?.name))
        streamingAddCompletion = completion
        streamingChangeInFlight = true
        // Stored, so a change made through DAM before the display is placed reaches it.
        beginStreamingChange(from: before)
        waitForStreamingDisplay(vd, index: index, serial: serial, main: main)
    }

    /// Removes streaming display `display`, if it is still there, and puts the others back
    /// where they were: where they were before the first came once it is the last.
    private func removeStreamingDisplay(_ display: AnyObject) {
        guard let i = streamingDisplays.firstIndex(where: { $0.display === display }) else { return }
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
        // Its ID can come back for another display.
        displaysMirroredByChoice.remove(last.id)
        streamingDisplaysMirroringByChoice.remove(last.id)
        // Dropping the last reference removes the display. While the set settles without
        // it, each change puts the resolutions and positions back if WindowServer's saved
        // layout for the smaller set changed them.
        streamingDisplays.remove(at: i)
        if streamingDisplays.isEmpty { streamingArrangement = nil }
        // Its 5 s start once WindowServer has taken the display off (startSettleOnceRemoved),
        // which can take seconds; in 15 s at the most.
        streamingSettle = arrangement.map { ($0, Date().addingTimeInterval(15)) }
        streamingSettleAwaitsRemoval = arrangement.map { _ in last.id }
        streamingChangeInFlight = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.mergeDevices() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.startSettleOnceRemoved()
            self?.reassertStreamingLayout()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.mergeDevices()
                self?.finishStreamingChange()
            }
        }
    }

    /// Notes that an addition or resize has begun, putting the displays back to `layout`.
    private func beginStreamingChange(from layout: DisplayArrangement) {
        streamingChangesBegun += 1
        streamingChangeLayout = layout
    }

    /// Starts the settle's 5 s after a removal once the display is no longer online.
    func startSettleOnceRemoved() {
        guard let id = streamingSettleAwaitsRemoval, !DisplayArrangement.onlineDisplayIDs().contains(id) else { return }
        streamingSettleAwaitsRemoval = nil
        streamingSettle = streamingSettle.map { ($0.arrangement, Date().addingTimeInterval(5)) }
    }

    /// The layout kept after the last change, until it expires.
    var activeStreamingSettle: DisplayArrangement? {
        streamingSettle.flatMap { $0.until > Date() ? $0.arrangement : nil }
    }

    /// Puts back the layout kept after a streaming display was added, removed or resized, until
    /// it expires, in one commit at a time: which displays mirror which, positions, and, for the
    /// same set, resolutions. Commits only what differs, so its own commits end the cycle.
    /// Permanently: they are the layout the set had, which WindowServer's saved one undid. A
    /// resize makes WindowServer apply the layout it saved for the set, which can mirror the
    /// other displays onto the streaming one, a second or so after DAM's own commit.
    func reassertStreamingLayout() {
        guard !streamingReassertInFlight, let settle = streamingSettle else { return }
        guard settle.until > Date() else { streamingSettle = nil; return }
        let arrangement = settle.arrangement
        // Not what the anchors keep: the layout can be from before an anchor came or went.
        let excluded = anchorManagedDisplayIDs
        let start = Self.configureDisplays(in: .permanently, { cfg in
            // Resolutions only for the same displays, mirrored the same way (see sameSet).
            let sameSet = DisplayArrangement.sameSet(captured: arrangement.mirrorMasters,
                                                     online: DisplayArrangement.onlineDisplayIDs(),
                                                     mirrorOf: { CGDisplayMirrorsDisplay($0) })
            let resized = sameSet && arrangement.restoreModes(in: cfg, excluding: excluded)
            return arrangement.restore(in: cfg, excluding: excluded) || resized
        }) { [weak self] err in
            sdLog.debug("reassert: CompleteDisplayConfiguration err=\(err.rawValue)")
            guard let self else { return }
            // A change that arrived meanwhile was skipped; look now.
            self.streamingReassertInFlight = false
            self.reassertStreamingLayout()
            self.processStreamingRequests()
        }
        if case .committing = start { streamingReassertInFlight = true }
    }

    /// Gives streaming display `id` a mode list starting with `mode`, then switches to it once
    /// WindowServer lists it, putting the others back as they were.
    private func resizeStreamingDisplay(id: CGDirectDisplayID, mode: StreamingDisplayModes.Mode,
                                        completion: @escaping (Bool) -> Void) {
        guard id != 0, mode.isValid, let i = streamingDisplays.firstIndex(where: { $0.id == id }),
              let vd = streamingDisplays[i].display as? CGVirtualDisplay,
              mode.pixelWidth <= Int(vd.maxPixelsWide), mode.pixelHeight <= Int(vd.maxPixelsHigh) else {
            return completion(false)
        }
        // A mirror the user made through DAM is kept; any other goes, so that the display shows
        // its own desktop at the new size.
        let keepsMirror = CGDisplayMirrorsDisplay(id) != 0 && streamingDisplaysMirroringByChoice.contains(id)
        // What it runs, asked before the new mode list: once a virtual display is given one, it
        // reports the list's first mode as its own straight away, while it still runs the old one.
        let running = CGDisplayCopyDisplayMode(id)
        // Already in it, mirroring nothing or as chosen: nothing to do.
        if CGDisplayMirrorsDisplay(id) == 0 || keepsMirror, let running, let wanted = Self.displayMode(mode, of: id),
           DisplayArrangement.sameMode(wanted, running) {
            keepUserMode(running, for: id)
            streamingDisplays[i].start = mode
            return completion(true)
        }
        let index = streamingDisplays[i].index
        sdLog.debug("resize \(index) to \(mode.width)×\(mode.height)@\(mode.refreshRate)\(mode.hiDPI ? " HiDPI" : "")")
        guard vd.apply(StreamingDisplayModes.settings(startingIn: mode)) else {
            sdLog.error("resize: applySettings failed")
            return completion(false)
        }
        // The layout kept after the last change holds its old size, which a reassert before
        // the switch would put back.
        streamingSettle?.arrangement.modes[id] = nil
        streamingChangeInFlight = true
        beginStreamingChange(from: activeStreamingSettle ?? DisplayArrangement.current())
        switchStreamingDisplay(id, to: mode, keepingMirror: keepsMirror, attempt: 0) { [weak self, weak vd] done in
            // Only once it runs it: a rotation that failed goes back to the old one.
            if done, let i = self?.streamingDisplays.firstIndex(where: { $0.id == id }) {
                self?.streamingDisplays[i].start = mode
            } else if !done, let running {
                // Its mode list goes back to one led by what it still runs, or it would go on
                // reporting the new mode as its own, and asking for that again would do nothing.
                sdLog.debug("resize: failed; listing \(running.width)×\(running.height) first again")
                _ = vd?.apply(StreamingDisplayModes.settings(startingIn: StreamingDisplayModes.Mode(running)))
            }
            completion(done)
        }
    }

    /// Turns streaming display `id` to `rotation`: resizes it to its mode turned the new way,
    /// and saves the rotation for its place.
    private func rotateStreamingDisplay(id: CGDirectDisplayID, rotation: DisplayRotation,
                                        completion: @escaping (Bool) -> Void) {
        guard let i = streamingDisplays.firstIndex(where: { $0.id == id && id != 0 }) else { return completion(false) }
        let display = streamingDisplays[i]
        let kept = display.standsInFor == nil
        if kept { StreamingRotationPreferences.setRotation(rotation, for: display.name) }
        guard rotation != display.rotation else { return completion(true) }
        sdLog.debug("rotate \(display.index) to \(rotation.rawValue)")
        let mode = display.start.rotated(display.rotation.inverse).rotated(rotation)
        streamingDisplays[i].rotation = rotation
        resizeStreamingDisplay(id: id, mode: mode) { [weak self] done in
            guard let self else { return completion(done) }
            if !done, let i = self.streamingDisplays.firstIndex(where: { $0.id == id }) {
                self.streamingDisplays[i].rotation = display.rotation
                if kept {
                    StreamingRotationPreferences.setRotation(display.rotation, for: display.name)
                }
            }
            self.publishStreamRotations()
            completion(done)
        }
    }

    /// Switches `id` to `mode` once WindowServer lists it, which takes a moment after a new
    /// mode list; gives up after two seconds. Unless `keepingMirror`, it stops mirroring. The
    /// others go back as `streamingChangeLayout` has them. `completion` runs before the next
    /// change starts.
    private func switchStreamingDisplay(_ id: CGDirectDisplayID, to mode: StreamingDisplayModes.Mode,
                                        keepingMirror: Bool, attempt: Int,
                                        completion: @escaping (Bool) -> Void) {
        guard let target = Self.displayMode(mode, of: id) else {
            guard attempt < 20, DisplayArrangement.onlineDisplayIDs().contains(id) else {
                sdLog.error("resize: \(mode.width)×\(mode.height) never listed")
                completion(false)
                return finishStreamingChange()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.switchStreamingDisplay(id, to: mode, keepingMirror: keepingMirror,
                                             attempt: attempt + 1, completion: completion)
            }
            return
        }
        let before = streamingChangeLayout ?? DisplayArrangement.current()
        let master = keepingMirror ? CGDisplayMirrorsDisplay(id) : 0
        let origin = before.origins[id] ?? CGDisplayBounds(id).origin
        let settle = { [weak self] (done: Bool) in
            guard let self else { return completion(false) }
            // Or an anchor settling would put the old size back (see reassertAnchorLayout).
            if done { self.keepUserMode(target, for: id) }
            // As it is now: a change made through DAM meanwhile is in it.
            let others = (self.streamingChangeLayout ?? before).excluding(id)
            // Failed, it still runs its old mode, which the layout taken after the new list
            // doesn't hold.
            let kept = done ? others.adding(id, origin: origin, mode: target, mirroring: master) : others
            self.streamingSettle = (kept, Date().addingTimeInterval(5))
            self.streamingSettleAwaitsRemoval = nil
            self.reassertStreamingLayout()
            self.mergeDevices()
            completion(done)
            self.finishStreamingChange()
        }
        // For the session, as placing one is.
        let start = Self.configureDisplays(in: .forSession, { cfg in
            // WindowServer may mirror, move or resize the others for the new size.
            if CGDisplayMirrorsDisplay(id) != master { VideoManager.configureMirror(cfg, id, master) }
            _ = before.restore(in: cfg, excluding: [id])
            before.restoreModes(in: cfg, excluding: [id])
            // Always: given a new mode list, the display reports `target` as its mode already
            // (see resizeStreamingDisplay), so asking whether it runs it says nothing.
            CGConfigureDisplayWithDisplayMode(cfg, id, target, nil)
            return true
        }) { err in
            sdLog.debug("resize: CompleteDisplayConfiguration err=\(err.rawValue)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settle(err == .success) }
        }
        if case .failed = start {
            completion(false)
            finishStreamingChange()
        }
    }

    /// The mode of `id` that is `mode`: its size, rate and scale.
    static func displayMode(_ mode: StreamingDisplayModes.Mode, of id: CGDirectDisplayID) -> CGDisplayMode? {
        DisplayArrangement.listedModes(of: id).first {
            $0.width == mode.width && $0.height == mode.height && $0.pixelWidth == mode.pixelWidth
                && $0.pixelHeight == mode.pixelHeight
                && DisplayArrangement.RateMatch.wholeHertz.matches($0.refreshRate, Double(mode.refreshRate))
        }
    }

    /// Forgets streaming display `vd` after WindowServer ended it.
    private func streamingDisplayEnded(_ vd: AnyObject?) {
        guard let vd, let i = streamingDisplays.firstIndex(where: { $0.display === vd }) else { return }
        sdLog.debug("terminationHandler: streaming display \(self.streamingDisplays[i].index) ended")
        let id = streamingDisplays[i].id
        // Main as last seen: gone, it is main no more.
        let wasMain = id != 0 && (CGDisplayIsMain(id) != 0 || allConnectedDisplays.contains { $0.cgDisplayID == id && $0.isMain })
        displaysMirroredByChoice.remove(id)
        streamingDisplaysMirroringByChoice.remove(id)
        streamingDisplays.remove(at: i)
        if streamingDisplays.isEmpty { streamingArrangement = nil }
        // As for one removed: main by choice no longer, or another streaming display handed
        // main would be left it.
        if streamingDisplays.isEmpty || wasMain { streamingDisplayIsMainByChoice = false }
        publishStreamRotations()
        mergeDevices()
    }

    private func isStreamingDisplay(_ vd: CGVirtualDisplay) -> Bool {
        streamingDisplays.contains { $0.display === vd }
    }

    private func waitForStreamingDisplay(_ vd: CGVirtualDisplay, index: Int, serial: UInt32, main: Bool) {
        whenOnline(vd, product: Self.streamingProductID, serial: serial,
                   wanted: { [weak self] in self?.isStreamingDisplay(vd) ?? false }) { [weak self] search in
            guard let self else { return }
            switch search {
            case .found(let id):
                sdLog.debug("\(index) online as \(id)")
                if let i = self.streamingDisplays.firstIndex(where: { $0.display === vd }) { self.streamingDisplays[i].id = id }
                // Let WindowServer lay out the new set first; it would undo a placement made before.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self else { return }
                    guard self.isStreamingDisplay(vd) else { return self.finishStreamingChange() }
                    self.placeStreamingDisplay(id, main: main)
                }
            case .released:
                // Ended meanwhile; nothing else finishes this change.
                self.finishStreamingChange()
            case .neverCame:
                sdLog.error("\(index) never came online — dropping it")
                self.streamingDisplays.removeAll { $0.display === vd }
                if self.streamingDisplays.isEmpty { self.streamingArrangement = nil }
                self.finishStreamingChange()
            }
        }
    }

    /// Puts the other displays back as `streamingChangeLayout` has them (as they were before
    /// the addition, with what was changed through DAM since), switches the new display to its
    /// start mode, and sets it right of the rest; with `main`, the whole arrangement then
    /// slides so that it is main.
    private func placeStreamingDisplay(_ id: CGDirectDisplayID, main: Bool) {
        let before = streamingChangeLayout ?? DisplayArrangement.current()
        let start = streamingDisplays.first { $0.id == id }?.start ?? StreamingDisplayModes.start
        let startMode = Self.displayMode(start, of: id)
        if startMode == nil { sdLog.error("place: no \(start.width)×\(start.height) mode") }
        let others = before.origins.compactMap { otherID, origin -> CGRect? in
            guard otherID != id, before.mirrorMasters[otherID] == 0 else { return nil }
            // The size it is put back to, not the one WindowServer gave it.
            let size = before.modes[otherID].map { CGSize(width: $0.width, height: $0.height) }
            return CGRect(origin: origin, size: size ?? CGDisplayBounds(otherID).size)
        }
        let origin = Self.streamingDisplayOrigin(others: others)
        var placed = before.adding(id, origin: origin, mode: startMode ?? CGDisplayCopyDisplayMode(id))
        if main { placed = placed.makingMain(id) }
        // From now on what a change made through DAM reaches, until the settle takes it over.
        streamingChangeLayout = placed
        let settle = { [weak self] in
            // WindowServer can still change the others' resolutions for the new set.
            self?.streamingSettle = (self?.streamingChangeLayout ?? placed, Date().addingTimeInterval(5))
            self?.streamingSettleAwaitsRemoval = nil
            self?.reassertStreamingLayout()
            self?.mergeDevices()
            // The display that was main may be gone, and a commit that changes nothing
            // fires no reconfiguration to check this.
            self?.finishStreamingChange(placed: id)
        }
        // For the session, not the app: when another app's own changes end, WindowServer goes
        // back to the session's layout, which would undo app-only ones.
        let transaction = Self.configureDisplays(in: .forSession, { cfg in
            // Set before the commit, or the check after it would hand main back; not before
            // the configuration begins, or a failure there would leave it set.
            if main { streamingDisplayIsMainByChoice = true }
            // WindowServer may have mirrored, moved or changed the resolutions of the others for
            // the new set, or laid it out as placed already, from a layout it saved for the set.
            let moved = placed.restore(in: cfg, excluding: [])
            return placed.restoreModes(in: cfg, excluding: []) || moved
        }) { err in
            sdLog.debug("place: CompleteDisplayConfiguration err=\(err.rawValue)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: settle)
        }
        switch transaction {
        case .committing:
            break
        case .unchanged:
            sdLog.debug("place: already in place")
            settle()
        case .failed:
            // Told none was made, so none is left: dropping it removes it, as for one that
            // never came online.
            sdLog.error("place: could not begin a configuration — dropping \(id)")
            streamingDisplays.removeAll { $0.id == id }
            if streamingDisplays.isEmpty { streamingArrangement = nil }
            mergeDevices()
            finishStreamingChange()
        }
    }
}

extension StreamingDisplayModes {
    /// Whether `mode` renders within the largest size listed, either way up.
    static func fits(_ mode: DisplayMode) -> Bool {
        (mode.pixelWidth <= maxPixelsWide && mode.pixelHeight <= maxPixelsHigh)
            || (mode.pixelWidth <= maxPixelsHigh && mode.pixelHeight <= maxPixelsWide)
    }
}
