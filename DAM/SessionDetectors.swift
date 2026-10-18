//
//  SessionDetectors.swift
//
//  Tell when another app's remote session starts and ends, for the apps that can't say so
//  themselves (Sunshine does, through its prep commands; see ControlSocket.swift). Each
//  detector reports a connection opening or closing, by a key of its own; the coordinator
//  starts the app's session with the first and ends it with the last.
//

import Darwin
import Foundation
import os.log

private let detLog = Logger(subsystem: AppIdentity.bundleID, category: "SessionDetectors")

/// A connection opening or closing, by a key that pairs the two.
enum SessionEvent: Equatable {
    case opened(key: String, client: String?)
    case closed(key: String)
}

/// Reports one app's connections.
protocol SessionDetector: AnyObject {
    var app: String { get }
    var onEvent: ((SessionEvent) -> Void)? { get set }
    func start()
    func stop()
}

/// What the apps' logs say.
enum SessionLogLines {
    /// RustDesk: `… INFO [src/server/connection.rs:1498] #365 Connection opened from 10.10.1.123:40381.`
    /// and `… #365 Connection closed: Peer close`.
    static func rustDesk(_ line: String) -> SessionEvent? {
        if let m = captures(#"#(\d+) Connection opened from (\S+?)\.?$"#, in: line) {
            // The address without its port: "10.10.1.123".
            let host = m[1].lastIndex(of: ":").map { String(m[1][..<$0]) } ?? m[1]
            return .opened(key: m[0], client: host)
        }
        if let m = captures(#"#(\d+) Connection closed"#, in: line) { return .closed(key: m[0]) }
        return nil
    }

    /// Parsec: `<user>#<id> connected.` and `<user>#<id> disconnected.`, its guest's name and number.
    static func parsec(_ line: String) -> SessionEvent? {
        if let m = captures(#"(\S+#\d+) disconnected\."#, in: line) { return .closed(key: m[0]) }
        if let m = captures(#"(\S+)#(\d+) connected\."#, in: line) {
            return .opened(key: "\(m[0])#\(m[1])", client: m[0])
        }
        return nil
    }

    /// The groups `pattern` captures in `line`, or nil when it doesn't match.
    static func captures(_ pattern: String, in line: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (1..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: line).map { String(line[$0]) } ?? ""
        }
    }
}

/// Reads the lines added to a log file as they come, from its end when it starts. Follows the
/// file when the app moves it aside and starts another, and when it is cut back.
final class LogFollower {
    private let url: URL
    private let onLine: (String) -> Void
    private var handle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0
    private var partial = Data()
    /// Looks for the file again while it isn't there or has been replaced.
    private var timer: Timer?

    init(url: URL, onLine: @escaping (String) -> Void) {
        self.url = url
        self.onLine = onLine
    }

    deinit { stop() }

    func start() {
        guard timer == nil else { return }
        open(fromEnd: true)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        close()
    }

    private func open(fromEnd: Bool) {
        close()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        self.handle = handle
        offset = fromEnd ? (try? handle.seekToEnd()) ?? 0 : 0
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: handle.fileDescriptor,
                                                               eventMask: [.extend, .write, .delete, .rename],
                                                               queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                // Moved aside: read what is left, then the new file from its start.
                self.readNew()
                self.open(fromEnd: false)
            } else {
                self.readNew()
            }
        }
        source.resume()
        self.source = source
        if !fromEnd { readNew() }
    }

    private func close() {
        source?.cancel()
        source = nil
        try? handle?.close()
        handle = nil
        partial.removeAll()
    }

    /// Opens the file once it is there, or again when the one at its path is another.
    private func check() {
        guard let handle else { return open(fromEnd: false) }
        var opened = stat()
        var atPath = stat()
        guard fstat(handle.fileDescriptor, &opened) == 0 else { return }
        if lstat(url.path, &atPath) != 0 || atPath.st_ino != opened.st_ino {
            readNew()
            self.open(fromEnd: false)
        } else {
            readNew()
        }
    }

    private func readNew() {
        guard let handle else { return }
        let size = (try? handle.seekToEnd()) ?? offset
        // Cut back: start again from its start.
        if size < offset { offset = 0; partial.removeAll() }
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: Int(size - offset)) else { return }
        offset += UInt64(data.count)
        partial.append(data)
        while let newline = partial.firstIndex(of: UInt8(ascii: "\n")) {
            let line = partial[partial.startIndex..<newline]
            partial.removeSubrange(partial.startIndex...newline)
            if let text = String(data: line, encoding: .utf8) { onLine(text) }
        }
    }
}

/// Connections from an app's log.
final class LogSessionDetector: SessionDetector {
    let app: String
    var onEvent: ((SessionEvent) -> Void)?
    private let url: URL
    private let parse: (String) -> SessionEvent?
    private var follower: LogFollower?
    /// The connections open, so a close of one opened before DAM looked is ignored.
    private(set) var open: Set<String> = []

    init(app: String, url: URL, parse: @escaping (String) -> SessionEvent?) {
        self.app = app
        self.url = url
        self.parse = parse
    }

    func start() {
        guard follower == nil else { return }
        detLog.debug("\(self.app): following \(self.url.path)")
        let follower = LogFollower(url: url) { [weak self] in self?.handle($0) }
        follower.start()
        self.follower = follower
    }

    func stop() {
        follower?.stop()
        follower = nil
        // Ends what is still open, so the session doesn't outlive the watching.
        for key in open { onEvent?(.closed(key: key)) }
        open.removeAll()
    }

