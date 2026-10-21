//
//  MenuBarIcon.swift
//

import AppKit

/// The menu bar symbol: a reservoir over a knurled dam over an outflow whose width shows how
/// many connections run through the app. Drawn from the same numbers as the Outline page of
/// icons/icon.svg, in units of that 300 x 300 page, scaled to the status item.
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
    /// How far, at full strength, ripples push the outflow's sides at its open end.
    private static let rippleAmplitude: CGFloat = 3
    /// The length of one ripple down the outflow.
    private static let rippleWavelength: CGFloat = 45
    /// How far, at full strength, the reservoir's rim tips as its water sloshes. Up and down,
    /// since the rim already reaches the image's sides.
    private static let slosh: CGFloat = 10
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
    /// `spin` degrees; ridges move right as `spin` grows. The outflow's curve near the dam
    /// bends toward `upstream` (`fraction` if nil), so a stream whose ends disagree bulges.
    /// Ripples at `ripple` strength (0 to 1 swelling out, 0 to -1 pinching in) run down the
    /// outflow, `ripplePhase` waves along,
    /// and the reservoir tips right by `sway` (0 to 1; negative tips left).
    static func image(fraction: CGFloat, spin: CGFloat = 0, upstream: CGFloat? = nil,
                      ripple: CGFloat = 0, ripplePhase: CGFloat = 0, sway: CGFloat = 0) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            let scale = symbolHeight / (topHeight + barHeight + cutHeight + stroke)
            let path = symbol(fraction: fraction, upstream: upstream ?? fraction, spin: spin,
                              ripple: ripple, ripplePhase: ripplePhase, sway: sway)
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

    private static func symbol(fraction: CGFloat, upstream: CGFloat, spin: CGFloat,
                               ripple: CGFloat, ripplePhase: CGFloat, sway: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        appendReservoir(to: path, sway: sway)
        path.appendRect(NSRect(x: barLeft, y: barY, width: barWidth, height: barHeight))
        appendOutflow(to: path, fraction: fraction, upstream: upstream, ripple: ripple, ripplePhase: ripplePhase)
        appendRidges(to: path, spin: spin)
        return path
    }

    /// The reservoir's two sides, curving up and out from the dam's top corners. Open at the
    /// top; the dam's outline is its floor. It tips right by `sway` of `slosh`: the right rim
    /// dips and the left one rises, most at the rim and not at all where they meet the dam.
    private static func appendReservoir(to path: NSBezierPath, sway: CGFloat) {
        let right = centreX + topWidth / 2, barRight = centreX + barWidth / 2
        let rightControl = { (c: (across: CGFloat, down: CGFloat)) in
            NSPoint(x: barRight + c.across * (right - barRight), y: topY + c.down * topHeight)
        }
        let rightSide = [NSPoint(x: right, y: topY), rightControl(topControls[0]),
                         rightControl(topControls[1]), NSPoint(x: barRight, y: barY)]
        let leftSide = rightSide.map { NSPoint(x: 2 * centreX - $0.x, y: $0.y) }
        let tip = { (p: NSPoint) -> NSPoint in
            let side: CGFloat = p.x < centreX ? -1 : 1
            return NSPoint(x: p.x, y: p.y + side * slosh * sway * (barY - p.y) / topHeight)
        }
        for side in [leftSide, rightSide].map({ $0.map(tip) }) {
            path.move(to: side[0])
            path.curve(to: side[3], controlPoint1: side[1], controlPoint2: side[2])
        }
    }

    /// The outflow's two sides, cut where they have dropped `cutHeight` below the dam. Open
    /// at the bottom, so the gap between their ends shows the width. The control points
    /// take their place from `upstream` instead.
    private static func appendOutflow(to path: NSBezierPath, fraction: CGFloat, upstream: CGFloat,
                                      ripple: CGFloat, ripplePhase: CGFloat) {
        let bottomLeft = centreX - barWidth * fraction / 2
        let upstreamLeft = centreX - barWidth * upstream / 2
        let x = { (t: CGFloat) in barLeft + t * (upstreamLeft - barLeft) }
        let side = cut([
            NSPoint(x: barLeft, y: barBottom),
            NSPoint(x: x(outflowControls[0].across), y: barBottom + outflowControls[0].down * outflowHeight),
            NSPoint(x: x(outflowControls[1].across), y: barBottom + outflowControls[1].down * outflowHeight),
            NSPoint(x: bottomLeft, y: barBottom + outflowHeight)
        ], atY: barBottom + cutHeight)
        guard ripple != 0 else { return appendSides(side, to: path) }
        // Ripples swell both sides together, one way only, then back to the plain curve: still
        // where the stream leaves the dam and strongest at its open end, like surges travelling
        // down falling water.
        let points = (0...24).map { i -> NSPoint in
            let p = point(on: side, at: CGFloat(i) / 24)
            let down = (p.y - barBottom) / cutHeight
            let wave = (1 - cos(2 * .pi * ((p.y - barBottom) / rippleWavelength - ripplePhase))) / 2
            return NSPoint(x: p.x - rippleAmplitude * ripple * down * wave, y: p.y)
        }
        for side in [points, points.map { NSPoint(x: 2 * centreX - $0.x, y: $0.y) }] {
            path.move(to: side[0])
            side.dropFirst().forEach(path.line(to:))
        }
    }

    /// The point `t` of the way along the cubic `p`.
    private static func point(on p: [NSPoint], at t: CGFloat) -> NSPoint {
        let lerp = { (a: NSPoint, b: NSPoint) in NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
        let ab = lerp(p[0], p[1]), bc = lerp(p[1], p[2]), cd = lerp(p[2], p[3])
        return lerp(lerp(ab, bc), lerp(bc, cd))
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
        let point = { (t: CGFloat) in Self.point(on: p, at: t) }
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

/// Shows `MenuBarIcon` on a status item button. When the connection count changes, the dam
/// shifts gear: it turns faster and faster, coming to rest with its ridges where they started.
/// The outflow's width goes with it, barely moving at first and quickest at the end, and flows
/// like poured liquid: the stream near the dam leads on a quick spring, its open end follows
/// on a slower, bouncier one that settles after the dam stops. Ripples run down the stream
/// while it flows and die away once it stills, and the reservoir's water sloshes, tipping
/// with the dam's turn and swinging back. With Reduce Motion on, the width eases to its new
/// size at once, without bounce, ripples, sloshing or turning.
final class MenuBarIconAnimator {
    /// How long the dam turns for, and the outflow's width with it.
    static let duration: TimeInterval = 0.9
    /// Degrees the dam turns per second of the change, rounded to whole ridge spacings.
    static let turnRate: CGFloat = 100
    /// Ripples travelling down the outflow per second.
    static let rippleRate: CGFloat = 2.5
    /// Seconds for ripples to die to about a third once the stream stops moving.
    static let rippleFade: CGFloat = 0.35

    /// A damped spring toward a target, stepped through time.
    private struct Spring {
        var value: CGFloat
        var velocity: CGFloat = 0
        /// Seconds per swing were it undamped.
        let response: CGFloat
        /// How far past the target it swings, as with SwiftUI springs: 0 settles without
        /// overshooting, more wobbles more.
        let bounce: CGFloat

        /// Moves `seconds` on toward `target`, without overshooting unless `bouncing`.
        mutating func step(toward target: CGFloat, by seconds: CGFloat, bouncing: Bool) {
            let stiffness = pow(2 * .pi / response, 2)
            let damping = 4 * .pi * (1 - (bouncing ? bounce : 0)) / response
            // Short steps keep it stable when a frame comes late.
            let steps = max(1, Int((seconds * 240).rounded(.up)))
            let dt = seconds / CGFloat(steps)
            for _ in 0..<steps {
                velocity += (-stiffness * (value - target) - damping * velocity) * dt
                value += velocity * dt
            }
        }

        func isSettled(at target: CGFloat) -> Bool {
            abs(value - target) < 0.0005 && abs(velocity) < 0.005
        }
    }

    private weak var button: NSStatusBarButton?
    private var count: Int?
    /// The width the springs pull toward, which moves with the dam to the new one.
    private var target = MenuBarIcon.outflowFraction(for: 0)
    private var newTarget = MenuBarIcon.outflowFraction(for: 0)
    /// The stream by the dam: quick, barely overshooting.
    private var upstream = Spring(value: MenuBarIcon.outflowFraction(for: 0), response: 0.45, bounce: 0.1)
    /// The stream's open end: lagging, and swinging a little past the new width.
    private var outflow = Spring(value: MenuBarIcon.outflowFraction(for: 0), response: 0.7, bounce: 0.3)
    /// The reservoir's tip, pushed by the stream moving and swinging back once it slows.
    private var slosh = Spring(value: 0, response: 0.8, bounce: 0.3)
    private var spin: CGFloat = 0
    /// Ripple strength, 0 to 1, stirred up by the outflow's open end moving.
    private var ripple: CGFloat = 0
    private var ripplePhase: CGFloat = 0
    /// 1 when the outflow is widening, so ripples swell it; -1 when narrowing, so they pinch it.
    private var rippleDirection: CGFloat = 1
    /// The direction drawn, which goes over to `rippleDirection` through flat water in
    /// `rippleTurn` rather than in one frame when a change reverses mid-animation.
    private var rippleSign: CGFloat = 1
    private static let rippleTurn: CGFloat = 0.25
    private var reduceMotion = false
    private var timer: Timer?

    init(button: NSStatusBarButton?) {
        self.button = button
    }

    /// Shows `count` connections: at once the first time, animated after, gently with Reduce
    /// Motion on (unless `ignoringReduceMotion`, for previews). A change mid-animation
    /// carries on from where the icon is, momentum included.
    func show(count newCount: Int, ignoringReduceMotion: Bool = false) {
        let newCount = min(max(newCount, 0), MenuBarIcon.maxCount)
        guard newCount != count else { return }
        let isFirst = count == nil
        count = newCount
        newTarget = MenuBarIcon.outflowFraction(for: newCount)
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !ignoringReduceMotion
        guard !isFirst else {
            timer?.invalidate()
            timer = nil
            settle()
            draw()
            return
        }
        animate()
    }

    private func settle() {
        target = newTarget
        upstream.value = target
        upstream.velocity = 0
        outflow.value = target
        outflow.velocity = 0
        slosh.value = 0
        slosh.velocity = 0
        spin = 0
        ripple = 0
        rippleSign = rippleDirection
    }

    private func animate() {
        timer?.invalidate()
        let spacing = MenuBarIcon.ridgeSpacing
        let startSpin = spin, startTarget = target
        rippleDirection = newTarget < startTarget ? -1 : 1
        if ripple < 0.02 { rippleSign = rippleDirection }
        let turns = reduceMotion ? 0 : max(1, (CGFloat(Self.duration) * Self.turnRate / spacing).rounded())
        let turnDuration = reduceMotion ? 0 : Self.duration
        // Up when there are no turns to add, so a change mid-turn never snaps the ridges back.
        let endSpin = ((startSpin / spacing).rounded(turns > 0 ? .down : .up) + turns) * spacing
        let start = ProcessInfo.processInfo.systemUptime
        var last = start
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = CGFloat(min(now - last, 0.1))
            last = now
            let progress = turnDuration > 0 ? min(1, (now - start) / turnDuration) : 1
            // Speeding up all the way, so the gear clunks into place.
            let eased = CGFloat(pow(progress, 3))
            self.spin = startSpin + (endSpin - startSpin) * eased
            self.target = startTarget + (self.newTarget - startTarget) * eased
            self.upstream.step(toward: self.target, by: elapsed, bouncing: !self.reduceMotion)
            self.outflow.step(toward: self.target, by: elapsed, bouncing: !self.reduceMotion)
            // The faster the open end moves, the stronger the ripples; they fade once it slows.
            let stirred = self.reduceMotion ? 0 : min(1, abs(self.outflow.velocity))
            self.ripple = max(stirred, self.ripple * exp(-elapsed / Self.rippleFade))
            self.ripplePhase += elapsed * Self.rippleRate
            let turn = 2 * elapsed / Self.rippleTurn
            self.rippleSign = min(1, max(-1, self.rippleSign + max(-turn, min(turn, self.rippleDirection - self.rippleSign))))
            self.slosh.step(toward: stirred, by: elapsed, bouncing: true)
            if progress >= 1, self.ripple < 0.02, self.slosh.isSettled(at: 0),
               self.upstream.isSettled(at: self.target), self.outflow.isSettled(at: self.target) {
                timer.invalidate()
                self.timer = nil
                self.settle()
            }
            self.draw()
        }
        // Common modes, so it keeps animating while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func draw() {
        // An overshoot past no width at all would cross the stream's sides; pinch it shut instead.
        button?.image = MenuBarIcon.image(fraction: max(0, outflow.value), spin: spin,
                                          upstream: max(0, upstream.value),
                                          ripple: ripple * rippleSign, ripplePhase: ripplePhase, sway: slosh.value)
    }
}
