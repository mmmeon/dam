//
//  DisplayRotation.swift
//
//  Rotating displays. A physical display is turned by macOS itself, as System Settings'
//  Rotation menu does: through MonitorPanel where it allows it, else through the
//  framebuffer's own transform, which Intel Macs offer for panels MonitorPanel leaves out
//  (the built-in one among them). A streaming display is DAM's own virtual display, which
//  macOS cannot turn; DAM gives it the turned size instead and turns each captured frame
//  back to the stream's shape (see VideoManager+Rotation.swift and MoonlightScreenCapture).
//

import CoreGraphics
import Foundation
import IOKit
import IOKit.graphics
import os.log

private let rotLog = Logger(subsystem: AppIdentity.bundleID, category: "Rotation")

/// How far a display's picture is turned, clockwise, as System Settings names them.
enum DisplayRotation: Int, CaseIterable, Codable {
    case standard = 0
    case quarter = 90
    case half = 180
    case threeQuarters = 270

    /// The rotation `degrees` names, rounded to a quarter turn.
    init(degrees: Double) {
        let quarters = Int((degrees / 90).rounded()) % 4
        self = DisplayRotation(rawValue: (quarters + 4) % 4 * 90) ?? .standard
    }

    /// Whether the picture lies on its side, so its width and height trade places.
    var swapsAxes: Bool { self == .quarter || self == .threeQuarters }

    /// The rotation that undoes this one.
    var inverse: DisplayRotation { DisplayRotation(degrees: Double(360 - rawValue)) }

    /// `width` × `height`, turned.
    func size(width: Int, height: Int) -> (width: Int, height: Int) {
        swapsAxes ? (height, width) : (width, height)
    }

    /// "Standard", "90°", …; spoken by the picker, so localised with the spoken messages.
    var label: String { Spoken.rotation(self) }
}

// MARK: - Physical displays

/// Turns physical displays through macOS. macOS keeps the rotation it is given, as it
/// does one set in System Settings.
enum SystemRotation {

    /// The rotation `id` is shown at now.
    static func current(of id: CGDirectDisplayID) -> DisplayRotation {
        DisplayRotation(degrees: CGDisplayRotation(id))
    }

    /// Whether macOS can turn `id`.
    static func canRotate(_ id: CGDirectDisplayID) -> Bool {
        if monitorPanelDisplay(id).map(canChangeOrientation) == true { return true }
        guard let framebuffer = framebuffer(of: id) else { return false }
        defer { IOObjectRelease(framebuffer) }
        return supportsTransform(framebuffer)
    }

    /// Turns `id` to `rotation`; returns whether macOS took it. The display reconfigures,
    /// which DAM sees as any other change.
    @discardableResult
    static func set(_ rotation: DisplayRotation, for id: CGDirectDisplayID) -> Bool {
        if let display = monitorPanelDisplay(id), canChangeOrientation(display) {
            // KVC unboxes the number for -setOrientation:(int).
            display.setValue(rotation.rawValue, forKey: "orientation")
            rotLog.debug("rotate \(id) to \(rotation.rawValue) through MonitorPanel")
            return true
        }
        guard let framebuffer = framebuffer(of: id) else { return false }
        defer { IOObjectRelease(framebuffer) }
        guard supportsTransform(framebuffer) else { return false }
        let options = IOOptionBits(transform(for: rotation)) << 16 | IOOptionBits(kIOFBSetTransform)
        let result = IOServiceRequestProbe(framebuffer, options)
        rotLog.debug("rotate \(id) to \(rotation.rawValue) through IOKit: \(result)")
        return result == KERN_SUCCESS
    }

    // MARK: MonitorPanel

