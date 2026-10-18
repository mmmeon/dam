//
//  RemoteSessions.swift
//
//  Remote sessions: another app (Sunshine, RustDesk, Parsec, Screen Sharing, …) streaming the
//  Mac to someone. A profile per app says what DAM does while one of its sessions is on: make
//  a streaming display for it, place it, and switch the sound output. Everything is put back
//  once the session ends. Sessions start and end through the control socket and URL scheme
//  (ControlSocket.swift), or as DAM sees them happen.
//

import CoreGraphics
import Foundation
import os.log

private let rsLog = Logger(subsystem: AppIdentity.bundleID, category: "RemoteSessions")

/// The apps DAM knows sessions of, by the ID they are asked for by (`--app`). Others can be
/// asked for too; they get the default profile and are shown by their ID.
enum RemoteSessionApp {
    static let known: [(id: String, name: String)] = [
        ("sunshine", "Sunshine"),
        ("rustdesk", "RustDesk"),
        ("parsec", "Parsec"),
        ("screensharing", "Screen Sharing"),
        ("chromeremotedesktop", "Chrome Remote Desktop"),
        ("teamviewer", "TeamViewer"),
        ("display", "Another App's Display")
    ]

    static func name(of id: String) -> String { known.first { $0.id == id }?.name ?? id }
}

/// What DAM does while a session of one app is on.
struct SessionProfile: Codable, Equatable {
    enum DisplayChoice: String, Codable {
        /// Leaves the displays alone.
        case none
        /// Makes a streaming display for the session and removes it after.
        case create
        /// Places the display the app makes itself, found by `adoptName`, and leaves it to
        /// the app to remove.
        case adopt
    }

    enum Placement: String, Codable {
        /// Right of the other displays, as streaming displays go.
        case extend
        /// The main display, with the menu bar and Dock.
        case main
        /// Shown on every other display, which mirror it.
        case mirror
    }

    var enabled = true
    /// Whether DAM watches for the app's sessions itself (see SessionDetectors.swift), for
    /// an app that can't start them through the command line.
    var watch = false
    var display: DisplayChoice = .create
    /// The size to make the display, in pixels; nil for the client's when the app says it,
    /// else 1920 × 1080.
    var width: Int?
    var height: Int?
    /// Its refresh rate; nil for the client's frame rate when the app says it, else 60.
    var refreshRate: Int?
    var placement: Placement = .extend
    /// The sound output for the session, by UID; nil leaves the output alone.
    var audioOutputUID: String?
    /// Part of the name of the display the app makes, for `.adopt`: "Parsec", "Jump".
    var adoptName: String?

    init() {}

    // Missing keys take their defaults, so profiles saved by an older DAM still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        watch = try c.decodeIfPresent(Bool.self, forKey: .watch) ?? false
        display = try c.decodeIfPresent(DisplayChoice.self, forKey: .display) ?? .create
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        refreshRate = try c.decodeIfPresent(Int.self, forKey: .refreshRate)
        placement = try c.decodeIfPresent(Placement.self, forKey: .placement) ?? .extend
        audioOutputUID = try c.decodeIfPresent(String.self, forKey: .audioOutputUID)
        adoptName = try c.decodeIfPresent(String.self, forKey: .adoptName)
    }

    /// The mode to make the display in, for a client that asked for `width` × `height` at
    /// `fps`, any of which may be unknown.
    func mode(clientWidth: Int?, clientHeight: Int?, clientFPS: Int?) -> StreamingDisplayModes.Mode {
        let fixed = width.flatMap { w in height.map { (w, $0) } }
        let client = clientWidth.flatMap { w in clientHeight.map { (w, $0) } }
        let size = fixed ?? client ?? (StreamingDisplayModes.start.width, StreamingDisplayModes.start.height)
        let fps = refreshRate ?? clientFPS ?? StreamingDisplayModes.start.refreshRate
        return StreamingDisplayModes.forStream(width: size.0, height: size.1, fps: fps)
    }
}

/// The profiles, by app ID, kept in Application Support.
enum SessionProfiles {
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppIdentity.name, isDirectory: true)
            .appendingPathComponent("remote-sessions.json")
    }

    static func load(from url: URL) -> [String: SessionProfile] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        do {
            return try JSONDecoder().decode([String: SessionProfile].self, from: data)
        } catch {
            rsLog.error("profiles: \(error.localizedDescription)")
            return [:]
        }
    }

    static func save(_ profiles: [String: SessionProfile], to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(profiles).write(to: url, options: .atomic)
        } catch {
            rsLog.error("profiles: saving failed: \(error.localizedDescription)")
        }
    }
}

