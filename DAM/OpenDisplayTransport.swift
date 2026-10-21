//
//  OpenDisplayTransport.swift
//  DAM
//
//  The byte streams DAM talks to an OpenDisplay receiver over: TCP to its Bonjour service
//  over WiFi, or, for an iPhone or iPad on a cable, port 9000 on it through usbmuxd, which
//  hands back a socket that then carries the bytes as they are.
//

import Foundation
import Network
import os

let odLog = Logger(subsystem: AppIdentity.bundleID, category: "OpenDisplay")

/// A connection to a receiver. Callbacks come on the main queue; `send` may be called from
/// any thread.
protocol OpenDisplayChannel: AnyObject {
    var onReady: (() -> Void)? { get set }
    var onReceive: ((Data) -> Void)? { get set }
    /// Called once, when the connection fails, is refused or closes.
    var onClose: ((String) -> Void)? { get set }
    /// Bytes handed to `send` and not yet written out.
    var pendingBytes: Int { get }
    /// Sends not yet written out.
    var pendingSends: Int { get }
    var transport: OpenDisplayTransport { get }
    func start()
    func send(_ data: Data)
    func close()
}

enum OpenDisplayTransport: String {
    case wifi = "Wi-Fi"
    case usb = "USB"
}

// MARK: - TCP

/// TCP to a receiver's Bonjour service or address.
final class OpenDisplayTCPChannel: OpenDisplayChannel {
    var onReady: (() -> Void)?
    var onReceive: ((Data) -> Void)?
    var onClose: ((String) -> Void)?
    let transport = OpenDisplayTransport.wifi

    private let connection: NWConnection
    private let lock = NSLock()
    private var pending = 0
    private var sends = 0
    private var closed = false

    /// " at" the address dialed, for one not a Bonjour name; for the log.
    let endpointDescription: String

    init(endpoint: NWEndpoint) {
        if case .hostPort = endpoint { endpointDescription = " at \(endpoint)" } else { endpointDescription = "" }
        let tcp = NWProtocolTCP.Options()
        // Input events are small; held back to coalesce, they read as lag.
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.serviceClass = .interactiveVideo
        // IPv4, where the receiver also takes the pointer over UDP: the iPad's doesn't at the
        // link-local IPv6 address a Bonjour name otherwise resolves to.
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        connection = NWConnection(to: endpoint, using: parameters)
    }

    var pendingBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return pending
    }

    var pendingSends: Int {
        lock.lock(); defer { lock.unlock() }
        return sends
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onReady?()
            case .failed(let error):
                self?.finish(error.localizedDescription)
            case .waiting(let error):
                // Refused or unreachable: it would wait for the network to change; give up.
                self?.finish(error.localizedDescription)
            case .cancelled:
                self?.finish("closed")
            default:
                break
            }
        }
        connection.start(queue: .main)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.onReceive?(data) }
            if let error { return self.finish(error.localizedDescription) }
            if complete { return self.finish("the receiver closed the connection") }
            self.receive()
        }
    }

    func send(_ data: Data) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        pending += data.count
        sends += 1
        lock.unlock()
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.pending -= data.count
            self.sends -= 1
            self.lock.unlock()
        })
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
        connection.cancel()
    }

    /// The address it reached, once it has: a Bonjour name resolved.
    var reachedAddress: NWEndpoint? {
        guard case .hostPort? = connection.currentPath?.remoteEndpoint else { return nil }
        return connection.currentPath?.remoteEndpoint
    }

    /// What the connection tried, for the log: its path and the endpoint it reached.
    var pathDescription: String {
        guard let path = connection.currentPath else { return "no path" }
        return "\(path.status) via \(path.availableInterfaces.map(\.name)) to \(path.remoteEndpoint.map { "\($0)" } ?? "none")"
    }

    private func finish(_ reason: String) {
        lock.lock()
        let first = onClose != nil
        let handler = onClose
        onClose = nil
        closed = true
        lock.unlock()
        guard first else { return }
        connection.cancel()
        handler?(reason)
    }
}

// MARK: - A socket's descriptor

/// A connected socket's descriptor, as usbmuxd hands it over (SIGPIPE already off, see
/// `Usbmuxd.openSocket`): read as it comes, written in order on a queue of its own.
final class OpenDisplaySocketChannel: OpenDisplayChannel {
    var onReady: (() -> Void)?
    var onReceive: ((Data) -> Void)?
    var onClose: ((String) -> Void)?
    let transport = OpenDisplayTransport.usb

    /// Gives the connected descriptor, or why there is none.
    private let connect: (@escaping (Result<Int32, Error>) -> Void) -> Void
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let writes = DispatchQueue(label: "\(AppIdentity.bundleID).opendisplay.write", qos: .userInteractive)
    private let lock = NSLock()
    private var pending = 0
    private var sends = 0
    private var closed = false

