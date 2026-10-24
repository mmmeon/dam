//
//  CableAdvertiser.swift
//
//  Advertises the agent's Moonlight host over Bonjour on cable links alone (CableLinks.swift),
//  so that only a device plugged in finds it, and Moonlight takes the cable's address. A
//  listener's own Bonjour service would go out on Wi-Fi too. Links are checked every few
//  seconds, as a device may be plugged in after the login window comes up.
//
//  Each link's service names a host of its own, whose one address is the link's. With the
//  Mac's own name, the device would resolve every address the Mac has, and Moonlight takes
//  the first IPv4 one, often Wi-Fi's, which the agent refuses.
//

import dnssd
import Foundation
import os

private let caLog = Logger(subsystem: AppIdentity.bundleID, category: "LoginAgentMoonlight")

final class CableAdvertiser {
    private struct Advert {
        let address: in_addr
        let record: DNSRecordRef
        let service: DNSServiceRef
    }

    private let name: String
    private let type: String
    private let port: UInt16
    private var connection: DNSServiceRef?
    private var adverts: [String: Advert] = [:]
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
        adverts = [:]
        if let connection { DNSServiceRefDeallocate(connection) }
        connection = nil
    }

    private func update() {
        let links = Self.addresses(of: CableLinks.interfaces())
        for (link, advert) in adverts where links[link]?.s_addr != advert.address.s_addr || if_nametoindex(link) == 0 {
            remove(advert)
            adverts[link] = nil
            caLog.notice("no longer advertised on \(link, privacy: .public)")
        }
        for (link, address) in links where adverts[link] == nil {
            guard let advert = advertise(on: link, address: address) else { continue }
            adverts[link] = advert
            caLog.notice("advertised on \(link, privacy: .public)")
        }
    }

    private func advertise(on link: String, address: in_addr) -> Advert? {
        let index = if_nametoindex(link)
        guard index != 0, let connection = sharedConnection() else { return nil }
        let host = "\(name)-\(link).local."
        var address = address
        var record: DNSRecordRef?
        var error = DNSServiceRegisterRecord(connection, &record, DNSServiceFlags(kDNSServiceFlagsUnique), index, host,
                                             UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN), 4, &address, 120,
                                             recordReply, nil)
        guard error == kDNSServiceErr_NoError, let record else {
            caLog.error("naming \(host, privacy: .public) failed: \(error)")
            return nil
        }
        var service: DNSServiceRef? = connection
        // No callback to read for the service: nothing here needs to hear back.
        error = DNSServiceRegister(&service, DNSServiceFlags(kDNSServiceFlagsShareConnection), index, name, type, nil,
                                   host, port.bigEndian, 0, nil, nil, nil)
        guard error == kDNSServiceErr_NoError, let service else {
            DNSServiceRemoveRecord(connection, record, 0)
            caLog.error("advertising on \(link, privacy: .public) failed: \(error)")
            return nil
        }
        return Advert(address: address, record: record, service: service)
    }

    private func remove(_ advert: Advert) {
        DNSServiceRefDeallocate(advert.service)
        if let connection { DNSServiceRemoveRecord(connection, advert.record, 0) }
    }

    private func sharedConnection() -> DNSServiceRef? {
        if let connection { return connection }
        var made: DNSServiceRef?
        let error = DNSServiceCreateConnection(&made)
        guard error == kDNSServiceErr_NoError, let made else {
            caLog.error("can't reach mDNSResponder: \(error)")
            return nil
        }
        DNSServiceSetDispatchQueue(made, .main)
        connection = made
        return made
    }

    /// Each link's IPv4 address. A link with IPv6 alone is left out: Moonlight takes an IPv6
    /// link-local address without its scope, which reaches nothing.
    private static func addresses(of links: Set<String>) -> [String: in_addr] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [:] }
        defer { freeifaddrs(first) }
        var found: [String: in_addr] = [:]
        var entry = first
        while let current = entry {
            defer { entry = current.pointee.ifa_next }
            let link = String(cString: current.pointee.ifa_name)
            guard links.contains(link), found[link] == nil,
                  let socket = current.pointee.ifa_addr, socket.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            found[link] = socket.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        }
        return found
    }
}

private func recordReply(_: DNSServiceRef?, _: DNSRecordRef?, _: DNSServiceFlags, _ error: DNSServiceErrorType,
                         _: UnsafeMutableRawPointer?) {
    if error != kDNSServiceErr_NoError { caLog.error("cable host name refused: \(error)") }
}
