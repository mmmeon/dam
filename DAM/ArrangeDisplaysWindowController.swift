//
//  ArrangeDisplaysWindowController.swift
//
//  The Arrange Displays HUD: a map of the displays, like the one in System Settings, on
//  the same borderless floating panel as the pickers. Dragging a display moves it; on
//  release it lands on the nearest edge of another display and the arrangement is applied.
//  Holding a display over others for a moment turns the drop into a mirror: on release
//  the displays underneath show the held one. A mirror set shows as a stack; dragging a
//  card off the back of the stack (it fans out under the pointer) gives that display its own desktop again. Dragging the main display's corner square
//  onto another display makes that the main display. The map follows the live arrangement, so a change made anywhere shows up here.
//  Esc, or a click anywhere else, closes it. Its help lives in the menu item's tooltip.
//

import AppKit
import Carbon.HIToolbox
import Combine
import os.log

private let hudLog = Logger(subsystem: AppIdentity.bundleID, category: "Arrange")

final class ArrangeDisplaysWindowController {

    private static let mapSize = NSSize(width: 440, height: 300)

    private let videoManager: VideoManager
    private let map = DisplayMapView()
    private var panel: HUDPanel?
    private var cancellable: AnyCancellable?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    /// The app to hand focus back to on close.
    private var previousApp: NSRunningApplication?

    init(videoManager: VideoManager) {
        self.videoManager = videoManager
        map.onArrange = { [weak self] layout, main in self?.apply(layout, main: main) }
        map.onMirror  = { [weak self] id, targets in self?.mirror(id, onto: targets) }
        map.onExtend  = { [weak self] id, origin in self?.extend(id, to: origin) }
        map.onCancel  = { [weak self] in self?.close(reason: "Esc in map") }
        cancellable = videoManager.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in self?.reload() }
    }

    /// The panel's content: the map on the same material as the picker HUD.
    private func makeContent() -> NSView {
        let content = NSVisualEffectView()
        content.material     = .hudWindow
        content.blendingMode = .behindWindow
        content.state        = .active
        map.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(map)
        NSLayoutConstraint.activate([
            map.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            map.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            map.topAnchor.constraint(equalTo: content.topAnchor),
            map.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            map.widthAnchor.constraint(equalToConstant: Self.mapSize.width),
            map.heightAnchor.constraint(equalToConstant: Self.mapSize.height),
        ])
        return content
    }

    /// Re-reads the arrangement, unless a drag is under way.
    private func reload() {
        guard panel != nil, !map.isDragging else { return }
        map.layout = videoManager.currentLayout()
    }

    private func apply(_ layout: DisplayLayout, main: CGDirectDisplayID?) {
        videoManager.arrange(layout, main: main) { [weak self] result in
            if case .failure(let error) = result {
                SpeechSynthesizer.shared.announce(error.localizedDescription)
            }
            self?.reload()
        }
    }

    private func mirror(_ id: CGDirectDisplayID, onto targets: [CGDirectDisplayID]) {
        videoManager.mirror(placement: id, onto: targets, in: map.layout) { [weak self] result in
            if case .failure(let error) = result {
                SpeechSynthesizer.shared.announce(error.localizedDescription)
            }
            self?.reload()
        }
    }

    private func extend(_ id: CGDirectDisplayID, to origin: CGPoint) {
        videoManager.extend(member: id, to: origin) { [weak self] result in
            if case .failure(let error) = result {
                SpeechSynthesizer.shared.announce(error.localizedDescription)
            }
            self?.reload()
        }
    }

    /// Shows the HUD centred on the screen under the mouse.
    func show() {
        videoManager.refresh()
        let p = panel ?? makeHUDPanel(nonactivating: true)
        if panel == nil {
            let content = makeContent()
            let size = content.fittingSize
            content.frame = NSRect(origin: .zero, size: size)
            p.contentView = content
            p.setContentSize(size)
            panel = p
        }
        reload()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = p.frame.size
            p.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }
        p.alphaValue = 0.97
        hudLog.debug("arrange HUD: showing, active=\(NSApp.isActive)")
        // The panel takes keys only while DAM is active; focus goes back on close.
        if previousApp == nil { previousApp = activateForHUDTouchBar() }
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(map)
        installMonitors()
        // Activation asked for while a menu closes, or as the app launches, can be dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.panel === p, p.isVisible else { return }
            hudLog.debug("arrange HUD: active=\(NSApp.isActive) key=\(p.isKeyWindow)")
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
                p.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Closes the HUD; `reason` is for the log.
    func close(reason: String = "asked") {
        hudLog.debug("arrange HUD: closing (\(reason, privacy: .public))")
        removeMonitors()
        panel?.orderOut(nil)
        restoreFocus(to: previousApp)
        previousApp = nil
    }

    /// Esc closes, wherever focus is; so does a press outside the panel.
    private func installMonitors() {
        removeMonitors()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                guard Int(event.keyCode) == kVK_Escape else { return event }
                self.close(reason: "Esc, local")
                return nil
            }
            if event.window !== self.panel { self.close(reason: "press in another window") }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.type != .keyDown || Int(event.keyCode) == kVK_Escape { self?.close(reason: "outside, \(event.type.rawValue)") }
        }
    }

    private func removeMonitors() {
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor  = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    }
}

