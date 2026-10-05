//
//  Brightness.swift
//
//  Display brightness: DDC/CI over the display's I2C bus for external displays, the
//  private DisplayServices framework for the Mac's own panel, and gamma dimming for
//  displays that take neither.
//

import AppKit
import Combine
import CoreGraphics
import IOKit
import IOKit.graphics
import IOKit.i2c
import os.log

private let brightnessLog = Logger(subsystem: AppIdentity.bundleID, category: "Brightness")

// MARK: - DDC/CI packets

/// DDC/CI packets for the VESA MCCS "VCP" features. Brightness is feature 0x10.
enum DDC {
    static let brightness: UInt8 = 0x10
    /// The display's DDC/CI address on the bus (0x37, shifted left for writing).
    static let displayAddress: UInt8 = 0x6E
    /// The host's sub-address, which starts every packet sent to the display.
    static let hostAddress: UInt8 = 0x51

    /// Set VCP Feature: sub-address, length, opcode 0x03, feature, value, checksum.
    static func setVCP(_ code: UInt8, value: UInt16) -> [UInt8] {
        withChecksum([hostAddress, 0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// Get VCP Feature: sub-address, length, opcode 0x01, feature, checksum.
    static func getVCP(_ code: UInt8) -> [UInt8] {
        withChecksum([hostAddress, 0x82, 0x01, code])
    }

    /// The checksum XORs the destination address with every byte of the packet.
    private static func withChecksum(_ bytes: [UInt8]) -> [UInt8] {
        bytes + [bytes.reduce(displayAddress, ^)]
    }

    /// Reads a Get VCP Feature reply: source, length, opcode 0x02, result, feature, type,
    /// maximum (2 bytes), current (2 bytes), checksum. Nil for a reply to another feature,
    /// an error result, or values that make no sense.
    static func parseVCPReply(_ reply: [UInt8], code: UInt8) -> (current: UInt16, max: UInt16)? {
        guard reply.count >= 10, reply[2] == 0x02, reply[3] == 0x00, reply[4] == code else { return nil }
        let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        guard max > 0, current <= max else { return nil }
        return (current, max)
    }
}

// MARK: - Transports

/// Sends DDC/CI packets to one display. Used from `BrightnessManager`'s queue only.
private protocol DDCTransport: AnyObject {
    /// Sends `packet` and, when `replyLength` is non-zero, returns the display's reply.
    func transact(_ packet: [UInt8], replyLength: Int) -> [UInt8]?
}

#if arch(arm64)

/// DDC on Apple silicon, through the display's DCPAVServiceProxy. IOAVService is private
/// API in IOKit, so it is looked up at run time.
private final class AVServiceTransport: DDCTransport {
    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias ReadWrite = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private static let create = symbol("IOAVServiceCreateWithService", as: Create.self)
    private static let read = symbol("IOAVServiceReadI2C", as: ReadWrite.self)
    private static let write = symbol("IOAVServiceWriteI2C", as: ReadWrite.self)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let iokit, let pointer = dlsym(iokit, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private let service: CFTypeRef

    /// The transport for the external display with `cgID`: the AV service of the one
    /// framebuffer that describes it best.
    init?(display cgID: CGDirectDisplayID) {
        guard let create = Self.create else { return nil }
        let framebuffers = DisplayRegistry.framebuffersWithAVServices().filter { $0.avService != 0 }
        guard let index = DisplayRegistry.uniqueMatch(vendor: CGDisplayVendorNumber(cgID),
                                                      product: CGDisplayModelNumber(cgID),
                                                      serial: CGDisplaySerialNumber(cgID),
                                                      in: framebuffers.map(\.attributes)),
              let service = create(kCFAllocatorDefault, framebuffers[index].avService)?.takeRetainedValue()
        else { return nil }
        self.service = service
    }

    func transact(_ packet: [UInt8], replyLength: Int) -> [UInt8]? {
        guard let read = Self.read, let write = Self.write else { return nil }
        // The service takes the host sub-address as an argument, not as part of the packet.
        // Some displays miss a packet sent once, so it goes twice, as MonitorControl does.
        var body = Array(packet.dropFirst())
        for attempt in 0..<2 {
            if attempt > 0 { usleep(10_000) }
            let sent = body.withUnsafeMutableBytes {
                write(service, UInt32(DDC.displayAddress >> 1), UInt32(DDC.hostAddress), $0.baseAddress!, UInt32($0.count))
            }
            guard sent == kIOReturnSuccess else { return nil }
        }
        guard replyLength > 0 else { return [] }
        usleep(50_000)  // the display needs time to prepare its reply
        var reply = [UInt8](repeating: 0, count: replyLength)
        let received = reply.withUnsafeMutableBytes {
            read(service, UInt32(DDC.displayAddress >> 1), UInt32(DDC.hostAddress), $0.baseAddress!, UInt32($0.count))
        }
        return received == kIOReturnSuccess ? reply : nil
    }
}

#else

/// DDC on Intel Macs, through the I2C bus of the display's IOFramebuffer.
private final class FramebufferTransport: DDCTransport {
    private let framebuffer: io_service_t

    /// The transport for the display with `cgID`, found by matching its vendor, product and
    /// serial number against the IODisplayConnect services (as `displayNameFromIOKit` does).
    init?(display cgID: CGDirectDisplayID) {
        let vendor = CGDisplayVendorNumber(cgID), product = CGDisplayModelNumber(cgID)
        let serial = CGDisplaySerialNumber(cgID)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var found: io_service_t = 0
        while found == 0 {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            // kIODisplayOnlyPreferredName = 0x200
            guard let info = IODisplayCreateInfoDictionary(service, IOOptionBits(0x200))?
                    .takeRetainedValue() as? [String: Any] else { continue }
            func u32(_ key: String) -> UInt32 { (info[key] as? NSNumber)?.uint32Value ?? 0 }
            guard u32("DisplayVendorID") == vendor, u32("DisplayProductID") == product,
                  serial == 0 || u32("DisplaySerialNumber") == serial else { continue }
            var parent: io_service_t = 0
            if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS { found = parent }
        }
        guard found != 0 else { return nil }
        framebuffer = found
    }

    deinit { IOObjectRelease(framebuffer) }

    func transact(_ packet: [UInt8], replyLength: Int) -> [UInt8]? {
        var interface: io_service_t = 0
        guard IOFBCopyI2CInterfaceForBus(framebuffer, 0, &interface) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(interface) }
        var connect: IOI2CConnectRef?
        guard IOI2CInterfaceOpen(interface, 0, &connect) == KERN_SUCCESS, let connect else { return nil }
        defer { IOI2CInterfaceClose(connect, 0) }

        var request = IOI2CRequest()
        request.sendAddress = UInt32(DDC.displayAddress)
        request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
        if replyLength > 0 {
            // A bus that does not list DDC/CI replies among its transaction types can hang in
            // the kernel when asked for one, locking up WindowServer, so it is read the simple
            // way instead, as MonitorControl does.
            let types = IORegistryEntryCreateCFProperty(interface, kIOI2CTransactionTypesKey as CFString,
                                                        kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber
            let ddcReply = (types?.uint32Value ?? 0) & (1 << kIOI2CDDCciReplyTransactionType) != 0
            request.replyAddress = UInt32(DDC.displayAddress + 1)
            request.replySubAddress = DDC.hostAddress
            request.replyTransactionType = IOOptionBits(ddcReply ? kIOI2CDDCciReplyTransactionType
                                                                 : kIOI2CSimpleTransactionType)
            request.minReplyDelay = 50_000_000  // ns: the display needs time to prepare its reply
        } else {
            request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
        }
        var send = packet
        var reply = [UInt8](repeating: 0, count: replyLength)
        let ok = send.withUnsafeMutableBytes { sendBytes in
            reply.withUnsafeMutableBytes { replyBytes in
                request.sendBuffer = vm_address_t(bitPattern: sendBytes.baseAddress)
                request.sendBytes = UInt32(sendBytes.count)
                request.replyBuffer = vm_address_t(bitPattern: replyBytes.baseAddress)
                request.replyBytes = UInt32(replyBytes.count)
                return IOI2CSendRequest(connect, 0, &request) == KERN_SUCCESS && request.result == kIOReturnSuccess
            }
        }
        return ok ? reply : nil
    }
}

#endif

// MARK: - Controls

/// One display's brightness, as a level from 0 to 1. Used from `BrightnessManager`'s queue only.
private protocol BrightnessControl: AnyObject {
    func read() -> Double?
    func write(_ level: Double) -> Bool
}

/// An external display's brightness, through DDC/CI.
private final class DDCBrightness: BrightnessControl {
    private let transport: DDCTransport
    /// The display's maximum brightness value, as its last reply gave it.
    private var maximum: UInt16 = 100

    init?(display cgID: CGDirectDisplayID) {
        #if arch(arm64)
        guard let transport = AVServiceTransport(display: cgID) else { return nil }
        #else
        guard let transport = FramebufferTransport(display: cgID) else { return nil }
        #endif
        self.transport = transport
    }

    func read() -> Double? {
        // Displays drop the odd request, so a failed read is tried again before giving up.
        for attempt in 0..<4 {
            if attempt > 0 { usleep(50_000) }
            if let reply = transport.transact(DDC.getVCP(DDC.brightness), replyLength: 11),
               let value = DDC.parseVCPReply(reply, code: DDC.brightness) {
                maximum = value.max
                return Double(value.current) / Double(value.max)
            }
        }
        return nil
    }

    func write(_ level: Double) -> Bool {
        let value = UInt16((level * Double(maximum)).rounded())
        let ok = transport.transact(DDC.setVCP(DDC.brightness, value: value), replyLength: 0) != nil
        usleep(50_000)  // DDC/CI asks for a pause between commands
        return ok
    }
}

/// The Mac's own panel, through the private DisplayServices framework.
private final class BuiltInBrightness: BrightnessControl {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                                          RTLD_LAZY)
    private static let get = framework.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: Get.self) }
    private static let set = framework.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: Set.self) }

    private let cgID: CGDirectDisplayID

    init?(display cgID: CGDirectDisplayID) {
        guard Self.get != nil, Self.set != nil else { return nil }
        self.cgID = cgID
    }

    func read() -> Double? {
        var level: Float = 0
        guard Self.get?(cgID, &level) == 0 else { return nil }
        return Double(level)
    }

    func write(_ level: Double) -> Bool {
        Self.set?(cgID, Float(level)) == 0
    }
}

