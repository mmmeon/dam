//
//  ControlSocket.swift
//
//  Lets scripts and other apps drive DAM. The running app listens on a Unix socket in
//  Application Support, readable only by the user. The command-line mode, which is the DAM
//  binary run with a command (`DAM session start --app sunshine`), sends it one JSON request
//  per line and waits for the JSON answer. A Sunshine prep command can then make a display
//  for the stream and have it placed before Sunshine starts capturing.
//

import CoreGraphics
import Darwin
import Foundation
import os.log

private let csLog = Logger(subsystem: AppIdentity.bundleID, category: "Control")

/// One request to the running app.
struct ControlRequest: Codable, Equatable {
    /// "session.start", "session.end", "display.list" or "status".
    var command: String
    var app: String?
    var client: String?
    var clientID: String?
    var width: Int?
    var height: Int?
    var fps: Int?
    /// "create", "adopt" or "none".
    var display: String?
    /// "extend", "main" or "mirror".
    var placement: String?
    /// A sound output's UID or name.
    var audio: String?
    /// Whether to black out the Mac's own screens.
    var blackout: Bool?
    /// For "session.end": every start of the session, not just one.
    var all: Bool?
}

extension ControlRequest {
    /// Values a request can't have, and why.
    struct Invalid: Error, Equatable { var message: String }

    static let commands: Set<String> = ["session.start", "session.end", "display.list", "status"]

    /// The highest frame rate a session can ask for.
    static let maxFPS = 240
    /// The widest or tallest client a session can ask for: 8K. Past the streaming display's
    /// own sizes on purpose, as a 5K or ultrawide client gets a HiDPI display of half its size.
    static let maxSide = 7680

    /// Why the request's values can't be used, or nil when they can. Every request is
    /// checked here, from the command line, the socket or a URL.
    var problem: String? {
        let side = Self.maxSide
        if let width, !(1...side).contains(width) { return "The width must be from 1 to \(side) pixels." }
        if let height, !(1...side).contains(height) { return "The height must be from 1 to \(side) pixels." }
        if let fps, !(1...Self.maxFPS).contains(fps) { return "The frame rate must be from 1 to \(Self.maxFPS)." }
        if let display, SessionProfile.DisplayChoice(rawValue: display) == nil { return "The display is create, adopt or none." }
        if let placement, SessionProfile.Placement(rawValue: placement) == nil { return "The placement is extend, main or mirror." }
        return nil
    }

    /// The request for `command` with the values in `fields`, by the command line's names
    /// for them (`app`, `client-id`, `width`, `blackout`, `all`, …); a `dam://` URL's query is
    /// read the same way. An empty value counts as none.
    static func make(_ command: String, fields: [String: String]) throws -> ControlRequest {
        func text(_ key: String) -> String? { fields[key].flatMap { $0.isEmpty ? nil : $0 } }
        func number(_ key: String, _ name: String) throws -> Int? {
            guard let text = text(key) else { return nil }
            guard let value = Int(text) else { throw Invalid(message: "The \(name) must be a number.") }
            return value
        }
        func flag(_ key: String) throws -> Bool? {
            guard let text = text(key) else { return nil }
            switch text.lowercased() {
            case "yes", "true", "1": return true
            case "no", "false", "0": return false
            default: throw Invalid(message: "\(key) is yes or no.")
            }
        }
        var request = ControlRequest(command: command)
        switch command {
        case "session.start":
            guard let app = text("app") else { throw Invalid(message: "No app given.") }
            request.app = app
            request.client = text("client")
            request.clientID = text("client-id")
            request.width = try number("width", "width")
            request.height = try number("height", "height")
            request.fps = try number("fps", "frame rate")
            request.display = text("display")
            request.placement = text("placement")
            request.audio = text("audio")
            request.blackout = try flag("blackout")
        case "session.end":
            guard let app = text("app") else { throw Invalid(message: "No app given.") }
            request.app = app
            request.all = try flag("all")
        default:
            break
        }
        if let problem = request.problem { throw Invalid(message: problem) }
        return request
    }
}

/// The running app's answer.
struct ControlResponse: Codable, Equatable {
    struct Display: Codable, Equatable {
        var id: UInt32
        var name: String
        var width: Int
        var height: Int
        var main: Bool
        var mirroring: Bool
        var streaming: Bool
    }

    struct Session: Codable, Equatable {
        var app: String
        var client: String?
        var count: Int
        var displayID: UInt32?
    }

    var ok: Bool
    var message: String?
    var displayID: UInt32?
    var warnings: [String]?
    var displays: [Display]?
    var sessions: [Session]?

    static func failure(_ message: String) -> ControlResponse { ControlResponse(ok: false, message: message) }
}

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

