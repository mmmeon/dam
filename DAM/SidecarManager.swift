//
//  SidecarManager.swift
//
//  Lists nearby iPads that can be used as a display, and connects or disconnects them,
//  through SidecarCore. The framework is private but — unlike the AirPlay routing API —
//  unguarded: nothing checks the caller. It is loaded at run time and every call is
//  optional, so on a Mac without Sidecar, or if a future macOS changes the framework,
//  the manager simply reports no devices.
//

import Foundation
import os

private let scLog = Logger(subsystem: AppIdentity.bundleID, category: "Sidecar")

/// How the Mac can reach an iPad for Sidecar.
enum SidecarLink: String {
    case usb = "USB"
    case wifi = "Wi‑Fi"

    /// The SF Symbol for the link.
    var symbolName: String { self == .usb ? "cable.connector" : "wifi" }
}

struct SidecarDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let isConnected: Bool
    /// SidecarCore's status word for the device: Rapport's endpoint status flags, which say
    /// which links reach the iPad.
    var status: UInt64 = 0

    /// What the app shows for this device: its nickname if the user set one, else its name.
    var label: String { VisibilityPreferences.nickname(.sidecar, for: name) ?? name }

    /// The link Sidecar would use: USB when the cable is attached, else Wi‑Fi when the iPad is
    /// reachable over it. Nil when only Bluetooth sees the iPad.
    var link: SidecarLink? { Self.link(fromStatus: status) }

    // Rapport endpoint status flags, as its description names them.
    static let usbFlag:               UInt64 = 1 << 24    // "USB"
    static let infrastructureWiFiFlag: UInt64 = 1 << 2    // "iWiFi": same Wi‑Fi network
    static let peerToPeerWiFiFlag:    UInt64 = 1 << 9     // "WiFiP2P": AWDL

    static func link(fromStatus status: UInt64) -> SidecarLink? {
        if status & usbFlag != 0 { return .usb }
        if status & (infrastructureWiFiFlag | peerToPeerWiFiFlag) != 0 { return .wifi }
        return nil
    }
}

final class SidecarManager: ObservableObject {
    /// False on Macs that cannot use Sidecar, or when SidecarCore could not be loaded.
    let isSupported: Bool
    @Published private(set) var devices: [SidecarDevice] = []

    private let manager: NSObject?
    /// The SidecarCore device objects behind `devices`, keyed by identifier.
    private var objects: [String: NSObject] = [:]

    private typealias ConnectFn = @convention(c) (AnyObject, Selector, AnyObject,
                                                  @escaping @convention(block) (NSError?) -> Void) -> Void

    init() {
        let path = "/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore"
        guard dlopen(path, RTLD_NOW) != nil,
              let cls = NSClassFromString("SidecarDisplayManager") as? NSObject.Type,
              cls.responds(to: NSSelectorFromString("isSupported")),
              cls.responds(to: NSSelectorFromString("sharedManager")),
              Self.isSupported(cls),
              let manager = cls.perform(NSSelectorFromString("sharedManager"))?
                  .takeUnretainedValue() as? NSObject
        else {
            isSupported = false
            self.manager = nil
            return
        }
        isSupported = true
        self.manager = manager
    }

    private static func isSupported(_ cls: NSObject.Type) -> Bool {
        let sel = NSSelectorFromString("isSupported")
        let fn = unsafeBitCast(cls.method(for: sel), to: (@convention(c) (AnyObject, Selector) -> Bool).self)
        return fn(cls, sel)
    }

    /// A device's identifier as a string. SidecarCore hands it over as an NSUUID.
    static func identifier(of object: NSObject) -> String? {
        switch object.value(forKey: "identifier") {
        case let uuid as UUID:     return uuid.uuidString
        case let string as String: return string
        case let other?:           return "\(other)"
        case nil:                  return nil
        }
    }

    /// Re-reads the nearby and connected devices.
    func refresh() {
        guard let manager else { return }
        let connected = Set((manager.value(forKey: "connectedDevices") as? [NSObject] ?? [])
            .compactMap(Self.identifier(of:)))
        var objects: [String: NSObject] = [:]
        var found: [SidecarDevice] = []
        for object in manager.value(forKey: "devices") as? [NSObject] ?? [] {
            guard let id = Self.identifier(of: object),
                  let name = object.value(forKey: "name") as? String else { continue }
            objects[id] = object
            found.append(SidecarDevice(id: id, name: name, isConnected: connected.contains(id),
                                       status: object.value(forKey: "status") as? UInt64 ?? 0))
        }
        self.objects = objects
        found.sort { $0.name < $1.name }
        if devices != found { devices = found }
    }

    /// Connects `device`, or disconnects it when it is connected. `completion` gets the
    /// error SidecarCore reported, if any, on the main thread.
    func toggle(_ device: SidecarDevice, completion: @escaping (Error?) -> Void) {
        guard let manager, let object = objects[device.id] else {
            return completion(SidecarError.deviceGone(device.name))
        }
        let selector = NSSelectorFromString(device.isConnected
            ? "disconnectFromDevice:completion:" : "connectToDevice:completion:")
        guard manager.responds(to: selector),
              let msgSend = dlsym(dlopen(nil, RTLD_NOW), "objc_msgSend") else {
            return completion(SidecarError.unavailable)
        }
        scLog.debug("\(device.isConnected ? "disconnecting" : "connecting", privacy: .public) \(device.name, privacy: .public)")
        unsafeBitCast(msgSend, to: ConnectFn.self)(manager, selector, object) { [weak self] error in
            DispatchQueue.main.async {
                if let error { scLog.error("\(error.localizedDescription, privacy: .public)") }
                self?.refresh()
                completion(error)
            }
        }
    }
}

