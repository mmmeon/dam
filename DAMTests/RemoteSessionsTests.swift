import XCTest
import CoreGraphics
@testable import DAM

/// Stands in for the displays and sound outputs, recording what the coordinator asks.
private final class FakeSessionDisplays: SessionDisplays {
    var made: [(mode: StreamingDisplayModes.Mode, identity: VideoManager.StreamingIdentity)] = []
    /// Those of `made` asked to be main as they were placed.
    var madeMain: [VideoManager.StreamingIdentity] = []
    var removed: [CGDirectDisplayID] = []
    var placed: [(CGDirectDisplayID, SessionProfile.Placement)] = []
    var outputUID: String? = "speakers"
    var connectedOutputs: Set<String> = ["speakers", "blackhole"]
    /// The ID the next display gets, or nil for none.
    var nextID: CGDirectDisplayID? = 100
    var placeSucceeds = true
    /// Displays asked for and not yet made; nil makes them at once.
    var pendingMakes: [() -> Void]?
    /// The mode displays come in, when not the one asked for.
    var madeAs: StreamingDisplayModes.Mode?

    func makeDisplay(_ mode: StreamingDisplayModes.Mode, identity: VideoManager.StreamingIdentity, main: Bool,
                     completion: @escaping (CGDirectDisplayID?) -> Void) {
        made.append((mode, identity))
        if main { madeMain.append(identity) }
        let id = nextID
        if let id { modes[id] = madeAs ?? mode }
        if pendingMakes != nil { pendingMakes?.append { completion(id) } } else { completion(id) }
    }

    func removeDisplay(_ id: CGDirectDisplayID) { removed.append(id) }

    /// Displays other apps made, by name.
    var others: [String: CGDirectDisplayID] = [:]

    func findDisplay(named name: String) -> CGDirectDisplayID? {
        others.first { $0.key.localizedCaseInsensitiveContains(name) }?.value
    }

    func isListed(_ id: CGDirectDisplayID) -> Bool { others.values.contains(id) }

    func place(_ id: CGDirectDisplayID, _ placement: SessionProfile.Placement, completion: @escaping (Bool) -> Void) {
        placed.append((id, placement))
        if placeSucceeds {
            // One main display, which another's taking main makes extended.
            if placement == .main { for (other, was) in placements where was == .main { placements[other] = .extend } }
            placements[id] = placement
        }
        completion(placeSucceeds)
    }

    var unplaced: [(CGDirectDisplayID, SessionProfile.Placement, main: CGDirectDisplayID?)] = []
    var mainDisplayID: CGDirectDisplayID? = 1

    func unplace(_ id: CGDirectDisplayID, _ placement: SessionProfile.Placement, main: CGDirectDisplayID?) {
        unplaced.append((id, placement, main))
        placements[id] = .extend
    }

    /// How each display is placed and its mode now; tests change them as a user would.
    var placements: [CGDirectDisplayID: SessionProfile.Placement] = [:]
    var modes: [CGDirectDisplayID: StreamingDisplayModes.Mode] = [:]
    var holdsLayout = false

    /// Displays gone offline.
    var gone: Set<CGDirectDisplayID> = []

    func placement(of id: CGDirectDisplayID) -> SessionProfile.Placement? {
        gone.contains(id) ? nil : placements[id] ?? .extend
    }
    func mode(of id: CGDirectDisplayID) -> StreamingDisplayModes.Mode? { modes[id] }
    func holdLayout(_ hold: Bool) { holdsLayout = hold }

    /// The displays kept lit while blacked out, or nil when not.
    var blackoutKeeping: Set<CGDirectDisplayID>?

    func blackOut(keeping: Set<CGDirectDisplayID>?) { blackoutKeeping = keeping }

    func setOutput(uid: String) -> Bool {
        guard connectedOutputs.contains(uid) else { return false }
        outputUID = uid
        return true
    }
}

/// A detector whose events a test sends through `onEvent`.
private final class ScriptedDetector: SessionDetector {
    let app: String
    var onEvent: ((SessionEvent) -> Void)?
    init(app: String) { self.app = app }
    func start() {}
    func stop() {}
}

