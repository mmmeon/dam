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
        if pendingMakes != nil { pendingMakes?.append { completion(id) } } else { completion(id) }
    }

    func removeDisplay(_ id: CGDirectDisplayID) { removed.append(id) }

    func place(_ id: CGDirectDisplayID, _ placement: SessionProfile.Placement, completion: @escaping (Bool) -> Void) {
        placed.append((id, placement))
        completion(placeSucceeds)
    }

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
}
