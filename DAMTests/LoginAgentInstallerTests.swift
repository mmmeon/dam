import XCTest
@testable import DAM

final class LoginAgentInstallerTests: XCTestCase {

    private let iPad = AutoConnectEntry(target: .openDisplay(key: "a"), mode: .startup)

    func testStatusFollowsWhatIsWantedAndWhatIsInstalled() {
        let wanted = LoginAgentSettings(entries: [iPad], names: ["a": "iPad"], usbIDs: ["udid": "a"])
        typealias S = LoginAgentInstaller
        XCTAssertEqual(S.status(wanted: nil, installed: nil, agentMatches: false), .notNeeded)
        XCTAssertEqual(S.status(wanted: wanted, installed: nil, agentMatches: false), .notInstalled)
        XCTAssertEqual(S.status(wanted: nil, installed: wanted, agentMatches: true), .unneeded)
        XCTAssertEqual(S.status(wanted: wanted, installed: wanted, agentMatches: true), .current)
        XCTAssertEqual(S.status(wanted: wanted, installed: wanted, agentMatches: false), .needsUpdate, "DAM's agent is newer")
        var learned = wanted
        learned.usbIDs = [:]
        XCTAssertEqual(S.status(wanted: wanted, installed: learned, agentMatches: true), .needsUpdate, "a cable ID learned since")
        var renamed = wanted
        renamed.names = ["a": "Studio iPad"]
        renamed.bitrateKbps = 40_000
        XCTAssertEqual(S.status(wanted: renamed, installed: wanted, agentMatches: true), .current, "not worth a password")
    }

    func testStatusFollowsWhoTheMoonlightHostIsAndWhomItServes() {
        let iPad = MoonlightClient(name: "iPad", certificate: Data([1]), paired: Date(), showsLoginWindow: true)
        let moonlight = LoginAgentSettings.Moonlight(uniqueID: "A", certificate: Data([9]), clients: [iPad])
        let wanted = LoginAgentSettings(moonlight: moonlight)
        typealias S = LoginAgentInstaller
        XCTAssertEqual(S.status(wanted: wanted, installed: nil, agentMatches: false), .notInstalled, "Moonlight alone")
        XCTAssertEqual(S.status(wanted: wanted, installed: wanted, agentMatches: true), .current)
        var other = wanted
        other.moonlight?.clients.append(MoonlightClient(name: "iPhone", certificate: Data([2]), paired: Date()))
        XCTAssertEqual(S.status(wanted: other, installed: wanted, agentMatches: true), .needsUpdate, "another device")
        XCTAssertEqual(S.status(wanted: LoginAgentSettings(), installed: wanted, agentMatches: true), .needsUpdate,
                       "a device no longer allowed")
        var newKey = wanted
        newKey.moonlight?.certificate = Data([8])
        XCTAssertEqual(S.status(wanted: newKey, installed: wanted, agentMatches: true), .needsUpdate, "a new host identity")
        var tuned = wanted
        tuned.moonlight?.defaults = ["dam.moonlight.hevc": "off"]
        XCTAssertEqual(S.status(wanted: tuned, installed: wanted, agentMatches: true), .current, "not worth a password")
    }

    func testTheMoonlightHostsFilesGoWhereOnlyRootReadsThem() {
        let staging = URL(fileURLWithPath: "/tmp/s")
        let with = LoginAgentInstaller.installScript(staging: staging, moonlight: true)
        let folder = "'/Library/Application Support/DAM/LoginWindow/Moonlight'"
        XCTAssertTrue(with.contains("mkdir -m 700 \(folder)"))
        for file in [MoonlightHost.keyFile, MoonlightHost.certificateFile, MoonlightHost.clientsFile] {
            XCTAssertTrue(with.contains("install -o root -g wheel -m 600 '/tmp/s/\(file)' '/Library/Application Support/DAM/LoginWindow/Moonlight/\(file)'"), file)
        }
        let without = LoginAgentInstaller.installScript(staging: staging)
        XCTAssertTrue(without.contains("rm -rf \(folder)"))
        XCTAssertFalse(without.contains(MoonlightHost.keyFile))
        // The launch agent goes last, so the agent never starts with half its files.
        XCTAssertTrue(with.split(separator: "\n").last?.contains("LaunchAgents") == true)
    }

    func testReceiversNeverConnectedByCableAreNamed() {
        let settings = LoginAgentSettings(entries: [iPad, AutoConnectEntry(target: .openDisplay(key: "b"), mode: .startup)],
                                          names: ["a": "iPad", "b": "iPhone"], usbIDs: ["udid": "a"])
        XCTAssertEqual(LoginAgentInstaller.unknownByCable(settings), ["iPhone"])
    }

    func testTheLaunchAgentRunsAtTheLoginWindowOnly() throws {
        let data = LoginAgentInstaller.launchAgentPlist()
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, LoginAgentInstaller.label)
        XCTAssertEqual(plist["LimitLoadToSessionType"] as? String, "LoginWindow")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/Library/Application Support/DAM/LoginWindow/DAMLoginAgent"])
        XCTAssertEqual(plist["KeepAlive"] as? [String: Bool], ["SuccessfulExit": false])
    }

    func testScriptsQuoteTheirPaths() {
        XCTAssertEqual(LoginAgentInstaller.quoted("/a b/it's"), "'/a b/it'\\''s'")
        let script = LoginAgentInstaller.installScript(staging: URL(fileURLWithPath: "/tmp/x y"))
        XCTAssertTrue(script.contains("install -o root -g wheel -m 755 '/tmp/x y/DAMLoginAgent' '/Library/Application Support/DAM/LoginWindow/DAMLoginAgent'"))
        XCTAssertTrue(script.hasPrefix("set -e"))
        XCTAssertTrue(LoginAgentInstaller.uninstallScript.contains("rm -rf '/Library/Application Support/DAM/LoginWindow'"))
    }

    func testScreenRecordingIsReadFromTheAgentsLastStart() {
        XCTAssertNil(LoginAgentInstaller.screenRecordingAllowed(log: "no settings; nothing to do\n"))
        let log = """
            2026-10-23T22:00:00Z  starting as uid 0 for 1 receiver(s); screen recording NOT allowed
            2026-10-23T22:10:00Z  starting as uid 0 for 1 receiver(s); screen recording allowed
            2026-10-23T22:10:01Z  iPad: Streaming 2048×1536 over USB
            """
        XCTAssertEqual(LoginAgentInstaller.screenRecordingAllowed(log: log), true)
        XCTAssertEqual(LoginAgentInstaller.screenRecordingAllowed(log: String(log.split(separator: "\n")[0])), false)
    }
}
