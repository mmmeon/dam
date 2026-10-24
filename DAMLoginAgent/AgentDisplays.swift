//
//  AgentDisplays.swift
//
//  The streaming displays the login window agent makes for receivers: at the size each
//  asks for, made the main display, so the login window moves onto it
//  (docs/root-and-login-window.md). Layout changes are the agent's own (`.forAppOnly`), so
//  macOS puts the displays back as they were when the agent exits at sign-in.
//

import CoreGraphics
import Foundation
import os

private let adLog = Logger(subsystem: AppIdentity.bundleID, category: "LoginAgentDisplays")

final class AgentDisplays {
    private var displays: [CGDirectDisplayID: CGVirtualDisplay] = [:]
    /// Whether each display made is made main; not when trying the agent in a signed-in session.
    private let makesMain: Bool

    init(makesMain: Bool = true) {
        self.makesMain = makesMain
    }
    /// How long a new display has to come online.
    static let onlineTimeout: TimeInterval = 10

    /// Makes a display in `mode` for `identity`, as DAM makes a streaming display, and makes
    /// it main once it is online; `done` gets its ID, or nil.
    func make(_ mode: StreamingDisplayModes.Mode, _ identity: StreamingDisplayIdentity,
              done: @escaping (CGDirectDisplayID?) -> Void) {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(.main)
        descriptor.name = identity.name
        descriptor.sizeInMillimeters = CGSize(width: 600, height: 340)
        let side = max(StreamingDisplayModes.maxPixelsSide, mode.pixelWidth, mode.pixelHeight)
        descriptor.maxPixelsWide = UInt32(side)
        descriptor.maxPixelsHigh = UInt32(side)
        descriptor.vendorID = StreamingDisplayIdentity.vendorID
        descriptor.productID = StreamingDisplayIdentity.productID
        descriptor.serialNum = identity.serial
        descriptor.terminationHandler = { [weak self] _, display in
            DispatchQueue.main.async {
                guard let self, let id = self.displays.first(where: { $0.value === display })?.key else { return }
                adLog.notice("display \(id) ended by the system")
                self.displays[id] = nil
            }
        }
        let display = CGVirtualDisplay(descriptor: descriptor)
        guard display.apply(StreamingDisplayModes.settings(startingIn: mode)) else {
            adLog.error("applySettings failed for \(mode.width)×\(mode.height)")
            return done(nil)
        }
        let id = display.displayID
        displays[id] = display
        adLog.notice("made display \(id) for \(identity.name, privacy: .public) at \(mode.width)×\(mode.height)\(mode.hiDPI ? " HiDPI" : "")")
        waitUntilOnline(id, deadline: Date() + Self.onlineTimeout) { [weak self] online in
            guard let self, online, self.displays[id] != nil else { return done(nil) }
            self.place(id, in: mode) { done(id) }
        }
    }

    func resize(_ id: CGDirectDisplayID, to mode: StreamingDisplayModes.Mode, done: @escaping (Bool) -> Void) {
        guard let display = displays[id], mode.pixelWidth <= Int(display.maxPixelsWide),
              mode.pixelHeight <= Int(display.maxPixelsHigh),
              display.apply(StreamingDisplayModes.settings(startingIn: mode)) else { return done(false) }
        place(id, in: mode) { done(true) }
    }

    func remove(_ id: CGDirectDisplayID) {
        adLog.notice("removing display \(id)")
        displays[id] = nil
    }

    /// Whether the Mac has a display other than the agent's, for receivers listed "only
    /// without a display of its own".
    func hasOwnDisplay() -> Bool {
        Self.online().contains { displays[$0] == nil && CGDisplayVendorNumber($0) != StreamingDisplayIdentity.vendorID }
    }

    // MARK: Layout

    static func online() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(32, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    private func waitUntilOnline(_ id: CGDirectDisplayID, deadline: Date, done: @escaping (Bool) -> Void) {
        if Self.online().contains(id) { return done(true) }
        guard Date() < deadline else {
            adLog.error("display \(id) never came online")
            return done(false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitUntilOnline(id, deadline: deadline, done: done) ?? done(false)
        }
    }

    /// Switches display `id` to `mode` and, unless told not to, makes it main: at the origin,
    /// the others in a row to its right, as the login window follows the main display. One
    /// change, and none when there is nothing to change: macOS holds a change that changes
    /// nothing for 10 s (docs/slow-display-removal.md). Committed off the main queue, which
    /// keeps the receiver's link alive meanwhile; `done` on the main queue.
    private func place(_ id: CGDirectDisplayID, in mode: StreamingDisplayModes.Mode, done: @escaping () -> Void) {
        // A virtual display first lists as 1×1; its mode comes a moment later.
        waitForSize(id, deadline: Date() + 3) { [weak self] in
            guard let self else { return done() }
            var config: CGDisplayConfigRef?
            CGBeginDisplayConfiguration(&config)
            var changes: [String] = []
            if let wanted = Self.mode(mode, of: id) {
                if !Self.same(CGDisplayCopyDisplayMode(id), wanted) {
                    CGConfigureDisplayWithDisplayMode(config, id, wanted, nil)
                    changes.append("mode")
                }
            } else {
                adLog.error("display \(id): no \(mode.width)×\(mode.height)@\(mode.refreshRate) mode")
            }
            if self.makesMain, CGDisplayBounds(id).origin != .zero {
                CGConfigureDisplayOrigin(config, id, 0, 0)
                var x = Int32(mode.width)
                for other in Self.online() where other != id && CGDisplayMirrorsDisplay(other) == 0 {
                    CGConfigureDisplayOrigin(config, other, x, 0)
                    x += Int32(CGDisplayBounds(other).width)
                }
                changes.append("main")
            }
            guard !changes.isEmpty else {
                CGCancelDisplayConfiguration(config)
                adLog.notice("display \(id) already as wanted")
                return done()
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let started = Date()
                let error = CGCompleteDisplayConfiguration(config, .forAppOnly)
                DispatchQueue.main.async {
                    adLog.notice("display \(id): \(changes.joined(separator: ", "), privacy: .public) → \(error.rawValue) in \(Int(Date().timeIntervalSince(started) * 1000)) ms; main now \(CGMainDisplayID())")
                    done()
                }
            }
        }
    }

    /// Waits until display `id` reports more than its first 1×1, or `deadline` passes.
    private func waitForSize(_ id: CGDirectDisplayID, deadline: Date, then: @escaping () -> Void) {
        if CGDisplayBounds(id).width > 1 || Date() >= deadline { return then() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return then() }
            self.waitForSize(id, deadline: deadline, then: then)
        }
    }

    /// The mode of display `id` that is `mode`, as DAM picks it: size, pixels and whole hertz.
    private static func mode(_ mode: StreamingDisplayModes.Mode, of id: CGDirectDisplayID) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
        return modes.first {
            $0.width == mode.width && $0.height == mode.height && $0.pixelWidth == mode.pixelWidth
                && $0.pixelHeight == mode.pixelHeight && Int($0.refreshRate.rounded()) == mode.refreshRate
        }
    }

    private static func same(_ a: CGDisplayMode?, _ b: CGDisplayMode) -> Bool {
        guard let a else { return false }
        return a.width == b.width && a.height == b.height && a.pixelWidth == b.pixelWidth
            && a.pixelHeight == b.pixelHeight && Int(a.refreshRate.rounded()) == Int(b.refreshRate.rounded())
    }
}