/// A display's gamma tables, one value from 0 to 1 per step of each channel.
struct GammaTables: Equatable {
    var red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue]

    /// The tables display `cgID` uses now.
    static func current(of cgID: CGDirectDisplayID) -> GammaTables? {
        let capacity = CGDisplayGammaTableCapacity(cgID)
        guard capacity > 0 else { return nil }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red, blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(cgID, capacity, &red, &green, &blue, &count) == .success,
              count > 0 else { return nil }
        let n = Int(count)
        return GammaTables(red: Array(red.prefix(n)), green: Array(green.prefix(n)), blue: Array(blue.prefix(n)))
    }

    func apply(to cgID: CGDirectDisplayID) -> Bool {
        CGSetDisplayTransferByTable(cgID, UInt32(red.count), red, green, blue) == .success
    }

    func scaled(by factor: Double) -> GammaTables {
        let f = CGGammaValue(factor)
        return GammaTables(red: red.map { $0 * f }, green: green.map { $0 * f }, blue: blue.map { $0 * f })
    }

    /// Whether `other` is these tables, give or take the rounding the hardware does when
    /// they are read back.
    func isClose(to other: GammaTables) -> Bool {
        guard red.count == other.red.count else { return false }
        let pairs = zip(red + green + blue, other.red + other.green + other.blue)
        return pairs.allSatisfy { abs($0 - $1) < 0.01 }
    }
}