// MARK: - DisplayMapView

/// Draws the arrangement to scale and lets displays, and the main display's square, be dragged.
final class DisplayMapView: NSView {

    /// Called with the arrangement to apply once a drag ends: the layout the display was
    /// dropped into, and the display the square was dropped on, if it was.
    var onArrange: ((DisplayLayout, CGDirectDisplayID?) -> Void)?
    /// Called when a display held over others is dropped: the held placement, and the
    /// placements under it that are to mirror it.
    var onMirror: ((CGDirectDisplayID, [CGDirectDisplayID]) -> Void)?
    /// Called when a display pulled off a mirror set is dropped clear of it: the display,
    /// and the origin (in layout space) it was dropped at.
    var onExtend: ((CGDirectDisplayID, CGPoint) -> Void)?
    /// Called when Esc is pressed while the map has focus.
    var onCancel: (() -> Void)?

    var layout = DisplayLayout(placements: []) {
        didSet { needsDisplay = true }
    }

    private enum Drag {
        /// A display, held `grip` from its origin, now at `frame` (in layout space).
        case display(id: CGDirectDisplayID, grip: CGPoint, frame: CGRect)
        /// Display `id`, pulled off the mirror set placed by `from`, likewise.
        case member(id: CGDirectDisplayID, from: CGDirectDisplayID, grip: CGPoint, frame: CGRect)
        /// The main display's square, now under `point` (in view space).
        case menuBar(point: CGPoint)
    }
    private var drag: Drag?
    private var dragMoved = false
    /// The displays under the held one, and whether it has been held there long enough
    /// that dropping it mirrors it onto them.
    private var under: [CGDirectDisplayID] = []
    private var mirrorArmed = false
    /// Whether a display pulled off a mirror set is back over its set, so dropping it
    /// changes nothing.
    private var overOwnSet = false
    private var holdTimer: Timer?
    private static let holdDelay: TimeInterval = 0.6

    var isDragging: Bool { drag != nil }

    /// The display or mirror set being dragged, if one is.
    private var heldID: CGDirectDisplayID? {
        switch drag {
        case .display(let id, _, _), .member(let id, _, _, _): return id
        default: return nil
        }
    }

