//
//  DisplayLayout.swift
//
//  The arrangement of the displays that show their own desktop, in the global display
//  space CoreGraphics uses (points, y down, the main display's top-left corner at the
//  origin), and the moves the Arrange Displays window and the "Position" menu make on it.
//  Every move keeps the rule WindowServer enforces: displays never overlap, and each one
//  shares part of an edge with another, so the pointer can always cross between them.
//

import CoreGraphics
import Foundation

/// One rectangle of the arrangement: a display showing its own desktop, positioned by
/// `id`. A user mirror set is one rectangle, positioned by its master and named after
/// every member; a display driven by a virtual anchor is positioned by the anchor.
struct DisplayPlacement: Equatable {
    let id: CGDirectDisplayID
    var frame: CGRect
    /// The display, or every display of the mirror set, shown here.
    let names: [String]
    let isMain: Bool
    /// The displays shown here, by ID: the positioned one, or the mirror set's members.
    let memberIDs: [CGDirectDisplayID]

    init(id: CGDirectDisplayID, frame: CGRect, names: [String], isMain: Bool,
         memberIDs: [CGDirectDisplayID]? = nil) {
        self.id = id
        self.frame = frame
        self.names = names
        self.isMain = isMain
        self.memberIDs = memberIDs ?? [id]
    }

    var name: String { names.joined(separator: " + ") }
}

/// Which side of another display a display is put on.
enum PlacementSide: CaseIterable {
    case left, right, above, below

    var label: String {
        switch self {
        case .left:  return "Left of"
        case .right: return "Right of"
        case .above: return "Above"
        case .below: return "Below"
        }
    }
}

struct DisplayLayout: Equatable {
    var placements: [DisplayPlacement]

    /// How much edge two displays must share to count as attached, and the least a drop
    /// leaves them sharing.
    static let minimumSharedEdge: CGFloat = 40

    init(placements: [DisplayPlacement]) {
        self.placements = placements
    }

    subscript(id: CGDirectDisplayID) -> DisplayPlacement? {
        placements.first { $0.id == id }
    }

    var main: DisplayPlacement? { placements.first(where: \.isMain) }

    /// How many displays are shown, counting each member of a mirror set.
    var displayCount: Int { placements.reduce(0) { $0 + $1.memberIDs.count } }

    /// The origin of every placement, with `main` (or the current main display) at the
    /// origin, which is what makes it the main display when applied.
    func origins(makingMain main: CGDirectDisplayID? = nil) -> [CGDirectDisplayID: CGPoint] {
        let anchor = (main.flatMap { self[$0] } ?? self.main ?? placements.first)?.frame.origin ?? .zero
        return Dictionary(uniqueKeysWithValues: placements.map {
            ($0.id, CGPoint(x: $0.frame.minX - anchor.x, y: $0.frame.minY - anchor.y))
        })
    }

    // MARK: - Moving

    /// The layout with display `id` dropped as near `origin` as the rules allow: it lands
    /// on the closest edge of another display and never on top of one. Displays that the
    /// move would leave detached are pulled along to the nearest edge too.
    func moving(_ id: CGDirectDisplayID, to origin: CGPoint) -> DisplayLayout {
        guard let index = placements.firstIndex(where: { $0.id == id }) else { return self }
        var result = self
        var frame = placements[index].frame
        frame.origin = origin
        let others = placements.enumerated().filter { $0.offset != index }.map(\.element.frame)
        result.placements[index].frame = Self.snap(frame, to: others) ?? frame
        return result.reattached(around: id)
    }

