//
//  CableAdvertiser.swift
//
//  Advertises the agent's Moonlight host over Bonjour on cable links alone (CableLinks.swift),
//  so that only a device plugged in finds it, and Moonlight takes the cable's address. A
//  listener's own Bonjour service would go out on Wi-Fi too. Links are checked every few
//  seconds, as a device may be plugged in after the login window comes up.
//

import dnssd
import Foundation
import os

private let caLog = Logger(subsystem: AppIdentity.bundleID, category: "LoginAgentMoonlight")

final class CableAdvertiser {
    private let name: String
    private let type: String
    private let port: UInt16
    private var registered: [String: DNSServiceRef] = [:]
    private var timer: Timer?

    init(name: String, type: String, port: UInt16) {
        self.name = name
        self.type = type
        self.port = port
    }

    func start() {
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.update() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        registered.values.forEach { DNSServiceRefDeallocate($0) }
        registered = [:]
    }

    private func update() {
        let links = CableLinks.interfaces()
        for (link, ref) in registered where !links.contains(link) || if_nametoindex(link) == 0 {
            DNSServiceRefDeallocate(ref)
            registered[link] = nil
            caLog.notice("no longer advertised on \(link, privacy: .public)")
        }
        for link in links where registered[link] == nil {
            let index = if_nametoindex(link)
            guard index != 0 else { continue }
            var ref: DNSServiceRef?
            // Registered with no callback to read: nothing here needs to hear back.
            let error = DNSServiceRegister(&ref, 0, index, name, type, nil, nil, port.bigEndian, 0, nil, nil, nil)
            guard error == kDNSServiceErr_NoError, let ref else {
                caLog.error("advertising on \(link, privacy: .public) failed: \(error)")
                continue
            }
            registered[link] = ref
            caLog.notice("advertised on \(link, privacy: .public)")
        }
    }
}
