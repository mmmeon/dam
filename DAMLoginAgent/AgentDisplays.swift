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
            // A virtual display first lists as 1×1; its mode comes a moment later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.setMode(mode, of: id)
                self.makeMain(id)
                done(id)
            }
        }
    }

    func resize(_ id: CGDirectDisplayID, to mode: StreamingDisplayModes.Mode, done: @escaping (Bool) -> Void) {
        guard let display = displays[id], mode.pixelWidth <= Int(display.maxPixelsWide),
              mode.pixelHeight <= Int(display.maxPixelsHigh),
              display.apply(StreamingDisplayModes.settings(startingIn: mode)) else { return done(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let set = self.setMode(mode, of: id)
            self.makeMain(id)
            done(set)
        }
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

    /// Switches display `id` to `mode`, as DAM picks it: size, pixels and whole hertz.
    @discardableResult
    private func setMode(_ mode: StreamingDisplayModes.Mode, of id: CGDirectDisplayID) -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
        guard let wanted = modes.first(where: {
            $0.width == mode.width && $0.height == mode.height && $0.pixelWidth == mode.pixelWidth
                && $0.pixelHeight == mode.pixelHeight && Int($0.refreshRate.rounded()) == mode.refreshRate
        }) else {
            adLog.error("display \(id): no \(mode.width)×\(mode.height)@\(mode.refreshRate) mode")
            return false
        }
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayWithDisplayMode(config, id, wanted, nil)
        let error = CGCompleteDisplayConfiguration(config, .forAppOnly)
        if error != .success { adLog.error("display \(id): mode → \(error.rawValue)") }
        return error == .success
    }

    /// Puts display `id` at the origin, which makes it main, and the others in a row to its
    /// right: the login window follows the main display.
    private func makeMain(_ id: CGDirectDisplayID) {
        guard makesMain else { return }
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayOrigin(config, id, 0, 0)
        var x = Int32(CGDisplayPixelsWide(id))
        for other in Self.online() where other != id && CGDisplayMirrorsDisplay(other) == 0 {
            CGConfigureDisplayOrigin(config, other, x, 0)
            x += Int32(CGDisplayPixelsWide(other))
        }
        let error = CGCompleteDisplayConfiguration(config, .forAppOnly)
        adLog.notice("display \(id) made main → \(error.rawValue); main now \(CGMainDisplayID())")
    }
}
