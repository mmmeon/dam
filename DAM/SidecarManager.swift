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

struct SidecarDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let isConnected: Bool
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

    /// Re-reads the nearby and connected devices.
    func refresh() {
        guard let manager else { return }
        let connected = Set((manager.value(forKey: "connectedDevices") as? [NSObject] ?? [])
            .compactMap { $0.value(forKey: "identifier") as? String })
        var objects: [String: NSObject] = [:]
        var found: [SidecarDevice] = []
        for object in manager.value(forKey: "devices") as? [NSObject] ?? [] {
            guard let id = object.value(forKey: "identifier") as? String,
                  let name = object.value(forKey: "name") as? String else { continue }
            objects[id] = object
            found.append(SidecarDevice(id: id, name: name, isConnected: connected.contains(id)))
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
