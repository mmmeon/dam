//
//  WakeGuard.swift
//
//  Puts a locked Mac on battery back to sleep when nobody unlocks it, as one carried in a
//  bag, whose keys or lid wake it. Waking itself can't be stopped: the Mac's controller
//  wakes it before macOS runs. So once it is locked and awake it has a few seconds to be
//  unlocked: 10 after it is locked, 15 after the power button (Touch ID, which may take a
//  second try) and 3 after the keyboard, trackpad or lid; keys pressed meanwhile don't add
//  to them, but for a password typed on a display that is plugged in, for up to 45 s.
//
//  A wake for anything else, as over the network, is left be, and so is a Mac in use from
//  elsewhere: a stream of DAM's, a remote session, or another app keeping it awake. On
//  power, as a Mac kept to be streamed from is, it does nothing. Off unless turned on.
//
//  After castbar's WakeGuard (MIT): wake reason from IOPMrootDomain, lock state from the
//  session, `pmset sleepnow` to sleep.
//

import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import os.log

private let wgLog = Logger(subsystem: AppIdentity.bundleID, category: "WakeGuard")

final class WakeGuard {
    private static let enabledKey = "\(AppIdentity.shortID).wakeGuard.enabled"

    static let shared = WakeGuard()

    static var isEnabled: Bool {
        get { UserDefaults.dam.bool(forKey: enabledKey) }
        set { UserDefaults.dam.set(newValue, forKey: enabledKey) }
    }

    /// Turns it on or off, from now and at later launches.
    func setEnabled(_ on: Bool) {
        Self.isEnabled = on
        on ? start() : stop()
    }

    /// Whether DAM is in use from elsewhere: a stream, a viewer or a remote session. On the
    /// main queue.
    var isInUse: () -> Bool = { false }

    /// The time it has to be unlocked in, counted from `since`; nil with nothing to watch.
    private var window: (since: Date, allowed: TimeInterval, why: String)?
    private var lastSleep = Date.distantPast
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?

    /// Starts watching, if turned on. On the main queue.
    func start() {
        guard Self.isEnabled, observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(forName: .init("com.apple.screenIsLocked"),
                                                               object: nil, queue: .main) { [weak self] _ in
            self?.arm(10, "locked")
        }))
        // A full wake only, not one in the dark for maintenance.
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                                           object: nil, queue: .main) { [weak self] _ in
            self?.woke()
        }))
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
        if Self.isLocked() { arm(10, "locked at start") }
        wgLog.debug("started")
    }

    func stop() {
        if !observers.isEmpty { wgLog.debug("stopped") }
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        timer?.invalidate()
        timer = nil
        window = nil
    }

    private func woke() {
        let reason = Self.wakeReason()
        wgLog.debug("woke: \(reason.isEmpty ? "no reason given" : reason, privacy: .public)")
        guard Self.isLocked(), let allowed = Self.allowance(forWake: reason) else { return }
        arm(allowed, "woken by \(reason)")
    }

    /// Seconds a wake for `reason` gives to unlock in; nil for a wake nobody at the Mac made.
    static func allowance(forWake reason: String) -> TimeInterval? {
        if reason.contains("PowerButton") || reason.contains("PWRB") { return 15 }
        let byHand = ["Keyboard", "Touchpad", "Trackpad", "Lid", "LID0"]
        return byHand.contains { reason.contains($0) } ? 3 : nil
    }

    private func arm(_ allowed: TimeInterval, _ why: String) {
        window = (Date(), allowed, why)
    }

    private func check() {
        guard let current = window else { return }
        guard Self.isLocked() else { window = nil; return }
        let elapsed = Date().timeIntervalSince(current.since)
        // A password typed on a display plugged in, when Touch ID fails.
        if Self.hasPhysicalDisplay(), Self.secondsSinceInput() < 3, elapsed < 45 { return }
        guard elapsed >= current.allowed, Date().timeIntervalSince(lastSleep) > 10 else { return }
        window = nil
        guard Self.isOnBattery() else { return wgLog.debug("not sleeping: on power") }
        guard !isInUse() else { return wgLog.debug("not sleeping: in use from elsewhere") }
        if let holder = Self.otherAppKeepingAwake() {
            return wgLog.debug("not sleeping: \(holder, privacy: .public) keeps the Mac awake")
        }
        wgLog.notice("sleeping: \(current.why, privacy: .public), \(Int(elapsed)) s not unlocked")
        lastSleep = Date()
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["sleepnow"]
        do { try pmset.run() } catch { wgLog.error("pmset: \(String(describing: error), privacy: .public)") }
    }

    // MARK: State

    static func isLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    static func wakeReason() -> String {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "Wake Reason" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String ?? ""
    }

    /// Seconds since a key was pressed or the pointer moved.
    static func secondsSinceInput() -> TimeInterval {
        let hid = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        defer { IOObjectRelease(hid) }
        let nanoseconds = IORegistryEntryCreateCFProperty(hid, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber
        return (nanoseconds?.doubleValue ?? .infinity) / 1_000_000_000
    }

    /// Whether a display other than DAM's own virtual ones is online, to type a password on.
    static func hasPhysicalDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).contains { CGDisplayVendorNumber($0) != VideoManager.anchorVendorID }
    }

    static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return source as String == kIOPMBatteryPowerKey
    }

    /// The name of another process holding the Mac awake, as a remote desktop's host or
    /// `caffeinate` does; nil if none.
    static func otherAppKeepingAwake() -> String? {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return nil }
        let keeping: Set<String> = [kIOPMAssertionTypePreventSystemSleep, kIOPMAssertionTypePreventUserIdleSystemSleep]
        let own = ProcessInfo.processInfo.processIdentifier
        for (pid, assertions) in all where pid.int32Value != own {
            if let held = assertions.first(where: { ($0[kIOPMAssertionTypeKey] as? String).map(keeping.contains) == true }) {
                let name = held["Process Name"] as? String ?? "process \(pid)"
                return "\(name) (\(held[kIOPMAssertionNameKey] as? String ?? "no name"))"
            }
        }
        return nil
    }
}
