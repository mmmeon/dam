//
//  VideoManager+Arrangement.swift
//
//  Reads the current arrangement of the displays as a `DisplayLayout` and applies a new
//  one, for the Arrange Displays window and the "Position" menu.
//

import CoreGraphics
import Foundation
import os.log

private let arrangeLog = Logger(subsystem: AppIdentity.bundleID, category: "Arrange")

/// A "Position" pick: put the display positioned by `id` on `side` of the one positioned
/// by `other`.
struct PositionSelection {
    let id: CGDirectDisplayID
    let other: CGDirectDisplayID
    let side: PlacementSide
}

extension VideoManager {

    /// The display that positions `display` in the arrangement: itself, or the master of
    /// the mirror set (or the virtual anchor) it follows. Nil when it is not connected.
    func placementID(for display: DisplayInfo) -> CGDirectDisplayID? {
        guard display.cgDisplayID != 0 else { return nil }
        let master = CGDisplayMirrorsDisplay(display.cgDisplayID)
        return master != CGDirectDisplayID(0) ? master : display.cgDisplayID
    }

    /// The arrangement right now: one placement per desktop, in the display list's order
    /// (built-in, externals, then AirPlay). A user mirror set is one placement named after
    /// its members, master first; a display driven by a virtual anchor is placed by the
    /// anchor.
    func currentLayout() -> DisplayLayout {
        let known = (allConnectedDisplays + allAirPlayDevices).filter { $0.cgDisplayID != 0 }
        var order: [CGDirectDisplayID] = []
        var members: [CGDirectDisplayID: [DisplayInfo]] = [:]
        for display in known {
            guard let id = placementID(for: display) else { continue }
            if members[id] == nil { order.append(id) }
            members[id, default: []].append(display)
        }
        return DisplayLayout(placements: order.map { id in
            let set = members[id]!.sorted { ($0.cgDisplayID == id ? 0 : 1) < ($1.cgDisplayID == id ? 0 : 1) }
            return DisplayPlacement(id: id, frame: CGDisplayBounds(id), names: set.map(\.label),
                                    isMain: CGDisplayIsMain(id) != 0,
                                    memberIDs: set.map(\.cgDisplayID))
        })
    }

    /// Applies `layout`: every placement gets its origin, shifted so that `main` (or the
    /// current main display) is at the origin, in one transaction. Mirror slaves follow
    /// their master. The arrangement each virtual anchor will restore on release is updated
    /// too, so the change outlives the anchor.
    func arrange(_ layout: DisplayLayout, main: CGDirectDisplayID? = nil,
                 completion: ((Result<Void, MirrorError>) -> Void)? = nil) {
        let origins = layout.origins(makingMain: main)
        guard !origins.isEmpty else { completion?(.failure(.notConnected)); return }
        guard origins.contains(where: { CGDisplayBounds($0.key).origin != $0.value }) else {
            completion?(.success(()))
            return
        }
        let summary = origins.map { "\($0.key)@\(Int($0.value.x)),\(Int($0.value.y))" }.sorted().joined(separator: " ")
        arrangeLog.debug("arrange: \(summary, privacy: .public)")
        var captured: [CGDirectDisplayID: CGPoint] = [:]
        for placement in layout.placements {
            for member in placement.memberIDs { captured[member] = origins[placement.id] }
        }
        commitDisplayChange({ cfg in
            for (id, origin) in origins {
                CGConfigureDisplayOrigin(cfg, id, Int32(origin.x), Int32(origin.y))
            }
        }) { [weak self] result in
            switch result {
            case .failure(let error):
                arrangeLog.error("arrange: \(String(describing: error))")
            case .success:
                guard let self else { break }
                for (name, arrangement) in self.virtualAnchorArrangements {
                    self.virtualAnchorArrangements[name] = arrangement.replacingOrigins(captured)
                }
            }
            completion?(result)
        }
    }

    /// Mirrors the placement `id` of `layout` onto the placements `targets`: every display
    /// shown there, and every other display already shown with `id`, mirrors the display
    /// that positions `id` (its first member when that is a virtual anchor). An `id` that
    /// places nothing is a display pulled off a mirror set, mirrored on its own.
    func mirror(placement id: CGDirectDisplayID, onto targets: [CGDirectDisplayID], in layout: DisplayLayout,
                completion: ((Result<Void, MirrorError>) -> Void)? = nil) {
        let known = (allConnectedDisplays + allAirPlayDevices).filter { $0.cgDisplayID != 0 }
        let display: (CGDirectDisplayID) -> DisplayInfo? = { cg in known.first { $0.cgDisplayID == cg } }
        let members = layout[id]?.memberIDs ?? [id]
        let masterID = members.contains(id) ? id : members.first ?? id
        guard let master = display(masterID) else { completion?(.failure(.notConnected)); return }
        let slaveIDs = members.filter { $0 != masterID }
            + targets.flatMap { layout[$0]?.memberIDs ?? [] }
        arrangeLog.debug("arrange: mirror \(masterID) onto \(slaveIDs)")
        mirror(master, on: slaveIDs.compactMap(display), completion: completion)
    }

    /// Takes display `id` out of its mirror set and drops it with its own desktop as near
    /// `origin` as the arrangement allows.
    func extend(member id: CGDirectDisplayID, to origin: CGPoint,
                completion: ((Result<Void, MirrorError>) -> Void)? = nil) {
        guard let display = (allConnectedDisplays + allAirPlayDevices).first(where: { $0.cgDisplayID == id }) else {
            completion?(.failure(.notConnected)); return
        }
        arrangeLog.debug("arrange: extend \(id) to \(Int(origin.x)),\(Int(origin.y))")
        extend(display) { [weak self] result in
            guard let self, case .success = result else { completion?(result); return }
            self.arrange(self.currentLayout().moving(id, to: origin), completion: completion)
        }
    }

    /// Applies a "Position" pick on the current arrangement.
    func applyPositionSelection(_ selection: PositionSelection,
                                completion: ((Result<Void, MirrorError>) -> Void)? = nil) {
        arrange(currentLayout().placing(selection.id, selection.side, of: selection.other),
                completion: completion)
    }
}
