//
//  ControlSocketPath.swift
//
//  Where DAM's control socket lives, and connecting to a Unix socket by path: used by the
//  control socket and by usbmuxd's client.
//

import Darwin
import Foundation

/// Where the running app listens.
enum ControlSocketPath {
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.name, isDirectory: true)
            .appendingPathComponent("control.sock")
    }

    /// `path` as a socket address, or nil when it is too long for one.
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    static func connect(_ fd: Int32, to path: String) -> Bool {
        guard var address = address(path) else { return false }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }
}