    init(connect: @escaping (@escaping (Result<Int32, Error>) -> Void) -> Void) {
        self.connect = connect
    }

    var pendingBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return pending
    }

    var pendingSends: Int {
        lock.lock(); defer { lock.unlock() }
        return sends
    }

    func start() {
        connect { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    if case .success(let fd) = result { Darwin.close(fd) }
                    return
                }
                switch result {
                case .failure(let error):
                    self.finish(error.localizedDescription)
                case .success(let fd):
                    self.lock.lock()
                    let closed = self.closed
                    if !closed { self.fd = fd }
                    self.lock.unlock()
                    if closed { Darwin.close(fd); return }
                    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
                    source.setEventHandler { [weak self] in self?.readAvailable() }
                    self.source = source
                    source.resume()
                    self.onReady?()
                }
            }
        }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buffer, buffer.count)
        if n > 0 {
            onReceive?(Data(buffer[0..<n]))
        } else if n == 0 {
            finish("the receiver closed the connection")
        } else if errno != EAGAIN && errno != EINTR {
            finish(String(cString: strerror(errno)))
        }
    }

    func send(_ data: Data) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        pending += data.count
        sends += 1
        lock.unlock()
        writes.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let fd = self.fd
            let closed = self.closed
            self.lock.unlock()
            defer {
                self.lock.lock()
                self.pending -= data.count
                self.sends -= 1
                self.lock.unlock()
            }
            guard !closed, fd >= 0 else { return }
            if !Usbmuxd.writeAll(fd, data) {
                let reason = String(cString: strerror(errno))
                // A write cut short by close() is no news.
                self.lock.lock()
                let closedSince = self.closed
                self.lock.unlock()
                if !closedSince { DispatchQueue.main.async { self.finish(reason) } }
            }
        }
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
        teardown()
    }

    private func teardown() {
        lock.lock()
        let fd = self.fd
        self.fd = -1
        lock.unlock()
        // After the writes queued before it, and after the read source lets go of it:
        // Dispatch needs the descriptor open until its cancel handler runs.
        let close = { [writes] in if fd >= 0 { writes.async { Darwin.close(fd) } } }
        // At once, not behind the writes: one blocked on a receiver that stopped reading
        // returns, so the close queued after it runs.
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        if let source {
            source.setCancelHandler(handler: close)
            source.cancel()
        } else {
            close()
        }
        source = nil
    }

    private func finish(_ reason: String) {
        guard let handler = onClose else { return }
        onClose = nil
        lock.lock()
        closed = true
        lock.unlock()
        teardown()
        handler(reason)
    }
}

// MARK: - usbmuxd

/// The iPhones and iPads on a cable, from usbmuxd, and connections to a port on one.
/// Messages are a 16-byte little-endian header (length, version 1, type 8, tag) and an
/// XML property list.
enum Usbmuxd {
    static let socketPath = "/var/run/usbmuxd"

    struct Device: Equatable {
        /// usbmuxd's number for it while it stays plugged in.
        let deviceID: Int
        /// Its UDID.
        let serial: String
    }

    enum MuxError: LocalizedError {
        case unavailable(String)
        case refused(Int)

        var errorDescription: String? {
            switch self {
            case .unavailable(let why): return "usbmuxd: \(why)"
            case .refused(3): return "nothing listening on the device"
            case .refused(let n): return "usbmuxd refused the connection (\(n))"
            }
        }
    }

