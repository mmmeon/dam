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

    /// RustDesk's desktop connections, told apart from its terminals (and other connections
    /// with no screen) by the lines that follow `Connection opened` within a few milliseconds.
    /// A desktop's: `new wakelock, require display on: true` (logged only for the first
    /// connection), `Option update: OptionMessage { … }` and video capture starting
    /// (`video_service.rs:485] #displays=2, current=0, …`). A terminal's: `require display on:
    /// false` and `terminal_service.rs` lines. Holds an opened connection until one comes; one
    /// still held when the next opens counts as a desktop. With the log's timestamps, any of
    /// these within `window` of the open count; a desktop's come within about 20 ms, over the
    /// internet too. Past it the connection may still be logging in (a password being typed,
    /// a click to accept), so it stays held: only video capture starting makes it a desktop,
    /// as the wakelock and options can be another connection's, and a terminal's line or the
    /// next open drops it, as one with no screen (a file transfer) makes no session.
    final class RustDeskConnections {
        private var pending: SessionEvent?
        /// When the held connection opened, by the log.
        private var pendingAt: TimeInterval?
        static let window: TimeInterval = 0.5

        func parse(_ line: String) -> SessionEvent? {
            // A connection held over a restart never shows what it was, nor closes.
            if SessionLogLines.rustDeskRestarted(line) {
                pending = nil
                return nil
            }
            let at = Self.time(of: line)
            if let event = SessionLogLines.rustDesk(line) {
                switch event {
                case .opened:
                    let earlier = expired(at) ? nil : pending
                    pending = event
                    pendingAt = at
                    return earlier
                case .closed(let key):
                    if case .opened(key, _, _)? = pending { pending = nil }
                    return event
                }
            }
            guard let held = pending else { return nil }
            if line.contains("require display on: false") || line.contains("terminal_service.rs") {
                pending = nil
                return nil
            }
            let capturing = line.contains("video_service.rs") && line.contains("#displays=")
            if capturing || (!expired(at) && (line.contains("require display on: true")
                                              || line.contains("Option update: OptionMessage"))) {
                pending = nil
                return held
            }
            return nil
        }

        /// Whether a line at `at` comes too long after the held connection opened to say
        /// what it was.
        private func expired(_ at: TimeInterval?) -> Bool {
            guard let opened = pendingAt, let at else { return false }
            return at - opened > Self.window || at < opened
        }

        /// Seconds into the day of a line's `[2026-10-20 15:26:04.995863 -04:00]`, or nil
        /// for a line without one. A new day reads as earlier, which ends the window too.
        static func time(of line: String) -> TimeInterval? {
            let chars = Array(line.utf8.prefix(28))
            guard chars.count == 28, chars[0] == UInt8(ascii: "["), chars[11] == UInt8(ascii: " "),
                  chars[14] == UInt8(ascii: ":"), chars[17] == UInt8(ascii: ":"), chars[20] == UInt8(ascii: ".") else { return nil }
            func number(_ range: Range<Int>) -> Double? {
                var value = 0.0
                for c in chars[range] {
                    guard c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") else { return nil }
                    value = value * 10 + Double(c - UInt8(ascii: "0"))
                }
                return value
            }
            guard let h = number(12..<14), let m = number(15..<17), let s = number(18..<20),
                  let f = number(21..<27) else { return nil }
            return h * 3600 + m * 60 + s + f / 1_000_000
        }
    }

    /// RustDesk starting its server afresh, `… INFO [src/server.rs:744] try start server`, after
    /// which no earlier connection is left, though their closes went unlogged.
    static func rustDeskRestarted(_ line: String) -> Bool { line.contains("try start server") }

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

    /// When an OpenDisplay line was written, by its `[15:26:04.995]`: the time of day only, so
    /// the last such time up to `now`, or nil for a line without one.
    static func openDisplayTime(of line: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard let m = captures(#"^\[(\d\d):(\d\d):(\d\d)(?:\.(\d+))?\]"#, in: line),
              let h = Int(m[0]), let min = Int(m[1]), let sec = Int(m[2]), h < 24, min < 60, sec < 60 else { return nil }
        let fraction = m[3].isEmpty ? 0 : (Double("0.\(m[3])") ?? 0)
        guard var time = calendar.date(bySettingHour: h, minute: min, second: sec, of: now) else { return nil }
        time += fraction
        // Written before midnight; a moment's leeway for clocks read a little apart.
        if time > now + 60 { time = calendar.date(byAdding: .day, value: -1, to: time) ?? time }
        return time
    }

    /// An added app's lines, by the regular expressions `opened` and `closed`, or nil when
    /// either isn't one. A group named `id` in both pairs a close with its open, so
    /// connections can overlap; without, a session lasts from the first line matching `opened`
    /// to the next matching `closed`. A group named `client` in `opened` names the client.
    static func custom(opened: String, closed: String) -> ((String) -> SessionEvent?)? {
        guard !opened.isEmpty, !closed.isEmpty,
              let open = try? NSRegularExpression(pattern: opened),
              let close = try? NSRegularExpression(pattern: closed) else { return nil }
        let paired = opened.contains("(?<id>") && closed.contains("(?<id>")
        let named = opened.contains("(?<client>")
        func group(_ name: String, of match: NSTextCheckingResult, in line: String) -> String? {
            Range(match.range(withName: name), in: line).map { String(line[$0]) }
        }
        return { line in
            let range = NSRange(line.startIndex..., in: line)
            if let m = close.firstMatch(in: line, range: range) {
                return .closed(key: paired ? group("id", of: m, in: line) ?? "" : "")
            }
            if let m = open.firstMatch(in: line, range: range) {
                let client = named ? group("client", of: m, in: line).flatMap { $0.isEmpty ? nil : $0 } : nil
                return .opened(key: paired ? group("id", of: m, in: line) ?? "" : "", client: client)
            }
            return nil
        }
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
        // A source's descriptor is closed only once it has been cancelled, or a new file
        // given the same descriptor could leave the next source dead.
        source.setCancelHandler { try? handle.close() }
        source.resume()
        self.source = source
        if !fromEnd { readNew() }
    }

    private func close() {
        // The file is closed by its source's cancel handler.
        source?.cancel()
        source = nil
        handle = nil
        partial.removeAll()
    }

    /// Opens the file once it is there, or again when the one at its path is another.
    private func check() {
        guard let handle else { return open(fromEnd: false) }
        var opened = stat()
        var atPath = stat()
        guard fstat(handle.fileDescriptor, &opened) == 0 else { return }
        // Through a link to the log, the file it leads to.
        if stat(url.path, &atPath) != 0 || atPath.st_ino != opened.st_ino || atPath.st_dev != opened.st_dev {
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
    /// Whether a line says the app started again, which ends every connection open.
    private let restarted: ((String) -> Bool)?
    /// Whether the connections the log's end shows open count when watching starts, while
    /// the app runs; not for an app whose log may hold an earlier run's.
    private let takesUpOpen: Bool
    /// Whether a line opening a connection counts only while the app runs: one written while
    /// it doesn't, as by hand, would start a session that its quit never ends.
    private let opensWhileRunning: Bool
    /// When the app running now started, and when a line was written: lines from before it
    /// started are an earlier run's, whose connections went with it, as after a crash.
    private let launched: (() -> Date?)?
    private let lineTime: ((String) -> Date?)?
    private var follower: LogFollower?
    private var timer: Timer?
    private var wasRunning = false
    private var lastLaunch: Date?
    /// The connections open, so a close of one opened before DAM looked is ignored.
    private(set) var open: Set<String> = []

    init(app: String, url: URL, parse: @escaping (String) -> SessionEvent?, isRunning: (() -> Bool)? = nil,
         restarted: ((String) -> Bool)? = nil, takesUpOpen: Bool = true, opensWhileRunning: Bool = false,
         launched: (() -> Date?)? = nil, lineTime: ((String) -> Date?)? = nil) {
        self.app = app
        self.url = url
        self.parse = parse
        self.isRunning = isRunning
        self.restarted = restarted
        self.takesUpOpen = takesUpOpen
        self.opensWhileRunning = opensWhileRunning
        self.launched = launched
        self.lineTime = lineTime
    }

    func start() {
        guard follower == nil else { return }
        detLog.debug("\(self.app): following \(self.url.path)")
        if takesUpOpen, let isRunning, isRunning() {
            var lines = Self.lastLines(of: url)
            if let lineTime, let since = launched?() { lines = Self.lines(lines, since: since, time: lineTime) }
            for event in Self.stillOpen(in: lines, parse: parse, restarted: restarted) { report(event) }
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
            // Started again since the last look, as after a crash: what was open went with it.
            if let launched, let now = launched() {
                if let last = lastLaunch, now != last, !open.isEmpty {
                    detLog.debug("\(self.app): started again")
                    closeAll()
                }
                lastLaunch = now
            }
            wasRunning = true
        } else if wasRunning {
            wasRunning = false
            if !open.isEmpty { detLog.debug("\(self.app): quit") }
            closeAll()
        }
    }

    func handle(_ line: String) {
        if let restarted, restarted(line) {
            if !open.isEmpty { detLog.debug("\(self.app): restarted") }
            // For the parser, which may hold a connection it should forget.
            _ = parse(line)
            closeAll()
        } else if let event = parse(line) {
            if case .opened = event, opensWhileRunning, let isRunning {
                guard isRunning() else {
                    detLog.debug("\(self.app): an open while it isn't running, ignored")
                    return
                }
                // So a quit before the next look still ends it.
                wasRunning = true
            }
            report(event)
        }
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
    static func stillOpen(in lines: [String], parse: (String) -> SessionEvent?,
                          restarted: ((String) -> Bool)? = nil) -> [SessionEvent] {
        var open: [(key: String, event: SessionEvent)] = []
        for line in lines {
            if let restarted, restarted(line) { _ = parse(line); open.removeAll(); continue }
            guard let event = parse(line) else { continue }
            switch event {
            case .opened(let key, _, _):
                if let i = open.firstIndex(where: { $0.key == key }) { open[i].event = event } else { open.append((key, event)) }
            case .closed(let key):
                open.removeAll { $0.key == key }
            }
        }
        return open.map(\.event)
    }

    /// `lines` from the first written at `since` or after, by `time`; a line with no time
    /// goes with the one before it.
    static func lines(_ lines: [String], since: Date, time: (String) -> Date?) -> [String] {
        // A second's leeway: the log's times can be cut to the millisecond, the start's not.
        let since = since - 1
        guard let first = lines.firstIndex(where: { time($0).map { $0 >= since } ?? false }) else { return [] }
        return Array(lines[first...])
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
    struct Process {
        let pid: pid_t
        /// Cut to 16 characters (MAXCOMLEN).
        let name: String
        let started: Date
    }

    /// Every user's processes, root's among them, as `ps` lists them.
    static func all() -> [Process] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
        // Room for a few started meanwhile.
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map { proc in
            let name = withUnsafeBytes(of: proc.kp_proc.p_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let start = proc.kp_proc.p_un.__p_starttime
            return Process(pid: proc.kp_proc.p_pid, name: name,
                           started: Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000))
        }
    }

    static func names() -> Set<String> { Set(all().map(\.name)) }

    static func isRunning(_ name: String) -> Bool { names().contains(String(name.prefix(Int(MAXCOMLEN)))) }

    /// Those named one of `names` whose executable's path contains `path`, when given: a
    /// name alone can be another's, as the system's own `parsecd` (CoreParsec) is Parsec's.
    static func matching(_ names: [String], path: String? = nil) -> [Process] {
        let cut = Set(names.map { String($0.prefix(Int(MAXCOMLEN))) })
        return all().filter { process in
            cut.contains(process.name) && (path.map { Self.path(of: process.pid)?.contains($0) ?? false } ?? true)
        }
    }

    /// When the newest of those `matching` started, or nil when none runs.
    static func started(_ names: [String], path: String? = nil) -> Date? {
        matching(names, path: path).map(\.started).max()
    }

    /// The path of process `pid`'s executable, or nil when it can't be read.
    static func path(of pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE, a macro Swift doesn't see.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}

/// The detectors DAM has, by app.
enum SessionDetectors {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// The apps DAM can watch for sessions of.
    static let watchable: Set<String> = ["rustdesk", "parsec", "screensharing", "chromeremotedesktop", "teamviewer", "opendisplay", "display"]

    /// OpenDisplay's process and log folder; its Debug build's are called "OpenDisplay Dev".
    static let openDisplayNames = ["OpenDisplay", "OpenDisplay Dev"]

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

    /// The detector for `app`; for an app added in Settings, as its `profile` says.
    static func make(for app: String, profile: SessionProfile?) -> SessionDetector? {
        if let profile, let detection = profile.detection {
            return make(added: app, detection, adoptName: profile.adoptName)
        }
        switch app {
        case "rustdesk":
            let url = logURL(for: app, standard: home.appendingPathComponent("Library/Logs/RustDesk/RustDesk_rCURRENT.log"))
            // A restart or quit ends connections without logging their closes.
            return LogSessionDetector(app: app, url: url, parse: SessionLogLines.RustDeskConnections().parse,
                                      isRunning: { RunningProcesses.isRunning("RustDesk") },
                                      restarted: SessionLogLines.rustDeskRestarted)
        case "parsec":
            let url = logURL(for: app, standard: home.appendingPathComponent(".parsec/log.txt"))
            // A quit or crash ends connections without logging their closes. Its log isn't
            // known to mark a start, so what its end shows open isn't taken up.
            return LogSessionDetector(app: app, url: url, parse: SessionLogLines.parsec,
                                      isRunning: { !RunningProcesses.matching(["parsecd"], path: "/Parsec.app/").isEmpty },
                                      takesUpOpen: false)
        case "screensharing":
            return ProcessSessionDetector(app: app, processName: "screensharingd")
        case "chromeremotedesktop":
            let url = logURL(for: app, standard: URL(fileURLWithPath: "/var/log/org.chromium.chromoting.log"))
            // As Parsec's.
            return LogSessionDetector(app: app, url: url, parse: SessionLogLines.chromeRemoteDesktop,
                                      isRunning: { RunningProcesses.isRunning("remoting_me2me_host") }, takesUpOpen: false)
        case "teamviewer":
            // Started for each incoming connection.
            return ProcessSessionDetector(app: app, processName: "TeamViewer_Desktop")
        case "opendisplay":
            // The Debug build logs to a folder of its own.
            let logs = home.appendingPathComponent("Library/Logs")
            let standard = newest(openDisplayNames.map { logs.appendingPathComponent("\($0)/opendisplay.log") })
            // What its log shows open counts only if written since it started: a crash leaves
            // its last session open there.
            return LogSessionDetector(app: app, url: logURL(for: app, standard: standard), parse: SessionLogLines.openDisplay,
                                      isRunning: { !RunningProcesses.names().isDisjoint(with: openDisplayNames) },
                                      launched: { RunningProcesses.started(openDisplayNames) },
                                      lineTime: { SessionLogLines.openDisplayTime(of: $0) })
        case "display":
            return DisplaySessionDetector(app: app, name: adoptName, displays: displayNames)
        default:
            return nil
        }
    }

    /// The detector for an app added in Settings, or nil while it isn't set up.
    static func make(added app: String, _ detection: SessionDetection, adoptName: String?) -> SessionDetector? {
        guard detection.problem(adoptName: adoptName) == nil else { return nil }
        switch detection.kind {
        case .log:
            guard let parse = SessionLogLines.custom(opened: detection.opened, closed: detection.closed) else { return nil }
            // With its process, a quit ends connections as Parsec's does, and what the log
            // shows open isn't taken up, as it may be an earlier run's.
            let name = detection.logProcessName
            return LogSessionDetector(app: app, url: logURL(for: app, standard: detection.logURL), parse: parse,
                                      isRunning: name.isEmpty ? nil : { RunningProcesses.isRunning(name) },
                                      takesUpOpen: false, opensWhileRunning: true)
        case .process:
            return ProcessSessionDetector(app: app, processName: detection.processName)
        case .display:
            return DisplaySessionDetector(app: app, name: { adoptName }, displays: displayNames)
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
            return fm.fileExists(atPath: "/Applications/OpenDisplay.app")
                || openDisplayNames.contains { fm.fileExists(atPath: "\(logs)/\($0)") }
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
    /// What each added app's detector was made from, to make it again when that changes.
    private var madeFrom: [String: SessionProfile] = [:]
    /// Called with what to announce when a watched session starts or ends.
    var announce: ((String) -> Void)?
    /// The session each open connection joined, by app and the detector's key: a session
    /// ended by hand leaves its connections open, and their closes mustn't end a later one.
    private var joined: [String: [String: UUID]] = [:]

    init(coordinator: RemoteSessionCoordinator, make: ((String) -> SessionDetector?)? = nil) {
        self.coordinator = coordinator
        self.make = make ?? { [unowned coordinator] app in
            SessionDetectors.make(for: app, profile: coordinator.profile(for: app))
        }
    }

    /// Starts and stops detectors to match the profiles.
    func update() {
        let added = Set(coordinator.addedApps)
        for app in SessionDetectors.watchable.union(added).union(detectors.keys) {
            let profile = coordinator.profile(for: app)
            let wanted = profile.enabled && profile.watch && (SessionDetectors.watchable.contains(app) || added.contains(app))
            // An added app's detector is made again once what it watches changes, but not
            // during a session: stopping it would end the session, and the new one wouldn't
            // see the connection already open. The change waits for the session to end.
            if added.contains(app), coordinator.sessions[app] == nil || !wanted, changed(app, profile),
               let detector = detectors.removeValue(forKey: app) {
                detector.stop()
            }
            if wanted, detectors[app] == nil, let detector = make(app) {
                if added.contains(app) { madeFrom[app] = profile }
                detector.onEvent = { [weak self] in self?.handle($0, of: app) }
                detectors[app] = detector
                detector.start()
            } else if !wanted, let detector = detectors.removeValue(forKey: app) {
                detector.stop()
                madeFrom[app] = nil
            }
        }
    }

    /// Whether `app` was changed in a way its detector takes up only once its session ends.
    func waitsForSessionEnd(_ app: String) -> Bool {
        coordinator.sessions[app] != nil && detectors[app] != nil && changed(app, coordinator.profile(for: app))
    }

    private func changed(_ app: String, _ profile: SessionProfile) -> Bool {
        guard let made = madeFrom[app] else { return false }
        return made.detection != profile.detection
            || (profile.detection?.kind == .display && made.adoptName != profile.adoptName)
    }

    func stop() {
        for detector in detectors.values { detector.stop() }
        detectors.removeAll()
    }

    func handle(_ event: SessionEvent, of app: String) {
        let name = RemoteSessionApp.name(of: app)
        switch event {
        case .opened(let key, let client, let display):
            let first = coordinator.sessions[app] == nil
            var request = SessionRequest(app: app, origin: .detector, client: client)
            switch display {
            case .unknown: break
            case .own(let id): request.adoptedDisplayID = id
            case .mac: request.display = SessionProfile.DisplayChoice.none
            }
            coordinator.begin(request) { [weak self] result in
                switch result {
                case .success(let start):
                    for warning in start.warnings { detLog.error("\(app): \(warning)") }
                    // Not when every connection closed while it was being set up: it ends now.
                    let on = (self?.coordinator.sessions[app]?.count ?? 0) > 0
                    if first, on { self?.announce?(Spoken.remoteSessionStarted(name)) }
                case .failure(let error):
                    detLog.error("\(app): \(error.description)")
                }
            }
            joined[app, default: [:]][key] = coordinator.sessions[app]?.id
        case .closed(let key):
            guard let id = joined[app]?.removeValue(forKey: key), let session = coordinator.sessions[app],
                  session.id == id else { return }
            // One still being set up was never announced.
            let last = session.count == 1 && !session.starting
            if case .success = coordinator.end(app: app), last { announce?(Spoken.remoteSessionEnded(name)) }
        }
    }
}
