//
//  AutoConnect.swift
//
//  The user's trusted displays, in order of preference, and which of them to connect next
//  (docs/auto-connect.md). OpenDisplay receivers on the list are all dialled at once by
//  OpenDisplaySender; of AirPlay displays and Sidecar iPads, the first in reach is connected,
//  and nothing more while one is.
//

import Foundation
import os

let acLog = Logger(subsystem: AppIdentity.bundleID, category: "AutoConnect")

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
        /// At the login window too, by the login window agent (root-and-login-window.md), which
        /// launchd runs at every one; after sign-in, as at login. OpenDisplay only, as nothing
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
        case .always:           return true
        case .login, .startup:  return windows.login
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
    /// The older Sidecar setting the list replaced: an iPad on USB connected while the Mac
    /// has no display of its own. Read once, to make the list.
    private static let sidecarWithoutDisplayKey = "\(AppIdentity.shortID).sidecar.autoConnectWithoutDisplay"

    /// The list, made from the older settings the first time it is read.
    static var entries: [AutoConnectEntry] {
        get {
            if let stored = UserDefaults.dam.array(forKey: key) as? [[String: Any]] {
                return stored.compactMap(AutoConnectEntry.init(dictionary:))
            }
            let made = migrated(receivers: UserDefaults.dam.stringArray(forKey: OpenDisplaySender.receiversKey) ?? [],
                                sidecarWithoutDisplay: UserDefaults.dam.bool(forKey: sidecarWithoutDisplayKey))
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

    /// How long after sign-in entries connected at login or startup may still be.
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

/// Whether entries connected at login or startup apply now.
struct AutoConnectWindows: Equatable {
    var login = false

    /// Outside the window: only entries connected always apply.
    static let none = AutoConnectWindows()
    /// For callers that don't care about windows.
    static let always = AutoConnectWindows(login: true)

    /// When this run of DAM's window ends. DAM started at sign-in when it started within
    /// `length` of the user's login; then the window runs `length` from its start. Opened by
    /// hand later, it has none.
    static func end(launch: Date, login: Date?, length: TimeInterval) -> Date? {
        guard let login, launch >= login - 5, launch.timeIntervalSince(login) <= length else { return nil }
        return launch + length
    }

    /// The window as it is at `now`, from its end.
    static func at(_ now: Date, end: Date?) -> AutoConnectWindows {
        AutoConnectWindows(login: end.map { now < $0 } ?? false)
    }
}

/// This run's window, worked out once at launch from the user's console login.
enum AutoConnectSession {
    static let end: Date? = {
        let end = AutoConnectWindows.end(launch: Date(), login: consoleLogin(), length: AutoConnectList.window)
        acLog.debug("window after login until \(end?.description ?? "none", privacy: .public)")
        return end
    }()

    static var now: AutoConnectWindows { AutoConnectWindows.at(Date(), end: end) }

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
