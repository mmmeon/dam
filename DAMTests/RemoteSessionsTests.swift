import XCTest
import CoreGraphics
@testable import DAM

/// Stands in for the displays and sound outputs, recording what the coordinator asks.
private final class FakeSessionDisplays: SessionDisplays {
    var made: [(mode: StreamingDisplayModes.Mode, identity: VideoManager.StreamingIdentity)] = []
    var removed: [CGDirectDisplayID] = []
    var placed: [(CGDirectDisplayID, SessionProfile.Placement)] = []
    var outputUID: String? = "speakers"
    var connectedOutputs: Set<String> = ["speakers", "blackhole"]
    /// The ID the next display gets, or nil for none.
    var nextID: CGDirectDisplayID? = 100
    var placeSucceeds = true
    /// Displays asked for and not yet made; nil makes them at once.
    var pendingMakes: [() -> Void]?

    func makeDisplay(_ mode: StreamingDisplayModes.Mode, identity: VideoManager.StreamingIdentity,
                     completion: @escaping (CGDirectDisplayID?) -> Void) {
        made.append((mode, identity))
        let id = nextID
        if let id { modes[id] = mode }
        if pendingMakes != nil { pendingMakes?.append { completion(id) } } else { completion(id) }
    }

    func removeDisplay(_ id: CGDirectDisplayID) { removed.append(id) }

    /// Displays other apps made, by name.
    var others: [String: CGDirectDisplayID] = [:]

    func findDisplay(named name: String) -> CGDirectDisplayID? {
        others.first { $0.key.localizedCaseInsensitiveContains(name) }?.value
    }

    func place(_ id: CGDirectDisplayID, _ placement: SessionProfile.Placement, completion: @escaping (Bool) -> Void) {
        placed.append((id, placement))
        if placeSucceeds { placements[id] = placement }
        completion(placeSucceeds)
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

    func testExtendNeedsNoPlacing() {
        let fake = FakeSessionDisplays()
        let c = coordinator(fake)
        _ = start(c, SessionRequest(app: "rustdesk"))
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
        XCTAssertEqual(events, [.opened(key: "5", client: nil)])
        online.removeLast()
        detector.check()
        XCTAssertEqual(events.last, .closed(key: "5"))
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
}
