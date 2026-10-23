//
//  AutoConnect.swift
//
//  The user's trusted displays, in order of preference, and which of them to connect next
//  (docs/auto-connect.md). OpenDisplay receivers on the list are all dialled at once by
//  OpenDisplaySender; of AirPlay displays and Sidecar iPads, the first in reach is connected,
//  and nothing more while one is.
//

import AppKit
import os

private let acLog = Logger(subsystem: AppIdentity.bundleID, category: "AutoConnect")

/// A display the user trusts to be connected without asking.
enum AutoConnectTarget: Hashable {
    /// An OpenDisplay receiver, by its key in OpenDisplaySender.
    case openDisplay(key: String)
    /// An AirPlay display, by its name.
    case airPlay(name: String)
    /// An iPad over Sidecar, by its name: SidecarCore's identifiers may change between updates.
    case sidecar(name: String)
    /// Whichever iPad is plugged in over USB, as the older Sidecar setting did.
    case anyIPadOnUSB
}

struct AutoConnectEntry: Hashable {
    /// When an entry is connected.
    enum Mode: String, CaseIterable {
        /// Whenever it comes within reach.
        case always
        /// In the window after DAM starts at sign-in.
        case login
        /// From boot: at the login window (once its agent exists, root-and-login-window.md),
        /// then in the window after the first sign-in since boot. OpenDisplay only, as nothing
        /// else can be connected before sign-in.
        case startup
    }

    var target: AutoConnectTarget
    /// Connected only while the Mac has no display of its own.
    var onlyWithoutOwnDisplay = false
    var mode: Mode = .always

    /// The modes `target` can have.
    static func modes(for target: AutoConnectTarget) -> [Mode] {
        if case .openDisplay = target { return Mode.allCases }
        return [.always, .login]
    }

    func applies(hasOwnDisplay: Bool, windows: AutoConnectWindows = .always) -> Bool {
        guard !(onlyWithoutOwnDisplay && hasOwnDisplay) else { return false }
        switch mode {
        case .always:  return true
        case .login:   return windows.login
        case .startup: return windows.startup
        }
    }

    // MARK: Storage

    /// As stored: a property list, so `defaults read` shows it.
    var dictionary: [String: Any] {
        var out: [String: Any] = ["onlyWithoutOwnDisplay": onlyWithoutOwnDisplay, "mode": mode.rawValue]
        switch target {
        case .openDisplay(let key): out["kind"] = "openDisplay"; out["id"] = key
        case .airPlay(let name):    out["kind"] = "airPlay"; out["id"] = name
        case .sidecar(let name):    out["kind"] = "sidecar"; out["id"] = name
        case .anyIPadOnUSB:         out["kind"] = "anyIPadOnUSB"
        }
        return out
    }

    init(target: AutoConnectTarget, onlyWithoutOwnDisplay: Bool = false, mode: Mode = .always) {
        self.target = target
        self.onlyWithoutOwnDisplay = onlyWithoutOwnDisplay
        self.mode = mode
    }

    /// Nil for a kind this version doesn't know, which is then dropped. An entry stored
    /// before modes, or with a mode its kind can't have, is connected always.
    init?(dictionary: [String: Any]) {
        let id = dictionary["id"] as? String
        switch (dictionary["kind"] as? String, id) {
        case ("openDisplay", let id?):  target = .openDisplay(key: id)
        case ("airPlay", let id?):      target = .airPlay(name: id)
        case ("sidecar", let id?):      target = .sidecar(name: id)
        case ("anyIPadOnUSB", _):       target = .anyIPadOnUSB
        default:                        return nil
        }
        onlyWithoutOwnDisplay = dictionary["onlyWithoutOwnDisplay"] as? Bool ?? false
        let mode = (dictionary["mode"] as? String).flatMap(Mode.init(rawValue:)) ?? .always
        self.mode = Self.modes(for: target).contains(mode) ? mode : .always
    }
}

enum AutoConnectList {
    private static let key = "\(AppIdentity.shortID).autoConnect.list"

