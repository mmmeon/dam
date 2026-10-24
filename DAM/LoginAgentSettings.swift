//
//  LoginAgentSettings.swift
//
//  What DAM tells the login window agent: the OpenDisplay receivers to connect at startup,
//  what DAM learned of them, and the bitrate. DAM writes it, root-only, when the list
//  changes; the agent reads it when the login window comes up (root-and-login-window.md).
//

import Foundation

struct LoginAgentSettings: Equatable {
    /// Where DAM writes it and the agent reads it.
    static let directory = URL(fileURLWithPath: "/Library/Application Support/DAM/LoginWindow", isDirectory: true)
    static let url = directory.appendingPathComponent("settings.plist")

    /// The receivers to connect at startup, best first.
    var entries: [AutoConnectEntry] = []
    var names: [String: String] = [:]
    var usbIDs: [String: String] = [:]
    var bonjourIDs: [String: String] = [:]
    var bitrateKbps = 20_000

    /// What DAM's settings give the agent: the OpenDisplay receivers connected at startup,
    /// and only what was learned of those.
    static func make(entries: [AutoConnectEntry], names: [String: String], usbIDs: [String: String],
                     bonjourIDs: [String: String], bitrateKbps: Int) -> LoginAgentSettings {
        let startup = entries.filter { entry in
            guard entry.mode == .startup, case .openDisplay = entry.target else { return false }
            return true
        }
        let keys = Set(AutoConnectList.openDisplayKeys(in: startup, hasOwnDisplay: false))
        return LoginAgentSettings(entries: startup, names: names.filter { keys.contains($0.key) },
                                  usbIDs: usbIDs.filter { keys.contains($0.value) },
                                  bonjourIDs: bonjourIDs.filter { keys.contains($0.value) },
                                  bitrateKbps: bitrateKbps)
    }

    /// The agent's store: cable only, and every entry dialled whatever the window.
    func store() -> MemoryOpenDisplayStore {
        MemoryOpenDisplayStore(bitrateKbps: bitrateKbps, pointerOverUDP: false, usbOnly: true, entries: entries,
                               names: names, usbIDs: usbIDs, bonjourIDs: bonjourIDs)
    }

    // MARK: Storage

    var dictionary: [String: Any] {
        ["entries": entries.map(\.dictionary), "names": names, "usbIDs": usbIDs, "bonjourIDs": bonjourIDs,
         "bitrateKbps": bitrateKbps]
    }

    init(entries: [AutoConnectEntry] = [], names: [String: String] = [:], usbIDs: [String: String] = [:],
         bonjourIDs: [String: String] = [:], bitrateKbps: Int = 20_000) {
        self.entries = entries
        self.names = names
        self.usbIDs = usbIDs
        self.bonjourIDs = bonjourIDs
        self.bitrateKbps = bitrateKbps
    }

    init(dictionary: [String: Any]) {
        entries = (dictionary["entries"] as? [[String: Any]] ?? []).compactMap(AutoConnectEntry.init(dictionary:))
        names = dictionary["names"] as? [String: String] ?? [:]
        usbIDs = dictionary["usbIDs"] as? [String: String] ?? [:]
        bonjourIDs = dictionary["bonjourIDs"] as? [String: String] ?? [:]
        bitrateKbps = (dictionary["bitrateKbps"] as? Int).map { max($0, 1_000) } ?? 20_000
    }

    var data: Data {
        (try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)) ?? Data()
    }

    static func read(from url: URL = url) throws -> LoginAgentSettings {
        let data = try Data(contentsOf: url)
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw CocoaError(.propertyListReadCorrupt) }
        return LoginAgentSettings(dictionary: dictionary)
    }
}
