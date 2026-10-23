//
//  OpenDisplayStore.swift
//
//  What OpenDisplaySender keeps between runs and reads as it sends: whether it sends, the
//  bitrate, the receivers turned on and which to dial now, and the names and IDs it learned.
//  In DAM it is the user's preferences and the Connect Automatically list; the login window
//  agent will have its own, from a file DAM writes for it (docs/root-and-login-window.md).
//

import Foundation

protocol OpenDisplayStore: AnyObject {
    /// Whether to send to receivers at all.
    var isEnabled: Bool { get }
    /// The video's bitrate, in kbit/s. Read from the streams' queues too.
    var bitrateKbps: Int { get set }
    /// Whether the pointer may go over UDP where a receiver offers it.
    var pointerOverUDP: Bool { get }

    /// The receivers turned on, by key. One turned on goes after those already on.
    var turnedOn: Set<String> { get set }
    /// The receivers turned on that may be dialled now, best first.
    func toDial(hasOwnDisplay: Bool) -> [String]
    /// A receiver's key as it changes, once its ID is known, keeping its place.
    func rename(_ old: String, to new: String)

    /// The names receivers were last seen with, by key.
    var names: [String: String] { get set }
    /// Receivers' IDs by the UDID of the device they run on.
    var usbIDs: [String: String] { get set }
    /// Receivers' IDs by their Bonjour name.
    var bonjourIDs: [String: String] { get set }
}

extension OpenDisplayStore {
    /// `turnedOn` for a store that keeps the receivers as entries of a Connect Automatically
    /// list: removed ones leave it, new ones go to its end, in key order.
    static func turningOn(_ keys: Set<String>, in entries: [AutoConnectEntry]) -> [AutoConnectEntry] {
        let on = Set(AutoConnectList.openDisplayKeys(in: entries, hasOwnDisplay: false))
        var out = entries
        for key in on.subtracting(keys) { out = AutoConnectList.settingOpenDisplay(key, on: false, in: out) }
        for key in keys.subtracting(on).sorted() { out = AutoConnectList.settingOpenDisplay(key, on: true, in: out) }
        return out
    }
}

/// DAM's: the user's preferences, and the Connect Automatically list with this run's windows.
final class DefaultsOpenDisplayStore: OpenDisplayStore {
    private static let namesKey = "\(AppIdentity.shortID).opendisplay.names"
    private static let usbIDsKey = "\(AppIdentity.shortID).opendisplay.usbIDs"
    private static let bonjourIDsKey = "\(AppIdentity.shortID).opendisplay.bonjourIDs"

    var isEnabled: Bool { OpenDisplaySender.isEnabled }

    var bitrateKbps: Int {
        get { OpenDisplaySender.bitrateKbps }
        set { OpenDisplaySender.bitrateKbps = newValue }
    }

    var pointerOverUDP: Bool { OpenDisplaySender.pointerOverUDP }

    /// The list keeps the order. The older setting under `OpenDisplaySender.receiversKey` is
    /// read once, when the list is first made.
    var turnedOn: Set<String> {
        get { Set(AutoConnectList.openDisplayKeys(in: AutoConnectList.entries, hasOwnDisplay: false)) }
        set { AutoConnectList.entries = Self.turningOn(newValue, in: AutoConnectList.entries) }
    }

    func toDial(hasOwnDisplay: Bool) -> [String] {
        AutoConnectList.openDisplayKeys(in: AutoConnectList.entries, hasOwnDisplay: hasOwnDisplay,
                                        windows: AutoConnectSession.now)
    }

    func rename(_ old: String, to new: String) {
        AutoConnectList.entries = AutoConnectList.renamingOpenDisplay(old, to: new, in: AutoConnectList.entries)
    }

    var names: [String: String] {
        get { UserDefaults.dam.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:] }
        set { UserDefaults.dam.set(newValue, forKey: Self.namesKey) }
    }

    var usbIDs: [String: String] {
        get { UserDefaults.dam.dictionary(forKey: Self.usbIDsKey) as? [String: String] ?? [:] }
        set { UserDefaults.dam.set(newValue, forKey: Self.usbIDsKey) }
    }

    var bonjourIDs: [String: String] {
        get { UserDefaults.dam.dictionary(forKey: Self.bonjourIDsKey) as? [String: String] ?? [:] }
        set { UserDefaults.dam.set(newValue, forKey: Self.bonjourIDsKey) }
    }
}

/// Kept in memory only: for tests, and for the login window agent, which starts from what DAM
/// wrote for it and learns no further than its run. Its entries all apply, whatever their mode.
final class MemoryOpenDisplayStore: OpenDisplayStore {
    private let lock = NSLock()
    private var _bitrateKbps: Int
    private var _entries: [AutoConnectEntry]
    private var _names: [String: String]
    private var _usbIDs: [String: String]
    private var _bonjourIDs: [String: String]
    let isEnabled: Bool
    let pointerOverUDP: Bool

    init(isEnabled: Bool = true, bitrateKbps: Int = 20_000, pointerOverUDP: Bool = true,
         entries: [AutoConnectEntry] = [], names: [String: String] = [:],
         usbIDs: [String: String] = [:], bonjourIDs: [String: String] = [:]) {
        self.isEnabled = isEnabled
        self.pointerOverUDP = pointerOverUDP
        _bitrateKbps = bitrateKbps
        _entries = entries
        _names = names
        _usbIDs = usbIDs
        _bonjourIDs = bonjourIDs
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    var entries: [AutoConnectEntry] { locked { _entries } }

    var bitrateKbps: Int {
        get { locked { _bitrateKbps } }
        set { locked { _bitrateKbps = newValue } }
    }

    var turnedOn: Set<String> {
        get { locked { Set(AutoConnectList.openDisplayKeys(in: _entries, hasOwnDisplay: false)) } }
        set { locked { _entries = Self.turningOn(newValue, in: _entries) } }
    }

    func toDial(hasOwnDisplay: Bool) -> [String] {
        locked { AutoConnectList.openDisplayKeys(in: _entries, hasOwnDisplay: hasOwnDisplay) }
    }

    func rename(_ old: String, to new: String) {
        locked { _entries = AutoConnectList.renamingOpenDisplay(old, to: new, in: _entries) }
    }

    var names: [String: String] {
        get { locked { _names } }
        set { locked { _names = newValue } }
    }

    var usbIDs: [String: String] {
        get { locked { _usbIDs } }
        set { locked { _usbIDs = newValue } }
    }

    var bonjourIDs: [String: String] {
        get { locked { _bonjourIDs } }
        set { locked { _bonjourIDs = newValue } }
    }
}
