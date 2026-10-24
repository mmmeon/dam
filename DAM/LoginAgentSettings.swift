//
//  LoginAgentSettings.swift
//
//  What DAM tells the login window agent: the OpenDisplay receivers to connect at startup,
//  what DAM learned of them, and the bitrate; and the Moonlight devices that may stream the
//  login window. DAM writes it, root-only, when either changes; the agent reads it when the
//  login window comes up (root-and-login-window.md).
//

import Foundation

struct LoginAgentSettings: Equatable {
    /// Where DAM writes it and the agent reads it.
    static let directory = URL(fileURLWithPath: "/Library/Application Support/DAM/LoginWindow", isDirectory: true)
    static let url = directory.appendingPathComponent("settings.plist")
    /// The Moonlight host's key, certificate and devices, as MoonlightHost keeps them; only
    /// root may read it, as it holds the key.
    static let moonlightDirectory = directory.appendingPathComponent("Moonlight", isDirectory: true)

    /// The receivers to connect at startup, best first.
    var entries: [AutoConnectEntry] = []
    var names: [String: String] = [:]
    var usbIDs: [String: String] = [:]
    var bonjourIDs: [String: String] = [:]
    var bitrateKbps = 20_000
    /// The Moonlight host, when a paired device may stream the login window.
    var moonlight: Moonlight?

    /// DAM's Moonlight host as the agent runs it: the same, so a device finds the host it
    /// paired with, but serving only the devices allowed, with no input.
    struct Moonlight: Equatable {
        /// The host's ID, which Moonlight keeps it by.
        var uniqueID: String
        /// The host's certificate, which Moonlight pinned when pairing. Its key is installed
        /// next to it, not written here, as anyone may read this.
        var certificate: Data
        var clients: [MoonlightClient]
        /// DAM's Moonlight settings that apply to its streams, such as video encryption and HEVC.
        var defaults: NSDictionary = [:]

        /// The settings copied from DAM's: those of its streams, not whether it hosts or
        /// pairs, which the agent decides.
        static func copied(from all: [String: Any]) -> NSDictionary {
            let prefix = "\(AppIdentity.shortID).moonlight."
            let kept = ["hevc", "adaptiveBitrate", "showsPointer", "videoEncryption"].map { prefix + $0 }
            return all.filter { kept.contains($0.key) } as NSDictionary
        }

        /// From DAM's paired devices, those allowed, with their input off; nil when none is.
        static func make(uniqueID: String, certificate: Data, clients: [MoonlightClient],
                         defaults: [String: Any]) -> Moonlight? {
            let allowed = clients.filter(\.showsLoginWindow).map { client -> MoonlightClient in
                var client = client
                client.allowsInput = false
                return client
            }
            guard !allowed.isEmpty else { return nil }
            return Moonlight(uniqueID: uniqueID, certificate: certificate, clients: allowed, defaults: copied(from: defaults))
        }

        var dictionary: [String: Any] {
            ["uniqueID": uniqueID, "certificate": certificate,
             "clients": (try? JSONEncoder().encode(clients)) ?? Data(), "defaults": defaults]
        }

        init(uniqueID: String, certificate: Data, clients: [MoonlightClient], defaults: NSDictionary = [:]) {
            self.uniqueID = uniqueID
            self.certificate = certificate
            self.clients = clients
            self.defaults = defaults
        }

        init?(dictionary: [String: Any]) {
            guard let uniqueID = dictionary["uniqueID"] as? String, let certificate = dictionary["certificate"] as? Data,
                  let data = dictionary["clients"] as? Data,
                  let clients = try? JSONDecoder().decode([MoonlightClient].self, from: data) else { return nil }
            self.init(uniqueID: uniqueID, certificate: certificate, clients: clients,
                      defaults: dictionary["defaults"] as? NSDictionary ?? [:])
        }
    }

    /// Whether the agent has anything to do.
    var isEmpty: Bool { entries.isEmpty && moonlight == nil }

    /// What DAM's settings give the agent: the OpenDisplay receivers connected at startup,
    /// and only what was learned of those.
    static func make(entries: [AutoConnectEntry], names: [String: String], usbIDs: [String: String],
                     bonjourIDs: [String: String], bitrateKbps: Int, moonlight: Moonlight? = nil) -> LoginAgentSettings {
        let startup = entries.filter { entry in
            guard entry.mode == .startup, case .openDisplay = entry.target else { return false }
            return true
        }
        let keys = Set(AutoConnectList.openDisplayKeys(in: startup, hasOwnDisplay: false))
        return LoginAgentSettings(entries: startup, names: names.filter { keys.contains($0.key) },
                                  usbIDs: usbIDs.filter { keys.contains($0.value) },
                                  bonjourIDs: bonjourIDs.filter { keys.contains($0.value) },
                                  bitrateKbps: bitrateKbps, moonlight: moonlight)
    }

    /// The agent's store: cable only, and every entry dialled whatever the window.
    func store() -> MemoryOpenDisplayStore {
        MemoryOpenDisplayStore(bitrateKbps: bitrateKbps, pointerOverUDP: false, usbOnly: true, entries: entries,
                               names: names, usbIDs: usbIDs, bonjourIDs: bonjourIDs)
    }

    // MARK: Storage

    var dictionary: [String: Any] {
        var dictionary: [String: Any] = ["entries": entries.map(\.dictionary), "names": names, "usbIDs": usbIDs,
                                         "bonjourIDs": bonjourIDs, "bitrateKbps": bitrateKbps]
        dictionary["moonlight"] = moonlight?.dictionary
        return dictionary
    }

    init(entries: [AutoConnectEntry] = [], names: [String: String] = [:], usbIDs: [String: String] = [:],
         bonjourIDs: [String: String] = [:], bitrateKbps: Int = 20_000, moonlight: Moonlight? = nil) {
        self.entries = entries
        self.names = names
        self.usbIDs = usbIDs
        self.bonjourIDs = bonjourIDs
        self.bitrateKbps = bitrateKbps
        self.moonlight = moonlight
    }

    init(dictionary: [String: Any]) {
        entries = (dictionary["entries"] as? [[String: Any]] ?? []).compactMap(AutoConnectEntry.init(dictionary:))
        names = dictionary["names"] as? [String: String] ?? [:]
        usbIDs = dictionary["usbIDs"] as? [String: String] ?? [:]
        bonjourIDs = dictionary["bonjourIDs"] as? [String: String] ?? [:]
        bitrateKbps = (dictionary["bitrateKbps"] as? Int).map { max($0, 1_000) } ?? 20_000
        moonlight = (dictionary["moonlight"] as? [String: Any]).flatMap(Moonlight.init(dictionary:))
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