/// A session asked for: whose it is, and what its client wants when the app says.
struct SessionRequest: Equatable {
    var app: String
    /// The client's name, shown in the display's name.
    var client: String?
    /// Something that stays the same for the client, such as its certificate's UUID, which
    /// keeps its display's identity from one session to the next; else its name is used.
    var clientID: String?
    var width: Int?
    var height: Int?
    var fps: Int?
    /// Changes to the app's profile for this session only.
    var display: SessionProfile.DisplayChoice?
    var placement: SessionProfile.Placement?
    var audioOutputUID: String?
    /// The display the app made, when it is already known, for `.adopt`.
    var adoptedDisplayID: CGDirectDisplayID?

    /// The app's profile with this request's changes.
    func applied(to profile: SessionProfile) -> SessionProfile {
        var profile = profile
        if let display { profile.display = display }
        if let placement { profile.placement = placement }
        if let audioOutputUID { profile.audioOutputUID = audioOutputUID }
        return profile
    }

    /// What the display made for it is called and known by: "Sunshine" or "Sunshine (laptop)".
    var identity: VideoManager.StreamingIdentity {
        let appName = RemoteSessionApp.name(of: app)
        let name = client.map { "\(appName) (\($0))" } ?? appName
        return VideoManager.StreamingIdentity(name: name, seed: "\(app)/\(clientID ?? client ?? "")")
    }
}

enum SessionError: Error, Equatable, CustomStringConvertible {
    /// The app's profile is turned off.
    case disabled(String)
    /// No streaming display could be made, as when there are as many as there can be.
    case noDisplay
    /// No session of the app is on.
    case notActive(String)

    var description: String {
        switch self {
        case .disabled(let app): return "Sessions of \(RemoteSessionApp.name(of: app)) are turned off in \(AppIdentity.name)."
        case .noDisplay: return "No display could be made for the session."
        case .notActive(let app): return "No \(RemoteSessionApp.name(of: app)) session is on."
        }
    }
}

/// A session that started, and what did not go as asked.
struct SessionStart: Equatable {
    /// The display made for it, if one was.
    var displayID: CGDirectDisplayID?
    var warnings: [String] = []
}

/// What the coordinator changes the Mac through, so it can be tested without displays.
protocol SessionDisplays: AnyObject {
    /// Makes a streaming display; `completion` gets its ID once it is placed, or nil.
    func makeDisplay(_ mode: StreamingDisplayModes.Mode, identity: VideoManager.StreamingIdentity,
                     completion: @escaping (CGDirectDisplayID?) -> Void)
    func removeDisplay(_ id: CGDirectDisplayID)
    /// The display online whose name contains `name`, ignoring case, other than DAM's own.
    func findDisplay(named name: String) -> CGDirectDisplayID?
    /// Places display `id` as `placement` says; `completion` gets whether it was done.
    func place(_ id: CGDirectDisplayID, _ placement: SessionProfile.Placement, completion: @escaping (Bool) -> Void)
    var outputUID: String? { get }
    /// Makes the output with `uid` the default; false when it isn't connected.
    func setOutput(uid: String) -> Bool
}

/// Starts and ends sessions, and puts back what they changed.
final class RemoteSessionCoordinator {
    /// One app's session, which any number of its connections can share.
    struct Session: Equatable {
        let app: String
        var client: String?
        /// How many times it was started and not yet ended.
        var count = 1
        /// The display made for it, or the app's own it was given, once it is placed.
        var displayID: CGDirectDisplayID?
        /// Whether DAM made the display, and removes it at the end.
        var madeDisplay = false
        /// Whether it has its own sound output, switched to or already on.
        var ownsOutput = false
        /// Whether it is still being set up.
        var starting = true
        var started = Date()
    }

    private let displays: SessionDisplays
    private let profilesURL: URL?
    private let defaults: UserDefaults
    private(set) var profiles: [String: SessionProfile]
    private(set) var sessions: [String: Session] = [:]
    /// Those waiting for a session being set up, by app.
    private var waiting: [String: [(Result<SessionStart, SessionError>) -> Void]] = [:]
    /// Called whenever a session starts or ends.
    var onChange: (() -> Void)?

    /// The output to go back to once no session wants its own, kept across launches in case
    /// DAM quits with one on.
    private var outputToRestore: String? {
        get { defaults.string(forKey: Self.outputToRestoreKey) }
        set { defaults.set(newValue, forKey: Self.outputToRestoreKey) }
    }
    private static let outputToRestoreKey = "\(AppIdentity.shortID).remoteSessions.outputToRestore"