    /// The layout with display `id` put on `side` of display `other`, centred along the
    /// shared edge; the rest is left where it is, pulled along if the move detached it.
    func placing(_ id: CGDirectDisplayID, _ side: PlacementSide, of other: CGDirectDisplayID) -> DisplayLayout {
        guard id != other, let moving = self[id], let target = self[other] else { return self }
        let size = moving.frame.size, t = target.frame
        let origin: CGPoint
        switch side {
        case .left:  origin = CGPoint(x: t.minX - size.width, y: t.midY - size.height / 2)
        case .right: origin = CGPoint(x: t.maxX, y: t.midY - size.height / 2)
        case .above: origin = CGPoint(x: t.midX - size.width / 2, y: t.minY - size.height)
        case .below: origin = CGPoint(x: t.midX - size.width / 2, y: t.maxY)
        }
        return self.moving(id, to: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()))
    }

    /// The side of `other` that display `id` sits on, when the two share an edge.
    func side(of id: CGDirectDisplayID, relativeTo other: CGDirectDisplayID) -> PlacementSide? {
        guard let a = self[id]?.frame, let b = self[other]?.frame else { return nil }
        if Self.sharedEdge(a, b, vertical: true) {
            if a.maxX == b.minX { return .left }
            if a.minX == b.maxX { return .right }
        }
        if Self.sharedEdge(a, b, vertical: false) {
            if a.maxY == b.minY { return .above }
            if a.minY == b.maxY { return .below }
        }
        return nil
    }

    // MARK: - Mirroring

    /// How much of the smaller of two displays a held display must cover for the other to
    /// count as underneath it.
    static let mirrorCoverage: CGFloat = 0.4

    /// The displays under display `id` when it is held at `frame`: each other placement
    /// that it and `frame` cover enough of each other, in the layout's order.
    func displaysUnder(_ id: CGDirectDisplayID, at frame: CGRect) -> [CGDirectDisplayID] {
        placements.filter { other in
            guard other.id != id else { return false }
            let common = frame.intersection(other.frame)
            guard !common.isNull, !common.isEmpty else { return false }
            let smaller = min(frame.width * frame.height, other.frame.width * other.frame.height)
            return common.width * common.height >= Self.mirrorCoverage * smaller
        }.map(\.id)
    }

    // MARK: - Rules

    /// Whether every display can be reached from every other across shared edges.
    var isConnected: Bool {
        guard let first = placements.first else { return true }
        return Self.component(of: first.id, in: placements).count == placements.count
    }

    /// `rect` moved the shortest way onto an edge of one of `others`, without overlapping
    /// any of them; nil when no edge takes it. Along the edge it keeps its position, clamped
    /// so the two still share `minimumSharedEdge`.
    static func snap(_ rect: CGRect, to others: [CGRect]) -> CGRect? {
        var best: (rect: CGRect, distance: CGFloat)?
        for other in others {
            for candidate in candidates(for: rect, beside: other)
            where !others.contains(where: { overlaps(candidate, $0) }) {
                let dx = candidate.minX - rect.minX, dy = candidate.minY - rect.minY
                let distance = dx * dx + dy * dy
                if best == nil || distance < best!.distance { best = (candidate, distance) }
            }
        }
        return best?.rect
    }

    /// The four positions of `rect` against the edges of `other`.
    private static func candidates(for rect: CGRect, beside other: CGRect) -> [CGRect] {
        let overlap = min(minimumSharedEdge, rect.width, rect.height, other.width, other.height)
        let x = min(max(rect.minX, other.minX - rect.width + overlap), other.maxX - overlap)
        let y = min(max(rect.minY, other.minY - rect.height + overlap), other.maxY - overlap)
        let size = rect.size
        return [
            CGRect(origin: CGPoint(x: other.minX - rect.width, y: y), size: size),
            CGRect(origin: CGPoint(x: other.maxX, y: y), size: size),
            CGRect(origin: CGPoint(x: x, y: other.minY - rect.height), size: size),
            CGRect(origin: CGPoint(x: x, y: other.maxY), size: size),
        ]
    }

    /// Whether two rectangles cover common ground; touching edges do not count.
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }

    /// Whether `a` and `b` touch along a vertical (or horizontal) edge for at least the
    /// minimum shared length.
    private static func sharedEdge(_ a: CGRect, _ b: CGRect, vertical: Bool) -> Bool {
        let overlap = min(minimumSharedEdge, a.width, a.height, b.width, b.height)
        if vertical {
            return (a.maxX == b.minX || a.minX == b.maxX)
                && min(a.maxY, b.maxY) - max(a.minY, b.minY) >= overlap
        }
        return (a.maxY == b.minY || a.minY == b.maxY)
            && min(a.maxX, b.maxX) - max(a.minX, b.minX) >= overlap
    }

    static func attached(_ a: CGRect, _ b: CGRect) -> Bool {
        sharedEdge(a, b, vertical: true) || sharedEdge(a, b, vertical: false)
    }

    private static func component(of id: CGDirectDisplayID, in placements: [DisplayPlacement]) -> Set<CGDirectDisplayID> {
        var seen: Set<CGDirectDisplayID> = [id]
        var queue = [id]
        while let next = queue.popLast(), let frame = placements.first(where: { $0.id == next })?.frame {
            for p in placements where !seen.contains(p.id) && attached(frame, p.frame) {
                seen.insert(p.id)
                queue.append(p.id)
            }
        }
        return seen
    }

    /// Pulls every group of displays not attached to `id`'s group onto its nearest edge,
    /// group by group, keeping each group's own shape.
    private func reattached(around id: CGDirectDisplayID) -> DisplayLayout {
        var result = self
        var attempts = placements.count
        while attempts > 0 {
            attempts -= 1
            let reached = Self.component(of: id, in: result.placements)
            guard reached.count < result.placements.count,
                  let stray = result.placements.first(where: { !reached.contains($0.id) }) else { break }
            let group = Self.component(of: stray.id, in: result.placements)
            let groupFrames = result.placements.filter { group.contains($0.id) }.map(\.frame)
            let union = groupFrames.dropFirst().reduce(groupFrames[0]) { $0.union($1) }
            let anchors = result.placements.filter { reached.contains($0.id) }.map(\.frame)
            guard let landed = Self.snap(union, to: anchors) else { break }
            let dx = landed.minX - union.minX, dy = landed.minY - union.minY
            for i in result.placements.indices where group.contains(result.placements[i].id) {
                result.placements[i].frame = result.placements[i].frame.offsetBy(dx: dx, dy: dy)
            }
        }
        return result
    }
}