final class RemoteSessionsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "RemoteSessionsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func coordinator(_ fake: FakeSessionDisplays, profiles: [String: SessionProfile] = [:]) -> RemoteSessionCoordinator {
        let c = RemoteSessionCoordinator(displays: fake, profilesURL: nil, defaults: defaults)
        for (app, profile) in profiles { c.setProfile(profile, for: app) }
        return c
    }

    private func start(_ c: RemoteSessionCoordinator, _ request: SessionRequest) -> Result<SessionStart, SessionError>? {
        var result: Result<SessionStart, SessionError>?
        c.begin(request) { result = $0 }
        return result
    }

    // MARK: - Display identity

    func testSeededSerialIsStableAndApartFromSlotSerials() {
        let a = VideoManager.streamingSerial(seed: "sunshine/laptop")
        XCTAssertEqual(a, VideoManager.streamingSerial(seed: "sunshine/laptop"))
        XCTAssertNotEqual(a, VideoManager.streamingSerial(seed: "sunshine/ipad"))
        for index in 0..<VideoManager.maxStreamingDisplays {
            XCTAssertNotEqual(a, VideoManager.streamingSerial(index))
        }
        XCTAssertEqual(a & 0x8000_0000, 0x8000_0000)
    }

    func testRequestIdentityNamesTheAppAndClient() {
        let named = SessionRequest(app: "sunshine", client: "laptop").identity
        XCTAssertEqual(named.name, "Sunshine (laptop)")
        XCTAssertEqual(named.seed, "sunshine/laptop")
        let byID = SessionRequest(app: "sunshine", client: "laptop", clientID: "ABC").identity
        XCTAssertEqual(byID.seed, "sunshine/ABC")
        XCTAssertEqual(SessionRequest(app: "rustdesk").identity.name, "RustDesk")
        XCTAssertEqual(SessionRequest(app: "myapp").identity.name, "myapp")
    }

    // MARK: - Profiles

    func testProfileFillsInMissingKeys() throws {
        let profile = try JSONDecoder().decode(SessionProfile.self, from: Data(#"{"placement":"main"}"#.utf8))
        XCTAssertTrue(profile.enabled)
        XCTAssertEqual(profile.display, .create)
        XCTAssertEqual(profile.placement, .main)
        XCTAssertNil(profile.audioOutputUID)
    }

    func testParsecAndRustDeskDefaultToMain() {
        let c = coordinator(FakeSessionDisplays())
        XCTAssertEqual(c.profile(for: "parsec").placement, .main)
        XCTAssertEqual(c.profile(for: "rustdesk").placement, .main)
        XCTAssertEqual(c.profile(for: "screensharing").placement, .extend)
    }

    func testProfilesRoundTripThroughTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/remote-sessions.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var profile = SessionProfile()
        profile.width = 1280
        profile.height = 800
        profile.audioOutputUID = "blackhole"
        profile.placement = .mirror
        SessionProfiles.save(["rustdesk": profile], to: url)
        XCTAssertEqual(SessionProfiles.load(from: url), ["rustdesk": profile])
    }

    func testModePrefersTheProfilesSizeThenTheClients() {
        var profile = SessionProfile()
        XCTAssertEqual(profile.mode(clientWidth: nil, clientHeight: nil, clientFPS: nil), StreamingDisplayModes.start)
        XCTAssertEqual(profile.mode(clientWidth: 1280, clientHeight: 800, clientFPS: 30),
                       StreamingDisplayModes.Mode(width: 1280, height: 800, refreshRate: 30))
        // As sharp as a Mac would show it.
        XCTAssertEqual(profile.mode(clientWidth: 2560, clientHeight: 1600, clientFPS: 60),
                       StreamingDisplayModes.Mode(width: 1280, height: 800, refreshRate: 60, hiDPI: true))
        profile.width = 1920
        profile.height = 1200
        profile.refreshRate = 60
        XCTAssertEqual(profile.mode(clientWidth: 1280, clientHeight: 800, clientFPS: 30),
                       StreamingDisplayModes.Mode(width: 1920, height: 1200, refreshRate: 60))
    }

    // MARK: - Sessions

    func testStartMakesPlacesAndSwitchesThenEndPutsBack() throws {
        let fake = FakeSessionDisplays()
        var profile = SessionProfile()
        profile.placement = .main
        profile.audioOutputUID = "blackhole"
        let c = coordinator(fake, profiles: ["sunshine": profile])

        let result = start(c, SessionRequest(app: "sunshine", client: "laptop", width: 1280, height: 800, fps: 60))
        XCTAssertEqual(try result?.get(), SessionStart(displayID: 100))
        XCTAssertEqual(fake.made.first?.mode, StreamingDisplayModes.Mode(width: 1280, height: 800, refreshRate: 60))
        XCTAssertEqual(fake.made.first?.identity.name, "Sunshine (laptop)")
        XCTAssertEqual(fake.placed.map(\.1), [.main])
        XCTAssertEqual(fake.outputUID, "blackhole")

        XCTAssertNoThrow(try c.end(app: "sunshine").get())
        XCTAssertEqual(fake.removed, [100])
        XCTAssertEqual(fake.outputUID, "speakers")
        XCTAssertTrue(c.sessions.isEmpty)
    }

    func testMainIsAskedForWithTheDisplay() {
        let fake = FakeSessionDisplays()
        let c = coordinator(fake)
        _ = start(c, SessionRequest(app: "rustdesk"))
        XCTAssertEqual(fake.madeMain.count, 1)
        _ = start(c, SessionRequest(app: "screensharing"))
        XCTAssertEqual(fake.madeMain.count, 1)
    }

    func testExtendNeedsNoPlacing() {
        let fake = FakeSessionDisplays()
        let c = coordinator(fake)
        _ = start(c, SessionRequest(app: "screensharing"))
        XCTAssertTrue(fake.placed.isEmpty)
        XCTAssertEqual(fake.made.count, 1)
    }

    func testSecondConnectionSharesTheSessionUntilBothEnd() {
        let fake = FakeSessionDisplays()
        let c = coordinator(fake)
        _ = start(c, SessionRequest(app: "rustdesk"))
        XCTAssertEqual(try start(c, SessionRequest(app: "rustdesk"))?.get(), SessionStart(displayID: 100))
        XCTAssertEqual(fake.made.count, 1)
        XCTAssertEqual(c.sessions["rustdesk"]?.count, 2)
        c.end(app: "rustdesk")
        XCTAssertTrue(fake.removed.isEmpty)
        c.end(app: "rustdesk")
        XCTAssertEqual(fake.removed, [100])
    }

    func testEndAllEndsEveryConnection() {
        let fake = FakeSessionDisplays()
        let c = coordinator(fake)
        _ = start(c, SessionRequest(app: "rustdesk"))
        _ = start(c, SessionRequest(app: "rustdesk"))
        c.end(app: "rustdesk", all: true)
        XCTAssertEqual(fake.removed, [100])
        XCTAssertNil(c.sessions["rustdesk"])
    }

    func testEndingWhileStartingEndsOnceTheDisplayIsPlaced() {
        let fake = FakeSessionDisplays()
        fake.pendingMakes = []
        let c = coordinator(fake)
        var result: Result<SessionStart, SessionError>?
        c.begin(SessionRequest(app: "sunshine")) { result = $0 }
        XCTAssertNoThrow(try c.end(app: "sunshine").get())
        XCTAssertTrue(fake.removed.isEmpty)
        fake.pendingMakes?.forEach { $0() }
        XCTAssertEqual(try result?.get().displayID, 100)
        XCTAssertEqual(fake.removed, [100])
        XCTAssertTrue(c.sessions.isEmpty)
    }

    func testAnAppRemovedWhileStartingLeavesNoProfile() {
        let fake = FakeSessionDisplays()
        fake.pendingMakes = []
        let c = coordinator(fake)
        let app = c.addApp(named: "Mine", kind: .process)
        c.begin(SessionRequest(app: app)) { _ in }
        c.removeApp(app)
        // Resized during the session, which would otherwise be kept for the next one.
        fake.modes[100] = StreamingDisplayModes.Mode(width: 800, height: 600, refreshRate: 30)
        fake.pendingMakes?.forEach { $0() }
        XCTAssertTrue(c.sessions.isEmpty)
        XCTAssertEqual(fake.removed, [100])
        XCTAssertEqual(c.addApp(named: "Mine", kind: .process), app, "no profile left to take its ID")
    }

    func testJoiningWhileStartingWaitsForTheDisplay() {
        let fake = FakeSessionDisplays()
        fake.pendingMakes = []
        let c = coordinator(fake)
        var first: Result<SessionStart, SessionError>?
        var second: Result<SessionStart, SessionError>?
        c.begin(SessionRequest(app: "sunshine")) { first = $0 }
        c.begin(SessionRequest(app: "sunshine")) { second = $0 }
        XCTAssertNil(second)
        fake.pendingMakes?.forEach { $0() }
        XCTAssertEqual(try first?.get().displayID, 100)
        XCTAssertEqual(try second?.get().displayID, 100)
        XCTAssertEqual(fake.made.count, 1)
    }

    func testTurnedOffProfileStartsNothing() {
        let fake = FakeSessionDisplays()
        var profile = SessionProfile()
        profile.enabled = false
        let c = coordinator(fake, profiles: ["parsec": profile])
        guard case .failure(.disabled("parsec")) = start(c, SessionRequest(app: "parsec")) else {
            return XCTFail("started")
        }
        XCTAssertTrue(fake.made.isEmpty)
        XCTAssertTrue(c.sessions.isEmpty)
    }

    func testNoDisplayFailsAndChangesNothingElse() {
        let fake = FakeSessionDisplays()
        fake.nextID = nil
        var profile = SessionProfile()
        profile.audioOutputUID = "blackhole"
        let c = coordinator(fake, profiles: ["sunshine": profile])
        guard case .failure(.noDisplay) = start(c, SessionRequest(app: "sunshine")) else { return XCTFail("started") }
        XCTAssertEqual(fake.outputUID, "speakers")
        XCTAssertTrue(c.sessions.isEmpty)
        XCTAssertFalse(fake.holdsLayout)
        // Nothing left for the next launch to switch the output to.
        fake.outputUID = "blackhole"
        _ = coordinator(fake)
        XCTAssertEqual(fake.outputUID, "blackhole")
    }

    func testNoDisplayAskedOnlySwitchesTheOutput() {
        let fake = FakeSessionDisplays()
        let c = coordinator(fake)
        let result = start(c, SessionRequest(app: "screensharing", display: SessionProfile.DisplayChoice.none,
                                              audioOutputUID: "blackhole"))
        XCTAssertEqual(try result?.get(), SessionStart())
        XCTAssertTrue(fake.made.isEmpty)
        XCTAssertEqual(fake.outputUID, "blackhole")
        c.end(app: "screensharing")
        XCTAssertEqual(fake.outputUID, "speakers")
    }

    func testMissingOutputAndFailedPlacingAreWarnings() throws {
        let fake = FakeSessionDisplays()
        fake.placeSucceeds = false
        let c = coordinator(fake)
        let start = try XCTUnwrap(self.start(c, SessionRequest(app: "sunshine", placement: .mirror,
                                                              audioOutputUID: "gone")))
        XCTAssertEqual(try start.get().displayID, 100)
        XCTAssertEqual(try start.get().warnings.count, 2)
        XCTAssertEqual(fake.outputUID, "speakers")
        // Neither failure is kept as a choice.
        XCTAssertNoThrow(try c.end(app: "sunshine").get())
        XCTAssertTrue(c.sessions.isEmpty)
        XCTAssertEqual(fake.removed, [100])
        XCTAssertEqual(c.profile(for: "sunshine"), SessionProfile())
    }

    func testOutputGoesBackOnlyOnceNoSessionWantsItsOwn() {
        let fake = FakeSessionDisplays()
        var profile = SessionProfile()
        profile.audioOutputUID = "blackhole"
        let c = coordinator(fake, profiles: ["sunshine": profile, "rustdesk": profile])
        _ = start(c, SessionRequest(app: "sunshine"))
        _ = start(c, SessionRequest(app: "rustdesk"))
        c.end(app: "sunshine")
        XCTAssertEqual(fake.outputUID, "blackhole")
        c.end(app: "rustdesk")
        XCTAssertEqual(fake.outputUID, "speakers")
    }

    func testOutputFromBeforeAQuitIsPutBackOnLaunch() {
        let fake = FakeSessionDisplays()
        var profile = SessionProfile()
        profile.audioOutputUID = "blackhole"
        _ = start(coordinator(fake, profiles: ["sunshine": profile]), SessionRequest(app: "sunshine"))
        XCTAssertEqual(fake.outputUID, "blackhole")
        // DAM quit without ending it.
        _ = coordinator(fake)
        XCTAssertEqual(fake.outputUID, "speakers")
    }

    // MARK: - Changes during a session

    func testChangesDuringASessionAreKeptForTheNext() {
        let fake = FakeSessionDisplays()
        let c = coordinator(fake, profiles: ["rustdesk": SessionProfile()])
        _ = start(c, SessionRequest(app: "rustdesk"))
        XCTAssertTrue(fake.holdsLayout)
        fake.placements[100] = .main
        fake.modes[100] = StreamingDisplayModes.Mode(width: 1280, height: 800, refreshRate: 30)
        fake.outputUID = "blackhole"
        c.end(app: "rustdesk")
        let next = c.profile(for: "rustdesk")
        XCTAssertEqual(next.placement, .main)
        XCTAssertEqual(next.width, 1280)
        XCTAssertEqual(next.height, 800)
        XCTAssertEqual(next.refreshRate, 30)
        XCTAssertEqual(next.audioOutputUID, "blackhole")
        // This time is still put back as it was.
        XCTAssertEqual(fake.outputUID, "speakers")
        XCTAssertFalse(fake.holdsLayout)
        XCTAssertEqual(fake.removed, [100])
    }

    func testLockedSettingsStayAsPicked() {
        let fake = FakeSessionDisplays()
        var profile = SessionProfile()
        profile.locked = Set(SessionProfile.Setting.allCases)
        let c = coordinator(fake, profiles: ["rustdesk": profile])
        _ = start(c, SessionRequest(app: "rustdesk"))
        fake.placements[100] = .mirror
        fake.modes[100] = StreamingDisplayModes.Mode(width: 1280, height: 800, refreshRate: 30)
        fake.outputUID = "blackhole"
        c.end(app: "rustdesk")
        XCTAssertEqual(c.profile(for: "rustdesk"), profile)
        XCTAssertEqual(fake.outputUID, "speakers")
    }

    func testATurnedDisplaysModeComparesAsItWasMade() {
        let made = StreamingDisplayModes.forStream(width: 3840, height: 2160, fps: 60)
        // Kept on its side: shown 1080 × 1920 points, 2160 pixels wide.
        let turned = LiveSessionDisplays.mode(width: 1080, height: 1920, pixelWidth: 2160, refreshRate: 60, turned: .quarter)
        XCTAssertEqual(turned, made)
        XCTAssertEqual(LiveSessionDisplays.mode(width: 1920, height: 1080, pixelWidth: 1920, refreshRate: 59.94, turned: .half),
                       StreamingDisplayModes.Mode(width: 1920, height: 1080, refreshRate: 60))
        XCTAssertEqual(LiveSessionDisplays.mode(width: 1280, height: 800, pixelWidth: 1280, refreshRate: 60, turned: nil),
                       StreamingDisplayModes.Mode(width: 1280, height: 800, refreshRate: 60))

        // So a session on a turned display keeps its profile as it was.
        let fake = FakeSessionDisplays()
        let c = coordinator(fake, profiles: ["sunshine": SessionProfile()])
        _ = start(c, SessionRequest(app: "sunshine", width: 3840, height: 2160, fps: 60))
        fake.modes[100] = turned
        c.end(app: "sunshine")
        XCTAssertNil(c.profile(for: "sunshine").width)
    }

    func testNothingChangedKeepsTheProfile() {
        let fake = FakeSessionDisplays()
        var profile = SessionProfile()
        profile.placement = .main
        profile.audioOutputUID = "blackhole"
        let c = coordinator(fake, profiles: ["rustdesk": profile])
        // Asked for this time only, so not kept either.
        _ = start(c, SessionRequest(app: "rustdesk", placement: .mirror))
        c.end(app: "rustdesk")
        XCTAssertEqual(c.profile(for: "rustdesk"), profile)
    }

    func testAGoneDisplaysPlacementIsntKept() {
        let fake = FakeSessionDisplays()
        fake.others["Jump Desktop"] = 7
        var profile = SessionProfile()
        profile.display = .adopt
        profile.adoptName = "Jump"
        profile.placement = .main
        let c = coordinator(fake, profiles: ["jump": profile])
        _ = start(c, SessionRequest(app: "jump"))
        // The app took its display away, which ended the session.
        fake.gone.insert(7)
        c.end(app: "jump")
        XCTAssertEqual(c.profile(for: "jump"), profile)
    }

    func testAnotherSessionsOutputIsntKept() {
        let fake = FakeSessionDisplays()
        var switching = SessionProfile()
        switching.audioOutputUID = "blackhole"
        let c = coordinator(fake, profiles: ["rustdesk": SessionProfile(), "sunshine": switching])
        _ = start(c, SessionRequest(app: "rustdesk"))
        fake.nextID = 101
        _ = start(c, SessionRequest(app: "sunshine"))
        c.end(app: "rustdesk")
        XCTAssertNil(c.profile(for: "rustdesk").audioOutputUID)
        c.end(app: "sunshine")
        XCTAssertEqual(fake.outputUID, "speakers")
    }

    func testLiftingTheBlackoutIsKeptUnlessLocked() {
        let fake = FakeSessionDisplays()
        var open = SessionProfile()
        open.blackout = true
        var locked = open
        locked.locked = [.blackout]
        let c = coordinator(fake, profiles: ["rustdesk": open, "parsec": locked])
        _ = start(c, SessionRequest(app: "rustdesk"))
        fake.nextID = 101
        _ = start(c, SessionRequest(app: "parsec"))
        c.liftBlackout()
        XCTAssertFalse(c.profile(for: "rustdesk").blackout)
        XCTAssertTrue(c.profile(for: "parsec").blackout)
    }

    func testLocksRoundTripThroughTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var profile = SessionProfile()
        profile.locked = [.placement, .audio]
        SessionProfiles.save(["rustdesk": profile], to: url)
        XCTAssertEqual(SessionProfiles.load(from: url)["rustdesk"]?.locked, [.placement, .audio])
    }

    func testEndingWhatIsntOnFails() {
        let c = coordinator(FakeSessionDisplays())
        guard case .failure(.notActive("rustdesk")) = c.end(app: "rustdesk") else { return XCTFail("ended") }
    }

    // MARK: - Command line

    func testCommandLineStartsOnlyForItsWords() {
        XCTAssertTrue(ControlCLI.isCommand(["DAM", "session", "start"]))
        XCTAssertTrue(ControlCLI.isCommand(["DAM", "status"]))
        XCTAssertFalse(ControlCLI.isCommand(["DAM"]))
        XCTAssertFalse(ControlCLI.isCommand(["DAM", "-psn_0_12345"]))
        XCTAssertFalse(ControlCLI.isCommand(["DAM", "-DAMDebugHUD", "settings"]))
    }

    func testStartTakesSunshinesVariables() throws {
        let env = ["SUNSHINE_CLIENT_NAME": "laptop", "SUNSHINE_CLIENT_WIDTH": "2256",
                   "SUNSHINE_CLIENT_HEIGHT": "1504", "SUNSHINE_CLIENT_FPS": "60", "SUNSHINE_CLIENT_CERT_UUID": "C1"]
        let request = try ControlCLI.request(from: ["session", "start", "--app", "sunshine"], environment: env)
        XCTAssertEqual(request, ControlRequest(command: "session.start", app: "sunshine", client: "laptop",
                                               clientID: "C1", width: 2256, height: 1504, fps: 60))
    }

    func testOptionsWinOverVariables() throws {
        let request = try ControlCLI.request(
            from: ["session", "start", "--app", "sunshine", "--width", "1280", "--placement", "main", "--audio", "BlackHole 2ch"],
            environment: ["SUNSHINE_CLIENT_WIDTH": "2256", "APOLLO_CLIENT_UUID": "A1", "SUNSHINE_CLIENT_CERT_UUID": "C1"])
        XCTAssertEqual(request.width, 1280)
        XCTAssertEqual(request.clientID, "A1")
        XCTAssertEqual(request.placement, "main")
        XCTAssertEqual(request.audio, "BlackHole 2ch")
    }

    func testBadCommandsAreRefused() {
        let env: [String: String] = [:]
        XCTAssertThrowsError(try ControlCLI.request(from: ["session", "start"], environment: env))
        XCTAssertThrowsError(try ControlCLI.request(from: ["session", "start", "--app"], environment: env))
        XCTAssertThrowsError(try ControlCLI.request(from: ["session", "start", "--app", "x", "--size", "1"], environment: env))
        XCTAssertThrowsError(try ControlCLI.request(from: ["session", "start", "--app", "x", "--width", "wide"], environment: env))
        XCTAssertThrowsError(try ControlCLI.request(from: ["session", "start", "--app", "x", "--placement", "left"], environment: env))
        XCTAssertThrowsError(try ControlCLI.request(from: ["display"], environment: env))
    }

    func testEndListAndStatus() throws {
        XCTAssertEqual(try ControlCLI.request(from: ["session", "end", "--app", "rustdesk", "--all"], environment: [:]),
                       ControlRequest(command: "session.end", app: "rustdesk", all: true))
        XCTAssertEqual(try ControlCLI.request(from: ["display", "list"], environment: [:]).command, "display.list")
        XCTAssertEqual(try ControlCLI.request(from: ["status"], environment: [:]).command, "status")
    }

    func testStartPrintsTheDisplayLast() {
        let request = ControlRequest(command: "session.start", app: "sunshine")
        let text = ControlCLI.text(for: ControlResponse(ok: true, message: "on", displayID: 7), to: request)
        XCTAssertEqual(text.split(separator: "\n").last, "7")
    }

    func testURLs() {
        let start = ControlHandler.request(from: URL(string: "dam://session/start?app=rustdesk&width=1280&height=800&placement=main")!)
        XCTAssertEqual(start, ControlRequest(command: "session.start", app: "rustdesk", width: 1280, height: 800, placement: "main"))
        let end = ControlHandler.request(from: URL(string: "dam://session/end?app=rustdesk&all=1")!)
        XCTAssertEqual(end, ControlRequest(command: "session.end", app: "rustdesk", all: true))
        XCTAssertNil(ControlHandler.request(from: URL(string: "dam://quit")!))
    }

    func testSizesAndChoicesAreCheckedHoweverTheyCome() {
        let side = ControlRequest.maxSide
        let start = ["session", "start", "--app", "x"]
        for bad in [["--width", "-2"], ["--width", "0"], ["--height", "\(side + 1)"], ["--width", "99999999999"],
                    ["--fps", "0"], ["--fps", "1000"], ["--display", "make"], ["--placement", "left"]] {
            XCTAssertThrowsError(try ControlCLI.request(from: start + bad, environment: [:]), "\(bad)")
        }
        XCTAssertThrowsError(try ControlCLI.request(from: start, environment: ["SUNSHINE_CLIENT_WIDTH": "-1"]))
        XCTAssertEqual(try ControlCLI.request(from: start + ["--width", "\(side)", "--fps", "240"], environment: [:]).width, side)

        // URLs: refused, not passed on with the bad value or without it.
        for query in ["width=-2&height=-2", "width=wide", "fps=0", "height=\(side + 1)", "display=make", "placement=left",
                      "blackout=maybe"] {
            XCTAssertNil(ControlHandler.request(from: URL(string: "dam://session/start?app=x&\(query)")!), query)
        }
        XCTAssertNil(ControlHandler.request(from: URL(string: "dam://session/start?width=1280")!))

        // The socket's requests come as JSON, checked by the handler with the same rules.
        XCTAssertNotNil(ControlRequest(command: "session.start", app: "x", width: -2, height: -2).problem)
        XCTAssertNotNil(ControlRequest(command: "session.start", app: "x", fps: 100_000).problem)
        XCTAssertNotNil(ControlRequest(command: "session.start", app: "x", display: "make").problem)
        XCTAssertNotNil(ControlRequest(command: "session.start", app: "x", placement: "left").problem)
        XCTAssertNil(ControlRequest(command: "session.start", app: "x", width: 1920, height: 1080, fps: 60,
                                    display: "create", placement: "mirror").problem)
        // A 5K or ultrawide client gets a HiDPI display of half its size.
        XCTAssertNil(ControlRequest(command: "session.start", app: "x", width: 5120, height: 1440).problem)
    }

    func testYesAndNoAreReadAlikeEverywhere() throws {
        for (text, value) in [("yes", true), ("true", true), ("1", true), ("no", false), ("false", false), ("0", false)] {
            XCTAssertEqual(ControlHandler.request(from: URL(string: "dam://session/start?app=x&blackout=\(text)")!)?.blackout, value)
            XCTAssertEqual(ControlHandler.request(from: URL(string: "dam://session/end?app=x&all=\(text)")!)?.all, value)
            XCTAssertEqual(try ControlCLI.request(from: ["session", "start", "--app", "x", "--blackout", text],
                                                  environment: [:]).blackout, value)
        }
        XCTAssertEqual(ControlHandler.request(from: URL(string: "dam://session/start?app=x&clientID=A&client-id=B")!)?.clientID, "A")
    }

    // MARK: - Socket

    func testRequestAndAnswerOverTheSocket() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("dam-\(UUID().uuidString.prefix(8)).sock").path
        var received: ControlRequest?
        let server = ControlServer(path: path) { request, reply in
            received = request
            // Answered later, as a session start is.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { reply(ControlResponse(ok: true, displayID: 42)) }
        }
        try server.start()
        defer { server.stop() }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let answered = expectation(description: "answer")
        var response: ControlResponse?
        DispatchQueue.global().async {
            response = ControlCLI.send(ControlRequest(command: "status"), to: path, timeout: 5)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 6)
        XCTAssertEqual(received?.command, "status")
        XCTAssertEqual(response, ControlResponse(ok: true, displayID: 42))

        // A second copy doesn't take over the socket.
        XCTAssertThrowsError(try ControlServer(path: path) { _, _ in }.start())
    }

    func testAClientThatDoesntReadCantHoldUpTheApp() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("dam-\(UUID().uuidString.prefix(8)).sock").path
        var took: TimeInterval?
        let server = ControlServer(path: path) { _, reply in
            let display = ControlResponse.Display(id: 1, name: String(repeating: "x", count: 1000), width: 1, height: 1,
                                                  main: false, mirroring: false, streaming: false)
            let start = Date()
            reply(ControlResponse(ok: true, displays: Array(repeating: display, count: 1000)))
            took = Date().timeIntervalSince(start)
        }
        try server.start()
        defer { server.stop() }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        XCTAssertTrue(ControlSocketPath.connect(fd, to: path))
        let line = Data("{\"command\":\"display.list\"}\n".utf8)
        XCTAssertEqual(line.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }, line.count)
        // Never read.
        let deadline = Date().addingTimeInterval(10)
        while took == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertLessThan(took ?? 99, 5)
    }

    func testAnswersDontRepeatAWholeRequest() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("dam-\(UUID().uuidString.prefix(8)).sock").path
        let server = ControlServer(path: path) { request, reply in reply(.failure("Unknown command \(request.command).")) }
        try server.start()
        defer { server.stop() }
        let answered = expectation(description: "answer")
        var response: ControlResponse?
        DispatchQueue.global().async {
            response = ControlCLI.send(ControlRequest(command: String(repeating: "x", count: 50_000)), to: path, timeout: 5)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 6)
        XCTAssertEqual(response?.ok, false)
        XCTAssertLessThanOrEqual(response?.message?.count ?? .max, 301)
    }

    func testNotRunningGivesNoAnswer() {
        XCTAssertNil(ControlCLI.send(ControlRequest(command: "status"), to: "/tmp/dam-nobody-\(UUID().uuidString.prefix(8)).sock"))
    }

    // MARK: - Detectors

    func testRustDeskLines() {
        // As RustDesk 1.5.0 writes them on this Mac.
        XCTAssertEqual(SessionLogLines.rustDesk("[2026-10-16 13:42:11.570016 -04:00] DEBUG [src/server/connection.rs:1498] #365 Connection opened from 10.10.1.123:40381."),
                       .opened(key: "365", client: "10.10.1.123"))
        XCTAssertEqual(SessionLogLines.rustDesk("[2026-10-16 13:45:39.337551 -04:00] INFO [src/server/connection.rs:5249] #365 Connection closed: Peer close"),
                       .closed(key: "365"))
        XCTAssertNil(SessionLogLines.rustDesk("[2026-10-16 13:45:39.337681 -04:00] INFO [src/server/connection.rs:1237] #365 connection loop exited"))
        XCTAssertNil(SessionLogLines.rustDesk("[2026-10-16 13:42:12.553353 -04:00] INFO [src/common.rs:2213] Connection secured"))
    }

    func testRustDeskTerminalsMakeNoSession() {
        let lines = SessionLogLines.RustDeskConnections()
        // As RustDesk 1.5.0 wrote them on 2026-10-20: a desktop, then a terminal.
        XCTAssertNil(lines.parse("[2026-10-20 15:26:04.995863 -04:00] DEBUG [src/server/connection.rs:1498] #1951 Connection opened from 10.10.1.123:36321."))
        XCTAssertEqual(lines.parse("[2026-10-20 15:26:05.005147 -04:00] INFO [src/platform/mod.rs:112] new wakelock, require display on: true"),
                       .opened(key: "1951", client: "10.10.1.123"))
        XCTAssertNil(lines.parse("[2026-10-20 15:26:05.011789 -04:00] INFO [src/server/connection.rs:4857] Option update: OptionMessage { image_quality: NotSet }"))
        XCTAssertEqual(lines.parse("[2026-10-20 15:27:12.557025 -04:00] INFO [src/server/connection.rs:5249] #1951 Connection closed: Peer close"),
                       .closed(key: "1951"))
        XCTAssertNil(lines.parse("[2026-10-20 15:27:22.031451 -04:00] DEBUG [src/server/connection.rs:1498] #1952 Connection opened from 10.10.1.123:40321."))
        XCTAssertNil(lines.parse("[2026-10-20 15:27:22.041027 -04:00] INFO [src/platform/mod.rs:112] new wakelock, require display on: false"))
        XCTAssertNil(lines.parse("[2026-10-20 15:27:22.047539 -04:00] INFO [src/server/terminal_service.rs:180] Creating new terminal service: ts_1 (persistent: false)"))
        XCTAssertNil(lines.parse("[2026-10-20 15:27:22.100000 -04:00] INFO [src/server/connection.rs:4857] Option update: OptionMessage { image_quality: NotSet }"))
        // Its close is passed on; the detector ignores a close of what it never saw open.
        XCTAssertEqual(lines.parse("#1952 Connection closed: Peer close"), .closed(key: "1952"))

        // A second desktop, which logs no new wakelock, by its options; one held when the next
        // opens counts as a desktop.
        XCTAssertNil(lines.parse("#3 Connection opened from 10.0.0.3:1."))
        XCTAssertEqual(lines.parse("Option update: OptionMessage { image_quality: NotSet }"), .opened(key: "3", client: "10.0.0.3"))
        XCTAssertNil(lines.parse("#4 Connection opened from 10.0.0.4:1."))
        XCTAssertEqual(lines.parse("#5 Connection opened from 10.0.0.5:1."), .opened(key: "4", client: "10.0.0.4"))
        XCTAssertEqual(lines.parse("video_service.rs:485] #displays=2, current=0, origin: (0, 0)"), .opened(key: "5", client: "10.0.0.5"))

        // A terminal whose lines come 5 s after its open, past the window, as after a login.
        XCTAssertNil(lines.parse("[2026-10-20 16:01:00.000000 -04:00] DEBUG [src/server/connection.rs:1498] #21 Connection opened from 10.0.0.21:1."))
        XCTAssertNil(lines.parse("[2026-10-20 16:01:05.000000 -04:00] INFO [src/server/terminal_service.rs:180] Creating new terminal service: ts_3"))
        XCTAssertNil(lines.parse("[2026-10-20 16:01:05.020000 -04:00] DEBUG [src/server/video_service.rs:485] #displays=2, current=0"))
        XCTAssertNil(lines.parse("[2026-10-20 16:02:00.000000 -04:00] DEBUG [src/server/connection.rs:1498] #22 Connection opened from 10.0.0.22:1."))
        XCTAssertNil(lines.parse("[2026-10-20 16:02:05.000000 -04:00] INFO [src/platform/mod.rs:112] new wakelock, require display on: false"))
        XCTAssertNil(lines.parse("[2026-10-20 16:02:05.010000 -04:00] DEBUG [src/server/video_service.rs:485] #displays=2, current=0"))
    }

    func testRustDeskCountsOnlyLinesSoonAfterAnOpen() throws {
        let lines = SessionLogLines.RustDeskConnections()
        XCTAssertEqual(try XCTUnwrap(SessionLogLines.RustDeskConnections.time(of: "[2026-10-20 15:26:04.995863 -04:00] INFO x")), 55564.995863, accuracy: 1e-6)
        XCTAssertNil(SessionLogLines.RustDeskConnections.time(of: "#3 Connection opened from 10.0.0.3:1."))
        // No desktop's line soon after: a wakelock or options later can be another
        // connection's, so they don't count.
        XCTAssertNil(lines.parse("[2026-10-20 15:30:00.000000 -04:00] DEBUG [src/server/connection.rs:1498] #7 Connection opened from 10.0.0.7:1."))
        XCTAssertNil(lines.parse("[2026-10-20 15:30:02.000000 -04:00] INFO [src/platform/mod.rs:112] new wakelock, require display on: true"))
        XCTAssertNil(lines.parse("[2026-10-20 15:30:03.000000 -04:00] INFO [src/server/connection.rs:4857] Option update: OptionMessage { custom_fps: 30 }"))
        // Still held with none when the next opens: no screen, as a file transfer, so no session.
        XCTAssertNil(lines.parse("[2026-10-20 15:30:10.000000 -04:00] DEBUG [src/server/connection.rs:1498] #10 Connection opened from 10.0.0.10:1."))
        XCTAssertEqual(lines.parse("[2026-10-20 15:30:10.009000 -04:00] INFO [src/platform/mod.rs:112] new wakelock, require display on: true"),
                       .opened(key: "10", client: "10.0.0.10"))
        XCTAssertNil(lines.parse("[2026-10-20 15:30:20.000000 -04:00] DEBUG [src/server/connection.rs:1498] #11 Connection opened from 10.0.0.11:1."))
        XCTAssertNil(lines.parse("[2026-10-20 15:30:25.000000 -04:00] DEBUG [src/server/connection.rs:1498] #12 Connection opened from 10.0.0.12:1."))
        // Within the window, a terminal's line still makes none.
        XCTAssertNil(lines.parse("[2026-10-20 15:31:00.000000 -04:00] DEBUG [src/server/connection.rs:1498] #8 Connection opened from 10.0.0.8:1."))
        XCTAssertNil(lines.parse("[2026-10-20 15:31:00.010000 -04:00] INFO [src/server/terminal_service.rs:180] Creating new terminal service: ts_2"))
        // Past midnight reads as past the window.
        XCTAssertNil(lines.parse("[2026-10-20 23:59:59.900000 -04:00] DEBUG [src/server/connection.rs:1498] #9 Connection opened from 10.0.0.9:1."))
        XCTAssertNil(lines.parse("[2026-10-21 00:00:00.100000 -04:00] INFO [src/server/connection.rs:4857] Option update: OptionMessage { }"))
        // RustDesk logs the open before the login: a client types its password for 5 s, then
        // the desktop's lines come, and its video capture starting makes the session.
        XCTAssertNil(lines.parse("[2026-10-21 16:00:00.000000 -04:00] DEBUG [src/server/connection.rs:1498] #20 Connection opened from 10.0.0.20:1."))
        XCTAssertNil(lines.parse("[2026-10-21 16:00:05.000000 -04:00] INFO [src/common.rs:2213] Connection secured"))
        XCTAssertNil(lines.parse("[2026-10-21 16:00:05.004000 -04:00] INFO [src/platform/mod.rs:112] new wakelock, require display on: true"))
        XCTAssertNil(lines.parse("[2026-10-21 16:00:05.008000 -04:00] INFO [src/server/connection.rs:4857] Option update: OptionMessage { image_quality: NotSet }"))
        XCTAssertEqual(lines.parse("[2026-10-21 16:00:05.020000 -04:00] DEBUG [src/server/video_service.rs:485] #displays=2, current=0, origin: (0, 0)"),
                       .opened(key: "20", client: "10.0.0.20"))
        XCTAssertNil(lines.parse("[2026-10-21 16:00:05.030000 -04:00] DEBUG [src/server/video_service.rs:485] #displays=2, current=0, origin: (0, 0)"))
    }

    func testParsecLines() {
        XCTAssertEqual(SessionLogLines.parsec("[I 2026-10-18 12:00:00] friend#1234 connected."),
                       .opened(key: "friend#1234", client: "friend"))
        XCTAssertEqual(SessionLogLines.parsec("[I 2026-10-18 12:30:00] friend#1234 disconnected."),
                       .closed(key: "friend#1234"))
        XCTAssertNil(SessionLogLines.parsec("1 guest connected"))
    }

    func testLogDetectorPairsOpensAndCloses() {
        let detector = LogSessionDetector(app: "rustdesk", url: URL(fileURLWithPath: "/nonexistent"),
                                          parse: SessionLogLines.rustDesk)
        var events: [SessionEvent] = []
        detector.onEvent = { events.append($0) }
        // Opened before DAM looked.
        detector.handle("#1 Connection closed: Peer close")
        detector.handle("#2 Connection opened from 10.0.0.2:1.")
        detector.handle("#2 Connection opened from 10.0.0.2:1.")
        detector.handle("#2 Connection closed: Peer close")
        XCTAssertEqual(events, [.opened(key: "2", client: "10.0.0.2"), .closed(key: "2")])
        detector.handle("#3 Connection opened from 10.0.0.3:1.")
        detector.stop()
        XCTAssertEqual(events.last, .closed(key: "3"))
    }

    func testLogDetectorEndsWhatARestartLeftOpen() {
        let detector = LogSessionDetector(app: "rustdesk", url: URL(fileURLWithPath: "/nonexistent"),
                                          parse: SessionLogLines.rustDesk, restarted: SessionLogLines.rustDeskRestarted)
        var events: [SessionEvent] = []
        detector.onEvent = { events.append($0) }
        // As seen 2026-10-20: RustDesk started again mid-session, and #1541's close never came.
        detector.handle("[2026-10-20 14:22:28.506591 -04:00] DEBUG [src/server/connection.rs:1498] #1541 Connection opened from 10.10.1.123:41257.")
        detector.handle("[2026-10-20 14:27:41.999746 -04:00] INFO [src/server.rs:744] try start server")
        detector.handle("[2026-10-20 14:27:44.498728 -04:00] DEBUG [src/server/connection.rs:1498] #1948 Connection opened from 10.10.1.123:41839.")
        detector.handle("[2026-10-20 14:35:21.288666 -04:00] INFO [src/server/connection.rs:5249] #1948 Connection closed: Peer close")
        XCTAssertEqual(events, [.opened(key: "1541", client: "10.10.1.123"), .closed(key: "1541"),
                                .opened(key: "1948", client: "10.10.1.123"), .closed(key: "1948")])
        XCTAssertTrue(LogSessionDetector.stillOpen(in: ["#1 Connection opened from 10.0.0.1:1.", "try start server"],
                                                   parse: SessionLogLines.rustDesk,
                                                   restarted: SessionLogLines.rustDeskRestarted).isEmpty)
    }

    func testRustDeskForgetsAConnectionHeldOverARestart() {
        let detector = LogSessionDetector(app: "rustdesk", url: URL(fileURLWithPath: "/nonexistent"),
                                          parse: SessionLogLines.RustDeskConnections().parse,
                                          restarted: SessionLogLines.rustDeskRestarted)
        var events: [SessionEvent] = []
        detector.onEvent = { events.append($0) }
        // #5 is held, not yet known as a desktop, when RustDesk starts again.
        detector.handle("#5 Connection opened from 10.0.0.5:1.")
        detector.handle("try start server")
        detector.handle("#6 Connection opened from 10.0.0.6:1.")
        detector.handle("new wakelock, require display on: true")
        detector.handle("#6 Connection closed: Peer close")
        XCTAssertEqual(events, [.opened(key: "6", client: "10.0.0.6"), .closed(key: "6")])
        let parse = SessionLogLines.RustDeskConnections().parse
        XCTAssertTrue(LogSessionDetector.stillOpen(in: ["#5 Connection opened from 10.0.0.5:1.", "try start server",
                                                        "#6 Connection opened from 10.0.0.6:1."],
                                                   parse: parse, restarted: SessionLogLines.rustDeskRestarted).isEmpty)
    }

    func testProcessDetectorWaitsBeforeEnding() {
        var running = true
        let detector = ProcessSessionDetector(app: "screensharing", processName: "screensharingd", grace: 5,
                                              isRunning: { _ in running })
        var events: [SessionEvent] = []
        detector.onEvent = { events.append($0) }
        let t0 = Date()
        detector.check(now: t0)
        XCTAssertEqual(events, [.opened(key: "screensharingd", client: nil)])
        running = false
        detector.check(now: t0.addingTimeInterval(2))
        detector.check(now: t0.addingTimeInterval(4))
        XCTAssertEqual(events.count, 1)
        // Back for the next connection before the grace ran out: still one session.
        running = true
        detector.check(now: t0.addingTimeInterval(6))
        running = false
        detector.check(now: t0.addingTimeInterval(8))
        detector.check(now: t0.addingTimeInterval(13))
        XCTAssertEqual(events, [.opened(key: "screensharingd", client: nil), .closed(key: "screensharingd")])
    }

    func testLogFollowerReadsNewLinesAcrossARotation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("app.log")
        try "old line\n".write(to: url, atomically: false, encoding: .utf8)
        var lines: [String] = []
        let follower = LogFollower(url: url) { lines.append($0) }
        follower.start()
        defer { follower.stop() }
        let append = { (text: String) in
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        }
        try append("first\nhalf")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(lines, ["first"])
        try append(" done\n")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(lines, ["first", "half done"])
        // Moved aside and a new one started, as RustDesk does on launch.
        try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent("app-1.log"))
        try "second\n".write(to: url, atomically: false, encoding: .utf8)
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        XCTAssertEqual(lines, ["first", "half done", "second"])
    }

    func testLogFollowerThroughALinkReadsEachLineOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.log")
        let link = dir.appendingPathComponent("link.log")
        try "old line\n".write(to: real, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        var lines: [String] = []
        let follower = LogFollower(url: link) { lines.append($0) }
        follower.start()
        defer { follower.stop() }
        let handle = try FileHandle(forWritingTo: real)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("first\n".utf8))
        try handle.close()
        // Past its look at the path, which took the link for another file and read it all again.
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        XCTAssertEqual(lines, ["first"])
    }

    func testWatcherStartsAndEndsSessionsAsTheDetectorSays() {
        final class FakeDetector: SessionDetector {
            let app: String
            var onEvent: ((SessionEvent) -> Void)?
            var running = false
            init(app: String) { self.app = app }
            func start() { running = true }
            func stop() { running = false }
        }
        let fake = FakeSessionDisplays()
        var profile = SessionProfile()
        profile.watch = true
        let c = coordinator(fake, profiles: ["rustdesk": profile])
        var made: [String: FakeDetector] = [:]
        let watcher = SessionWatcher(coordinator: c) { app in
            let d = FakeDetector(app: app)
            made[app] = d
            return d
        }
        var said: [String] = []
        watcher.announce = { said.append($0) }
        watcher.update()
        XCTAssertEqual(Set(made.keys), ["rustdesk"])
        XCTAssertEqual(made["rustdesk"]?.running, true)

        let detector = made["rustdesk"]!
        detector.onEvent?(.opened(key: "1", client: "10.0.0.2"))
        detector.onEvent?(.opened(key: "2", client: "10.0.0.3"))
        XCTAssertEqual(fake.made.count, 1)
        XCTAssertEqual(fake.made.first?.identity.name, "RustDesk (10.0.0.2)")
        XCTAssertEqual(c.sessions["rustdesk"]?.followsApp, false)
        detector.onEvent?(.closed(key: "1"))
        XCTAssertTrue(fake.removed.isEmpty)
        detector.onEvent?(.closed(key: "2"))
        XCTAssertEqual(fake.removed, [100])
        XCTAssertEqual(said.count, 2)

        profile.watch = false
        c.setProfile(profile, for: "rustdesk")
        watcher.update()
        XCTAssertEqual(detector.running, false)
        XCTAssertTrue(watcher.detectors.isEmpty)
    }

    /// A watched app's detector, whose events the test sends; and its watcher.
    private func watched(_ c: RemoteSessionCoordinator, app: String) -> (SessionWatcher, ScriptedDetector) {
        let detector = ScriptedDetector(app: app)
        let watcher = SessionWatcher(coordinator: c) { $0 == app ? detector : nil }
        watcher.update()
        return (watcher, detector)
    }

    func testAConnectionsCloseDoesntEndALaterSession() {
        let fake = FakeSessionDisplays()
        var profile = SessionProfile()
        profile.watch = true
        let c = coordinator(fake, profiles: ["rustdesk": profile])
        let (watcher, detector) = watched(c, app: "rustdesk")
        var said: [String] = []
        watcher.announce = { said.append($0) }
        detector.onEvent?(.opened(key: "1", client: nil))
        // Ended by hand, as from the menu, while connection 1 stays open.
        c.end(app: "rustdesk", all: true)
        XCTAssertEqual(fake.removed, [100])
        fake.nextID = 101
        detector.onEvent?(.opened(key: "2", client: nil))
        detector.onEvent?(.closed(key: "1"))
        XCTAssertEqual(c.sessions["rustdesk"]?.displayID, 101)
        XCTAssertEqual(fake.removed, [100])
        detector.onEvent?(.closed(key: "2"))
        XCTAssertNil(c.sessions["rustdesk"])
        XCTAssertEqual(fake.removed, [100, 101])
        XCTAssertEqual(said.count, 3)
    }

    func testAConnectionGoneBeforeItsDisplayCameIsntAnnounced() {
        let fake = FakeSessionDisplays()
        fake.pendingMakes = []
        var profile = SessionProfile()
        profile.watch = true
        let c = coordinator(fake, profiles: ["parsec": profile])
        let (watcher, detector) = watched(c, app: "parsec")
        var said: [String] = []
        watcher.announce = { said.append($0) }
        detector.onEvent?(.opened(key: "guest#1", client: "guest"))
        detector.onEvent?(.closed(key: "guest#1"))
        fake.pendingMakes?.forEach { $0() }
        XCTAssertNil(c.sessions["parsec"])
        XCTAssertEqual(fake.removed, [100])
        XCTAssertEqual(said, [])
    }

    func testFindsRunningProcesses() {
        XCTAssertTrue(RunningProcesses.names().contains("launchd"))
    }

    // MARK: - Adopting

    func testAdoptPlacesTheAppsDisplayAndLeavesIt() {
        let fake = FakeSessionDisplays()
        fake.others = ["Parsec Virtual Display": 7]
        var profile = SessionProfile()
        profile.display = .adopt
        profile.placement = .main
        let c = coordinator(fake, profiles: ["parsec": profile])
        XCTAssertEqual(try start(c, SessionRequest(app: "parsec"))?.get(), SessionStart(displayID: 7))
        XCTAssertTrue(fake.made.isEmpty)
        XCTAssertEqual(fake.placed.map(\.0), [7])
        c.end(app: "parsec")
        XCTAssertTrue(fake.removed.isEmpty)
    }

    func testAdoptWaitsForTheDisplayToCome() {
        let fake = FakeSessionDisplays()
        var profile = SessionProfile()
        profile.display = .adopt
        profile.adoptName = "jump"
        let c = coordinator(fake, profiles: ["jumpdesktop": profile])
        c.adoptInterval = 0.05
        var result: Result<SessionStart, SessionError>?
        c.begin(SessionRequest(app: "jumpdesktop")) { result = $0 }
        XCTAssertNil(result)
        fake.others = ["Jump Desktop Display": 9]
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(try result?.get().displayID, 9)
    }

    func testAdoptWaitsForADisplayToldOfToBeListed() {
        let fake = FakeSessionDisplays()
        var profile = SessionProfile()
        profile.display = .adopt
        profile.placement = .main
        let c = coordinator(fake, profiles: ["opendisplay": profile])
        c.adoptInterval = 0.05
        // Another display goes by the name, but the app told of its own.
        fake.others = ["OpenDisplay (other)": 3]
        var request = SessionRequest(app: "opendisplay")
        request.adoptedDisplayID = 8
        var result: Result<SessionStart, SessionError>?
        c.begin(request) { result = $0 }
        XCTAssertNil(result)
        XCTAssertTrue(fake.placed.isEmpty)
        fake.others["OpenDisplay"] = 8
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(try result?.get(), SessionStart(displayID: 8))
        XCTAssertEqual(fake.placed.map(\.0), [8])
    }

    func testAdoptCarriesOnWithoutTheDisplay() {
        let fake = FakeSessionDisplays()
        var profile = SessionProfile()
        profile.display = .adopt
        profile.audioOutputUID = "blackhole"
        let c = coordinator(fake, profiles: ["splashtop": profile])
        c.adoptInterval = 0.001
        var result: Result<SessionStart, SessionError>?
        c.begin(SessionRequest(app: "splashtop")) { result = $0 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(try result?.get().displayID)
        XCTAssertEqual(try result?.get().warnings.count, 1)
        XCTAssertEqual(fake.outputUID, "blackhole")
    }

    func testAnotherAppsDisplayIsAdoptedByDefault() {
        let c = coordinator(FakeSessionDisplays())
        XCTAssertEqual(c.profile(for: "display").display, .adopt)
        XCTAssertEqual(c.profile(for: "opendisplay").display, .adopt)
        XCTAssertEqual(c.profile(for: "rustdesk").display, .create)
    }

    func testDisplayDetectorFollowsTheNamedDisplay() {
        var online: [(id: CGDirectDisplayID, name: String)] = [(1, "lenovo")]
        let detector = DisplaySessionDetector(app: "display", name: { "jump" }, displays: { online })
        var events: [SessionEvent] = []
        detector.onEvent = { events.append($0) }
        detector.check()
        XCTAssertTrue(events.isEmpty)
        online.append((5, "Jump Desktop"))
        detector.check()
        detector.check()
        XCTAssertEqual(events, [.opened(key: "5", client: nil, display: .own(5))])
        online.removeLast()
        detector.check()
        XCTAssertEqual(events.last, .closed(key: "5"))
    }

    func testOpenDisplayLines() {
        XCTAssertEqual(SessionLogLines.openDisplay("[11:43:29.019] capture started: 2048x1536 display 4128835 generation 1 mode extend localCursor=true session wifi:Mo's iPad"),
                       .opened(key: "wifi:Mo's iPad", client: "Mo's iPad", display: .own(4128835)))
        XCTAssertEqual(SessionLogLines.openDisplay("[11:42:58.450] capture started: 1600x900 display 731413954 generation 1 mode mirror localCursor=true session usb:00008103-001"),
                       .opened(key: "usb:00008103-001", client: nil, display: .mac))
        XCTAssertEqual(SessionLogLines.openDisplay("[11:44:00.000] capture ended: session wifi:Mo's iPad"),
                       .closed(key: "wifi:Mo's iPad"))
        // Before the fork named the session.
        XCTAssertNil(SessionLogLines.openDisplay("[11:43:29.019] capture started: 2048x1536 display 4128835 generation 1 mode extend localCursor=true"))
        XCTAssertNil(SessionLogLines.openDisplay("[11:43:29.019] status[wifi:iPad]: Extending to iPad (2048×1536)"))
    }

    func testLogDetectorEndsWhenTheAppQuits() {
        var running = false
        let detector = LogSessionDetector(app: "opendisplay", url: URL(fileURLWithPath: "/nonexistent"),
                                          parse: SessionLogLines.openDisplay, isRunning: { running })
        var events: [SessionEvent] = []
        detector.onEvent = { events.append($0) }
        // Never seen running, as when the lines are written by hand: they still count.
        detector.handle("capture started: 1x1 display 5 generation 1 mode extend localCursor=true session wifi:iPad")
        detector.checkRunning()
        XCTAssertEqual(events.count, 1)
        running = true
        detector.checkRunning()
        running = false
        detector.checkRunning()
        XCTAssertEqual(events.last, .closed(key: "wifi:iPad"))
        detector.stop()
        XCTAssertEqual(events.count, 2)
    }

    func testLogDetectorTakesUpWhatTheLogLeftOpen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("opendisplay.log")
        try """
        [1] capture started: 1x1 display 5 generation 1 mode extend localCursor=true session wifi:old
        [2] capture ended: session wifi:old
        [3] capture started: 1x1 display 5 generation 1 mode extend localCursor=true session wifi:iPad
        [4] capture started: 1x1 display 6 generation 2 mode extend localCursor=true session wifi:iPad
        [5] capture started: 1x1 display 1 generation 1 mode mirror localCursor=true session usb:x

        """.write(to: url, atomically: false, encoding: .utf8)
        var running = false
        var events: [SessionEvent] = []
        let quit = LogSessionDetector(app: "opendisplay", url: url, parse: SessionLogLines.openDisplay, isRunning: { running })
        quit.onEvent = { events.append($0) }
        quit.start()
        quit.stop()
        // The app isn't running, so what the log left open is over.
        XCTAssertTrue(events.isEmpty)

        running = true
        let detector = LogSessionDetector(app: "opendisplay", url: url, parse: SessionLogLines.openDisplay, isRunning: { running })
        detector.onEvent = { events.append($0) }
        detector.start()
        defer { detector.stop() }
        XCTAssertEqual(events, [.opened(key: "wifi:iPad", client: "iPad", display: .own(6)),
                                .opened(key: "usb:x", client: nil, display: .mac)])
        XCTAssertEqual(LogSessionDetector.lastLines(of: url, bytes: 20).count, 0)
    }

    func testWatcherAdoptsTheDisplayTheDetectorSaw() {
        final class FakeDetector: SessionDetector {
            let app: String
            var onEvent: ((SessionEvent) -> Void)?
            init(app: String) { self.app = app }
            func start() {}
            func stop() {}
        }
        let fake = FakeSessionDisplays()
        var profile = SessionProfile()
        profile.watch = true
        profile.display = .adopt
        profile.placement = .main
        let c = coordinator(fake, profiles: ["opendisplay": profile])
        fake.others = ["OpenDisplay iPad": 7]
        var detector: FakeDetector?
        let watcher = SessionWatcher(coordinator: c) { app in
            guard app == "opendisplay" else { return nil }
            detector = FakeDetector(app: app)
            return detector
        }
        watcher.update()
        // Extending: its own display, by ID.
        detector?.onEvent?(.opened(key: "wifi:iPad", client: "iPad", display: .own(7)))
        XCTAssertEqual(c.sessions["opendisplay"]?.displayID, 7)
        XCTAssertEqual(c.sessions["opendisplay"]?.followsApp, true)
        XCTAssertEqual(fake.placed.map(\.0), [7])
        detector?.onEvent?(.closed(key: "wifi:iPad"))
        // Mirroring: the Mac's screen, so nothing to adopt or place.
        detector?.onEvent?(.opened(key: "wifi:iPad", client: "iPad", display: .mac))
        XCTAssertEqual(c.sessions["opendisplay"]?.starting, false)
        XCTAssertNil(c.sessions["opendisplay"]?.displayID)
        XCTAssertEqual(c.sessions["opendisplay"]?.followsApp, true)
        XCTAssertEqual(fake.placed.count, 1)
        detector?.onEvent?(.closed(key: "wifi:iPad"))
        XCTAssertNil(c.sessions["opendisplay"])
        XCTAssertTrue(fake.made.isEmpty)
        XCTAssertTrue(fake.removed.isEmpty)
    }

    func testChromeRemoteDesktopLines() {
        XCTAssertEqual(SessionLogLines.chromeRemoteDesktop("Oct 18 12:00:00 host remoting_me2me_host[1]: Client connected: me@example.com/chromoting_ftl_1234"),
                       .opened(key: "me@example.com/chromoting_ftl_1234", client: "me@example.com"))
        XCTAssertEqual(SessionLogLines.chromeRemoteDesktop("Client disconnected: me@example.com/chromoting_ftl_1234"),
                       .closed(key: "me@example.com/chromoting_ftl_1234"))
        XCTAssertNil(SessionLogLines.chromeRemoteDesktop("Channel IP for client: me@example.com/x ip='1.2.3.4'"))
    }

    func testLogsCanBeMovedForTests() {
        let defaults = UserDefaults(suiteName: "dam.tests.\(UUID().uuidString)")!
        let standard = URL(fileURLWithPath: "/var/log/app.log")
        XCTAssertEqual(SessionDetectors.logURL(for: "rustdesk", standard: standard, defaults: defaults), standard)
        defaults.set(["rustdesk": "/tmp/rustdesk.log"], forKey: "SessionDetectorLogs")
        XCTAssertEqual(SessionDetectors.logURL(for: "rustdesk", standard: standard, defaults: defaults).path, "/tmp/rustdesk.log")
        XCTAssertEqual(SessionDetectors.logURL(for: "parsec", standard: standard, defaults: defaults), standard)
    }

    func testProcessNamesAreMatchedAsTheSystemCutsThem() {
        // TeamViewer_Desktop is longer than the 16 characters kept.
        XCTAssertFalse(RunningProcesses.isRunning("TeamViewer_Desktop_not_running_here"))
        XCTAssertTrue(RunningProcesses.isRunning("launchd"))
    }

    // MARK: - Blackout

    func testBlackoutKeepsTheSessionsDisplayLitUntilItEnds() {
        let fake = FakeSessionDisplays()
        var profile = SessionProfile()
        profile.blackout = true
        let c = coordinator(fake, profiles: ["rustdesk": profile])
        _ = start(c, SessionRequest(app: "rustdesk"))
        XCTAssertEqual(fake.blackoutKeeping, [100])
        XCTAssertTrue(c.isBlackedOut)
        c.end(app: "rustdesk")
        XCTAssertNil(fake.blackoutKeeping)
    }

    func testADisplayGoneIsForgottenAndTheSessionGoesOn() {
        let fake = FakeSessionDisplays()
        var profile = SessionProfile()
        profile.blackout = true
        let c = coordinator(fake, profiles: ["rustdesk": profile])
        _ = start(c, SessionRequest(app: "rustdesk"))
        XCTAssertEqual(fake.blackoutKeeping, [100])
        c.displayGone(100)
        XCTAssertNil(c.sessions["rustdesk"]?.displayID)
        // Still blacked out, keeping nothing lit, and nothing of its own is removed at the end.
        XCTAssertEqual(fake.blackoutKeeping, [])
        c.end(app: "rustdesk")
        XCTAssertTrue(fake.removed.isEmpty)
        XCTAssertNil(fake.blackoutKeeping)
    }

    func testLiftingTheBlackoutKeepsTheSession() {
        let fake = FakeSessionDisplays()
        let c = coordinator(fake)
        _ = start(c, SessionRequest(app: "sunshine", blackout: true))
        c.liftBlackout()
        XCTAssertNil(fake.blackoutKeeping)
        XCTAssertFalse(c.isBlackedOut)
        XCTAssertNotNil(c.sessions["sunshine"])
    }

    func testBlackoutOption() throws {
        XCTAssertEqual(try ControlCLI.request(from: ["session", "start", "--app", "x", "--blackout", "yes"], environment: [:]).blackout, true)
        XCTAssertThrowsError(try ControlCLI.request(from: ["session", "start", "--app", "x", "--blackout", "maybe"], environment: [:]))
    }

    // MARK: - Added apps

    func testAddedAppLogLines() throws {
        let parse = try XCTUnwrap(SessionLogLines.custom(opened: #"#(?<id>\d+) Connection opened from (?<client>[\d.]+)"#,
                                                          closed: #"#(?<id>\d+) Connection closed"#))
        XCTAssertEqual(parse("12:00 #7 Connection opened from 10.0.0.2:4000"), .opened(key: "7", client: "10.0.0.2"))
        XCTAssertEqual(parse("12:05 #7 Connection closed: reset"), .closed(key: "7"))
        XCTAssertNil(parse("12:05 something else"))
        // Without an id in both, one session runs from the first open to the next close.
        let plain = try XCTUnwrap(SessionLogLines.custom(opened: "client joined", closed: "client left"))
        XCTAssertEqual(plain("a client joined"), .opened(key: "", client: nil))
        XCTAssertEqual(plain("a client left"), .closed(key: ""))
        XCTAssertNil(SessionLogLines.custom(opened: "(", closed: "left"))
        XCTAssertNil(SessionLogLines.custom(opened: "joined", closed: ""))
    }

    func testAddedAppIDs() {
        XCTAssertEqual(RemoteSessionApp.id(forName: "Jump Desktop", taken: []), "jump-desktop")
        XCTAssertEqual(RemoteSessionApp.id(forName: "Jump Desktop", taken: ["jump-desktop"]), "jump-desktop-2")
        XCTAssertEqual(RemoteSessionApp.id(forName: "Parsec", taken: []), "parsec-2")
        XCTAssertEqual(RemoteSessionApp.id(forName: "!!", taken: []), "app")
    }

    func testAddingAndRemovingAnApp() {
        let fake = FakeSessionDisplays()
        let c = coordinator(fake)
        let app = c.addApp(named: "Jump Desktop", kind: .display)
        XCTAssertEqual(c.addedApps, [app])
        XCTAssertEqual(RemoteSessionApp.name(of: app), "Jump Desktop")
        XCTAssertEqual(c.profile(for: app).display, .adopt)
        XCTAssertEqual(c.profile(for: app).detection?.problem(adoptName: nil), "Give part of its display's name.")
        fake.others = ["Jump Desktop Display": 200]
        var mine = c.profile(for: app)
        mine.adoptName = "Jump"
        c.setProfile(mine, for: app)
        XCTAssertEqual(start(c, SessionRequest(app: app)), .success(SessionStart(displayID: 200)))
        c.removeApp(app)
        XCTAssertNil(c.sessions[app])
        XCTAssertTrue(c.addedApps.isEmpty)
        XCTAssertEqual(RemoteSessionApp.name(of: app), app)
        // A known app isn't removed.
        var rustDesk = c.profile(for: "rustdesk")
        rustDesk.watch = false
        c.setProfile(rustDesk, for: "rustdesk")
        c.removeApp("rustdesk")
        XCTAssertEqual(c.profile(for: "rustdesk"), rustDesk)
        XCTAssertTrue(c.addedApps.isEmpty)
    }

    func testAddedProfileRoundTrips() throws {
        var profile = SessionProfile()
        profile.name = "Mine"
        var detection = SessionDetection()
        detection.logPath = "~/x.log"
        detection.opened = "in"
        detection.closed = "out"
        profile.detection = detection
        detection.logProcessName = "minehost"
        profile.detection = detection
        let decoded = try JSONDecoder().decode(SessionProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded, profile)
        XCTAssertNil(try JSONDecoder().decode(SessionProfile.self, from: Data("{}".utf8)).detection)
        // Saved before it had a process.
        let older = try JSONDecoder().decode(SessionDetection.self, from: Data(#"{"kind":"log","logPath":"~/x.log"}"#.utf8))
        XCTAssertEqual(older.logProcessName, "")
        XCTAssertEqual(older.logPath, "~/x.log")
    }

    func testAnAddedAppsLogCountsOnlyWhileItsProcessRuns() throws {
        func detector(process: String) throws -> LogSessionDetector {
            var detection = SessionDetection()
            detection.logPath = "/nonexistent/x.log"
            detection.opened = "client joined"
            detection.closed = "client left"
            detection.logProcessName = process
            return try XCTUnwrap(SessionDetectors.make(added: "mine", detection, adoptName: nil) as? LogSessionDetector)
        }
        var events: [SessionEvent] = []
        let gone = try detector(process: "minehost_not_running_here")
        gone.onEvent = { events.append($0) }
        gone.handle("a client joined")
        XCTAssertTrue(events.isEmpty)
        let running = try detector(process: "launchd")
        running.onEvent = { events.append($0) }
        running.handle("a client joined")
        XCTAssertEqual(events, [.opened(key: "", client: nil)])
        // Without one, as before.
        let none = try detector(process: "")
        none.onEvent = { events.append($0) }
        none.handle("a client joined")
        XCTAssertEqual(events.count, 2)
    }

    func testALogCountingOnlyWhileTheAppRunsEndsWhenItQuits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("x.log")
        try "a client joined\n".write(to: url, atomically: false, encoding: .utf8)
        let parse = try XCTUnwrap(SessionLogLines.custom(opened: "client joined", closed: "client left"))
        var running = true
        var events: [SessionEvent] = []
        let detector = LogSessionDetector(app: "mine", url: url, parse: parse, isRunning: { running },
                                          takesUpOpen: false, opensWhileRunning: true)
        detector.onEvent = { events.append($0) }
        detector.start()
        defer { detector.stop() }
        // What the log shows open isn't taken up.
        XCTAssertTrue(events.isEmpty)
        running = false
        detector.checkRunning()
        detector.handle("a client joined")
        XCTAssertTrue(events.isEmpty)
        // Quits before the next look: the open saw it running, so the quit still ends it.
        running = true
        detector.handle("a client joined")
        running = false
        detector.checkRunning()
        XCTAssertEqual(events, [.opened(key: "", client: nil), .closed(key: "")])
    }

    func testWatcherRemakesAnAddedAppsDetector() {
        final class FakeDetector: SessionDetector {
            let app: String
            var onEvent: ((SessionEvent) -> Void)?
            var running = false
            init(app: String) { self.app = app }
            func start() { running = true }
            func stop() { running = false }
        }
        let c = coordinator(FakeSessionDisplays())
        let app = c.addApp(named: "Mine", kind: .process)
        var made: [FakeDetector] = []
        let watcher = SessionWatcher(coordinator: c) { name in
            guard name == app else { return nil }
            let d = FakeDetector(app: name)
            made.append(d)
            return d
        }
        watcher.update()
        XCTAssertEqual(made.count, 1)
        var profile = c.profile(for: app)
        profile.detection?.processName = "minehost"
        c.setProfile(profile, for: app)
        watcher.update()
        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(made[0].running, false)
        XCTAssertEqual(made[1].running, true)
        // Not during a session, which stopping it would end: once it ends.
        made[1].onEvent?(.opened(key: "minehost", client: nil))
        XCTAssertNotNil(c.sessions[app])
        profile.detection?.processName = "minehost2"
        c.setProfile(profile, for: app)
        watcher.update()
        XCTAssertEqual(made.count, 2)
        XCTAssertNotNil(c.sessions[app])
        XCTAssertTrue(watcher.waitsForSessionEnd(app))
        made[1].onEvent?(.closed(key: "minehost"))
        XCTAssertNil(c.sessions[app])
        watcher.update()
        XCTAssertEqual(made.count, 3)
        XCTAssertFalse(watcher.waitsForSessionEnd(app))
        c.removeApp(app)
        watcher.update()
        XCTAssertEqual(made[2].running, false)
        XCTAssertNil(watcher.detectors[app])
    }
}

// MARK: - What failed isn't learned

extension RemoteSessionsTests {
    func testAFailedPlacementIsntKept() {
        let fake = FakeSessionDisplays()
        fake.placeSucceeds = false
        var profile = SessionProfile()
        profile.placement = .main
        let c = coordinator(fake, profiles: ["rustdesk": profile])
        _ = start(c, SessionRequest(app: "rustdesk"))
        c.end(app: "rustdesk")
        XCTAssertEqual(c.profile(for: "rustdesk"), profile)
    }

    func testAPlacementChangedAfterAFailedOneIsKept() {
        let fake = FakeSessionDisplays()
        fake.placeSucceeds = false
        var profile = SessionProfile()
        profile.placement = .main
        let c = coordinator(fake, profiles: ["rustdesk": profile])
        _ = start(c, SessionRequest(app: "rustdesk"))
        fake.placements[100] = .mirror
        c.end(app: "rustdesk")
        XCTAssertEqual(c.profile(for: "rustdesk").placement, .mirror)
    }

    func testAnOutputThatWasntConnectedIsntKept() {
        let fake = FakeSessionDisplays()
        var profile = SessionProfile()
        profile.audioOutputUID = "gone"
        let c = coordinator(fake, profiles: ["sunshine": profile])
        _ = start(c, SessionRequest(app: "sunshine"))
        XCTAssertEqual(fake.outputUID, "speakers")
        c.end(app: "sunshine")
        XCTAssertEqual(c.profile(for: "sunshine"), profile)
    }

    func testAFailedOutputAskedForIsntKept() {
        let fake = FakeSessionDisplays()
        let c = coordinator(fake)
        _ = start(c, SessionRequest(app: "sunshine", audioOutputUID: "gone"))
        c.end(app: "sunshine")
        XCTAssertNil(c.profile(for: "sunshine").audioOutputUID)
    }

    func testASizeTheDisplayCouldntTakeIsntKept() {
        let fake = FakeSessionDisplays()
        fake.madeAs = StreamingDisplayModes.Mode(width: 1920, height: 1080, refreshRate: 60)
        let c = coordinator(fake)
        _ = start(c, SessionRequest(app: "sunshine", width: 1280, height: 800, fps: 60))
        c.end(app: "sunshine")
        XCTAssertNil(c.profile(for: "sunshine").width)

        // Changed from there, it is.
        _ = start(c, SessionRequest(app: "sunshine", width: 1280, height: 800, fps: 60))
        fake.modes[100] = StreamingDisplayModes.Mode(width: 1600, height: 900, refreshRate: 60)
        c.end(app: "sunshine")
        XCTAssertEqual(c.profile(for: "sunshine").width, 1600)
    }

    func testTheRemainingOwnersOutputComesBack() {
        let fake = FakeSessionDisplays()
        fake.connectedOutputs.insert("headphones")
        var blackhole = SessionProfile()
        blackhole.audioOutputUID = "blackhole"
        var headphones = SessionProfile()
        headphones.audioOutputUID = "headphones"
        let c = coordinator(fake, profiles: ["sunshine": blackhole, "rustdesk": headphones])
        _ = start(c, SessionRequest(app: "sunshine"))
        fake.nextID = 101
        _ = start(c, SessionRequest(app: "rustdesk"))
        XCTAssertEqual(fake.outputUID, "headphones")
        c.end(app: "rustdesk")
        XCTAssertEqual(fake.outputUID, "blackhole")
        c.end(app: "sunshine")
        XCTAssertEqual(fake.outputUID, "speakers")
        XCTAssertEqual(c.profile(for: "sunshine").audioOutputUID, "blackhole")
        XCTAssertEqual(c.profile(for: "rustdesk").audioOutputUID, "headphones")
    }

    func testAnOutputPickedBetweenTwoOwnersIsntKept() {
        let fake = FakeSessionDisplays()
        fake.connectedOutputs.formUnion(["headphones", "tv"])
        var blackhole = SessionProfile()
        blackhole.audioOutputUID = "blackhole"
        var headphones = SessionProfile()
        headphones.audioOutputUID = "headphones"
        let c = coordinator(fake, profiles: ["sunshine": blackhole, "rustdesk": headphones])
        _ = start(c, SessionRequest(app: "sunshine"))
        fake.nextID = 101
        _ = start(c, SessionRequest(app: "rustdesk"))
        // Whose it was can't be told: it stays, and neither keeps it.
        fake.outputUID = "tv"
        c.end(app: "rustdesk")
        XCTAssertEqual(fake.outputUID, "tv")
        c.end(app: "sunshine")
        XCTAssertEqual(c.profile(for: "sunshine").audioOutputUID, "blackhole")
        XCTAssertEqual(c.profile(for: "rustdesk").audioOutputUID, "headphones")
    }

    func testAnotherSessionTakingMainIsntKept() {
        let fake = FakeSessionDisplays()
        let c = coordinator(fake)
        _ = start(c, SessionRequest(app: "parsec"))
        fake.nextID = 101
        _ = start(c, SessionRequest(app: "rustdesk"))
        XCTAssertEqual(fake.placements[100], .extend)
        c.end(app: "parsec")
        XCTAssertNil(c.profiles["parsec"])
        XCTAssertEqual(c.profile(for: "parsec").placement, .main)
        // A change of its own after still is.
        fake.placements[101] = .mirror
        c.end(app: "rustdesk")
        XCTAssertEqual(c.profile(for: "rustdesk").placement, .mirror)
    }

    func testAnotherSessionsRestoreIsntKept() {
        let fake = FakeSessionDisplays()
        var switching = SessionProfile()
        switching.audioOutputUID = "blackhole"
        let c = coordinator(fake, profiles: ["sunshine": switching, "rustdesk": SessionProfile()])
        _ = start(c, SessionRequest(app: "sunshine"))
        fake.nextID = 101
        // Starts with Sunshine's output on.
        _ = start(c, SessionRequest(app: "rustdesk"))
        c.end(app: "sunshine")
        XCTAssertEqual(fake.outputUID, "speakers")
        c.end(app: "rustdesk")
        XCTAssertNil(c.profile(for: "rustdesk").audioOutputUID)
    }

    // MARK: Quitting while starting

    func testQuittingWhileStartingLeavesNothingForTheNextLaunch() {
        let fake = FakeSessionDisplays()
        fake.pendingMakes = []
        var profile = SessionProfile()
        profile.audioOutputUID = "blackhole"
        let c = coordinator(fake, profiles: ["sunshine": profile])
        var result: Result<SessionStart, SessionError>?
        c.begin(SessionRequest(app: "sunshine")) { result = $0 }
        c.endAll()
        XCTAssertTrue(c.sessions.isEmpty)
        XCTAssertFalse(fake.holdsLayout)
        guard case .failure(.notActive("sunshine")) = result else { return XCTFail("not given up on") }
        // The display comes after all, and goes; nothing is switched.
        fake.pendingMakes?.forEach { $0() }
        XCTAssertEqual(fake.removed, [100])
        XCTAssertEqual(fake.outputUID, "speakers")
        // Changed since, which the next launch leaves.
        fake.outputUID = "blackhole"
        _ = coordinator(fake)
        XCTAssertEqual(fake.outputUID, "blackhole")
    }

    // MARK: Links

    private func refusedAsNotFromLink(_ result: Result<Void, SessionError>) -> Bool {
        if case .failure(.notFromLink) = result { return true }
        return false
    }

    func testALinkCantEndOrJoinASessionItDidntStart() {
        let fake = FakeSessionDisplays()
        let c = coordinator(fake)
        _ = start(c, SessionRequest(app: "rustdesk"))
        XCTAssertTrue(refusedAsNotFromLink(c.end(app: "rustdesk", all: true, from: .link)))
        guard case .failure(.notFromLink("rustdesk")) = start(c, SessionRequest(app: "rustdesk", origin: .link)) else {
            return XCTFail("joined")
        }
        XCTAssertEqual(c.sessions["rustdesk"]?.count, 1)
        // So the app's own end ends it.
        c.end(app: "rustdesk")
        XCTAssertNil(c.sessions["rustdesk"])
        XCTAssertEqual(fake.removed, [100])
    }

    func testALinkEndsOnlyWhatLinksStarted() {
        let fake = FakeSessionDisplays()
        let c = coordinator(fake)
        _ = start(c, SessionRequest(app: "sunshine", origin: .link))
        XCTAssertNoThrow(try start(c, SessionRequest(app: "sunshine", origin: .link))?.get())
        _ = start(c, SessionRequest(app: "sunshine"))
        XCTAssertEqual(c.sessions["sunshine"]?.count, 3)
        XCTAssertNoThrow(try c.end(app: "sunshine", all: true, from: .link).get())
        XCTAssertEqual(c.sessions["sunshine"]?.count, 1)
        XCTAssertTrue(refusedAsNotFromLink(c.end(app: "sunshine", from: .link)))
        c.end(app: "sunshine")
        XCTAssertNil(c.sessions["sunshine"])
    }

    func testALinkCantBlackOutTheScreens() throws {
        let fake = FakeSessionDisplays()
        var profile = SessionProfile()
        profile.blackout = true
        let c = coordinator(fake, profiles: ["rustdesk": profile])
        // Asking to is refused, with nothing set up.
        XCTAssertEqual(start(c, SessionRequest(app: "sunshine", origin: .link, blackout: true)), .failure(.blackoutFromLink))
        XCTAssertNil(c.sessions["sunshine"])
        XCTAssertTrue(fake.made.isEmpty)
        // A profile that blacks out doesn't for a link, which is told.
        let started = try XCTUnwrap(try start(c, SessionRequest(app: "rustdesk", origin: .link))?.get())
        XCTAssertEqual(started.displayID, 100)
        XCTAssertEqual(started.warnings, ["The screens weren't blacked out, as a link can't black them out."])
        XCTAssertNil(fake.blackoutKeeping)
        XCTAssertFalse(c.isBlackedOut)
        c.end(app: "rustdesk", from: .link)
        // Nor is the profile changed, so the app's own sessions still black out.
        XCTAssertTrue(c.profile(for: "rustdesk").blackout)
        XCTAssertNoThrow(try start(c, SessionRequest(app: "rustdesk"))?.get())
        XCTAssertEqual(fake.blackoutKeeping, [100])
        // Asking not to is a link's to ask.
        c.end(app: "rustdesk")
        XCTAssertNoThrow(try start(c, SessionRequest(app: "sunshine", origin: .link, blackout: false))?.get())
    }

    func testALinkCantAdoptADisplay() {
        let fake = FakeSessionDisplays()
        fake.others = ["Built-in Retina Display": 1]
        let c = coordinator(fake)
        XCTAssertEqual(start(c, SessionRequest(app: "retina", origin: .link, display: .adopt, placement: .mirror)),
                       .failure(.adoptFromLink))
        XCTAssertNil(c.sessions["retina"])
        XCTAssertTrue(fake.placed.isEmpty)
        // The command line can.
        XCTAssertNoThrow(try start(c, SessionRequest(app: "retina", display: .adopt, placement: .mirror))?.get())
    }

    func testAnAppsStartJoiningALinksSessionSetsItUpAgain() throws {
        let fake = FakeSessionDisplays()
        var profile = SessionProfile()
        profile.blackout = true
        profile.audioOutputUID = "blackhole"
        let c = coordinator(fake, profiles: ["rustdesk": profile])
        _ = start(c, SessionRequest(app: "rustdesk", origin: .link, audioOutputUID: "speakers"))
        XCTAssertNil(fake.blackoutKeeping)
        XCTAssertEqual(fake.outputUID, "speakers")
        // The app's own start, as its profile says, not as the link asked.
        fake.nextID = 101
        let started = try XCTUnwrap(try start(c, SessionRequest(app: "rustdesk", origin: .detector))?.get())
        XCTAssertEqual(started.displayID, 101)
        XCTAssertEqual(fake.removed, [100])
        XCTAssertEqual(fake.blackoutKeeping, [101])
        XCTAssertEqual(fake.outputUID, "blackhole")
        XCTAssertEqual(c.sessions["rustdesk"]?.count, 2)
        XCTAssertEqual(c.sessions["rustdesk"]?.fromLinks, 1)
        // The link's end leaves it on; the app's ends it.
        XCTAssertNoThrow(try c.end(app: "rustdesk", from: .link).get())
        XCTAssertEqual(c.sessions["rustdesk"]?.count, 1)
        XCTAssertTrue(refusedAsNotFromLink(c.end(app: "rustdesk", from: .link)))
        c.end(app: "rustdesk")
        XCTAssertNil(c.sessions["rustdesk"])
        XCTAssertEqual(fake.removed, [100, 101])
        XCTAssertNil(fake.blackoutKeeping)
        XCTAssertEqual(fake.outputUID, "speakers")
    }

    func testAnAppsStartJoiningALinksSessionBeingSetUpWaitsForIt() throws {
        let fake = FakeSessionDisplays()
        fake.pendingMakes = []
        let c = coordinator(fake)
        var linkResult: Result<SessionStart, SessionError>?
        var result: Result<SessionStart, SessionError>?
        c.begin(SessionRequest(app: "sunshine", origin: .link)) { linkResult = $0 }
        c.begin(SessionRequest(app: "sunshine")) { result = $0 }
        XCTAssertNil(result)
        XCTAssertEqual(fake.made.count, 1)
        // The link's display comes, and goes for the app's own.
        fake.nextID = 101
        let first = try XCTUnwrap(fake.pendingMakes?.removeFirst())
        first()
        XCTAssertEqual(try linkResult?.get().displayID, 100)
        XCTAssertEqual(fake.removed, [100])
        XCTAssertEqual(fake.made.count, 2)
        fake.pendingMakes?.forEach { $0() }
        XCTAssertEqual(try result?.get().displayID, 101)
        XCTAssertEqual(c.sessions["sunshine"]?.count, 2)
        XCTAssertEqual(c.sessions["sunshine"]?.fromLinks, 1)
    }

    func testAnAdoptedDisplaysPlacementIsPutBack() {
        let fake = FakeSessionDisplays()
        fake.others = ["Foo Display": 7]
        let c = coordinator(fake)
        _ = start(c, SessionRequest(app: "foo", display: .adopt, placement: .main))
        XCTAssertEqual(fake.placements[7], .main)
        c.end(app: "foo")
        XCTAssertEqual(fake.unplaced.map(\.0), [7])
        XCTAssertEqual(fake.unplaced.first?.1, .main)
        XCTAssertEqual(fake.unplaced.first?.main, 1)

        _ = start(c, SessionRequest(app: "foo", display: .adopt, placement: .mirror))
        c.end(app: "foo")
        XCTAssertEqual(fake.unplaced.last?.1, .mirror)

        // Main already before: nothing of DAM's to put back.
        fake.unplaced = []
        fake.placements[7] = .main
        _ = start(c, SessionRequest(app: "foo", display: .adopt, placement: .main))
        c.end(app: "foo")
        XCTAssertTrue(fake.unplaced.isEmpty)
    }

    // MARK: Sessions only DAM sees

    func testARequestsAdoptingSessionCanBeEnded() {
        let fake = FakeSessionDisplays()
        fake.others = ["Foo Display": 7]
        let c = coordinator(fake)
        _ = start(c, SessionRequest(app: "foo", display: .adopt, placement: .mirror))
        // No detector would see the app's end, so it is ended as any other.
        XCTAssertEqual(c.sessions["foo"]?.followsApp, false)
        XCTAssertNoThrow(try c.end(app: "foo", all: true).get())
        XCTAssertTrue(fake.removed.isEmpty)

        _ = start(c, SessionRequest(app: "foo", origin: .detector, display: .adopt))
        XCTAssertEqual(c.sessions["foo"]?.followsApp, true)
    }

    func testNoDisplayToAdoptLeavesTheScreensLit() throws {
        let fake = FakeSessionDisplays()
        let c = coordinator(fake)
        c.adoptInterval = 0.001
        var result: Result<SessionStart, SessionError>?
        c.begin(SessionRequest(app: "foo", display: .adopt, blackout: true)) { result = $0 }
        let done = expectation(description: "gave up looking")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { done.fulfill() }
        wait(for: [done], timeout: 2)
        let start = try XCTUnwrap(try result?.get())
        XCTAssertNil(start.displayID)
        XCTAssertEqual(start.warnings.count, 2)
        XCTAssertNil(fake.blackoutKeeping)
        XCTAssertFalse(c.isBlackedOut)
    }

    // MARK: Detectors

    func testOpenDisplayLineTimes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 1)))
        let today = try XCTUnwrap(SessionLogLines.openDisplayTime(of: "[00:30:00.250] capture ended: session x", now: now, calendar: calendar))
        XCTAssertEqual(today.timeIntervalSince(now), -1800 + 0.25, accuracy: 0.001)
        // Later in the day than now: yesterday's.
        let yesterday = SessionLogLines.openDisplayTime(of: "[23:59:00.000] capture ended: session x", now: now, calendar: calendar)
        XCTAssertEqual(yesterday, now - 3600 - 60)
        XCTAssertNil(SessionLogLines.openDisplayTime(of: "capture ended: session x", now: now, calendar: calendar))
        XCTAssertNil(SessionLogLines.openDisplayTime(of: "[1] capture ended: session x", now: now, calendar: calendar))
    }

    /// The time of a test line's `[seconds]`.
    private static func secondsTime(_ line: String) -> Date? {
        SessionLogLines.captures(#"^\[(\d+)\]"#, in: line).flatMap { Double($0[0]) }.map { Date(timeIntervalSince1970: $0) }
    }

    func testLinesFromBeforeTheAppStartedAreLeftOut() {
        let lines = ["[1] a", "no time", "[5] b", "more", "[9] c"]
        XCTAssertEqual(LogSessionDetector.lines(lines, since: Date(timeIntervalSince1970: 5.5), time: Self.secondsTime),
                       ["[5] b", "more", "[9] c"])
        XCTAssertEqual(LogSessionDetector.lines(lines, since: Date(timeIntervalSince1970: 20), time: Self.secondsTime), [])
    }

    func testAnOpenDisplayLineFromDaysAgoIsLeftOut() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 12)))
        // Two days ago, at a time of day after the start's; then today's lines, over midnight.
        let lines = [
            "[11:00:00.000] capture started: 1x1 display 5 generation 1 mode extend localCursor=true session wifi:old",
            "[23:50:00.000] status",
            "[00:10:00.000] status",
            "[10:05:00.000] status"
        ]
        let time = { SessionLogLines.openDisplayTime(of: $0, now: now, calendar: calendar) }
        XCTAssertEqual(LogSessionDetector.lines(lines, since: now - 13 * 3600, time: time), Array(lines[1...]))
        XCTAssertEqual(LogSessionDetector.lines(lines, since: now - 3 * 3600, time: time), [lines[3]])
    }

    func testOpenDisplayRunningOverADayTakesNothingUp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("opendisplay.log")
        try "[1] capture started: 1x1 display 6 generation 1 mode extend localCursor=true session wifi:new\n"
            .write(to: url, atomically: false, encoding: .utf8)
        // Every line's time of day dates it within the last day.
        let recent: (String) -> Date? = { _ in Date() - 60 }
        for (launched, taken) in [(Date() - 3600, true), (Date() - 2 * LogSessionDetector.day, false)] {
            var events: [SessionEvent] = []
            let detector = LogSessionDetector(app: "opendisplay", url: url, parse: SessionLogLines.openDisplay,
                                              isRunning: { true }, launched: { launched }, lineTime: recent,
                                              timesOfDay: true)
            detector.onEvent = { events.append($0) }
            detector.start()
            XCTAssertEqual(events.isEmpty, !taken)
            detector.stop()
        }
    }

    func testOpenDisplayIsntRevivedFromAnEarlierRun() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("opendisplay.log")
        // A session a crash left open, then one since the app started again.
        try """
        [100] capture started: 1x1 display 5 generation 1 mode extend localCursor=true session wifi:old
        [200] started
        [300] capture started: 1x1 display 6 generation 1 mode extend localCursor=true session wifi:new

        """.write(to: url, atomically: false, encoding: .utf8)
        var launched = Date(timeIntervalSince1970: 200)
        var events: [SessionEvent] = []
        let detector = LogSessionDetector(app: "opendisplay", url: url, parse: SessionLogLines.openDisplay, isRunning: { true },
                                          launched: { launched }, lineTime: Self.secondsTime)
        detector.onEvent = { events.append($0) }
        detector.start()
        XCTAssertEqual(events, [.opened(key: "wifi:new", client: "new", display: .own(6))])
        // Started again between looks: what was open went with it.
        launched = Date(timeIntervalSince1970: 400)
        detector.checkRunning()
        XCTAssertEqual(events.last, .closed(key: "wifi:new"))
        detector.stop()
        XCTAssertEqual(events.count, 2)
    }

    func testALogNotTakenUpStillEndsWhenTheAppQuits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("log.txt")
        try "guest#1 connected.\n".write(to: url, atomically: false, encoding: .utf8)
        var running = true
        var events: [SessionEvent] = []
        let detector = LogSessionDetector(app: "parsec", url: url, parse: SessionLogLines.parsec, isRunning: { running },
                                          takesUpOpen: false)
        detector.onEvent = { events.append($0) }
        detector.start()
        defer { detector.stop() }
        XCTAssertTrue(events.isEmpty)
        detector.handle("guest#2 connected.")
        running = false
        detector.checkRunning()
        XCTAssertEqual(events, [.opened(key: "guest#2", client: "guest"), .closed(key: "guest#2")])
    }

    func testProcessesAreFoundByPath() {
        XCTAssertFalse(RunningProcesses.matching(["launchd"]).isEmpty)
        XCTAssertNotNil(RunningProcesses.started(["launchd"]))
        let me = RunningProcesses.all().first { $0.pid == getpid() }
        XCTAssertNotNil(me)
        XCTAssertNotNil(RunningProcesses.path(of: getpid()))
        // The system's own parsecd isn't Parsec's.
        XCTAssertTrue(RunningProcesses.matching(["parsecd"], path: "/Parsec.app/not-here/").isEmpty)
    }

    func testAnAppsIconIsFoundWhereverItIs() {
        // By bundle ID.
        XCTAssertEqual(SettingsWindowController.sessionAppURL("screensharing", detection: nil)?.lastPathComponent,
                       "Screen Sharing.app")
        // An added app by the process its log names, while it runs: the outermost app.
        var detection = SessionDetection(kind: .log)
        detection.logProcessName = "Finder"
        XCTAssertEqual(SettingsWindowController.sessionAppURL("added-test", detection: detection)?.lastPathComponent,
                       "Finder.app")
        detection.logProcessName = "no-such-process"
        XCTAssertNil(SettingsWindowController.sessionAppURL("added-test", detection: detection))
    }
}