/// A display that takes no brightness commands (no DDC through its port, dock or adapter),
/// dimmed in software by scaling its gamma tables: the backlight stays as it is and the
/// picture gets darker. macOS puts the tables back when DAM quits; ColorSync can reset
/// them on a display change, so `reassert` applies the dimming again.
private final class GammaBrightness: BrightnessControl {
    /// The darkest the picture gets, so the slider's end never leaves a black screen.
    static let floor = 0.15

    private let cgID: CGDirectDisplayID
    /// The display's own tables, before any dimming.
    private var original: GammaTables
    private var applied: GammaTables?
    private var level = 1.0

    init?(display cgID: CGDirectDisplayID) {
        guard let tables = GammaTables.current(of: cgID) else { return nil }
        self.cgID = cgID
        original = tables
    }

    deinit {
        if level < 1 { _ = original.apply(to: cgID) }
    }

    func read() -> Double? { level }

    var isDimmed: Bool { level < 1 }

    func write(_ level: Double) -> Bool {
        self.level = level
        return apply()
    }

    /// Applies the dimming again if something reset the tables, taking the tables found as
    /// the display's own.
    func reassert() {
        guard level < 1, let applied, let current = GammaTables.current(of: cgID),
              !current.isClose(to: applied) else { return }
        brightnessLog.debug("display \(self.cgID)'s gamma was reset; dimming it again")
        original = current
        _ = apply()
    }