    /// Back cards of a mirror set's stack, by how far they step out from the front card;
    /// further while the pointer is over the stack, to show they can be pulled off.
    private static let stackStep: CGFloat = 8
    private static let fannedStackStep: CGFloat = 12
    private static let fanDuration: CFTimeInterval = 0.15
    /// The mirror set the pointer is over, whose back cards are fanned out.
    private var hoveredStack: CGDirectDisplayID?
    /// How far each stack is fanned out, 0 to 1, while it moves or stays fanned.
    private var fan: [CGDirectDisplayID: CGFloat] = [:]
    private var fanTimer: Timer?
    private var fanTick: CFTimeInterval = 0

    private static let padding: CGFloat = 24
    private static let maxScale: CGFloat = 0.25
    /// The picker HUD's palette, inverted: a display is a block of the label colour, and its
    /// name and the main display's square are cut out of it, showing the material.
    private static var block: NSColor { .labelColor }
    private static let font = NSFont.systemFont(ofSize: 15, weight: .medium)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape { onCancel?() } else { super.keyDown(with: event) }
    }

    // MARK: Mapping

    /// Points per layout point, and the view point of the layout origin, chosen so the
    /// arrangement fits centred with room to drag a display past its edge.
    private var transform: (scale: CGFloat, offset: CGPoint) {
        let frames = layout.placements.map(\.frame)
        guard let first = frames.first else { return (1, .zero) }
        let union = frames.dropFirst().reduce(first) { $0.union($1) }
        let pad = Self.padding
        let available = NSSize(width: max(bounds.width - 2 * pad, 1), height: max(bounds.height - 2 * pad, 1))
        // Leave room around the arrangement for a display to be dragged outside it.
        let largest = frames.map { max($0.width, $0.height) }.max() ?? 1
        let scale = min(Self.maxScale,
                        available.width / (union.width + largest),
                        available.height / (union.height + largest))
        let offset = CGPoint(x: bounds.midX - union.midX * scale, y: bounds.midY - union.midY * scale)
        return (scale, offset)
    }

    private func viewRect(_ frame: CGRect) -> CGRect {
        let (scale, offset) = transform
        return CGRect(x: offset.x + frame.minX * scale, y: offset.y + frame.minY * scale,
                      width: frame.width * scale, height: frame.height * scale)
    }

    private func layoutPoint(_ point: CGPoint) -> CGPoint {
        let (scale, offset) = transform
        return CGPoint(x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale)
    }

    private func viewFrame(of placement: DisplayPlacement) -> CGRect {
        if case .display(let id, _, let frame) = drag, id == placement.id { return viewRect(frame) }
        return viewRect(placement.frame)
    }

    /// The main display's marker: a square set in from its top-left corner, where the menu
    /// bar starts.
    private func menuBarRect(in rect: CGRect) -> CGRect {
        let side = min(max(min(rect.width, rect.height) * 0.1, 5), 12)
        let margin = max(4, side * 0.8)
        return CGRect(x: rect.minX + margin, y: rect.minY + margin, width: side, height: side)
    }

    /// Where a press picks up the marker: the square and the margin around it.
    private func menuBarGrabRect(in rect: CGRect) -> CGRect {
        let square = menuBarRect(in: rect)
        let side = min(min(rect.width, rect.height) / 2, max(square.maxX - rect.minX + 4, 18))
        return CGRect(x: rect.minX, y: rect.minY, width: side, height: side)
    }

    private func placement(at point: CGPoint) -> DisplayPlacement? {
        layout.placements.last { viewFrame(of: $0).contains(point) }
    }

    /// The display whose card in a mirror set's stack shows at `point`, past the front
    /// card, and the set it is in. Only members of a user mirror set can be pulled off.
    private func stackMember(at point: CGPoint) -> (id: CGDirectDisplayID, set: DisplayPlacement)? {
        guard placement(at: point) == nil else { return nil }
        for placement in layout.placements.reversed() where placement.memberIDs.first == placement.id {
            let front = viewFrame(of: placement)
            for i in 1..<min(placement.memberIDs.count, 3)
            where stackCard(i, of: front, fan: fan[placement.id] ?? 0).contains(point) {
                return (placement.memberIDs[i], placement)
            }
        }
        return nil
    }

    /// Back card `i` of the stack in front of `front`, fanned out by `fan` (0 to 1, eased).
    private func stackCard(_ i: Int, of front: CGRect, fan: CGFloat) -> CGRect {
        let eased = 1 - (1 - fan) * (1 - fan)
        let d = CGFloat(i) * (Self.stackStep + (Self.fannedStackStep - Self.stackStep) * eased)
        return front.offsetBy(dx: d, dy: -d)
    }

    /// The user mirror set whose stack, fanned out, covers `point`.
    private func stack(at point: CGPoint) -> CGDirectDisplayID? {
        layout.placements.last { placement in
            guard placement.memberIDs.count > 1, placement.memberIDs.first == placement.id else { return false }
            let front = viewFrame(of: placement)
            let back = stackCard(min(placement.memberIDs.count, 3) - 1, of: front, fan: 1)
            return front.union(back).contains(point)
        }?.id
    }

    /// The placements as drawn: while a display is pulled off a mirror set, the set without
    /// it and the display on its own at the drag.
    private var shownPlacements: [DisplayPlacement] {
        guard case .member(let id, let from, _, let frame) = drag,
              let set = layout[from], let i = set.memberIDs.firstIndex(of: id) else { return layout.placements }
        var names = set.names, members = set.memberIDs
        let name = names.remove(at: i)
        members.remove(at: i)
        return layout.placements.map {
            $0.id == from ? DisplayPlacement(id: from, frame: set.frame, names: names, isMain: set.isMain,
                                             memberIDs: members) : $0
        } + [DisplayPlacement(id: id, frame: frame, names: [name], isMain: false)]
    }

    // MARK: Drawing

    /// A hairline, as the HUD's grid lines: one pixel on this screen.
    private var hairline: CGFloat { 1 / (window?.backingScaleFactor ?? 2) }

    /// A placement's blocks, back to front, snapped to whole pixels: a mirror set shows as
    /// a short stack behind the display.
    private func blocks(of placement: DisplayPlacement) -> [CGRect] {
        let rect = viewFrame(of: placement)
        let behind = stride(from: min(placement.names.count, 3) - 1, through: 1, by: -1).map {
            stackCard($0, of: rect, fan: fan[placement.id] ?? 0)
        }
        return (behind + [rect]).map { backingAlignedRect($0, options: .alignAllEdgesNearest) }
    }

    /// Draws a block in `rect`, replacing what is under it. The block stops a hairline
    /// short of the rectangle's edge, so blocks that touch or overlap stay apart.
    private func block(_ rect: CGRect) {
        rect.fill(using: .clear)
        Self.block.setFill()
        rect.insetBy(dx: hairline, dy: hairline).fill()
    }

    /// Cuts `rect` out of what has been drawn, so the material shows through.
    private func cut(_ rect: CGRect) {
        backingAlignedRect(rect, options: .alignAllEdgesNearest).fill(using: .clear)
    }

    override func draw(_ dirtyRect: NSRect) {
        // The held display is drawn last, over the others.
        var ordered = shownPlacements
        if let id = heldID, let i = ordered.lastIndex(where: { $0.id == id }) {
            ordered.append(ordered.remove(at: i))
        }
        for placement in ordered { draw(placement) }

        // The held square is cut out of the displays it is over and a block anywhere else.
        if case .menuBar(let point) = drag, let main = layout.main {
            var square = menuBarRect(in: viewRect(main.frame))
            square.origin = CGPoint(x: point.x - square.width / 2, y: point.y - square.height / 2)
            square = backingAlignedRect(square, options: .alignAllEdgesNearest)
            Self.block.setFill()
            square.fill(using: .copy)
            for rect in ordered.flatMap(blocks) where rect.intersects(square) {
                cut(rect.intersection(square))
            }
        }
    }

    private func draw(_ placement: DisplayPlacement) {
        let rect = viewFrame(of: placement)
        let menuBarHeld: Bool = { if case .menuBar = drag { return true }; return false }()

        // A display about to mirror the held one is drawn hollow, its name in the block's colour.
        if mirrorArmed && under.contains(placement.id) {
            drawHollow(placement)
            return
        }
        blocks(of: placement).forEach(block)
        if placement.isMain && !menuBarHeld {
            cut(menuBarRect(in: rect))
        }

        let style = NSMutableParagraphStyle()
        style.alignment     = .center
        style.lineBreakMode = .byTruncatingMiddle
        let font = rect.width < 120 ? NSFont.systemFont(ofSize: 11, weight: .medium) : Self.font
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.black, .paragraphStyle: style,
        ]
        // The name is cut out of the block rather than drawn in a colour.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
        drawLabel(label(of: placement), in: rect, attributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A placement's name; the held display, once it would mirror, says where to.
    private func label(of placement: DisplayPlacement) -> String {
        guard mirrorArmed, heldID == placement.id else { return placement.name }
        let targets = under.compactMap { layout[$0]?.name }
        return "Mirror on " + targets.joined(separator: " + ")
    }

    private func drawLabel(_ string: String, in rect: CGRect, attributes: [NSAttributedString.Key: Any]) {
        let text = string as NSString
        let size = text.size(withAttributes: attributes)
        let inset = rect.insetBy(dx: 6, dy: 4)
        let labelRect = CGRect(x: inset.minX, y: inset.midY - size.height / 2,
                               width: inset.width, height: size.height)
        text.draw(with: labelRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                  attributes: attributes)
    }

    /// A display outlined rather than filled, so it reads as about to be replaced.
    private func drawHollow(_ placement: DisplayPlacement) {
        let rect = backingAlignedRect(viewFrame(of: placement), options: .alignAllEdgesNearest)
        rect.fill(using: .clear)
        Self.block.setStroke()
        let outline = NSBezierPath(rect: rect.insetBy(dx: 1.5, dy: 1.5))
        outline.lineWidth = 2
        outline.setLineDash([6, 4], count: 2, phase: 0)
        outline.stroke()
        let style = NSMutableParagraphStyle()
        style.alignment     = .center
        style.lineBreakMode = .byTruncatingMiddle
        let font = rect.width < 120 ? NSFont.systemFont(ofSize: 11, weight: .medium) : Self.font
        drawLabel(placement.name, in: rect, attributes: [
            .font: font, .foregroundColor: Self.block, .paragraphStyle: style,
        ])
    }

    // MARK: Dragging

    // MARK: Hovering

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited,
                                                              .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard drag == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        setHoveredStack(stack(at: point))
        (stackMember(at: point) != nil ? NSCursor.openHand : NSCursor.arrow).set()
    }

    override func mouseExited(with event: NSEvent) {
        guard drag == nil else { return }
        setHoveredStack(nil)
        NSCursor.arrow.set()
    }

    private func setHoveredStack(_ id: CGDirectDisplayID?) {
        guard id != hoveredStack else { return }
        hoveredStack = id
        guard fanTimer == nil else { return }
        fanTick = CACurrentMediaTime()
        fanTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.stepFan()
        }
    }

    /// Moves every stack's fan toward its target, the hovered one out and the rest in,
    /// and stops once they have all arrived.
    private func stepFan() {
        let now = CACurrentMediaTime()
        let delta = CGFloat((now - fanTick) / Self.fanDuration)
        fanTick = now
        var ids = Set(fan.keys)
        if let hoveredStack { ids.insert(hoveredStack) }
        for id in ids {
            let target: CGFloat = id == hoveredStack ? 1 : 0
            let value = fan[id] ?? 0
            let next = value < target ? min(value + delta, target) : max(value - delta, target)
            fan[id] = next == 0 ? nil : next
        }
        needsDisplay = true
        let settled = ids.allSatisfy { (fan[$0] ?? 0) == ($0 == hoveredStack ? 1 : 0) }
        if settled {
            fanTimer?.invalidate()
            fanTimer = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragMoved = false
        if let (id, set) = stackMember(at: point) {
            let origin = layoutPoint(point)
            let card = stackCard(set.memberIDs.firstIndex(of: id) ?? 1, of: viewRect(set.frame),
                                 fan: fan[set.id] ?? 0)
            let cardOrigin = layoutPoint(card.origin)
            NSCursor.closedHand.set()
            drag = .member(id: id, from: set.id,
                           grip: CGPoint(x: origin.x - cardOrigin.x, y: origin.y - cardOrigin.y),
                           frame: CGRect(origin: cardOrigin, size: set.frame.size))
            needsDisplay = true
            return
        }
        guard let hit = placement(at: point) else { return }
        if hit.isMain, layout.placements.count > 1, menuBarGrabRect(in: viewRect(hit.frame)).contains(point) {
            drag = .menuBar(point: point)
        } else {
            let origin = layoutPoint(point)
            drag = .display(id: hit.id,
                            grip: CGPoint(x: origin.x - hit.frame.minX, y: origin.y - hit.frame.minY),
                            frame: hit.frame)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragMoved = true
        switch drag {
        case .display(let id, let grip, var frame):
            let origin = layoutPoint(point)
            frame.origin = CGPoint(x: origin.x - grip.x, y: origin.y - grip.y)
            drag = .display(id: id, grip: grip, frame: frame)
            track(under: layout.displaysUnder(id, at: frame))
        case .member(let id, let from, let grip, var frame):
            let origin = layoutPoint(point)
            frame.origin = CGPoint(x: origin.x - grip.x, y: origin.y - grip.y)
            drag = .member(id: id, from: from, grip: grip, frame: frame)
            let under = layout.displaysUnder(id, at: frame)
            overOwnSet = under.contains(from)
            track(under: overOwnSet ? [] : under)
        case .menuBar:
            drag = .menuBar(point: point)
        case nil:
            return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let mirrorOnto = mirrorArmed ? under : []
        let backOnSet = overOwnSet
        defer {
            drag = nil; endHold(); overOwnSet = false; needsDisplay = true
            setHoveredStack(stack(at: point))
            (stackMember(at: point) != nil ? NSCursor.openHand : NSCursor.arrow).set()
        }
        guard dragMoved else { return }
        switch drag {
        case .display(let id, _, _) where !mirrorOnto.isEmpty,
             .member(let id, _, _, _) where !mirrorOnto.isEmpty:
            onMirror?(id, mirrorOnto)
        case .member(let id, _, _, let frame):
            guard !backOnSet else { return }
            onExtend?(id, CGPoint(x: frame.minX.rounded(), y: frame.minY.rounded()))
        case .display(let id, _, let frame):
            let dropped = layout.moving(id, to: CGPoint(x: frame.minX.rounded(), y: frame.minY.rounded()))
            guard dropped != layout else { return }
            layout = dropped
            onArrange?(dropped, nil)
        case .menuBar:
            drag = nil
            guard let target = placement(at: point), !target.isMain else { return }
            onArrange?(layout, target.id)
        case nil:
            return
        }
    }

    // MARK: Holding

    /// Follows the displays under the held one. Holding it over the same ones for a moment
    /// arms the mirror; once armed it stays armed while it is over any display.
    private func track(under now: [CGDirectDisplayID]) {
        guard now != under else { return }
        under = now
        if now.isEmpty {
            endHold()
        } else if !mirrorArmed {
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDelay, repeats: false) { [weak self] _ in
                guard let self, self.isDragging, !self.under.isEmpty else { return }
                self.mirrorArmed = true
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                self.needsDisplay = true
            }
        }
    }

    private func endHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        under = []
        mirrorArmed = false
    }
}
