//
//  DisplayRegistry.swift
//
//  Displays as their framebuffers describe them in the I/O Registry on Apple silicon,
//  where there are no IODisplayConnect services to read names and IDs from.
//

import CoreGraphics
import Foundation
import IOKit

enum DisplayRegistry {

    /// What a framebuffer reports about the display it drives, from the "ProductAttributes"
    /// of its "DisplayAttributes".
    struct Attributes: Equatable {
        var vendor: UInt32?
        var product: UInt32?
        var serial: UInt32?
        var name: String?

        init(vendor: UInt32?, product: UInt32?, serial: UInt32?, name: String?) {
            self.vendor = vendor
            self.product = product
            self.serial = serial
            self.name = name
        }

        fileprivate init(entry: io_registry_entry_t) {
            let display = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue()
            let product = (display as? [String: Any])?["ProductAttributes"] as? [String: Any] ?? [:]
            func u32(_ key: String) -> UInt32? { (product[key] as? NSNumber)?.uint32Value }
            self.init(vendor: u32("LegacyManufacturerID"), product: u32("ProductID"),
                      serial: u32("SerialNumber"), name: product["ProductName"] as? String)
        }
    }

    /// A framebuffer and, for an external display, the DCPAVServiceProxy that carries its DDC.
    final class Framebuffer {
        let attributes: Attributes
        /// Retained; zero when the framebuffer has no external AV service.
        fileprivate(set) var avService: io_service_t = 0

        fileprivate init(attributes: Attributes) { self.attributes = attributes }
        deinit { if avService != 0 { IOObjectRelease(avService) } }
    }

    /// The entry names of display framebuffers on Apple silicon.
    private static let framebufferNames: Set<String> = ["AppleCLCD2", "IOMobileFramebufferShim"]

    /// The product name of display `cgID`, or nil when no framebuffer describes it.
    static func productName(for cgID: CGDirectDisplayID) -> String? {
        var attributes: [Attributes] = []
        for name in framebufferNames {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching(name),
                                               &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let entry = IOIteratorNext(iterator), entry != 0 {
                attributes.append(Attributes(entry: entry))
                IOObjectRelease(entry)
            }
        }
        let fits = matches(for: cgID, in: attributes)
        return fits.lazy.compactMap { attributes[$0].name }.first
    }

    /// Every display framebuffer, each with the external AV service that follows it in the
    /// registry. A framebuffer comes before its AV service, so a service belongs to the
    /// framebuffer seen last. This walks the whole registry; cache what it finds.
    static func framebuffersWithAVServices() -> [Framebuffer] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(IORegistryGetRootEntry(kIOMainPortDefault), kIOServicePlane,
                                            IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var framebuffers: [Framebuffer] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            var nameBuffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameBuffer)
            let name = String(cString: nameBuffer)
            if framebufferNames.contains(name) {
                framebuffers.append(Framebuffer(attributes: Attributes(entry: entry)))
            } else if name == "DCPAVServiceProxy", let last = framebuffers.last, last.avService == 0,
                      IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? String == "External" {
                IOObjectRetain(entry)
                last.avService = entry
            }
            IOObjectRelease(entry)
        }
        return framebuffers
    }

    /// The indices of `candidates` that fit display `cgID`, best first.
    static func matches(for cgID: CGDirectDisplayID, in candidates: [Attributes]) -> [Int] {
        matches(vendor: CGDisplayVendorNumber(cgID), product: CGDisplayModelNumber(cgID),
                serial: CGDisplaySerialNumber(cgID), in: candidates)
    }

    /// The indices of `candidates` that fit a display CoreGraphics reports with `vendor`,
    /// `product` and `serial`, best first.
    static func matches(vendor: UInt32, product: UInt32, serial: UInt32,
                        in candidates: [Attributes]) -> [Int] {
        scored(vendor: vendor, product: product, serial: serial, in: candidates).map(\.index)
    }

    /// The one index of `candidates` that fits best, or nil when none fits or the best fit
    /// is shared — two identical monitors with no serials to tell them apart.
    static func uniqueMatch(vendor: UInt32, product: UInt32, serial: UInt32,
                            in candidates: [Attributes]) -> Int? {
        let fits = scored(vendor: vendor, product: product, serial: serial, in: candidates)
        guard let best = fits.first else { return nil }
        if fits.count > 1, fits[1].score == best.score { return nil }
        return best.index
    }

    /// Vendor and product must agree. A serial that agrees ranks first, then one either
    /// side lacks, then one that differs: the registry can encode the serial differently
    /// from the EDID number CoreGraphics reports. Ties keep the registry's order.
    private static func scored(vendor: UInt32, product: UInt32, serial: UInt32,
                               in candidates: [Attributes]) -> [(index: Int, score: Int)] {
        let fits = candidates.enumerated().compactMap { index, candidate -> (index: Int, score: Int)? in
            guard candidate.vendor == vendor, candidate.product == product else { return nil }
            let theirs = candidate.serial ?? 0
            return (index, serial == 0 || theirs == 0 ? 1 : (serial == theirs ? 2 : 0))
        }
        return fits.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
    }
}
