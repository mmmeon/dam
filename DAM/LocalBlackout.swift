//
//  LocalBlackout.swift
//
//  Blacks out the Mac's own screens while a remote session is on, so someone at the Mac
//  doesn't see what the remote user does. It turns each screen's gamma to black: the picture
//  is still drawn, and captures and streams of it are untouched; only the light leaves.
//  macOS resets gamma when the displays change, so it is set again after each change, and
//  puts it back itself when DAM quits, however it quits.
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
    }

    func stop() {
        guard isOn else { return }
        isOn = false
        reapply?.cancel()
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
