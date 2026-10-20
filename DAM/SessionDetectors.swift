//
//  SessionDetectors.swift
//
//  Tell when another app's remote session starts and ends, for the apps that can't say so
//  themselves (Sunshine does, through its prep commands; see ControlSocket.swift). Each
//  detector reports a connection opening or closing, by a key of its own; the coordinator
//  starts the app's session with the first and ends it with the last.
//

import CoreGraphics
import Darwin
import Foundation
import os.log

private let detLog = Logger(subsystem: AppIdentity.bundleID, category: "SessionDetectors")

/// What a detector knows of the screen an app streams.
enum StreamedDisplay: Equatable {
    case unknown
    /// A display the app made for the session, to adopt.
    case own(CGDirectDisplayID)
    /// The Mac's own screen, as the app mirrors it: no display to make or adopt.
    case mac
}

/// A connection opening or closing, by a key that pairs the two.
enum SessionEvent: Equatable {
    case opened(key: String, client: String?, display: StreamedDisplay = .unknown)
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

    /// Chrome Remote Desktop's host: `Client connected: user@example.com/chromoting…` and
    /// `Client disconnected: …`, by the client's JID (remoting/host/host_event_logger_posix.cc).
    static func chromeRemoteDesktop(_ line: String) -> SessionEvent? {
        if let m = captures(#"Client connected: (\S+)"#, in: line) {
            return .opened(key: m[0], client: m[0].split(separator: "/").first.map(String.init))
        }
        if let m = captures(#"Client disconnected: (\S+)"#, in: line) { return .closed(key: m[0]) }
        return nil
    }

    /// OpenDisplay, as the fork's `dam-session-log` branch writes it: `capture started: 2048x1536
    /// display 4128835 generation 1 mode extend localCursor=true session wifi:iPad` and
    /// `capture ended: session wifi:iPad`, by its session for the device. Extending, it
    /// streams a display of its own; mirroring, the Mac's main one.
    static func openDisplay(_ line: String) -> SessionEvent? {
        if let m = captures(#"capture started: \S+ display (\d+) generation \d+ mode (\w+) .*?session (\S.*)$"#, in: line) {
            let display: StreamedDisplay = m[1] == "extend" ? CGDirectDisplayID(m[0]).map { .own($0) } ?? .unknown : .mac
            // A WiFi session is named after the device's service; a USB one by its UDID.
            let client = m[2].hasPrefix("wifi:") ? String(m[2].dropFirst(5)) : nil
            return .opened(key: m[2], client: client, display: display)
        }
        if let m = captures(#"capture ended: session (\S.*)$"#, in: line) { return .closed(key: m[0]) }
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
    /// Whether the app runs, for one that can quit without logging the close. With it, a
    /// connection the log's end shows open when DAM starts watching counts while the app runs.
    private let isRunning: (() -> Bool)?
    private var follower: LogFollower?
    private var timer: Timer?
    private var wasRunning = false
    /// The connections open, so a close of one opened before DAM looked is ignored.
    private(set) var open: Set<String> = []

    init(app: String, url: URL, parse: @escaping (String) -> SessionEvent?, isRunning: (() -> Bool)? = nil) {
        self.app = app
        self.url = url
        self.parse = parse
        self.isRunning = isRunning
    }

    func start() {
        guard follower == nil else { return }
        detLog.debug("\(self.app): following \(self.url.path)")
        if let isRunning, isRunning() {
            for event in Self.stillOpen(in: Self.lastLines(of: url), parse: parse) { report(event) }
        }
        let follower = LogFollower(url: url) { [weak self] in self?.handle($0) }
        follower.start()
        self.follower = follower
        if isRunning != nil {
            checkRunning()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkRunning() }
        }
    }

    func stop() {
        follower?.stop()
        follower = nil
        timer?.invalidate()
        timer = nil
        // Ends what is still open, so the session doesn't outlive the watching.
        closeAll()
    }

    private func closeAll() {
        for key in open { onEvent?(.closed(key: key)) }
        open.removeAll()
    }

    /// Ends what is open once the app quits. Only after it was seen running, so lines
    /// written by hand (tools/sessiontest) still count.
    func checkRunning() {
        guard let isRunning else { return }
        if isRunning() {
            wasRunning = true
        } else if wasRunning {
            wasRunning = false
            if !open.isEmpty { detLog.debug("\(self.app): quit") }
            closeAll()
        }
    }

    func handle(_ line: String) {
        if let event = parse(line) { report(event) }
    }

    private func report(_ event: SessionEvent) {
        switch event {
        case .opened(let key, _, _):
            guard open.insert(key).inserted else { return }
        case .closed(let key):
            guard open.remove(key) != nil else { return }
        }
        detLog.debug("\(self.app): \(String(describing: event))")
        onEvent?(event)
    }
}

extension LogSessionDetector {
    /// The connections `lines` leave open, each as it was last opened, in the order opened.
    static func stillOpen(in lines: [String], parse: (String) -> SessionEvent?) -> [SessionEvent] {
        var open: [(key: String, event: SessionEvent)] = []
        for event in lines.compactMap(parse) {
            switch event {
            case .opened(let key, _, _):
                if let i = open.firstIndex(where: { $0.key == key }) { open[i].event = event } else { open.append((key, event)) }
            case .closed(let key):
                open.removeAll { $0.key == key }
            }
        }
        return open.map(\.event)
    }

    /// The whole lines in the last `bytes` of the file at `url`.
    static func lastLines(of url: URL, bytes: UInt64 = 256 * 1024) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > bytes ? size - bytes : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return [] }
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        // The first is cut short unless the read began at the start.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines.filter { !$0.isEmpty }
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

/// A connection for as long as a display whose name contains `name` is online, for apps that
/// make their own display for each session: Jump Desktop, Splashtop, Duet, ….
final class DisplaySessionDetector: SessionDetector {
    let app: String
    var onEvent: ((SessionEvent) -> Void)?
    private let name: () -> String?
    private let displays: () -> [(id: CGDirectDisplayID, name: String)]
    private var timer: Timer?
    /// The matching displays online.
    private(set) var open: Set<CGDirectDisplayID> = []

    init(app: String, name: @escaping () -> String?, displays: @escaping () -> [(id: CGDirectDisplayID, name: String)]) {
        self.app = app
        self.name = name
        self.displays = displays
    }

    func start() {
        guard timer == nil else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for id in open { onEvent?(.closed(key: "\(id)")) }
        open.removeAll()
    }

    func check() {
        guard let name = name(), !name.isEmpty else { return }
        let matching = displays().filter { $0.name.localizedCaseInsensitiveContains(name) }
        let ids = Set(matching.map(\.id))
        for gone in open.subtracting(ids) {
            open.remove(gone)
            onEvent?(.closed(key: "\(gone)"))
        }
        for display in matching where !open.contains(display.id) {
            open.insert(display.id)
            detLog.debug("\(self.app): \(display.name) came")
            onEvent?(.opened(key: "\(display.id)", client: nil, display: .own(display.id)))
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
    static let watchable: Set<String> = ["rustdesk", "parsec", "screensharing", "chromeremotedesktop", "teamviewer", "opendisplay", "display"]

    /// For "display": the displays online, and the name to watch for; set by the app.
    static var displayNames: () -> [(id: CGDirectDisplayID, name: String)] = { [] }
    static var adoptName: () -> String? = { nil }

    /// The log to follow for `app`: `standard`, or, for tests (tools/sessiontest), the path
    /// the default SessionDetectorLogs gives for the app.
    static func logURL(for app: String, standard: URL, defaults: UserDefaults = .standard) -> URL {
        guard let path = (defaults.dictionary(forKey: "SessionDetectorLogs")?[app] as? String),
              !path.isEmpty else { return standard }
        return URL(fileURLWithPath: path)
    }

    static func make(for app: String) -> SessionDetector? {
        switch app {
        case "rustdesk":
            let url = logURL(for: app, standard: home.appendingPathComponent("Library/Logs/RustDesk/RustDesk_rCURRENT.log"))
            return LogSessionDetector(app: app, url: url, parse: SessionLogLines.rustDesk)
        case "parsec":
            let url = logURL(for: app, standard: home.appendingPathComponent(".parsec/log.txt"))
            return LogSessionDetector(app: app, url: url, parse: SessionLogLines.parsec)
        case "screensharing":
            return ProcessSessionDetector(app: app, processName: "screensharingd")
        case "chromeremotedesktop":
            let url = logURL(for: app, standard: URL(fileURLWithPath: "/var/log/org.chromium.chromoting.log"))
            return LogSessionDetector(app: app, url: url, parse: SessionLogLines.chromeRemoteDesktop)
        case "teamviewer":
            // Started for each incoming connection.
            return ProcessSessionDetector(app: app, processName: "TeamViewer_Desktop")
        case "opendisplay":
            // The Debug build logs to a folder of its own.
            let logs = home.appendingPathComponent("Library/Logs")
            let standard = newest(["OpenDisplay", "OpenDisplay Dev"].map { logs.appendingPathComponent("\($0)/opendisplay.log") })
            return LogSessionDetector(app: app, url: logURL(for: app, standard: standard), parse: SessionLogLines.openDisplay,
                                      isRunning: { !RunningProcesses.names().isDisjoint(with: ["OpenDisplay", "OpenDisplay Dev"]) })
        case "display":
            return DisplaySessionDetector(app: app, name: adoptName, displays: displayNames)
        default:
            return nil
        }
    }

    /// The one of `urls` changed last, or the first when none is there.
    static func newest(_ urls: [URL]) -> URL {
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        return urls.max { modified($0) < modified($1) } ?? urls[0]
    }

    /// Whether the app is on this Mac.
    static func isInstalled(_ app: String) -> Bool {
        let fm = FileManager.default
        switch app {
        case "rustdesk": return fm.fileExists(atPath: "/Applications/RustDesk.app")
        case "parsec": return fm.fileExists(atPath: "/Applications/Parsec.app")
        case "screensharing", "display": return true
        case "chromeremotedesktop":
            return fm.fileExists(atPath: "/Library/PrivilegedHelperTools/org.chromium.chromoting.me2me_host.app")
        case "teamviewer": return fm.fileExists(atPath: "/Applications/TeamViewer.app")
        case "opendisplay":
            // Often built from source, so its log tells too.
            let logs = home.appendingPathComponent("Library/Logs").path
            return fm.fileExists(atPath: "/Applications/OpenDisplay.app") || fm.fileExists(atPath: "\(logs)/OpenDisplay")
                || fm.fileExists(atPath: "\(logs)/OpenDisplay Dev")
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
        case .opened(_, let client, let display):
            let first = coordinator.sessions[app] == nil
            var request = SessionRequest(app: app, client: client)
            switch display {
            case .unknown: break
            case .own(let id): request.adoptedDisplayID = id
            case .mac: request.display = SessionProfile.DisplayChoice.none
            }
            coordinator.begin(request) { [weak self] result in
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