    func handle(_ line: String) {
        guard let event = parse(line) else { return }
        switch event {
        case .opened(let key, _):
            guard open.insert(key).inserted else { return }
        case .closed(let key):
            guard open.remove(key) != nil else { return }
        }
        detLog.debug("\(self.app): \(String(describing: event))")
        onEvent?(event)
    }
}

/// A connection for as long as a process runs, as `screensharingd` runs only while someone
/// is connected. Checks every two seconds, and ends a few seconds after it goes, as it can
/// stay a moment after the last connection and come back for the next.
final class ProcessSessionDetector: SessionDetector {
    let app: String
    var onEvent: ((SessionEvent) -> Void)?
    private let processName: String
    private let grace: TimeInterval
    private let isRunning: (String) -> Bool
    private var timer: Timer?
    private(set) var isOpen = false
    private var goneSince: Date?

    init(app: String, processName: String, grace: TimeInterval = 5,
         isRunning: @escaping (String) -> Bool = RunningProcesses.isRunning) {
        self.app = app
        self.processName = processName
        self.grace = grace
        self.isRunning = isRunning
    }

    func start() {
        guard timer == nil else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if isOpen { onEvent?(.closed(key: processName)) }
        isOpen = false
        goneSince = nil
    }

    func check(now: Date = Date()) {
        if isRunning(processName) {
            goneSince = nil
            guard !isOpen else { return }
            isOpen = true
            detLog.debug("\(self.app): \(self.processName) is running")
            onEvent?(.opened(key: processName, client: nil))
        } else if isOpen {
            let since = goneSince ?? now
            goneSince = since
            guard now.timeIntervalSince(since) >= grace else { return }
            isOpen = false
            goneSince = nil
            detLog.debug("\(self.app): \(self.processName) is gone")
            onEvent?(.closed(key: processName))
        }
    }
}

/// The processes running, by name.
enum RunningProcesses {
    /// Every user's processes, root's among them, as `ps` lists them. Names are cut to 16
    /// characters (MAXCOMLEN).
    static func names() -> Set<String> {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
        // Room for a few started meanwhile.
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else { return [] }
        return Set(procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map { proc in
            withUnsafeBytes(of: proc.kp_proc.p_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        })
    }

    static func isRunning(_ name: String) -> Bool { names().contains(String(name.prefix(Int(MAXCOMLEN)))) }
}

/// The detectors DAM has, by app.
enum SessionDetectors {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// The apps DAM can watch for sessions of.
    static let watchable: Set<String> = ["rustdesk", "parsec", "screensharing"]

    static func make(for app: String) -> SessionDetector? {
        switch app {
        case "rustdesk":
            return LogSessionDetector(app: app, url: home.appendingPathComponent("Library/Logs/RustDesk/RustDesk_rCURRENT.log"),
                                      parse: SessionLogLines.rustDesk)
        case "parsec":
            return LogSessionDetector(app: app, url: home.appendingPathComponent(".parsec/log.txt"),
                                      parse: SessionLogLines.parsec)
        case "screensharing":
            return ProcessSessionDetector(app: app, processName: "screensharingd")
        default:
            return nil
        }
    }

    /// Whether the app is on this Mac.
    static func isInstalled(_ app: String) -> Bool {
        let fm = FileManager.default
        switch app {
        case "rustdesk": return fm.fileExists(atPath: "/Applications/RustDesk.app")
        case "parsec": return fm.fileExists(atPath: "/Applications/Parsec.app")
        case "screensharing": return true
        case "sunshine":
            return ["/Applications/Sunshine.app", "/usr/local/bin/sunshine", "/opt/homebrew/bin/sunshine"]
                .contains { fm.fileExists(atPath: $0) }
        default: return false
        }
    }
}

/// Runs a detector for each app whose profile asks to be watched, and starts and ends its
/// sessions as the detector says.
final class SessionWatcher {
    private let coordinator: RemoteSessionCoordinator
    private let make: (String) -> SessionDetector?
    private(set) var detectors: [String: SessionDetector] = [:]
    /// Called with what to announce when a watched session starts or ends.
    var announce: ((String) -> Void)?

    init(coordinator: RemoteSessionCoordinator, make: @escaping (String) -> SessionDetector? = SessionDetectors.make) {
        self.coordinator = coordinator
        self.make = make
    }

    /// Starts and stops detectors to match the profiles.
    func update() {
        for app in SessionDetectors.watchable {
            let profile = coordinator.profile(for: app)
            let wanted = profile.enabled && profile.watch
            if wanted, detectors[app] == nil, let detector = make(app) {
                detector.onEvent = { [weak self] in self?.handle($0, of: app) }
                detectors[app] = detector
                detector.start()
            } else if !wanted, let detector = detectors.removeValue(forKey: app) {
                detector.stop()
            }
        }
    }

    func stop() {
        for detector in detectors.values { detector.stop() }
        detectors.removeAll()
    }

    func handle(_ event: SessionEvent, of app: String) {
        let name = RemoteSessionApp.name(of: app)
        switch event {
        case .opened(_, let client):
            let first = coordinator.sessions[app] == nil
            coordinator.begin(SessionRequest(app: app, client: client)) { [weak self] result in
                switch result {
                case .success(let start):
                    for warning in start.warnings { detLog.error("\(app): \(warning)") }
                    if first { self?.announce?(Spoken.remoteSessionStarted(name)) }
                case .failure(let error):
                    detLog.error("\(app): \(error.description)")
                }
            }
        case .closed:
            let last = coordinator.sessions[app]?.count == 1
            if case .success = coordinator.end(app: app), last { announce?(Spoken.remoteSessionEnded(name)) }
        }
    }
}
