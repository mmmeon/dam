//
//  ArrangeTouchBar.swift
//
//  The Touch Bar's arrange flow, opened by the "Arrange" button on the modal bar: pick the
//  display to move, the side to put it on, the display to put it beside, then confirm from
//  a preview of the result. Each page has a back button; the first goes back to the modal
//  bar. The result is applied through `VideoManager.arrange`.
//

import AppKit

final class ArrangeTouchBar: NSObject {

    static let shared = ArrangeTouchBar()

    /// The pages of the flow, each carrying what was picked so far.
    enum Step: Equatable {
        case pickDisplay
        case pickSide(moving: CGDirectDisplayID)
        case pickOther(moving: CGDirectDisplayID, side: PlacementSide)
        case confirm(moving: CGDirectDisplayID, side: PlacementSide, other: CGDirectDisplayID)

        /// The page before this one; nil from the first.
        var previous: Step? {
            switch self {
            case .pickDisplay:                          return nil
            case .pickSide:                             return .pickDisplay
            case .pickOther(let moving, _):             return .pickSide(moving: moving)
            case .confirm(let moving, let side, _):     return .pickOther(moving: moving, side: side)
            }
        }
    }

    /// The side buttons, in the order shown, with their short labels.
    static let sides: [(side: PlacementSide, label: String)] = [
        (.left, "Left"), (.right, "Right"), (.above, "Top"), (.below, "Bottom"),
    ]

    /// The preview's sentence: "tv left of LEN T24i-20", "tv above LEN T24i-20".
    static func sentence(moving: String, side: PlacementSide, other: String) -> String {
        "\(moving) \(side.label.lowercased()) \(other)"
    }

    private static let idPrefix = "\(AppIdentity.bundleID).arrange"

    private weak var videoManager: VideoManager?
    /// Re-presents the bar the flow was opened from.
    private var back: (() -> Void)?
    private var layout = DisplayLayout(placements: [])
    private var step: Step = .pickDisplay
    private var bar: NSTouchBar?
    /// What each button does, by the button.
    private var actions: [ObjectIdentifier: () -> Void] = [:]

    private override init() {}

    // MARK: - Flow

    /// Reads the arrangement and presents the first page. `back` re-presents the bar the
    /// flow replaces, and is called when the flow ends.
    func start(videoManager: VideoManager, back: @escaping () -> Void) {
        self.videoManager = videoManager
        self.back = back
        videoManager.refresh()
        layout = videoManager.currentLayout()
        guard layout.placements.count >= 2 else {
            SpeechSynthesizer.shared.announce("No other display")
            return back()
        }
        show(.pickDisplay)
    }

    private func show(_ step: Step) {
        self.step = step
        actions.removeAll()
        if let bar { NSTouchBar.dismissSystemModal(bar) }
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = identifiers(for: step)
        self.bar = bar
        NSTouchBar.presentSystemModal(bar, for: ControlStripPresenter.stripID)
        if case .confirm(let moving, let side, let other) = step, Feedback.voice,
           let a = layout[moving], let b = layout[other] {
            SpeechSynthesizer.shared.speak(Self.sentence(moving: a.name, side: side, other: b.name),
                                           caption: false)
        }
    }

    private func end() {
        if let bar { NSTouchBar.dismissSystemModal(bar) }
        bar = nil
        actions.removeAll()
        back?()
    }

    private func goBack() {
        if let previous = step.previous { show(previous) } else { end() }
    }

    private func confirm(moving: CGDirectDisplayID, side: PlacementSide, other: CGDirectDisplayID) {
        let result = layout.placing(moving, side, of: other)
        videoManager?.arrange(result) { [weak self] outcome in
            if case .failure(let error) = outcome {
                SpeechSynthesizer.shared.announce(error.localizedDescription)
            }
            self?.end()
        }
    }

    // MARK: - Items

    private func id(_ key: String) -> NSTouchBarItem.Identifier {
        NSTouchBarItem.Identifier("\(Self.idPrefix).\(key)")
    }

    private func identifiers(for step: Step) -> [NSTouchBarItem.Identifier] {
        var ids: [NSTouchBarItem.Identifier] = [id("back"), .flexibleSpace, id("label")]
        switch step {
        case .pickDisplay:
            ids += layout.placements.indices.map { id("display.\($0)") }
        case .pickSide:
            ids += Self.sides.indices.map { id("side.\($0)") }
        case .pickOther(let moving, _):
            ids += layout.placements.indices.filter { layout.placements[$0].id != moving }.map { id("other.\($0)") }
        case .confirm:
            ids += [id("preview"), id("confirm"), id("cancel")]
        }
        return ids
    }