    /// The message usbmuxd takes for `object`.
    static func message(_ object: [String: Any], tag: UInt32) -> Data? {
        var body = object
        body["ClientVersionString"] = "\(AppIdentity.name) \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")"
        body["ProgName"] = AppIdentity.name
        guard let plist = try? PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0) else { return nil }
        var out = Data()
        for value in [UInt32(16 + plist.count), 1, 8, tag] {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        out.append(plist)
        return out
    }

    /// The port as usbmuxd wants it: in network byte order, read as a little-endian number.
    static func portNumber(_ port: UInt16) -> Int { Int(port.bigEndian) }

    /// A device from an `Attached` message, or from a `DeviceList` entry; only one on a cable.
    static func device(_ entry: [String: Any]) -> Device? {
        guard let properties = entry["Properties"] as? [String: Any],
              (properties["ConnectionType"] as? String) == "USB",
              let id = (entry["DeviceID"] as? NSNumber)?.intValue ?? (properties["DeviceID"] as? NSNumber)?.intValue,
              let serial = properties["SerialNumber"] as? String else { return nil }
        return Device(deviceID: id, serial: serial)
    }

    /// Opens usbmuxd's socket; blocking.
    fileprivate static func openSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MuxError.unavailable(String(cString: strerror(errno))) }
        guard ControlSocketPath.connect(fd, to: socketPath) else {
            let why = String(cString: strerror(errno))
            Darwin.close(fd)
            throw MuxError.unavailable(why)
        }
        // A write to a peer gone fails rather than ending DAM: to usbmuxd, and to the
        // receiver this descriptor carries after a Connect.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    fileprivate static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var at = 0
            while at < raw.count {
                let n = write(fd, raw.baseAddress! + at, raw.count - at)
                if n > 0 { at += n } else if n < 0 && errno == EINTR { continue } else { return false }
            }
            return true
        }
    }

    fileprivate static func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var out = Data(count: count)
        var at = 0
        let ok = out.withUnsafeMutableBytes { raw -> Bool in
            while at < count {
                let n = read(fd, raw.baseAddress! + at, count - at)
                if n > 0 { at += n } else if n < 0 && errno == EINTR { continue } else { return false }
            }
            return true
        }
        return ok ? out : nil
    }

    /// The next message on `fd`, as a dictionary; blocking.
    fileprivate static func readMessage(_ fd: Int32) -> [String: Any]? {
        guard let header = readExactly(fd, 16) else { return nil }
        let length = header.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        guard length >= 16, length < 1 << 24, let body = readExactly(fd, length - 16) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: body, format: nil)) as? [String: Any]
    }

    /// Connects to `port` on `device`; the descriptor then carries the device's bytes. Blocking.
    static func connect(to device: Device, port: UInt16) throws -> Int32 {
        let fd = try openSocket()
        // A usbmuxd that never answers fails the dial as a refusal does, not holding the
        // thread for good; the tunnel it becomes has no timeouts.
        setTimeouts(fd, connectTimeout)
        guard let request = message(["MessageType": "Connect", "DeviceID": device.deviceID,
                                     "PortNumber": portNumber(port)], tag: 1),
              writeAll(fd, request), let reply = readMessage(fd) else {
            Darwin.close(fd)
            throw MuxError.unavailable("no answer")
        }
        let number = (reply["Number"] as? NSNumber)?.intValue ?? -1
        guard number == 0 else {
            Darwin.close(fd)
            throw MuxError.refused(number)
        }
        setTimeouts(fd, 0)
        return fd
    }

    /// How long a dial waits on usbmuxd, as long as the sender waits on a dial.
    static let connectTimeout: TimeInterval = 5

    /// Reads and writes on `fd` give up after `seconds`; 0 for never.
    private static func setTimeouts(_ fd: Int32, _ seconds: TimeInterval) {
        var limit = timeval(tv_sec: Int(seconds), tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, size)
    }

    /// Watches devices come and go: `changed` gets the whole list on the main queue each
    /// time it changes, empty when usbmuxd is gone.
    final class Watcher {
        var changed: (([Device]) -> Void)?
        private var fd: Int32 = -1
        private var stopped = false
        private let lock = NSLock()
        private let thread = DispatchQueue(label: "\(AppIdentity.bundleID).usbmuxd", qos: .utility)

        func start() {
            lock.lock()
            stopped = false
            lock.unlock()
            thread.async { [weak self] in self?.run() }
        }

        func stop() {
            lock.lock()
            stopped = true
            // Unblocks the read on the watching queue, which closes it: closed here, its
            // number could be reused while that queue still reads from it.
            if fd >= 0 { shutdown(fd, SHUT_RDWR) }
            lock.unlock()
        }

        private var isStopped: Bool {
            lock.lock(); defer { lock.unlock() }
            return stopped
        }

        /// Listens until stopped, starting again a few seconds after usbmuxd goes.
        private func run() {
            while !isStopped {
                var devices: [Int: Device] = [:]
                if let fd = try? Usbmuxd.openSocket() {
                    lock.lock()
                    // Stopped while opening: stop() had no socket to shut down.
                    let stopped = self.stopped
                    if !stopped { self.fd = fd }
                    lock.unlock()
                    if stopped { Darwin.close(fd); return }
                    if let request = Usbmuxd.message(["MessageType": "Listen"], tag: 1), Usbmuxd.writeAll(fd, request) {
                        while let message = Usbmuxd.readMessage(fd) {
                            switch message["MessageType"] as? String {
                            case "Attached":
                                if let device = Usbmuxd.device(message) { devices[device.deviceID] = device }
                            case "Detached":
                                if let id = (message["DeviceID"] as? NSNumber)?.intValue { devices[id] = nil }
                            default:
                                continue
                            }
                            let list = devices.values.sorted { $0.deviceID < $1.deviceID }
                            DispatchQueue.main.async { [weak self] in
                                guard let self, !self.isStopped else { return }
                                self.changed?(list)
                            }
                        }
                    }
                    lock.lock()
                    self.fd = -1
                    lock.unlock()
                    Darwin.close(fd)
                }
                guard !isStopped else { return }
                DispatchQueue.main.async { [weak self] in self?.changed?([]) }
                Thread.sleep(forTimeInterval: 3)
            }
        }
    }
}