    init(displays: SessionDisplays, profilesURL: URL? = SessionProfiles.defaultURL, defaults: UserDefaults = .dam) {
        self.displays = displays
        self.profilesURL = profilesURL
        self.defaults = defaults
        profiles = profilesURL.map(SessionProfiles.load(from:)) ?? [:]
        // A session was on when DAM last quit; its display went with it, the output didn't.
        if let uid = outputToRestore {
            rsLog.debug("putting back the output from before the last session")
            _ = displays.setOutput(uid: uid)
            outputToRestore = nil
        }
    }

    func profile(for app: String) -> SessionProfile {
        if let profile = profiles[app] { return profile }
        var profile = SessionProfile()
        // Another app's display is there to be placed, not made.
        if app == "display" { profile.display = .adopt }
        return profile
    }

    func setProfile(_ profile: SessionProfile, for app: String) {
        profiles[app] = profile
        if let profilesURL { SessionProfiles.save(profiles, to: profilesURL) }
    }

    /// Starts a session of `request.app`, or joins the one on; `completion` runs once its
    /// display is placed and its output switched.
    func begin(_ request: SessionRequest, completion: @escaping (Result<SessionStart, SessionError>) -> Void) {
        let app = request.app
        if var session = sessions[app] {
            session.count += 1
            sessions[app] = session
            rsLog.debug("\(app): joined, \(session.count) on")
            if session.starting {
                waiting[app, default: []].append(completion)
            } else {
                completion(.success(SessionStart(displayID: session.displayID)))
            }
            return
        }
        let profile = request.applied(to: profile(for: app))
        guard profile.enabled else { return completion(.failure(.disabled(app))) }
        rsLog.debug("\(app): starting for \(request.client ?? "a client")")
        sessions[app] = Session(app: app, client: request.client)
        waiting[app] = [completion]
        onChange?()

        switch profile.display {
        case .none:
            switchOutput(app, profile: profile, start: SessionStart())
        case .create:
            let mode = profile.mode(clientWidth: request.width, clientHeight: request.height, clientFPS: request.fps)
            displays.makeDisplay(mode, identity: request.identity) { [weak self] id in
                guard let self else { return }
                guard let id else {
                    rsLog.error("\(app): no display")
                    return self.finish(app, .failure(.noDisplay))
                }
                self.sessions[app]?.madeDisplay = true
                self.place(app, id, profile: profile, start: SessionStart(displayID: id))
            }
        case .adopt:
            let name = profile.adoptName ?? RemoteSessionApp.name(of: app)
            waitForDisplay(named: name, known: request.adoptedDisplayID, attempts: Self.adoptAttempts) { [weak self] id in
                guard let self else { return }
                guard let id else {
                    var start = SessionStart()
                    start.warnings.append("No display called \(name) came.")
                    return self.switchOutput(app, profile: profile, start: start)
                }
                self.place(app, id, profile: profile, start: SessionStart(displayID: id))
            }
        }
    }

    /// How many times to look for the display an app makes, `adoptInterval` apart.
    static let adoptAttempts = 30
    /// How long to wait between looks; shorter in tests.
    var adoptInterval: TimeInterval = 0.5