/// The running app's end: accepts connections, reads one request from each, and answers.
final class ControlServer {
    typealias Handler = (ControlRequest, @escaping (ControlResponse) -> Void) -> Void

    private let path: String
    private let handler: Handler
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    /// Requests being read, by connection.
    private var clients: [Int32: (source: DispatchSourceRead, data: Data)] = [:]

    /// The most a request can be.
    private static let maxRequest = 64 * 1024

    init(path: String = ControlSocketPath.defaultURL.path, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    deinit { stop() }

    enum StartError: Error { case pathTooLong, inUse, socket(Int32) }

    /// Listens, unless another copy of DAM already does.
    func start() throws {
        guard var address = ControlSocketPath.address(path) else { throw StartError.pathTooLong }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        // A socket left by a copy that quit answers nothing and is removed; one that answers
        // belongs to a copy still running.
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        if probe >= 0 {
            let answered = ControlSocketPath.connect(probe, to: path)
            close(probe)
            if answered { throw StartError.inUse }
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.socket(errno) }
        // Made private before it can be connected to.
        let mask = umask(0o077)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(mask)
        guard bound == 0, listen(fd, 8) == 0 else {
            let error = errno
            close(fd)
            throw StartError.socket(error)
        }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.accept() }
        // A source's descriptor is closed only once it has been cancelled.
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
        csLog.debug("listening on \(self.path)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        clients.values.forEach { $0.source.cancel() }
        clients.removeAll()
        if listenFD >= 0 {
            listenFD = -1
            unlink(path)
        }
    }

    private func accept() {
        while true {
            let fd = Darwin.accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            // Only this user's processes; the socket's mode should already see to it.
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self] in self?.read(fd) }
            source.setCancelHandler { close(fd) }
            clients[fd] = (source, Data())
            source.resume()
        }
    }

    private func read(_ fd: Int32) {
        guard clients[fd] != nil else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count < 0, errno == EAGAIN { return }
        guard count > 0 else { return drop(fd) }
        clients[fd]?.data.append(contentsOf: buffer[0..<count])
        guard let data = clients[fd]?.data else { return }
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else {
            if data.count > Self.maxRequest { drop(fd) }
            return
        }
        // One request a connection: stop reading, answer on a descriptor of the answer's
        // own (the source's goes with it), close.
        let answer = dup(fd)
        clients[fd]?.source.cancel()
        clients[fd] = nil
        guard answer >= 0 else { return }
        let line = data[data.startIndex..<newline]
        guard let request = try? JSONDecoder().decode(ControlRequest.self, from: line) else {
            return Self.reply(.failure("That request couldn't be read."), to: answer)
        }
        csLog.debug("request: \(request.command)")
        handler(request) { Self.reply($0, to: answer) }
    }

    private func drop(_ fd: Int32) {
        clients[fd]?.source.cancel()
        clients[fd] = nil
    }

    /// The most of a message an answer carries, as a message can repeat what was asked.
    private static let maxMessage = 300

    private static func reply(_ response: ControlResponse, to fd: Int32) {
        var response = response
        if let message = response.message, message.count > maxMessage {
            response.message = String(message.prefix(maxMessage)) + "…"
        }
        var data = (try? JSONEncoder().encode(response)) ?? Data()
        data.append(UInt8(ascii: "\n"))
        // Blocking for the write: answers are small, and the client is waiting for it. But
        // only for a moment, as this is the main thread and a client may never read.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var wait = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else { break }
                offset += written
            }
        }
        close(fd)
    }
}

/// The command-line mode: the DAM binary run with a command, talking to the running app.
enum ControlCLI {
    /// The words that start the command-line mode. Anything else, such as the `-psn_` or
    /// `-Key value` arguments a launch can carry, starts the app.
    static let commands: Set<String> = ["session", "display", "status", "help", "--help", "-h"]

    static func isCommand(_ arguments: [String]) -> Bool {
        arguments.count > 1 && commands.contains(arguments[1])
    }

    static let usage = """
    Usage:
      DAM session start --app APP [--client NAME] [--client-id ID]
                        [--width W --height H] [--fps F]
                        [--display create|adopt|none] [--placement extend|main|mirror]
                        [--audio OUTPUT] [--blackout yes|no]
      DAM session end --app APP [--all]
      DAM display list
      DAM status

    session start makes and places the app's display as its profile says, switches the
    sound output, and prints the display's ID once it is ready. Left out, the client's
    name, size and frame rate come from Sunshine's SUNSHINE_CLIENT_* variables, and its ID
    from APOLLO_CLIENT_UUID or SUNSHINE_CLIENT_CERT_UUID.

    Apps: \(RemoteSessionApp.known.map(\.id).joined(separator: ", ")), or any other name.
    """