    private func button(_ title: String, tinted: Bool = false, action: @escaping () -> Void) -> NSButton {
        let btn = NSButton(title: title, target: self, action: #selector(tapped(_:)))
        btn.bezelStyle = .rounded
        if tinted { btn.bezelColor = .controlAccentColor }
        actions[ObjectIdentifier(btn)] = action
        return btn
    }

    @objc private func tapped(_ sender: NSButton) {
        actions[ObjectIdentifier(sender)]?()
    }

    private func label(_ text: String) -> NSView {
        let tf = NSTextField(labelWithString: text)
        tf.textColor = .white
        tf.font = .systemFont(ofSize: 12)
        return tf
    }

    private func truncated(_ s: String, max: Int = 12) -> String {
        s.count > max ? String(s.prefix(max - 1)) + "…" : s
    }

    /// What the page asks for, or, on the preview, what confirming does.
    private func labelText(for step: Step) -> String {
        switch step {
        case .pickDisplay:
            return "Move:"
        case .pickSide(let moving):
            return "\(truncated(layout[moving]?.name ?? "")):"
        case .pickOther(let moving, let side):
            return "\(truncated(layout[moving]?.name ?? "")) \(side.label.lowercased()):"
        case .confirm(let moving, let side, let other):
            return Self.sentence(moving: truncated(layout[moving]?.name ?? ""), side: side,
                                 other: truncated(layout[other]?.name ?? ""))
        }
    }

    /// A small map of `layout` for the Touch Bar, in the Arrange window's flat style, with
    /// display `moving` tinted.
    static func previewImage(of layout: DisplayLayout, moving: CGDirectDisplayID,
                             height: CGFloat = 26, maxWidth: CGFloat = 96) -> NSImage? {
        let frames = layout.placements.map(\.frame)
        guard let first = frames.first else { return nil }
        let union = frames.dropFirst().reduce(first) { $0.union($1) }
        let scale = min(height / union.height, maxWidth / union.width)
        let size = NSSize(width: (union.width * scale).rounded(.up), height: (union.height * scale).rounded(.up))
        return NSImage(size: size, flipped: true) { _ in
            for placement in layout.placements {
                let f = placement.frame
                let rect = CGRect(x: (f.minX - union.minX) * scale, y: (f.minY - union.minY) * scale,
                                  width: f.width * scale, height: f.height * scale).insetBy(dx: 0.5, dy: 0.5)
                (placement.id == moving ? NSColor.controlAccentColor.withAlphaComponent(0.7)
                                        : NSColor.white.withAlphaComponent(0.25)).setFill()
                rect.fill()
                NSColor.white.withAlphaComponent(0.8).setStroke()
                rect.frame(withWidth: 1)
            }
            return true
        }
    }
}

// MARK: - NSTouchBarDelegate

extension ArrangeTouchBar: NSTouchBarDelegate {

    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier.rawValue.hasPrefix(Self.idPrefix + ".") else { return nil }
        let key = String(identifier.rawValue.dropFirst(Self.idPrefix.count + 1))
        let item = NSCustomTouchBarItem(identifier: identifier)
        let parts = key.split(separator: ".").map(String.init)
        switch (parts.first ?? "", parts.count > 1 ? Int(parts[1]) : nil, step) {
        case ("back", _, _):
            item.view = button("◀") { [weak self] in self?.goBack() }
        case ("label", _, _):
            item.view = label(labelText(for: step))
        case ("display", let i?, .pickDisplay) where layout.placements.indices.contains(i):
            let placement = layout.placements[i]
            item.view = button(truncated(placement.name)) { [weak self] in
                self?.show(.pickSide(moving: placement.id))
            }
        case ("side", let i?, .pickSide(let moving)) where Self.sides.indices.contains(i):
            let entry = Self.sides[i]
            item.view = button(entry.label) { [weak self] in
                self?.show(.pickOther(moving: moving, side: entry.side))
            }
        case ("other", let i?, .pickOther(let moving, let side)) where layout.placements.indices.contains(i):
            let placement = layout.placements[i]
            item.view = button(truncated(placement.name)) { [weak self] in
                self?.show(.confirm(moving: moving, side: side, other: placement.id))
            }
        case ("preview", _, .confirm(let moving, let side, let other)):
            guard let image = Self.previewImage(of: layout.placing(moving, side, of: other), moving: moving)
            else { return nil }
            item.view = NSImageView(image: image)
        case ("confirm", _, .confirm(let moving, let side, let other)):
            item.view = button("Confirm", tinted: true) { [weak self] in
                self?.confirm(moving: moving, side: side, other: other)
            }
        case ("cancel", _, _):
            item.view = button("Cancel") { [weak self] in self?.end() }
        default:
            return nil
        }
        return item
    }
}
