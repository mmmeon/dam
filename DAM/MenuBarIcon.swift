//
//  MenuBarIcon.swift
//

import AppKit

/// The menu bar symbol: a reservoir over a knurled dam over an outflow whose width shows how
/// many connections run through the app. Drawn from the same numbers as the Outline page of
/// icon.svg, in units of that 300 x 300 page, scaled to the status item.
enum MenuBarIcon {
    /// Wider than tall, like the symbol; still inside the status item's square length.
    static let size = NSSize(width: 20, height: 18)
    /// The symbol's drawn height, outline included, in points: about that of the system
    /// icons beside it.
    private static let symbolHeight: CGFloat = 13

    private static let page: CGFloat = 300
    private static let centreX: CGFloat = 150
    private static let stroke: CGFloat = 14
    private static let barWidth: CGFloat = 200
    private static let barHeight: CGFloat = 63.3
    private static let topWidth: CGFloat = 270
    private static let topHeight: CGFloat = 60
    /// The outflow's full height; only `cutHeight` of it shows.
    private static let outflowHeight: CGFloat = 100
    private static let cutHeight: CGFloat = 50
    /// Degrees between ridges around the dam.
    static let ridgeSpacing: CGFloat = 25

    /// The outflow's width at no connections, as a fraction of the dam's width.
    private static let trickle: CGFloat = 16 / 129.406
    /// Connections at which the outflow is halfway between a trickle and the dam's width.
    private static let halfway: CGFloat = 4
    /// Connections past this draw the same as this many.
    static let maxCount = 8

    // Curves from the hand-drawn pieces, as fractions of the way between their corners.
    private static let topControls: [(across: CGFloat, down: CGFloat)] = [(0.8928, 0.3416), (0.8658, 0.7816)]
    private static let outflowControls: [(across: CGFloat, down: CGFloat)] = [(0.5297, 0.1455), (0.9001, 0.4318)]

    private static var topY: CGFloat { page / 2 - (topHeight + barHeight + cutHeight) / 2 }
    private static var barY: CGFloat { topY + topHeight }
    private static var barBottom: CGFloat { barY + barHeight }
    private static var barLeft: CGFloat { centreX - barWidth / 2 }

    /// The outflow's uncut lower edge for `count` connections, as a fraction of the dam's width.
    static func outflowFraction(for count: Int) -> CGFloat {
        let n = CGFloat(min(max(count, 0), maxCount))
        return trickle + (1 - trickle) * n / (n + halfway)
    }

    /// A template image of the symbol with the outflow at `fraction` and the dam turned
    /// `spin` degrees; ridges move right as `spin` grows.
    static func image(fraction: CGFloat, spin: CGFloat = 0) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            let scale = symbolHeight / (topHeight + barHeight + cutHeight + stroke)
            let path = symbol(fraction: fraction, spin: spin)
            // The symbol is centred on the page's centre; put that on the image's.
            var transform = AffineTransform(translationByX: rect.midX, byY: rect.midY)
            transform.scale(scale)
            transform.translate(x: -centreX, y: -page / 2)
            path.transform(using: transform)
            path.lineWidth = stroke * scale
            path.lineJoinStyle = .round
            // Round ends on the open curves; the ridges' ends sit under the dam's outline.
            path.lineCapStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func symbol(fraction: CGFloat, spin: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        appendReservoir(to: path)
        path.appendRect(NSRect(x: barLeft, y: barY, width: barWidth, height: barHeight))
        appendOutflow(to: path, fraction: fraction)
        appendRidges(to: path, spin: spin)
        return path
    }

    /// The reservoir's two sides, curving up and out from the dam's top corners. Open at the
    /// top; the dam's outline is its floor.
    private static func appendReservoir(to path: NSBezierPath) {
        let right = centreX + topWidth / 2, barRight = centreX + barWidth / 2
        let rightControl = { (c: (across: CGFloat, down: CGFloat)) in
            NSPoint(x: barRight + c.across * (right - barRight), y: topY + c.down * topHeight)
        }
        let rightSide = [NSPoint(x: right, y: topY), rightControl(topControls[0]),
                         rightControl(topControls[1]), NSPoint(x: barRight, y: barY)]
        appendSides(rightSide.map { NSPoint(x: 2 * centreX - $0.x, y: $0.y) }, to: path)
    }