    enum ParseError: Error, Equatable { case usage(String) }

    /// The request `arguments` (without the program's path) ask for, with `environment`
    /// filling in what Sunshine passes.
    static func request(from arguments: [String], environment: [String: String]) throws -> ControlRequest {
        guard let first = arguments.first else { throw ParseError.usage("No command given.") }
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var rest = arguments.dropFirst()
        var words: [String] = []
        while let word = rest.popFirst() {
            if word.hasPrefix("--") {
                let key = String(word.dropFirst(2))
                if key == "all" { flags.insert(key); continue }
                guard let value = rest.popFirst() else { throw ParseError.usage("\(word) needs a value.") }
                options[key] = value
            } else {
                words.append(word)
            }
        }
        let known: Set<String> = ["app", "client", "client-id", "width", "height", "fps", "display", "placement", "audio",
                                  "blackout"]
        if let unknown = options.keys.first(where: { !known.contains($0) }) {
            throw ParseError.usage("Unknown option --\(unknown).")
        }
        if flags.contains("all") { options["all"] = "yes" }
        func make(_ command: String) throws -> ControlRequest {
            do {
                return try ControlRequest.make(command, fields: options)
            } catch let error as ControlRequest.Invalid {
                throw ParseError.usage(error.message)
            }
        }

        switch (first, words.first) {
        case ("session", "start"):
            // What Sunshine passes, for what the options leave out.
            func variable(_ name: String) -> String? { environment[name].flatMap { $0.isEmpty ? nil : $0 } }
            options["client"] = options["client"] ?? variable("SUNSHINE_CLIENT_NAME")
            options["client-id"] = options["client-id"] ?? variable("APOLLO_CLIENT_UUID") ?? variable("SUNSHINE_CLIENT_CERT_UUID")
            options["width"] = options["width"] ?? variable("SUNSHINE_CLIENT_WIDTH")
            options["height"] = options["height"] ?? variable("SUNSHINE_CLIENT_HEIGHT")
            options["fps"] = options["fps"] ?? variable("SUNSHINE_CLIENT_FPS")
            return try make("session.start")
        case ("session", "end"):
            return try make("session.end")
        case ("display", "list"):
            return try make("display.list")
        case ("status", nil):
            return try make("status")
        default:
            throw ParseError.usage("Unknown command.")
        }
    }

    /// Runs the command in `arguments` (with the program's path first) and returns the exit
    /// status: 0 when done, 1 when the app said no, 2 for a bad command, 3 when DAM isn't running.
    static func run(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
                    socketPath: String = ControlSocketPath.defaultURL.path) -> Int32 {
        let args = Array(arguments.dropFirst())
        if ["help", "--help", "-h"].contains(args.first ?? "") {
            print(usage)
            return 0
        }
        let request: ControlRequest
        do {
            request = try self.request(from: args, environment: environment)
        } catch ParseError.usage(let message) {
            FileHandle.standardError.write(Data("\(message)\n\n\(usage)\n".utf8))
            return 2
        } catch {
            return 2
        }
        guard let response = send(request, to: socketPath) else {
            FileHandle.standardError.write(Data("\(AppIdentity.name) isn't running, or isn't listening for commands.\n".utf8))
            return 3
        }
        print(text(for: response, to: request))
        return response.ok ? 0 : 1
    }

    /// Sends `request` and waits for the answer: up to a minute, as making a display can take
    /// a quarter of that.
    static func send(_ request: ControlRequest, to path: String, timeout: Int = 60) -> ControlResponse? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard ControlSocketPath.connect(fd, to: path) else { return nil }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        guard var data = try? JSONEncoder().encode(request) else { return nil }
        data.append(UInt8(ascii: "\n"))
        let sent = data.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
        guard sent == data.count else { return nil }
        var answer = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            answer.append(contentsOf: buffer[0..<count])
        }
        let line = answer.split(separator: UInt8(ascii: "\n")).first ?? answer[...]
        return try? JSONDecoder().decode(ControlResponse.self, from: Data(line))
    }

    /// What to print for `response`.
    static func text(for response: ControlResponse, to request: ControlRequest) -> String {
        var lines: [String] = []
        if let message = response.message { lines.append(message) }
        if let displays = response.displays {
            lines += displays.map { d in
                let flags = [d.main ? "main" : nil, d.mirroring ? "mirroring" : nil, d.streaming ? "streaming" : nil]
                    .compactMap { $0 }.joined(separator: ", ")
                return "\(d.id)\t\(d.width)×\(d.height)\t\(d.name)" + (flags.isEmpty ? "" : "\t(\(flags))")
            }
        }
        if let sessions = response.sessions {
            lines += sessions.isEmpty ? ["No remote sessions."] : sessions.map { s in
                RemoteSessionApp.name(of: s.app) + (s.client.map { " (\($0))" } ?? "")
                    + (s.count > 1 ? " ×\(s.count)" : "") + (s.displayID.map { "\tdisplay \($0)" } ?? "")
            }
        }
        // A script reads the display's ID off the last line.
        if request.command == "session.start", let id = response.displayID { lines.append("\(id)") }
        for warning in response.warnings ?? [] { lines.append("warning: \(warning)") }
        return lines.joined(separator: "\n")
    }
}