// MARK: - Connecting, with or without a display

extension SidecarManager {
    /// Connects `device`. With no display at all Sidecar has nothing to join, so the Mac gets
    /// a stand-in display first, dropped again should the iPad fail or never come up.
    /// Failures are announced; `completion` gets SidecarCore's result on the main queue.
    func connect(_ device: SidecarDevice, videoManager: VideoManager,
                 completion: ((Error?) -> Void)? = nil) {
        videoManager.ensureDisplayForSidecar { [weak self, weak videoManager] in
            guard let self else { return }
            self.toggle(device) { error in
                if let error {
                    SpeechSynthesizer.shared.announce(error.localizedDescription)
                    videoManager?.releaseBootstrapDisplay()
                }
                completion?(error)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak videoManager] in
            guard let videoManager, !videoManager.connectedDisplays.contains(where: \.isSidecar) else { return }
            videoManager.releaseBootstrapDisplay()
        }
    }

    /// Disconnects the iPad behind a Sidecar display, announcing a failure.
    func disconnect(display: DisplayInfo, completion: ((Error?) -> Void)? = nil) {
        refresh()
        guard let device = devices.first(where: { $0.isConnected && $0.name == display.name }) else {
            let error = SidecarError.deviceGone(display.name)
            SpeechSynthesizer.shared.announce(error.localizedDescription)
            completion?(error)
            return
        }
        toggle(device) { error in
            if let error { SpeechSynthesizer.shared.announce(error.localizedDescription) }
            completion?(error)
        }
    }
}

// MARK: - Connecting on plug-in

/// Connects an iPad over Sidecar once it is plugged in over USB while the Mac has no display
/// of its own, when Settings ask for it — also one already plugged in when the app starts, as
/// it does at login. Checked every few seconds. An iPad is connected once per plug-in, so one
/// disconnected by hand stays so until plugged in again. Sidecar is often not ready just after
/// login, so a failed attempt is retried a few times.
final class SidecarAutoConnector {
    struct Attempt: Equatable {
        var count = 0
        var nextTry = Date.distantPast
        /// Connected, by this or by hand: nothing more to do until the iPad is unplugged.
        var done = false
    }

    static let interval: TimeInterval = 3
    static let retryDelay: TimeInterval = 10
    /// How long an attempt may take before another is allowed: a stand-in display and the
    /// Sidecar connection can each take several seconds.
    static let attemptTimeout: TimeInterval = 45
    static let maxAttempts = 6

    private let sidecar: SidecarManager
    private weak var video: VideoManager?
    private var timer: Timer?
    /// The iPads on USB, by identifier.
    private var attempts: [String: Attempt] = [:]

    init(sidecar: SidecarManager, video: VideoManager) {
        self.sidecar = sidecar
        self.video = video
    }

    func start() {
        guard sidecar.isSupported, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    private func tick() {
        guard VisibilityPreferences.autoConnectsSidecarWithoutDisplay, let video else { return }
        sidecar.refresh()
        let now = Date()
        let plan = Self.plan(devices: sidecar.devices, attempts: attempts,
                             hasOwnDisplay: video.hasOwnDisplay(), now: now)
        attempts = plan.attempts
        guard let device = plan.connect else { return }
        attempts[device.id]?.count += 1
        attempts[device.id]?.nextTry = now + Self.attemptTimeout
        scLog.debug("auto-connecting \(device.name, privacy: .public), attempt \(self.attempts[device.id]?.count ?? 0)")
        SpeechSynthesizer.shared.announce(ConnectTarget.sidecar(device).connectingAnnouncement)
        sidecar.connect(device, videoManager: video) { [weak self] error in
            guard let self, self.attempts[device.id] != nil else { return }
            if error == nil {
                self.attempts[device.id]?.done = true
            } else {
                self.attempts[device.id]?.nextTry = Date() + Self.retryDelay
            }
        }
    }

    /// Which iPad to connect now, if any, and the updated attempts. iPads that left USB are
    /// forgotten, new ones start fresh, and a connected one counts as done. Nothing is
    /// connected while the Mac has a display of its own or an iPad is already connected.
    static func plan(devices: [SidecarDevice], attempts: [String: Attempt],
                     hasOwnDisplay: Bool, now: Date) -> (connect: SidecarDevice?, attempts: [String: Attempt]) {
        let onUSB = devices.filter { $0.link == .usb }
        var next = attempts.filter { entry in onUSB.contains { $0.id == entry.key } }
        for device in onUSB {
            if next[device.id] == nil { next[device.id] = Attempt() }
            if device.isConnected { next[device.id]?.done = true }
        }
        guard !hasOwnDisplay, !devices.contains(where: \.isConnected) else { return (nil, next) }
        let device = onUSB.first { device in
            guard let a = next[device.id] else { return false }
            return !a.done && a.count < maxAttempts && a.nextTry <= now
        }
        return (device, next)
    }
}

enum SidecarError: LocalizedError {
    case deviceGone(String)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .deviceGone(let name): return "\(name) is no longer nearby"
        case .unavailable:          return "Sidecar is not available"
        }
    }
}