    /// The list, made from the older settings the first time it is read.
    static var entries: [AutoConnectEntry] {
        get {
            if let stored = UserDefaults.dam.array(forKey: key) as? [[String: Any]] {
                return stored.compactMap(AutoConnectEntry.init(dictionary:))
            }
            let made = migrated(receivers: UserDefaults.dam.stringArray(forKey: OpenDisplaySender.receiversKey) ?? [],
                                sidecarWithoutDisplay: VisibilityPreferences.autoConnectsSidecarWithoutDisplay)
            self.entries = made
            return made
        }
        set {
            UserDefaults.dam.set(deduplicated(newValue).map(\.dictionary), forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static let didChange = Notification.Name("\(AppIdentity.shortID).autoConnect.didChange")

    /// The list the older settings stood for: the receivers turned on, in the order they were
    /// stored (sorted by key), then any iPad on USB while the Mac has no display of its own;
    /// all connected always, as they were.
    static func migrated(receivers: [String], sidecarWithoutDisplay: Bool) -> [AutoConnectEntry] {
        var out = receivers.map { AutoConnectEntry(target: .openDisplay(key: $0)) }
        if sidecarWithoutDisplay { out.append(AutoConnectEntry(target: .anyIPadOnUSB, onlyWithoutOwnDisplay: true)) }
        return deduplicated(out)
    }

    /// The first entry for each target.
    static func deduplicated(_ entries: [AutoConnectEntry]) -> [AutoConnectEntry] {
        var seen = Set<AutoConnectTarget>()
        return entries.filter { seen.insert($0.target).inserted }
    }

    // MARK: Window

    private static let windowKey = "\(AppIdentity.shortID).autoConnect.windowSeconds"
    static let defaultWindow: TimeInterval = 120
    /// The window lengths Settings offers, in seconds.
    static let windowChoices: [TimeInterval] = [30, 60, 120, 300, 600]

    /// How long after sign-in (or startup) entries connected at login (or startup) may still be.
    static var window: TimeInterval {
        get { (UserDefaults.dam.object(forKey: windowKey) as? Double).map { max(0, $0) } ?? defaultWindow }
        set { UserDefaults.dam.set(newValue, forKey: windowKey) }
    }

    // MARK: OpenDisplay

    /// The receivers on the list that apply now, best first: the ones to dial.
    static func openDisplayKeys(in entries: [AutoConnectEntry], hasOwnDisplay: Bool,
                                windows: AutoConnectWindows = .always) -> [String] {
        entries.compactMap { entry in
            guard entry.applies(hasOwnDisplay: hasOwnDisplay, windows: windows),
                  case .openDisplay(let key) = entry.target else { return nil }
            return key
        }
    }

    /// Puts a receiver on the list, at the end, or takes it off.
    static func settingOpenDisplay(_ key: String, on: Bool, in entries: [AutoConnectEntry]) -> [AutoConnectEntry] {
        let target = AutoConnectTarget.openDisplay(key: key)
        if on { return entries.contains { $0.target == target } ? entries : entries + [AutoConnectEntry(target: target)] }
        return entries.filter { $0.target != target }
    }

    /// A receiver's key as it changes, once its ID is known, keeping its place. When the new
    /// key is listed already, the earlier of the two places is kept.
    static func renamingOpenDisplay(_ old: String, to new: String, in entries: [AutoConnectEntry]) -> [AutoConnectEntry] {
        deduplicated(entries.map { entry in
            guard entry.target == .openDisplay(key: old) else { return entry }
            var renamed = entry
            renamed.target = .openDisplay(key: new)
            return renamed
        })
    }
}

// MARK: - Windows

/// Whether entries connected at login, or at startup, apply now.
struct AutoConnectWindows: Equatable {
    var login = false
    var startup = false

    /// Outside any window: only entries connected always apply.
    static let none = AutoConnectWindows()
    /// For callers that don't care about windows.
    static let always = AutoConnectWindows(login: true, startup: true)

    /// When the windows of this run of DAM end. DAM started at sign-in when it started within
    /// `length` of the user's login; then the login window runs `length` from its start, and,
    /// for the first such start since boot, the startup window too. Opened by hand later, it
    /// has neither.
    static func ends(launch: Date, login: Date?, boot: Date, bootSeenBefore: Date?,
                     length: TimeInterval) -> (login: Date?, startup: Date?) {
        guard let login, launch >= login - 5, launch.timeIntervalSince(login) <= length else { return (nil, nil) }
        let end = launch + length
        let firstSinceBoot = bootSeenBefore.map { abs($0.timeIntervalSince(boot)) > 1 } ?? true
        return (end, firstSinceBoot ? end : nil)
    }

    /// The windows open at `now`, from their ends.
    static func at(_ now: Date, ends: (login: Date?, startup: Date?)) -> AutoConnectWindows {
        AutoConnectWindows(login: ends.login.map { now < $0 } ?? false,
                           startup: ends.startup.map { now < $0 } ?? false)
    }
}

/// This run's windows, worked out once at launch from the system's boot time and the user's
/// console login.
enum AutoConnectSession {
    private static let bootSeenKey = "\(AppIdentity.shortID).autoConnect.bootSeen"

    static let ends: (login: Date?, startup: Date?) = {
        let boot = bootTime() ?? .distantPast
        let seen = (UserDefaults.dam.object(forKey: bootSeenKey) as? Double).map(Date.init(timeIntervalSince1970:))
        let ends = AutoConnectWindows.ends(launch: Date(), login: consoleLogin(), boot: boot, bootSeenBefore: seen,
                                           length: AutoConnectList.window)
        // Only a start at sign-in uses up the startup window; one opened by hand doesn't.
        if ends.login != nil { UserDefaults.dam.set(boot.timeIntervalSince1970, forKey: bootSeenKey) }
        acLog.debug("windows: login until \(ends.login?.description ?? "none", privacy: .public), startup until \(ends.startup?.description ?? "none", privacy: .public)")
        return ends
    }()

    static var now: AutoConnectWindows { AutoConnectWindows.at(Date(), ends: ends) }

    private static func bootTime() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }

    /// When this user last logged in at the console, from the login records.
    private static func consoleLogin() -> Date? {
        let user = NSUserName()
        var latest: Date?
        setutxent()
        defer { endutxent() }
        while let entry = getutxent() {
            guard entry.pointee.ut_type == USER_PROCESS else { continue }
            let name = withUnsafeBytes(of: entry.pointee.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let line = withUnsafeBytes(of: entry.pointee.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard name == user, line == "console" else { continue }
            let time = Date(timeIntervalSince1970: TimeInterval(entry.pointee.ut_tv.tv_sec))
            if latest.map({ time > $0 }) ?? true { latest = time }
        }
        return latest
    }
}

// MARK: - Deciding

/// An AirPlay display or a Sidecar iPad in reach now.
struct AutoConnectCandidate: Equatable {
    enum Kind { case airPlay, sidecar }

    let kind: Kind
    let name: String
    let isConnected: Bool
    /// For an iPad: plugged in over USB.
    var onUSB = false

    /// What its attempts are kept under.
    var attemptKey: String { (kind == .airPlay ? "airplay:" : "sidecar:") + name }

    func matches(_ target: AutoConnectTarget) -> Bool {
        switch target {
        case .airPlay(let name):  return kind == .airPlay && self.name == name
        case .sidecar(let name):  return kind == .sidecar && self.name == name
        case .anyIPadOnUSB:       return kind == .sidecar && onUSB
        case .openDisplay:        return false
        }
    }
}

enum AutoConnectPlan {
    struct Attempt: Equatable {
        var count = 0
        var nextTry = Date.distantPast
        /// Connected, automatically or by hand: not tried again until it leaves reach, so one
        /// disconnected by hand stays so.
        var done = false
    }

    static let maxAttempts = 6

    /// Which display to connect now, if any, and the attempts to keep.
    ///
    /// Nothing is connected while an AirPlay display or an iPad is, listed or not: the first
    /// available is enough, and a better one appearing later doesn't replace it. Otherwise the
    /// list is gone down in order; the first entry in reach that may still be tried decides.
    /// When it is waiting to be tried again, or is an AirPlay display and AirPlay isn't ready,
    /// nothing is connected yet rather than a worse one. Displays out of reach are forgotten,
    /// so one that comes back starts afresh.
    static func plan(entries: [AutoConnectEntry], candidates: [AutoConnectCandidate],
                     attempts: [String: Attempt], hasOwnDisplay: Bool, airPlayReady: Bool,
                     windows: AutoConnectWindows = .always,
                     now: Date) -> (connect: AutoConnectCandidate?, attempts: [String: Attempt]) {
        var next = attempts.filter { entry in candidates.contains { $0.attemptKey == entry.key } }
        for candidate in candidates {
            if next[candidate.attemptKey] == nil { next[candidate.attemptKey] = Attempt() }
            if candidate.isConnected { next[candidate.attemptKey]?.done = true }
        }
        guard !candidates.contains(where: \.isConnected) else { return (nil, next) }
        for entry in entries where entry.applies(hasOwnDisplay: hasOwnDisplay, windows: windows) {
            for candidate in candidates where candidate.matches(entry.target) {
                guard let attempt = next[candidate.attemptKey], !attempt.done, attempt.count < maxAttempts else { continue }
                guard attempt.nextTry <= now, candidate.kind != .airPlay || airPlayReady else { return (nil, next) }
                return (candidate, next)
            }
        }
        return (nil, next)
    }
}

// MARK: - Connecting

/// Connects the AirPlay display or iPad that `AutoConnectPlan` picks, checked every few
/// seconds, from DAM's start at login on. OpenDisplay receivers are OpenDisplaySender's own.
final class AutoConnector {
    static let interval: TimeInterval = 3
    static let retryDelay: TimeInterval = 10
    /// How long an attempt may take before another is allowed: a stand-in display and the
    /// Sidecar connection can each take several seconds, and so can Control Center's panel.
    static let attemptTimeout: TimeInterval = 45
    /// AirPlay waits this long after the last key press: driving Control Center's panel moves
    /// the focus, which would take keys meant for something else, as just after login.
    static let quietAfterTyping: TimeInterval = 2

    private let sidecar: SidecarManager
    private weak var video: VideoManager?
    private var timer: Timer?
    private var attempts: [String: AutoConnectPlan.Attempt] = [:]
    /// Control Center answered Accessibility once; it may be slow to start after login.
    private var controlCenterAnswered = false

    init(sidecar: SidecarManager, video: VideoManager) {
        self.sidecar = sidecar
        self.video = video
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    private func tick() {
        guard let video else { return }
        let entries = AutoConnectList.entries
        // Nothing to look for: neither SidecarCore nor Control Center is asked.
        guard entries.contains(where: { if case .openDisplay = $0.target { return false } else { return true } }) else {
            attempts = [:]
            return
        }
        sidecar.refresh()
        let candidates = video.allAirPlayDevices.map {
            AutoConnectCandidate(kind: .airPlay, name: $0.name, isConnected: $0.isConnected)
        } + sidecar.devices.map {
            AutoConnectCandidate(kind: .sidecar, name: $0.name, isConnected: $0.isConnected, onUSB: $0.link == .usb)
        }
        let now = Date()
        let plan = AutoConnectPlan.plan(entries: entries, candidates: candidates, attempts: attempts,
                                        hasOwnDisplay: video.hasOwnDisplay(), airPlayReady: airPlayReady(),
                                        windows: AutoConnectSession.now, now: now)
        attempts = plan.attempts
        guard let candidate = plan.connect else { return }
        let key = candidate.attemptKey
        attempts[key]?.count += 1
        attempts[key]?.nextTry = now + Self.attemptTimeout
        acLog.debug("connecting \(candidate.name, privacy: .public), attempt \(self.attempts[key]?.count ?? 0)")
        let finished: (Bool) -> Void = { [weak self] connected in
            guard let self, self.attempts[key] != nil else { return }
            if connected {
                self.attempts[key]?.done = true
            } else {
                self.attempts[key]?.nextTry = Date() + Self.retryDelay
            }
        }
        switch candidate.kind {
        case .airPlay:
            guard let display = video.allAirPlayDevices.first(where: { $0.name == candidate.name }) else { return }
            video.connectAirPlay(deviceName: display.name,
                                 announcing: ConnectTarget.airPlay(display).connectingAnnouncement,
                                 completion: finished)
        case .sidecar:
            guard let device = sidecar.devices.first(where: { $0.name == candidate.name }) else { return }
            SpeechSynthesizer.shared.announce(ConnectTarget.sidecar(device).connectingAnnouncement)
            sidecar.connect(device, videoManager: video) { error in finished(error == nil) }
        }
    }

    /// Whether Control Center's panel can be driven now without getting in the way: with
    /// Accessibility granted (never asked for here), Control Center answering, and no key
    /// pressed for a moment.
    private func airPlayReady() -> Bool {
        guard VideoManager.hasAccessibilityAccess(prompting: false) else { return false }
        if !controlCenterAnswered { controlCenterAnswered = Self.controlCenterAnswers() }
        return controlCenterAnswered
            && CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) >= Self.quietAfterTyping
    }

    /// Whether Control Center is running and answers Accessibility, without opening anything.
    private static func controlCenterAnswers() -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first
        else { return false }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        var children: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success
    }
}