/// The running app's answers to requests, from the socket or a `dam://` URL.
final class ControlHandler {
    private let coordinator: RemoteSessionCoordinator
    private let video: VideoManager
    private let sessionDisplays: LiveSessionDisplays

    init(coordinator: RemoteSessionCoordinator, video: VideoManager, sessionDisplays: LiveSessionDisplays) {
        self.coordinator = coordinator
        self.video = video
        self.sessionDisplays = sessionDisplays
    }

    func handle(_ request: ControlRequest, reply: @escaping (ControlResponse) -> Void) {
        if let problem = request.problem { return reply(.failure(problem)) }
        switch request.command {
        case "session.start":
            guard let app = request.app?.lowercased(), !app.isEmpty else { return reply(.failure("No app given.")) }
            var audioUID: String?
            if let audio = request.audio {
                guard let uid = sessionDisplays.outputUID(matching: audio) else {
                    return reply(.failure("No sound output is called \(audio)."))
                }
                audioUID = uid
            }
            let session = SessionRequest(app: app, client: request.client, clientID: request.clientID,
                                         width: request.width, height: request.height, fps: request.fps,
                                         display: request.display.flatMap(SessionProfile.DisplayChoice.init(rawValue:)),
                                         placement: request.placement.flatMap(SessionProfile.Placement.init(rawValue:)),
                                         audioOutputUID: audioUID, blackout: request.blackout)
            coordinator.begin(session) { result in
                switch result {
                case .success(let start):
                    reply(ControlResponse(ok: true, message: "\(RemoteSessionApp.name(of: app)) session on.",
                                          displayID: start.displayID,
                                          warnings: start.warnings.isEmpty ? nil : start.warnings))
                case .failure(let error):
                    reply(.failure(error.description))
                }
            }
        case "session.end":
            guard let app = request.app?.lowercased(), !app.isEmpty else { return reply(.failure("No app given.")) }
            switch coordinator.end(app: app, all: request.all ?? false) {
            case .success: reply(ControlResponse(ok: true, message: "\(RemoteSessionApp.name(of: app)) session ended."))
            case .failure(let error): reply(.failure(error.description))
            }
        case "display.list":
            reply(ControlResponse(ok: true, displays: displays()))
        case "status":
            let sessions = coordinator.sessions.values.sorted { $0.started < $1.started }.map {
                ControlResponse.Session(app: $0.app, client: $0.client, count: $0.count, displayID: $0.displayID)
            }
            reply(ControlResponse(ok: true, sessions: sessions))
        default:
            reply(.failure("Unknown command \(request.command)."))
        }
    }

    /// The displays that are on, as `display list` shows them.
    private func displays() -> [ControlResponse.Display] {
        (video.allConnectedDisplays + video.allAirPlayDevices).filter { $0.cgDisplayID != 0 }.map { d in
            let bounds = CGDisplayBounds(d.cgDisplayID)
            return ControlResponse.Display(id: d.cgDisplayID, name: d.label, width: Int(bounds.width),
                                           height: Int(bounds.height), main: CGDisplayIsMain(d.cgDisplayID) != 0,
                                           mirroring: d.isMirroring, streaming: d.isStreaming)
        }
    }

    /// The request a `dam://session/start?app=…` URL asks for, or nil for any other URL, or
    /// for one whose values can't be used, which is logged.
    static func request(from url: URL) -> ControlRequest? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host else { return nil }
        let command = ([host] + url.pathComponents.filter { $0 != "/" }).joined(separator: ".")
        var query = Dictionary((components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
                               uniquingKeysWith: { _, last in last })
        guard ControlRequest.commands.contains(command) else { return nil }
        // The client's ID either way it is spelled.
        if let id = query["clientID"] { query["client-id"] = id }
        do {
            return try ControlRequest.make(command, fields: query)
        } catch {
            NSLog("\(AppIdentity.name): \(url.absoluteString): \((error as? ControlRequest.Invalid)?.message ?? "\(error)")")
            return nil
        }
    }
}