    /// Finds the display named `name`, or `known`, waiting for it to come; nil if it doesn't.
    private func waitForDisplay(named name: String, known: CGDirectDisplayID?, attempts: Int,
                                completion: @escaping (CGDirectDisplayID?) -> Void) {
        if let id = known ?? displays.findDisplay(named: name) { return completion(id) }
        guard attempts > 1 else { return completion(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + adoptInterval) { [weak self] in
            self?.waitForDisplay(named: name, known: nil, attempts: attempts - 1, completion: completion)
        }
    }

    /// Places `app`'s display `id` as its profile says, then switches the output.
    private func place(_ app: String, _ id: CGDirectDisplayID, profile: SessionProfile, start: SessionStart) {
        sessions[app]?.displayID = id
        guard profile.placement != .extend else { return switchOutput(app, profile: profile, start: start) }
        displays.place(id, profile.placement) { [weak self] placed in
            var start = start
            if !placed { start.warnings.append("The display couldn't be made \(profile.placement.rawValue).") }
            self?.switchOutput(app, profile: profile, start: start)
        }
    }

    /// Switches the output for `app`'s session if its profile names one, then reports.
    private func switchOutput(_ app: String, profile: SessionProfile, start: SessionStart) {
        var start = start
        if let uid = profile.audioOutputUID {
            let previous = displays.outputUID
            if uid == previous {
                sessions[app]?.ownsOutput = true
            } else if displays.setOutput(uid: uid) {
                // The first to switch keeps what was there before any session.
                if outputToRestore == nil { outputToRestore = previous }
                sessions[app]?.ownsOutput = true
            } else {
                start.warnings.append("The sound output for the session couldn't be switched to: it isn't connected, or can't be the output.")
            }
        }
        finish(app, .success(start))
    }

    /// Reports to everyone waiting for `app`'s session, and ends it if that was asked for
    /// meanwhile or it failed.
    private func finish(_ app: String, _ result: Result<SessionStart, SessionError>) {
        let completions = waiting.removeValue(forKey: app) ?? []
        if case .failure = result {
            sessions[app] = nil
        } else {
            sessions[app]?.starting = false
        }
        for completion in completions { completion(result) }
        // Ended while it was being set up.
        if let session = sessions[app], session.count <= 0 { end(app: app, all: true) }
        onChange?()
    }

    /// Ends one start of `app`'s session, or every one with `all`; the last puts back what
    /// the session changed.
    @discardableResult
    func end(app: String, all: Bool = false) -> Result<Void, SessionError> {
        guard var session = sessions[app] else { return .failure(.notActive(app)) }
        session.count = all ? 0 : session.count - 1
        guard session.count <= 0 else {
            sessions[app] = session
            rsLog.debug("\(app): left, \(session.count) on")
            return .success(())
        }
        // Ended once it is set up (see finish).
        guard !session.starting else {
            sessions[app] = session
            return .success(())
        }
        rsLog.debug("\(app): ended")
        sessions[app] = nil
        // Removing the display puts the other displays back as they were before it came.
        if let id = session.displayID, session.madeDisplay { displays.removeDisplay(id) }
        if session.ownsOutput, !sessions.values.contains(where: \.ownsOutput), let uid = outputToRestore {
            if !displays.setOutput(uid: uid) { rsLog.error("\(app): the output from before isn't connected") }
            outputToRestore = nil
        }
        onChange?()
        return .success(())
    }

    /// Ends every session, as when DAM quits.
    func endAll() {
        for app in sessions.keys { end(app: app, all: true) }
    }
}

/// The coordinator's changes, made through VideoManager and AudioManager.
final class LiveSessionDisplays: SessionDisplays {
    private let video: VideoManager
    private let audio: AudioManager

    init(video: VideoManager, audio: AudioManager) {
        self.video = video
        self.audio = audio
    }

    func makeDisplay(_ mode: StreamingDisplayModes.Mode, identity: VideoManager.StreamingIdentity,
                     completion: @escaping (CGDirectDisplayID?) -> Void) {
        video.createStreamingDisplay(mode: mode, identity: identity, completion: completion)
    }

    func removeDisplay(_ id: CGDirectDisplayID) { video.removeStreamingDisplay(id: id) }

    func findDisplay(named name: String) -> CGDirectDisplayID? {
        guard !name.isEmpty else { return nil }
        return displayNames.first { $0.name.localizedCaseInsensitiveContains(name) }?.id
    }

    /// The online displays' IDs and names, other than DAM's own.
    var displayNames: [(id: CGDirectDisplayID, name: String)] {
        video.allConnectedDisplays.filter { $0.cgDisplayID != 0 && !$0.isStreaming }.map { ($0.cgDisplayID, $0.name) }
    }

    func place(_ id: CGDirectDisplayID, _ placement: SessionProfile.Placement, completion: @escaping (Bool) -> Void) {
        guard let display = video.allConnectedDisplays.first(where: { $0.cgDisplayID == id }) else {
            return completion(false)
        }
        let done: (Result<Void, VideoManager.MirrorError>) -> Void = { result in
            if case .failure(let error) = result { rsLog.error("place \(id): \(String(describing: error))") }
            completion((try? result.get()) != nil)
        }
        switch placement {
        case .extend: completion(true)
        case .main: video.setMainDisplay(display, completion: done)
        case .mirror: video.mirror(display, on: video.mirrorTargets(for: display), completion: done)
        }
    }

    var outputUID: String? { audio.defaultDeviceUID }

    func setOutput(uid: String) -> Bool { audio.setDefaultDevice(uid: uid) }

    /// The UID of the output named or with UID `nameOrUID`, matching names without regard to case.
    func outputUID(matching nameOrUID: String) -> String? {
        if AudioManager.deviceID(forUID: nameOrUID) != nil { return nameOrUID }
        let device = audio.allOutputDevices.first {
            $0.name.caseInsensitiveCompare(nameOrUID) == .orderedSame
                || $0.label.caseInsensitiveCompare(nameOrUID) == .orderedSame
        }
        return device.flatMap { AudioManager.uid(of: $0.id) }
    }
}
