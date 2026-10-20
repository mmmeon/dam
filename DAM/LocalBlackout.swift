//
//  LocalBlackout.swift
//
//  Blacks out the Mac's own screens while a remote session is on, so someone at the Mac
//  doesn't see what the remote user does. It turns each screen's gamma to black: the picture
//  is still drawn, and captures and streams of it are untouched; only the light leaves.
//  macOS resets gamma when the displays change, so it is set again after each change, and
//  puts it back itself when DAM quits, however it quits. It can also reset it with no change
//  reported, as after a display's mode is put back, so it is looked at every second too.
//

import CoreGraphics
import Foundation
import os.log

private let boLog = Logger(subsystem: AppIdentity.bundleID, category: "Blackout")

final class LocalBlackout {
    /// The displays left lit: the session's, which the remote user sees.
    private(set) var keeping: Set<CGDirectDisplayID> = []
    private(set) var isOn = false
    /// Which displays to black out of those online; DAM's own virtual displays are left.
    private let shouldBlackOut: (CGDirectDisplayID) -> Bool
    private var registered = false
    private var reapply: DispatchWorkItem?
    private var watch: Timer?

    init(shouldBlackOut: @escaping (CGDirectDisplayID) -> Bool) {
        self.shouldBlackOut = shouldBlackOut
    }

    deinit { if isOn { CGDisplayRestoreColorSyncSettings() } }

    func start(keeping: Set<CGDirectDisplayID>) {
        self.keeping = keeping
        isOn = true
        if !registered {
            CGDisplayRegisterReconfigurationCallback(Self.reconfigured, Unmanaged.passUnretained(self).toOpaque())
            registered = true
        }
        apply()
        if watch == nil {
            // In every mode, so it still looks while a menu is open.
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.applyWhereLit() }
            RunLoop.main.add(timer, forMode: .common)
            watch = timer
        }
    }

    func stop() {
        guard isOn else { return }
        isOn = false
        reapply?.cancel()
        watch?.invalidate()
        watch = nil
        if registered {
            CGDisplayRemoveReconfigurationCallback(Self.reconfigured, Unmanaged.passUnretained(self).toOpaque())
            registered = false
        }
        CGDisplayRestoreColorSyncSettings()
        boLog.debug("screens back")
    }

    /// The displays it blacks out now.
    var blackedOut: [CGDirectDisplayID] {
        DisplayArrangement.onlineDisplayIDs().filter { !keeping.contains($0) && shouldBlackOut($0) }
    }

    private func apply() {
        guard isOn else { return }
        for id in blackedOut {
            let err = CGSetDisplayTransferByFormula(id, 0, 0, 1, 0, 0, 1, 0, 0, 1)
            if err != .success { boLog.error("display \(id): \(err.rawValue)") }
        }
        boLog.debug("blacked out \(self.blackedOut)")
    }

    /// Blacks out again the displays whose gamma something else put back.
    private func applyWhereLit() {
        guard isOn else { return }
        let lit = blackedOut.filter { !Self.isBlack($0) }
        guard !lit.isEmpty else { return }
        boLog.debug("lit again: \(lit)")
        apply()
    }

    /// Whether the display's gamma is black, as `apply` leaves it.
    static func isBlack(_ id: CGDirectDisplayID) -> Bool {
        var red = [CGGammaValue](repeating: 0, count: 256)
        var green = red, blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, 256, &red, &green, &blue, &count) == .success, count > 0 else { return true }
        let n = Int(count)
        return (red.prefix(n) + green.prefix(n) + blue.prefix(n)).max() ?? 0 < 0.05
    }

    private static let reconfigured: CGDisplayReconfigurationCallBack = { _, flags, info in
        guard !flags.contains(.beginConfigurationFlag), let info else { return }
        let blackout = Unmanaged<LocalBlackout>.fromOpaque(info).takeUnretainedValue()
        DispatchQueue.main.async { blackout.scheduleReapply() }
    }

    /// Sets the gamma again once the change has settled; several callbacks come for one change.
    private func scheduleReapply() {
        reapply?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.apply() }
        reapply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