    private static let monitorPanelLoaded: Bool = {
        dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY) != nil
    }()

    /// MonitorPanel's MPDisplay for `id`, the object System Settings rotates displays with.
    private static func monitorPanelDisplay(_ id: CGDirectDisplayID) -> NSObject? {
        guard monitorPanelLoaded, let managerClass = NSClassFromString("MPDisplayMgr") as? NSObject.Type else {
            return nil
        }
        let displays = managerClass.init().value(forKey: "displays") as? [NSObject] ?? []
        return displays.first { ($0.value(forKey: "displayID") as? NSNumber)?.uint32Value == id }
    }

    private static func canChangeOrientation(_ display: NSObject) -> Bool {
        (display.value(forKey: "canChangeOrientation") as? Bool) == true
    }

    // MARK: IOKit

    /// kIOFBSetTransform: the probe option that sets a framebuffer's transform, from
    /// IOGraphicsTypesPrivate.h. A framebuffer lists it in IOFBProbeOptions when it can.
    private static let kIOFBSetTransform: UInt32 = 0x400

    /// The transform IOKit names for `rotation`: the axes swapped and inverted.
    static func transform(for rotation: DisplayRotation) -> UInt32 {
        switch rotation {
        case .standard:      return UInt32(kIOScaleRotate0)
        case .quarter:       return UInt32(kIOScaleRotate90)
        case .half:          return UInt32(kIOScaleRotate180)
        case .threeQuarters: return UInt32(kIOScaleRotate270)
        }
    }

    private static func supportsTransform(_ framebuffer: io_service_t) -> Bool {
        let options = IORegistryEntryCreateCFProperty(framebuffer, "IOFBProbeOptions" as CFString,
                                                      kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
        return (options?.uint32Value ?? 0) & kIOFBSetTransform != 0
    }

    /// The framebuffer driving `id`: the parent of its IODisplayConnect, found by vendor,
    /// product and serial number as CGDisplayIOServicePort did. Nil for displays with none,
    /// such as virtual ones, and on Macs whose displays have no IOFramebuffer. The caller
    /// releases it.
    private static func framebuffer(of id: CGDirectDisplayID) -> io_service_t? {
        let vendor = CGDisplayVendorNumber(id), product = CGDisplayModelNumber(id)
        let serial = CGDisplaySerialNumber(id)
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iter)
                == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var service = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }
            // kIODisplayOnlyPreferredName
            guard let info = IODisplayCreateInfoDictionary(service, IOOptionBits(0x200))?
                .takeRetainedValue() as? [String: Any] else { continue }
            func number(_ key: String) -> UInt32 { (info[key] as? NSNumber)?.uint32Value ?? 0 }
            guard number(kDisplayVendorID) == vendor, number(kDisplayProductID) == product,
                  serial == 0 || number(kDisplaySerialNumber) == serial else { continue }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { continue }
            return parent
        }
        return nil
    }
}

// MARK: - Streaming displays

/// The rotation of each streaming display, for the capture threads, which can't ask the
/// main-thread VideoManager. Captures already running hear of a change through
/// `didChange`.
final class StreamRotations {

    static let shared = StreamRotations()
    static let didChange = Notification.Name("\(AppIdentity.bundleID).streamRotationDidChange")

    private let lock = NSLock()
    private var rotations: [CGDirectDisplayID: DisplayRotation] = [:]

    /// The rotation captures of `id` turn their frames back by; standard for any display
    /// macOS turns itself.
    func rotation(of id: CGDirectDisplayID) -> DisplayRotation {
        lock.lock(); defer { lock.unlock() }
        return rotations[id] ?? .standard
    }

    /// Sets the rotations of the streaming displays online, by ID; on the main queue.
    func update(_ new: [CGDirectDisplayID: DisplayRotation]) {
        lock.lock()
        let changed = new.filter { $0.value != .standard } != rotations
        rotations = new.filter { $0.value != .standard }
        lock.unlock()
        if changed { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }
}

/// The rotation chosen for each display DAM shows turned through a stand-in, by its name,
/// put back when it comes back. macOS keeps the rotations it makes itself.
enum PresentedRotationPreferences {
    private static let key = "\(AppIdentity.shortID).rotation.presented"

    static func rotation(for name: String) -> DisplayRotation {
        let stored = UserDefaults.dam.dictionary(forKey: key)?[name] as? Int
        return stored.flatMap(DisplayRotation.init(rawValue:)) ?? .standard
    }

    static func setRotation(_ rotation: DisplayRotation, for name: String) {
        var all = UserDefaults.dam.dictionary(forKey: key) ?? [:]
        all[name] = rotation == .standard ? nil : rotation.rawValue
        UserDefaults.dam.set(all, forKey: key)
    }
}

/// The rotation chosen for each streaming display, by its name. A streaming display is
/// made anew for each stream, so its rotation is kept for the next one in its place.
enum StreamingRotationPreferences {
    private static let key = "\(AppIdentity.shortID).rotation.streaming"

    static func rotation(for name: String) -> DisplayRotation {
        let stored = UserDefaults.dam.dictionary(forKey: key)?[name] as? Int
        return stored.flatMap(DisplayRotation.init(rawValue:)) ?? .standard
    }

    static func setRotation(_ rotation: DisplayRotation, for name: String) {
        var all = UserDefaults.dam.dictionary(forKey: key) ?? [:]
        all[name] = rotation == .standard ? nil : rotation.rawValue
        UserDefaults.dam.set(all, forKey: key)
    }
}
