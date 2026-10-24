//
//  CableLinks.swift
//
//  The networks devices make over a USB cable: an iPad or iPhone, or an Android phone
//  tethering, gives the Mac a USB NCM interface with link-local addresses (docs/usb.md).
//  The login window agent serves Moonlight over these alone, and advertises it on them.
//

import Foundation
import IOKit
import Network

enum CableLinks {
    /// The BSD names of the Mac's interfaces over USB NCM.
    static func interfaces() -> Set<String> {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOEthernetInterface"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var names = Set<String>()
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(parent) }
            guard IOObjectConformsTo(parent, "AppleUSBNCMData") != 0,
                  let name = IORegistryEntryCreateCFProperty(service, "BSD Name" as CFString, kCFAllocatorDefault, 0)?
                      .takeRetainedValue() as? String else { continue }
            names.insert(name)
        }
        return names
    }

    /// Whether a connection from `endpoint` came over a cable.
    static func admits(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return admits([UInt8](address.rawValue), scope: nil, subnets: LocalNetwork.namedSubnets(), cable: interfaces())
        case .ipv6(let address):
            return admits([UInt8](address.rawValue), scope: address.interface?.name,
                          subnets: LocalNetwork.namedSubnets(), cable: interfaces())
        default:
            return false
        }
    }

    /// Whether an address is on a cable link: a link-local IPv6 address scoped to one, or an
    /// address within a cable interface's subnet and no other's. Wi-Fi without DHCP takes
    /// a 169.254 address too, and then a cable's can't be told from it.
    static func admits(_ bytes: [UInt8], scope: String?, subnets: [(interface: String, subnet: LocalNetwork.Subnet)],
                       cable: Set<String>) -> Bool {
        var bytes = bytes
        if bytes.count == 16, bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            bytes = Array(bytes[12...])
        }
        if let scope, bytes.count == 16, bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return cable.contains(scope) }
        let on = subnets.filter { $0.subnet.contains(bytes) }.map(\.interface)
        return !on.isEmpty && on.allSatisfy(cable.contains)
    }
}
