//
//  RemoteSessions.swift
//
//  Remote sessions: another app (Sunshine, RustDesk, Parsec, Screen Sharing, …) streaming the
//  Mac to someone. A profile per app says what DAM does while one of its sessions is on: make
//  a streaming display for it, place it, and switch the sound output. Everything is put back
//  once the session ends. What is changed through DAM during a session is kept in the profile
//  for the next one, but for the settings picked in Settings. Sessions start and end through
//  the control socket and URL scheme (ControlSocket.swift), or as DAM sees them happen.
//

import CoreGraphics
import Foundation
import os.log

private let rsLog = Logger(subsystem: AppIdentity.bundleID, category: "RemoteSessions")

/// The apps DAM knows sessions of, by the ID they are asked for by (`--app`). Others can be
/// asked for too; they get the default profile and are shown by their ID, or by the name
/// they were added under in Settings.
enum RemoteSessionApp {
    static let known: [(id: String, name: String)] = [
        ("sunshine", "Sunshine"),
        ("rustdesk", "RustDesk"),
        ("parsec", "Parsec"),
        ("screensharing", "Screen Sharing"),
        ("chromeremotedesktop", "Chrome Remote Desktop"),
        ("teamviewer", "TeamViewer"),
        ("opendisplay", "OpenDisplay"),
        ("display", "Another App's Display")
    ]

    /// The names of the apps added in Settings, by ID; kept by the coordinator.
    static var added: [String: String] = [:]

    static func name(of id: String) -> String { known.first { $0.id == id }?.name ?? added[id] ?? id }

    /// An ID for an app added as `name`, other than `taken`: "Jump Desktop" gives "jump-desktop".
    static func id(forName name: String, taken: Set<String>) -> String {
        let words = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let base = words.isEmpty ? "app" : words.joined(separator: "-")
        let used = taken.union(known.map(\.id))
        var id = base
        var n = 2
        while used.contains(id) { id = "\(base)-\(n)"; n += 1 }
        return id
    }
}