    private func apply() -> Bool {
        let tables = level < 1 ? original.scaled(by: Self.floor + (1 - Self.floor) * level) : original
        applied = tables
        return tables.apply(to: cgID)
    }
}

// MARK: - Manager

/// Reads and sets display brightness. A DDC request can take a tenth of a second, so the
/// talking to displays happens on one serial queue; the state here is kept on the main queue.
final class BrightnessManager: ObservableObject {
    /// The displays whose brightness can be set, as found when each was last read.
    @Published private(set) var adjustable: Set<CGDirectDisplayID> = []
    /// The adjustable displays that take no brightness commands and are dimmed in software.
    private(set) var dimmedInSoftware: Set<CGDirectDisplayID> = []
    /// The last brightness read or set for each display, from 0 to 1.
    let levels = CurrentValueSubject<[CGDirectDisplayID: Double], Never>([:])

    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).brightness", qos: .userInitiated)
    /// Each display's control, made when it is first needed. Touched on `queue` only.
    private var controls: [CGDirectDisplayID: BrightnessControl] = [:]
    /// The displays that have answered a brightness command. One that never has is dimmed
    /// in software instead; one that has keeps being asked. Touched on `queue` only.
    private var answered: Set<CGDirectDisplayID> = []
    /// When each display dimmed in software was last asked for its brightness again, in
    /// case it was only asleep the first time. Touched on `queue` only.
    private var lastAsked: [CGDirectDisplayID: Date] = [:]

    private var lastRead: [CGDirectDisplayID: Date] = [:]
    private var reading: Set<CGDirectDisplayID> = []
    /// The level still to be sent to each display, the latest the user chose.
    private var pending: [CGDirectDisplayID: Double] = [:]
    private var writing: Set<CGDirectDisplayID> = []
    private var lastSet: [CGDirectDisplayID: Date] = [:]

    /// The brightness of display `cgID`, or nil when it cannot be set.
    func level(for cgID: CGDirectDisplayID) -> Double? {
        adjustable.contains(cgID) ? levels.value[cgID] : nil
    }

    /// Reads, in the background, the brightness of each physical display among `displays`
    /// and forgets displays not among them. A display is read again at most every few
    /// seconds, or half a minute when it gave no answer the last time.
    func refresh(_ displays: [DisplayInfo]) {
        let ids = Set(displays.filter { !$0.isSidecar && $0.cgDisplayID != 0 }.map(\.cgDisplayID))
        if !adjustable.isSubset(of: ids) { adjustable.formIntersection(ids) }
        dimmedInSoftware.formIntersection(ids)
        lastRead = lastRead.filter { ids.contains($0.key) }
        queue.async { [weak self] in
            guard let self else { return }
            self.controls = self.controls.filter { ids.contains($0.key) }
            self.answered.formIntersection(ids)
            self.lastAsked = self.lastAsked.filter { ids.contains($0.key) }
            // The display configuration may have changed since; ColorSync resets gamma then.
            for control in self.controls.values { (control as? GammaBrightness)?.reassert() }
        }

        let now = Date()
        for id in ids where !reading.contains(id) && !writing.contains(id) {
            let interval: TimeInterval = adjustable.contains(id) ? 2 : 30
            if let last = lastRead[id], now.timeIntervalSince(last) < interval { continue }
            reading.insert(id)
            lastRead[id] = now
            queue.async { [weak self] in
                guard let self else { return }
                var control = self.control(for: id)
                if let gamma = control as? GammaBrightness, !gamma.isDimmed,
                   Date().timeIntervalSince(self.lastAsked[id] ?? .distantPast) > 60 {
                    self.lastAsked[id] = Date()
                    self.controls[id] = nil
                    control = self.control(for: id)
                }
                var level = control?.read()
                if level != nil, !(control is GammaBrightness) { self.answered.insert(id) }
                if level == nil, !self.answered.contains(id), let gamma = GammaBrightness(display: id) {
                    brightnessLog.debug("display \(id) takes no brightness commands; dimming it in software")
                    self.controls[id] = gamma
                    control = gamma
                    level = gamma.read()
                }
                // A display that stopped answering may have been replaced by another with
                // its ID; look it up afresh next time.
                if level == nil { self.controls[id] = nil }
                let software = control is GammaBrightness
                DispatchQueue.main.async { self.finishReading(id, level: level, software: software) }
            }
        }
    }

    /// Sets display `cgID` to `level` (0 to 1). While the user drags a slider only the
    /// latest level waits to be sent.
    func set(_ level: Double, for cgID: CGDirectDisplayID) {
        let level = min(max(level, 0), 1)
        levels.value[cgID] = level
        lastSet[cgID] = Date()
        pending[cgID] = level
        if !writing.contains(cgID) { sendPending(cgID) }
    }

    private func sendPending(_ cgID: CGDirectDisplayID) {
        guard let level = pending.removeValue(forKey: cgID) else {
            writing.remove(cgID)
            return
        }
        writing.insert(cgID)
        queue.async { [weak self] in
            guard let self else { return }
            let ok = self.control(for: cgID)?.write(level) ?? false
            if !ok { brightnessLog.error("setting brightness of display \(cgID) failed") }
            DispatchQueue.main.async { self.sendPending(cgID) }
        }
    }

    private func finishReading(_ cgID: CGDirectDisplayID, level: Double?, software: Bool) {
        reading.remove(cgID)
        if software { dimmedInSoftware.insert(cgID) } else { dimmedInSoftware.remove(cgID) }
        guard let level else {
            if adjustable.contains(cgID) { adjustable.remove(cgID) }
            return
        }
        // A read that overlapped the user's last change may predate it.
        if !writing.contains(cgID), Date().timeIntervalSince(lastSet[cgID] ?? .distantPast) > 1 {
            levels.value[cgID] = level
        }
        if !adjustable.contains(cgID) { adjustable.insert(cgID) }
    }

    /// Runs on `queue`.
    private func control(for cgID: CGDirectDisplayID) -> BrightnessControl? {
        if let control = controls[cgID] { return control }
        let control: BrightnessControl? = CGDisplayIsBuiltin(cgID) != 0
            ? BuiltInBrightness(display: cgID) : DDCBrightness(display: cgID)
        controls[cgID] = control
        return control
    }
}

