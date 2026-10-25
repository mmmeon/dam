//
//  WakeGuard.swift
//
//  Puts a locked Mac on battery back to sleep when nobody unlocks it, as one carried in a
//  bag, whose keys or lid wake it. Waking itself can't be stopped: the Mac's controller
//  wakes it before macOS runs. So once it is locked and awake it has a few seconds to be
//  unlocked: 10 after it is locked, 15 after the power button (Touch ID, which may take a
//  second try, and after a wake that doesn't say what woke it) and 3 after the keyboard,
//  trackpad or lid; keys pressed meanwhile don't add to them, but for a password typed on
//  a display that is plugged in, for up to 45 s.
//
//  Whether someone at the Mac woke it is the kernel's to say: IOPMrootDomain's
//  IOPMUserTriggeredFullWake, set as it reaches full wake, is true for a wake by its keys,
//  trackpad, power button or lid, or a timer, and false for one over the network or for a
//  notification or another process asking for the display. The wake reason only sets the
//  time, as its codes differ from Mac to Mac: a 2016–2017 MacBook Pro gives "EC.PowerButton
//  PWRB" for its power button and "SPIT" for its keyboard and trackpad, on SPI.
//
//  A wake nobody at the Mac made is left be, and so is a Mac in use from elsewhere: a
//  stream of DAM's, a remote session, or another app keeping it awake. On power, as a Mac
//  kept to be streamed from is, it does nothing. Off unless turned on.
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
    /// Whether waiting for a password typed has been logged since `window` was set.
    private var typingLogged = false
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
        let reason = Self.wakeProperty("Wake Reason"), type = Self.wakeProperty("Wake Type")
        let byUser = Self.userTriggeredFullWake()
        wgLog.debug("woke: reason \(reason.isEmpty ? "none" : reason, privacy: .public), type \(type.isEmpty ? "none" : type, privacy: .public), by a user \(byUser.map { $0 ? "yes" : "no" } ?? "not said", privacy: .public)")
        guard Self.isLocked(), let allowed = Self.allowance(forWake: reason, byUser: byUser) else { return }
        arm(allowed, "woken by \(reason.isEmpty ? type : reason)")
    }

    /// Seconds a wake for `reason` gives to unlock in; nil for a wake nobody at the Mac made.
    /// `byUser` is IOPMUserTriggeredFullWake; without it, the reason alone says.
    static func allowance(forWake reason: String, byUser: Bool?) -> TimeInterval? {
        let powerButton = ["PowerButton", "PWRB", "pwrbtn"].contains { reason.contains($0) }
        if let byUser {
            guard byUser else { return nil }
            // A wake that doesn't say may have been the power button.
            return powerButton || reason.isEmpty ? 15 : 3
        }
        if powerButton { return 15 }
        // SPIT: a 2016–2017 MacBook Pro's keyboard and trackpad, on SPI.
        let byHand = ["Keyboard", "Touchpad", "Trackpad", "Lid", "LID0", "SPIT"]
        return byHand.contains { reason.contains($0) } ? 3 : nil
    }

    private func arm(_ allowed: TimeInterval, _ why: String) {
        window = (Date(), allowed, why)
        typingLogged = false
    }

    private func check() {
        guard let current = window else { return }
        guard Self.isLocked() else {
            // As loginwindow does itself for a wake within the password delay after the
            // display turned off.
            window = nil
            return wgLog.debug("not sleeping: unlocked")
        }
        let elapsed = Date().timeIntervalSince(current.since)
        // A password typed on a display plugged in, when Touch ID fails.
        if Self.hasPhysicalDisplay(), Self.secondsSinceInput() < 3, elapsed < 45 {
            if !typingLogged { wgLog.debug("waiting: typing on a display") }
            typingLogged = true
            return
        }
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

    /// Whether the kernel took the last full wake for one by someone at the Mac; nil if it
    /// doesn't say.
    static func userTriggeredFullWake() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "IOPMUserTriggeredFullWake" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }

    /// The power manager's `name` for the last wake, as "Wake Reason" or "Wake Type"; empty without one.
    static func wakeProperty(_ name: String) -> String {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, name as CFString, kCFAllocatorDefault, 0)?
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