/// How DAM tells when an app added in Settings starts and ends a session.
struct SessionDetection: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        /// Lines in its log: one matching `opened` starts a connection, one matching `closed` ends it.
        case log
        /// A process that runs only while someone is connected.
        case process
        /// A display it makes for each session, by part of its name (the profile's `adoptName`).
        case display
    }

    var kind: Kind = .log
    var logPath = ""
    /// Regular expressions; see SessionLogLines.custom.
    var opened = ""
    var closed = ""
    var processName = ""
    /// For `.log`: the process the app runs, if given. Its connections end when it quits, and
    /// a line opening one counts only while it runs.
    var logProcessName = ""

    init(kind: Kind = .log) { self.kind = kind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .log
        logPath = try c.decodeIfPresent(String.self, forKey: .logPath) ?? ""
        opened = try c.decodeIfPresent(String.self, forKey: .opened) ?? ""
        closed = try c.decodeIfPresent(String.self, forKey: .closed) ?? ""
        processName = try c.decodeIfPresent(String.self, forKey: .processName) ?? ""
        logProcessName = try c.decodeIfPresent(String.self, forKey: .logProcessName) ?? ""
    }

    /// The log's file, with `~` for the home folder.
    var logURL: URL { URL(fileURLWithPath: (logPath as NSString).expandingTildeInPath) }

    /// What is missing or wrong for DAM to watch, or nil when it can; `adoptName` is the
    /// profile's, for `.display`.
    func problem(adoptName: String?) -> String? {
        switch kind {
        case .log:
            if logPath.isEmpty { return "Choose its log file." }
            if opened.isEmpty || closed.isEmpty { return "Give the lines that open and close a connection." }
            if (try? NSRegularExpression(pattern: opened)) == nil { return "The opened pattern isn't a valid regular expression." }
            if (try? NSRegularExpression(pattern: closed)) == nil { return "The closed pattern isn't a valid regular expression." }
        case .process:
            if processName.isEmpty { return "Give the process's name." }
        case .display:
            if adoptName?.isEmpty ?? true { return "Give part of its display's name." }
        }
        return nil
    }
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

    /// A setting that can be picked in Settings, or follow what is changed during sessions.
    enum Setting: String, Codable, CaseIterable {
        case placement, size, audio, blackout
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
    /// Whether the Mac's own screens go black while the session is on (LocalBlackout.swift).
    var blackout = false
    /// The settings picked in Settings. A change made through DAM during a session is kept
    /// for the next session in the others, and leaves these as they are.
    var locked: Set<Setting> = []
    /// For an app added in Settings: its name, and how its sessions are told.
    var name: String?
    var detection: SessionDetection?

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
        blackout = try c.decodeIfPresent(Bool.self, forKey: .blackout) ?? false
        locked = try c.decodeIfPresent(Set<Setting>.self, forKey: .locked) ?? []
        name = try c.decodeIfPresent(String.self, forKey: .name)
        detection = try c.decodeIfPresent(SessionDetection.self, forKey: .detection)
    }

    /// Whether the app was added in Settings.
    var isAdded: Bool { detection != nil }

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
    /// What asked for a session, or for its end.
    enum Origin: Equatable {
        /// The command line or the control socket, both this user's own.
        case command
        /// A `dam://` link, which any page or app can open.
        case link
        /// A detector DAM runs (SessionDetectors.swift), which ends what it started.
        case detector
    }

    var app: String
    var origin: Origin = .command
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
    var blackout: Bool?
    /// The display the app made, when it is already known, for `.adopt`.
    var adoptedDisplayID: CGDirectDisplayID?

    /// The app's profile with this request's changes.
    func applied(to profile: SessionProfile) -> SessionProfile {
        var profile = profile
        if let display { profile.display = display }
        if let placement { profile.placement = placement }
        if let audioOutputUID { profile.audioOutputUID = audioOutputUID }
        if let blackout { profile.blackout = blackout }
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
    /// A link asked to end or join a session that something else started.
    case notFromLink(String)
    /// A link asked to black out the screens.
    case blackoutFromLink

    var description: String {
        switch self {
        case .disabled(let app): return "Sessions of \(RemoteSessionApp.name(of: app)) are turned off in \(AppIdentity.name)."
        case .noDisplay: return "No display could be made for the session."
        case .notActive(let app): return "No \(RemoteSessionApp.name(of: app)) session is on."
        case .notFromLink(let app):
            return "The \(RemoteSessionApp.name(of: app)) session wasn't started by a link, so a link can't end or join it."
        case .blackoutFromLink:
            return "A link can't black out the screens; the command line can."
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
    /// Makes a streaming display, main already when `main`; `completion` gets its ID once it
    /// is placed, or nil.
    func makeDisplay(_ mode: StreamingDisplayModes.Mode, identity: VideoManager.StreamingIdentity, main: Bool,
                     completion: @escaping (CGDirectDisplayID?) -> Void)
    func removeDisplay(_ id: CGDirectDisplayID)
    /// The display online whose name contains `name`, ignoring case, other than DAM's own.
    func findDisplay(named name: String) -> CGDirectDisplayID?
    /// Whether display `id` is online and known, other than DAM's own; it can be placed then.
    func isListed(_ id: CGDirectDisplayID) -> Bool
    /// Places display `id` as `placement` says; `completion` gets whether it was done.
    func place(_ id: CGDirectDisplayID, _ placement: SessionProfile.Placement, completion: @escaping (Bool) -> Void)
    var outputUID: String? { get }
    /// Makes the output with `uid` the default; false when it isn't connected.
    func setOutput(uid: String) -> Bool
    /// Blacks out the Mac's screens but `keeping`, or, with nil, lights them again.
    func blackOut(keeping: Set<CGDirectDisplayID>?)
    /// How display `id` is placed now, as chosen through DAM; nil when it is gone.
    func placement(of id: CGDirectDisplayID) -> SessionProfile.Placement?
    /// Display `id`'s mode now, before any turn DAM gives it, or nil when it is gone.
    func mode(of id: CGDirectDisplayID) -> StreamingDisplayModes.Mode?
    /// While true, changes made to the displays leave the layout put back after the
    /// sessions as it was before them.
    func holdLayout(_ hold: Bool)
}

/// Starts and ends sessions, and puts back what they changed.
final class RemoteSessionCoordinator {
    /// One app's session, which any number of its connections can share.
    struct Session: Equatable {
        let app: String
        var client: String?
        /// Its app's profile with the changes its request asked for.
        var profile = SessionProfile()
        /// The sound output when it started.
        var outputAtStart: String?
        /// How many times it was started and not yet ended.
        var count = 1
        /// How many of those were by `dam://` links: a link ends only these.
        var fromLinks = 0
        /// The display made for it, or the app's own it was given, once it is placed.
        var displayID: CGDirectDisplayID?
        /// Whether DAM made the display, and removes it at the end.
        var madeDisplay = false
        /// The mode DAM made it in.
        var madeMode: StreamingDisplayModes.Mode?
        /// What setting up came to, which may not be what was asked: the display's mode
        /// once made, its placement once placed, and the output once switched, or as another
        /// session's end put it back. Only what is neither this nor what was asked is learned.
        var modeAtStart: StreamingDisplayModes.Mode?
        var placementAtStart: SessionProfile.Placement?
        var outputAfterStart: String?
        /// Whether it has its own sound output, switched to or already on.
        var ownsOutput = false
        /// Whether it blacks out the Mac's screens.
        var blacksOut = false
        /// Whether it lasts as long as the app's own display or stream, which DAM can't end:
        /// ending it would leave the app streaming. Only for one a detector started, which
        /// ends it too.
        var followsApp = false
        /// Whether it is still being set up.
        var starting = true
        var started = Date()
        /// Tells it from a later session of the same app.
        let id = UUID()
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
    /// Called when a profile takes on what was changed during a session.
    var onLearn: (() -> Void)?

    /// The output to go back to once no session wants its own, kept across launches in case
    /// DAM quits with one on.
    private var outputToRestore: String? {
        get { defaults.string(forKey: Self.outputToRestoreKey) }
        set { defaults.set(newValue, forKey: Self.outputToRestoreKey) }
    }
    private static let outputToRestoreKey = "\(AppIdentity.shortID).remoteSessions.outputToRestore"

    /// The output from before the first of the sessions on, put back after the last even if
    /// it was changed during them; kept across launches like `outputToRestore`.
    private var outputBeforeSessions: String? {
        get { defaults.string(forKey: Self.outputBeforeSessionsKey) }
        set { defaults.set(newValue, forKey: Self.outputBeforeSessionsKey) }
    }
    private static let outputBeforeSessionsKey = "\(AppIdentity.shortID).remoteSessions.outputBeforeSessions"

    init(displays: SessionDisplays, profilesURL: URL? = SessionProfiles.defaultURL, defaults: UserDefaults = .dam) {
        self.displays = displays
        self.profilesURL = profilesURL
        self.defaults = defaults
        profiles = profilesURL.map(SessionProfiles.load(from:)) ?? [:]
        noteAddedNames()
        // A session was on when DAM last quit; its display went with it, the output didn't.
        if let uid = outputBeforeSessions ?? outputToRestore {
            rsLog.debug("putting back the output from before the last session")
            _ = displays.setOutput(uid: uid)
            outputToRestore = nil
            outputBeforeSessions = nil
        }
    }

    func profile(for app: String) -> SessionProfile {
        if let profile = profiles[app] { return profile }
        var profile = SessionProfile()
        // Another app's display is there to be placed, not made.
        if app == "display" || app == "opendisplay" { profile.display = .adopt }
        // Parsec and RustDesk stream the main display, whichever that is when the display is placed.
        if app == "parsec" || app == "rustdesk" { profile.placement = .main }
        return profile
    }

    func setProfile(_ profile: SessionProfile, for app: String) {
        profiles[app] = profile
        noteAddedNames()
        if let profilesURL { SessionProfiles.save(profiles, to: profilesURL) }
    }

    /// The apps added in Settings, by name.
    var addedApps: [String] {
        profiles.filter(\.value.isAdded).sorted {
            ($0.value.name ?? $0.key).localizedStandardCompare($1.value.name ?? $1.key) == .orderedAscending
        }.map(\.key)
    }

    /// Adds an app named `name` whose sessions are told as `kind` says, and returns its ID.
    func addApp(named name: String, kind: SessionDetection.Kind = .log) -> String {
        let id = RemoteSessionApp.id(forName: name, taken: Set(profiles.keys))
        var profile = SessionProfile()
        profile.name = name
        profile.detection = SessionDetection(kind: kind)
        profile.watch = true
        if kind == .display { profile.display = .adopt }
        setProfile(profile, for: id)
        return id
    }

    /// Removes an app added in Settings, ending its session if one is on.
    func removeApp(_ app: String) {
        guard profiles[app]?.isAdded == true else { return }
        if sessions[app] != nil { end(app: app, all: true) }
        profiles[app] = nil
        noteAddedNames()
        if let profilesURL { SessionProfiles.save(profiles, to: profilesURL) }
    }

    private func noteAddedNames() {
        RemoteSessionApp.added = profiles.filter(\.value.isAdded).mapValues { $0.name ?? "" }.filter { !$0.value.isEmpty }
    }

    /// Starts a session of `request.app`, or joins the one on; `completion` runs once its
    /// display is placed and its output switched. A link joins only a session links started:
    /// joining another would leave it on once the app's own end came. Nor does a link black
    /// out the screens, which would leave whoever is at the Mac in the dark at any page's
    /// asking: one that asks to is refused, and a profile's blackout is left off for it.
    func begin(_ request: SessionRequest, completion: @escaping (Result<SessionStart, SessionError>) -> Void) {
        let app = request.app
        if request.origin == .link, request.blackout == true { return completion(.failure(.blackoutFromLink)) }
        if var session = sessions[app] {
            if request.origin == .link, session.fromLinks < session.count {
                return completion(.failure(.notFromLink(app)))
            }
            session.count += 1
            if request.origin == .link { session.fromLinks += 1 }
            sessions[app] = session
            rsLog.debug("\(app): joined, \(session.count) on")
            if session.starting {
                waiting[app, default: []].append(completion)
            } else {
                completion(.success(SessionStart(displayID: session.displayID)))
            }
            return
        }
        var profile = request.applied(to: profile(for: app))
        guard profile.enabled else { return completion(.failure(.disabled(app))) }
        var first = SessionStart()
        if request.origin == .link, profile.blackout {
            profile.blackout = false
            first.warnings.append("The screens weren't blacked out, as a link can't black them out.")
        }
        rsLog.debug("\(app): starting for \(request.client ?? "a client")")
        if sessions.isEmpty {
            outputBeforeSessions = displays.outputUID
            displays.holdLayout(true)
        }
        var session = Session(app: app, client: request.client, profile: profile, outputAtStart: displays.outputUID)
        session.fromLinks = request.origin == .link ? 1 : 0
        // Mirroring, OpenDisplay asks for no display, but its profile still adopts. Only a
        // detector's session: nothing else would see the app's end.
        session.followsApp = request.origin == .detector
            && (profile.display == .adopt || self.profile(for: app).display == .adopt)
        let id = session.id
        sessions[app] = session
        waiting[app] = [completion]
        onChange?()

        switch profile.display {
        case .none:
            switchOutput(app, profile: profile, start: first)
        case .create:
            let mode = profile.mode(clientWidth: request.width, clientHeight: request.height, clientFPS: request.fps)
            // Main in the commit that places it: one commit fewer, each of which can take
            // seconds while the app is already capturing the main display.
            displays.makeDisplay(mode, identity: request.identity, main: profile.placement == .main) { [weak self] displayID in
                guard let self else { return }
                // Given up on meanwhile, as when DAM quits: nothing else would remove it.
                guard self.sessions[app]?.id == id else {
                    if let displayID { self.displays.removeDisplay(displayID) }
                    return
                }
                guard let displayID else {
                    rsLog.error("\(app): no display")
                    return self.finish(app, .failure(.noDisplay))
                }
                self.sessions[app]?.madeDisplay = true
                self.sessions[app]?.madeMode = mode
                self.sessions[app]?.modeAtStart = self.displays.mode(of: displayID) ?? mode
                var start = first
                start.displayID = displayID
                self.place(app, displayID, profile: profile, start: start)
            }
        case .adopt:
            let name = profile.adoptName ?? RemoteSessionApp.name(of: app)
            waitForDisplay(named: name, known: request.adoptedDisplayID, attempts: Self.adoptAttempts) { [weak self] displayID in
                guard let self, self.sessions[app]?.id == id else { return }
                var start = first
                guard let displayID else {
                    start.warnings.append("No display called \(name) came.")
                    // Nothing of the session's to leave lit, so every screen would go black.
                    var profile = profile
                    if profile.blackout {
                        profile.blackout = false
                        start.warnings.append("The screens weren't blacked out, as the session has no display to leave lit.")
                    }
                    return self.switchOutput(app, profile: profile, start: start)
                }
                start.displayID = displayID
                self.place(app, displayID, profile: profile, start: start)
            }
        }
    }

    /// How many times to look for the display an app makes, `adoptInterval` apart.
    static let adoptAttempts = 30
    /// How long to wait between looks; shorter in tests.
    var adoptInterval: TimeInterval = 0.5

    /// Finds the display named `name`, or `known`, waiting for it to come; nil if it doesn't.
    /// The app can tell of its display before DAM has it listed, and it can't be placed until.
    private func waitForDisplay(named name: String, known: CGDirectDisplayID?, attempts: Int,
                                completion: @escaping (CGDirectDisplayID?) -> Void) {
        let found: CGDirectDisplayID?
        if let known { found = displays.isListed(known) ? known : nil } else { found = displays.findDisplay(named: name) }
        if let id = found { return completion(id) }
        guard attempts > 1 else { return completion(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + adoptInterval) { [weak self] in
            self?.waitForDisplay(named: name, known: known, attempts: attempts - 1, completion: completion)
        }
    }

    /// Places `app`'s display `id` as its profile says, then switches the output.
    private func place(_ app: String, _ id: CGDirectDisplayID, profile: SessionProfile, start: SessionStart) {
        sessions[app]?.displayID = id
        guard profile.placement != .extend else {
            sessions[app]?.placementAtStart = displays.placement(of: id)
            return switchOutput(app, profile: profile, start: start)
        }
        let session = sessions[app]?.id
        displays.place(id, profile.placement) { [weak self] placed in
            guard let self, session != nil, self.sessions[app]?.id == session else { return }
            var start = start
            if !placed { start.warnings.append("The display couldn't be made \(profile.placement.rawValue).") }
            self.sessions[app]?.placementAtStart = self.displays.placement(of: id)
            self.switchOutput(app, profile: profile, start: start)
        }
    }

    /// Switches the output for `app`'s session if its profile names one, blacks out the
    /// screens if it asks to, then reports.
    private func switchOutput(_ app: String, profile: SessionProfile, start: SessionStart) {
        var start = start
        if profile.blackout {
            sessions[app]?.blacksOut = true
            updateBlackout()
        }
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
        sessions[app]?.outputAfterStart = displays.outputUID
        finish(app, .success(start))
    }

    /// Reports to everyone waiting for `app`'s session, and ends it if that was asked for
    /// meanwhile or it failed.
    private func finish(_ app: String, _ result: Result<SessionStart, SessionError>) {
        let completions = waiting.removeValue(forKey: app) ?? []
        if case .failure = result {
            sessions[app] = nil
            // The first failed: nothing to put back but what begin set up.
            if sessions.isEmpty {
                outputBeforeSessions = nil
                displays.holdLayout(false)
            }
        } else {
            sessions[app]?.starting = false
        }
        for completion in completions { completion(result) }
        // Ended while it was being set up.
        if let session = sessions[app], session.count <= 0 { end(app: app, all: true) }
        onChange?()
    }

    /// Ends one start of `app`'s session, or every one with `all`; the last puts back what
    /// the session changed. A link ends only what links started, so a page can't end a
    /// session that the app, a script or a detector started.
    @discardableResult
    func end(app: String, all: Bool = false, from origin: SessionRequest.Origin = .command) -> Result<Void, SessionError> {
        guard var session = sessions[app] else { return .failure(.notActive(app)) }
        if origin == .link {
            guard session.fromLinks > 0 else { return .failure(.notFromLink(app)) }
            let ending = all ? session.fromLinks : 1
            session.fromLinks -= ending
            session.count -= ending
        } else {
            session.count = all ? 0 : session.count - 1
            session.fromLinks = min(session.fromLinks, max(session.count, 0))
        }
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
        learn(from: session)
        // Removing the display puts the other displays back as they were before it came.
        if let id = session.displayID, session.madeDisplay { displays.removeDisplay(id) }
        if session.blacksOut { updateBlackout() }
        if session.ownsOutput, !sessions.values.contains(where: \.ownsOutput), let uid = outputToRestore {
            if !displays.setOutput(uid: uid) { rsLog.error("\(app): the output from before isn't connected") }
            outputToRestore = nil
            // Put back for the others, not changed by them: theirs to compare with, not learn.
            for other in sessions.keys { sessions[other]?.outputAfterStart = displays.outputUID }
        }
        if sessions.isEmpty { putBackAfterSessions(app) }
        onChange?()
        return .success(())
    }

    /// Once the last session has gone: the output from before them, and the layout let go.
    private func putBackAfterSessions(_ app: String) {
        // Changed during the sessions without one of them asking.
        if let uid = outputBeforeSessions, displays.outputUID != uid, !displays.setOutput(uid: uid) {
            rsLog.error("\(app): the output from before isn't connected")
        }
        outputBeforeSessions = nil
        displays.holdLayout(false)
    }

    /// Keeps in the app's profile what was changed through DAM during `session`, which has
    /// just ended, for the next one; but not in the settings locked in Settings. A change is
    /// what is neither what was asked nor what setting up came to: a placement, size or
    /// output that failed is no choice of the user's.
    private func learn(from session: Session) {
        let asked = session.profile
        // An app removed while its session was starting: nothing of it to keep.
        if asked.isAdded && profiles[session.app] == nil { return }
        let saved = profile(for: session.app)
        var next = saved
        // An app's own display can be gone already, ending the session.
        if let id = session.displayID, !saved.locked.contains(.placement),
           let now = displays.placement(of: id), now != asked.placement, now != session.placementAtStart {
            next.placement = now
        }
        func same(_ a: StreamingDisplayModes.Mode, _ b: StreamingDisplayModes.Mode?) -> Bool {
            guard let b else { return false }
            return (a.pixelWidth, a.pixelHeight, a.refreshRate) == (b.pixelWidth, b.pixelHeight, b.refreshRate)
        }
        if session.madeDisplay, let id = session.displayID, let made = session.madeMode,
           !saved.locked.contains(.size), let now = displays.mode(of: id),
           !same(now, made), !same(now, session.modeAtStart) {
            next.width = now.pixelWidth
            next.height = now.pixelHeight
            next.refreshRate = now.refreshRate
        }
        // Not when another session switched it.
        if !saved.locked.contains(.audio), !sessions.values.contains(where: \.ownsOutput),
           let now = displays.outputUID, now != asked.audioOutputUID ?? session.outputAtStart,
           now != session.outputAfterStart {
            next.audioOutputUID = now
        }
        guard next != saved else { return }
        rsLog.debug("\(session.app): keeping the session's changes for the next one")
        setProfile(next, for: session.app)
        onLearn?()
    }

    /// Whether the Mac's screens are blacked out for a session.
    var isBlackedOut: Bool { sessions.values.contains(where: \.blacksOut) }

    /// Blacks out the screens but the sessions' own while a session that asks to is on.
    private func updateBlackout() {
        let wanting = sessions.values.filter(\.blacksOut)
        displays.blackOut(keeping: wanting.isEmpty ? nil : Set(sessions.values.compactMap(\.displayID)))
    }

    /// Lights the screens again, for whoever is at the Mac, until the next session; the next
    /// sessions leave them lit unless blacking out is locked in Settings.
    func liftBlackout() {
        for (app, session) in sessions where session.blacksOut {
            sessions[app]?.blacksOut = false
            var saved = profile(for: app)
            if saved.blackout, !saved.locked.contains(.blackout) {
                saved.blackout = false
                setProfile(saved, for: app)
                onLearn?()
            }
        }
        updateBlackout()
        onChange?()
    }

    /// Ends every session, as when DAM quits.
    func endAll() {
        for app in sessions.keys { end(app: app, all: true) }
        // Those still being set up wait to end once they are (see finish), which a quit
        // doesn't: they are given up on now. Nothing of theirs is switched yet, only their
        // display may be made, so what was kept from before them mustn't be put back by the
        // next launch.
        let starting = sessions.filter(\.value.starting)
        for (app, session) in starting {
            rsLog.debug("\(app): given up on while starting")
            sessions[app] = nil
            if let id = session.displayID, session.madeDisplay { displays.removeDisplay(id) }
            for completion in waiting.removeValue(forKey: app) ?? [] { completion(.failure(.notActive(app))) }
        }
        guard !starting.isEmpty else { return }
        if sessions.isEmpty { putBackAfterSessions("sessions") }
        onChange?()
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

    func makeDisplay(_ mode: StreamingDisplayModes.Mode, identity: VideoManager.StreamingIdentity, main: Bool,
                     completion: @escaping (CGDirectDisplayID?) -> Void) {
        video.createStreamingDisplay(mode: mode, identity: identity, main: main, completion: completion)
    }

    func removeDisplay(_ id: CGDirectDisplayID) { video.removeStreamingDisplay(id: id) }

    func findDisplay(named name: String) -> CGDirectDisplayID? {
        guard !name.isEmpty else { return nil }
        return displayNames.first { $0.name.localizedCaseInsensitiveContains(name) }?.id
    }

    func isListed(_ id: CGDirectDisplayID) -> Bool { displayNames.contains { $0.id == id } }

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

    /// The Mac's own screens: every display but DAM's virtual ones.
    private lazy var blackout = LocalBlackout { [weak video] id in
        guard let video else { return false }
        return !video.streamingDisplayIDs.contains(id) && CGDisplayVendorNumber(id) != VideoManager.anchorVendorID
    }

    func blackOut(keeping: Set<CGDirectDisplayID>?) {
        if let keeping { blackout.start(keeping: keeping) } else { blackout.stop() }
    }

    /// Mirrored when every display it can be mirrored on mirrors it, main when it is main;
    /// mirrored only when that was done through DAM, not by WindowServer applying a layout
    /// it saved, and for a streaming display main the same way.
    func placement(of id: CGDirectDisplayID) -> SessionProfile.Placement? {
        guard let display = video.allConnectedDisplays.first(where: { $0.cgDisplayID == id }) else { return nil }
        let targets = video.mirrorTargets(for: display).map(\.cgDisplayID).filter { $0 != 0 }
        // An anchored iPad is mirrored through its anchor.
        let mirroredByChoice = ([id] + (video.anchorID(driving: id).map { [$0] } ?? []))
            .contains(where: video.displaysMirroredByChoice.contains)
        if mirroredByChoice, !targets.isEmpty, targets.allSatisfy({ video.userMirrorMaster(of: $0) == id }) {
            return .mirror
        }
        let mainByChoice = !display.isStreaming || video.streamingDisplayIsMainByChoice
        return CGDisplayIsMain(id) != 0 && mainByChoice ? .main : .extend
    }

    func mode(of id: CGDirectDisplayID) -> StreamingDisplayModes.Mode? {
        guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
        return Self.mode(width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth,
                         refreshRate: mode.refreshRate, turned: video.streamingRotation(of: id))
    }

    /// The mode of a display shown at `width` × `height` and turned by `turned`, as it was
    /// asked for: a streaming display kept turned is made at the turned size, which would
    /// otherwise look like a change of size each session.
    static func mode(width: Int, height: Int, pixelWidth: Int, refreshRate: Double,
                     turned: DisplayRotation?) -> StreamingDisplayModes.Mode {
        StreamingDisplayModes.Mode(width: width, height: height, refreshRate: Int(refreshRate.rounded()),
                                   hiDPI: pixelWidth > width).rotated((turned ?? .standard).inverse)
    }

    func holdLayout(_ hold: Bool) { video.holdsStreamingArrangement = hold }

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