// MARK: - Menu slider

/// A brightness slider for a display's submenu, kept in step with what the display reports
/// while the menu is open.
final class BrightnessSliderView: NSView {
    private let cgID: CGDirectDisplayID
    private weak var manager: BrightnessManager?
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var subscription: AnyCancellable?

    init(display cgID: CGDirectDisplayID, manager: BrightnessManager) {
        self.cgID = cgID
        self.manager = manager
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 28))

        slider.doubleValue = manager.level(for: cgID) ?? 0
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved(_:))
        slider.setAccessibilityLabel("Brightness")
        if manager.dimmedInSoftware.contains(cgID) {
            toolTip = "This display takes no brightness commands, so \(AppIdentity.name) darkens its picture instead."
        }

        let stack = NSStackView(views: [sunImage("sun.min"), slider, sunImage("sun.max")])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 14)
        stack.frame = bounds
        stack.autoresizingMask = [.width, .height]
        addSubview(stack)

        subscription = manager.levels
            .map { $0[cgID] }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                // Leave the knob alone while it is being dragged.
                guard let self, let level, NSEvent.pressedMouseButtons == 0 else { return }
                self.slider.doubleValue = level
            }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func sunImage(_ symbolName: String) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage())
        view.contentTintColor = .secondaryLabelColor
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        manager?.set(sender.doubleValue, for: cgID)
    }
}
