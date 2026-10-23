//
//  AutoConnect.swift
//
//  The user's trusted displays, in order of preference, and which of them to connect next
//  (docs/auto-connect.md). OpenDisplay receivers on the list are all dialled at once by
//  OpenDisplaySender; of AirPlay displays and Sidecar iPads, the first in reach is connected,
//  and nothing more while one is.
//

import Foundation

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
    var target: AutoConnectTarget
    /// Connected only while the Mac has no display of its own.
    var onlyWithoutOwnDisplay = false

    func applies(hasOwnDisplay: Bool) -> Bool { !(onlyWithoutOwnDisplay && hasOwnDisplay) }

    // MARK: Storage

    /// As stored: a property list, so `defaults read` shows it.
    var dictionary: [String: Any] {
        var out: [String: Any] = ["onlyWithoutOwnDisplay": onlyWithoutOwnDisplay]
        switch target {
        case .openDisplay(let key): out["kind"] = "openDisplay"; out["id"] = key
        case .airPlay(let name):    out["kind"] = "airPlay"; out["id"] = name
        case .sidecar(let name):    out["kind"] = "sidecar"; out["id"] = name
        case .anyIPadOnUSB:         out["kind"] = "anyIPadOnUSB"
        }
        return out
    }

    init(target: AutoConnectTarget, onlyWithoutOwnDisplay: Bool = false) {
        self.target = target
        self.onlyWithoutOwnDisplay = onlyWithoutOwnDisplay
    }

    /// Nil for a kind this version doesn't know, which is then dropped.
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
    /// stored (sorted by key), then any iPad on USB while the Mac has no display of its own.
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

    // MARK: OpenDisplay

    /// The receivers on the list whose condition holds, best first: the ones to dial.
    static func openDisplayKeys(in entries: [AutoConnectEntry], hasOwnDisplay: Bool) -> [String] {
        entries.compactMap { entry in
            guard entry.applies(hasOwnDisplay: hasOwnDisplay), case .openDisplay(let key) = entry.target else { return nil }
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
                     now: Date) -> (connect: AutoConnectCandidate?, attempts: [String: Attempt]) {
        var next = attempts.filter { entry in candidates.contains { $0.attemptKey == entry.key } }
        for candidate in candidates {
            if next[candidate.attemptKey] == nil { next[candidate.attemptKey] = Attempt() }
            if candidate.isConnected { next[candidate.attemptKey]?.done = true }
        }
        guard !candidates.contains(where: \.isConnected) else { return (nil, next) }
        for entry in entries where entry.applies(hasOwnDisplay: hasOwnDisplay) {
            for candidate in candidates where candidate.matches(entry.target) {
                guard let attempt = next[candidate.attemptKey], !attempt.done, attempt.count < maxAttempts else { continue }
                guard attempt.nextTry <= now, candidate.kind != .airPlay || airPlayReady else { return (nil, next) }
                return (candidate, next)
            }
        }
        return (nil, next)
    }
}