    /// The outflow's two sides, cut where they have dropped `cutHeight` below the dam. Open
    /// at the bottom, so the gap between their ends shows the width.
    private static func appendOutflow(to path: NSBezierPath, fraction: CGFloat) {
        let bottomLeft = centreX - barWidth * fraction / 2
        let x = { (t: CGFloat) in barLeft + t * (bottomLeft - barLeft) }
        let side = cut([
            NSPoint(x: barLeft, y: barBottom),
            NSPoint(x: x(outflowControls[0].across), y: barBottom + outflowControls[0].down * outflowHeight),
            NSPoint(x: x(outflowControls[1].across), y: barBottom + outflowControls[1].down * outflowHeight),
            NSPoint(x: bottomLeft, y: barBottom + outflowHeight)
        ], atY: barBottom + cutHeight)
        appendSides(side, to: path)
    }

    /// The cubic `left` and its mirror image across the centre, as two open curves.
    private static func appendSides(_ left: [NSPoint], to path: NSBezierPath) {
        let right = left.map { NSPoint(x: 2 * centreX - $0.x, y: $0.y) }
        for side in [left, right] {
            path.move(to: side[0])
            path.curve(to: side[3], controlPoint1: side[1], controlPoint2: side[2])
        }
    }

    /// The part of the cubic `p` above `y`, as its own cubic. `p` must descend steadily.
    private static func cut(_ p: [NSPoint], atY y: CGFloat) -> [NSPoint] {
        let lerp = { (a: NSPoint, b: NSPoint, t: CGFloat) in
            NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        let point = { (t: CGFloat) -> NSPoint in
            let ab = lerp(p[0], p[1], t), bc = lerp(p[1], p[2], t), cd = lerp(p[2], p[3], t)
            return lerp(lerp(ab, bc, t), lerp(bc, cd, t), t)
        }
        var lo: CGFloat = 0, hi: CGFloat = 1
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if point(mid).y < y { lo = mid } else { hi = mid }
        }
        let t = (lo + hi) / 2
        let first = lerp(p[0], p[1], t)
        return [p[0], first, lerp(first, lerp(p[1], p[2], t), t), point(t)]
    }

    /// Ridges on the dam's front face, spaced as on a turning cylinder seen side-on: they
    /// bunch toward the ends and come and go under the dam's outline.
    private static func appendRidges(to path: NSBezierPath, spin: CGFloat) {
        var phase = spin.truncatingRemainder(dividingBy: ridgeSpacing)
        if phase < 0 { phase += ridgeSpacing }
        for k in -4...4 {
            let degrees = CGFloat(k) * ridgeSpacing + phase
            guard abs(degrees) < 90 else { continue }
            let x = centreX + barWidth / 2 * sin(degrees * .pi / 180)
            path.move(to: NSPoint(x: x, y: barY))
            path.line(to: NSPoint(x: x, y: barBottom))
        }
    }
}

/// Shows `MenuBarIcon` on a status item button. When the connection count changes, the
/// outflow eases to its new width while the dam turns, and the dam comes to rest with its
/// ridges where they started.
final class MenuBarIconAnimator {
    static let duration: TimeInterval = 1.5
    /// Degrees the dam turns per second of the change, rounded to whole ridge spacings.
    static let turnRate: CGFloat = 100

    private weak var button: NSStatusBarButton?
    private var count: Int?
    private var fraction = MenuBarIcon.outflowFraction(for: 0)
    private var spin: CGFloat = 0
    private var timer: Timer?

    init(button: NSStatusBarButton?) {
        self.button = button
    }

    /// Shows `count` connections: at once the first time or with Reduce Motion on (unless
    /// `ignoringReduceMotion`, for previews), animated otherwise. A change mid-animation
    /// carries on from where the icon is.
    func show(count newCount: Int, ignoringReduceMotion: Bool = false) {
        let newCount = min(max(newCount, 0), MenuBarIcon.maxCount)
        guard newCount != count else { return }
        let isFirst = count == nil
        count = newCount
        let target = MenuBarIcon.outflowFraction(for: newCount)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !ignoringReduceMotion
        guard !isFirst, !reduceMotion else {
            timer?.invalidate()
            timer = nil
            fraction = target
            spin = 0
            draw()
            return
        }
        animate(to: target)
    }

    private func animate(to target: CGFloat) {
        timer?.invalidate()
        let spacing = MenuBarIcon.ridgeSpacing
        let startFraction = fraction, startSpin = spin
        let turns = max(1, (CGFloat(Self.duration) * Self.turnRate / spacing).rounded())
        let endSpin = ((startSpin / spacing).rounded(.down) + turns) * spacing
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - start) / Self.duration)
            let eased = CGFloat(1 - cos(.pi * progress)) / 2
            self.fraction = startFraction + (target - startFraction) * eased
            self.spin = startSpin + (endSpin - startSpin) * eased
            if progress >= 1 {
                timer.invalidate()
                self.timer = nil
                self.spin = 0
            }
            self.draw()
        }
        // Common modes, so it keeps animating while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func draw() {
        button?.image = MenuBarIcon.image(fraction: fraction, spin: spin)
    }
}
