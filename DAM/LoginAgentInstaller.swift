//
//  LoginAgentInstaller.swift
//
//  Installs DAM's login window agent (DAMLoginAgent, carried in DAM.app), its LaunchAgent and
//  the settings it reads, and takes them away again, through macOS's administrator dialog
//  (docs/root-and-login-window.md). The agent goes to /Library, not run from DAM.app, so
//  moving or updating DAM never leaves launchd pointing at nothing.
//

import Foundation
import os

private let liLog = Logger(subsystem: AppIdentity.bundleID, category: "LoginAgent")

enum LoginAgentInstaller {
    static let label = "\(AppIdentity.bundleID).loginagent"
    static let directory = LoginAgentSettings.directory
    static let installedAgent = directory.appendingPathComponent("DAMLoginAgent")
    static let launchAgent = URL(fileURLWithPath: "/Library/LaunchAgents/\(label).plist")
    static let log = URL(fileURLWithPath: "/Library/Logs/DAM/LoginAgent.log")

    /// The agent DAM carries, next to its own executable.
    static var bundledAgent: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("DAMLoginAgent")
    }

    enum Status: Equatable {
        /// No receiver connects at startup, and nothing is installed.
        case notNeeded
        /// Receivers connect at startup, and nothing is installed.
        case notInstalled
        /// Installed, but its receivers, their cable IDs or the agent are older than DAM's.
        case needsUpdate
        case current
        /// Installed, but no receiver connects at startup any more.
        case unneeded
    }

    /// What should be installed now: the receivers connected at startup and what DAM learned
    /// of them; nil when there are none.
    static func wanted() -> LoginAgentSettings? {
        let store = DefaultsOpenDisplayStore()
        let settings = LoginAgentSettings.make(entries: AutoConnectList.entries, names: store.names,
                                               usbIDs: store.usbIDs, bonjourIDs: store.bonjourIDs,
                                               bitrateKbps: OpenDisplaySender.bitrateKbps)
        return settings.entries.isEmpty ? nil : settings
    }

    static func status() -> Status {
        let fm = FileManager.default
        let installed = fm.fileExists(atPath: launchAgent.path) ? try? LoginAgentSettings.read() : nil
        let agentMatches = bundledAgent.map { fm.contentsEqual(atPath: $0.path, andPath: installedAgent.path) } ?? false
        return status(wanted: wanted(), installed: installed, agentMatches: agentMatches)
    }

    /// Whether what is installed does what `wanted` asks. The receivers, their order and how
    /// they are found by cable count; names and the bitrate don't, as a stale one does no
    /// harm and each would mean asking for the password again.
    static func status(wanted: LoginAgentSettings?, installed: LoginAgentSettings?, agentMatches: Bool) -> Status {
        guard let installed else { return wanted == nil ? .notNeeded : .notInstalled }
        guard let wanted else { return .unneeded }
        let same = installed.entries == wanted.entries && installed.usbIDs == wanted.usbIDs && agentMatches
        return same ? .current : .needsUpdate
    }

    /// The receivers at startup the agent can't find by cable: they were never connected by
    /// one, so DAM doesn't know which device they run on.
    static func unknownByCable(_ settings: LoginAgentSettings) -> [String] {
        let known = Set(settings.usbIDs.values)
        return AutoConnectList.openDisplayKeys(in: settings.entries, hasOwnDisplay: false)
            .filter { !known.contains($0) }
            .map { settings.names[$0] ?? $0 }
    }

    /// Whether the agent may record the screen, as it said the last time it started; nil
    /// before it has.
    static func screenRecordingAllowed(log text: String) -> Bool? {
        guard let line = text.split(separator: "\n").last(where: { $0.contains("screen recording") }) else { return nil }
        return !line.contains("NOT allowed")
    }

    static func screenRecordingAllowed() -> Bool? {
        (try? String(contentsOf: log, encoding: .utf8)).flatMap(screenRecordingAllowed(log:))
    }

    // MARK: Installing

    /// The LaunchAgent: started as root when the login window comes up, stopped at sign-in;
    /// started again after a crash, not after it exits with nothing to do.
    static func launchAgentPlist(agent: URL = installedAgent, log: URL = log) -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "LimitLoadToSessionType": "LoginWindow",
            "ProgramArguments": [agent.path],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path,
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
    }

    /// The shell script root runs to put the files staged in `staging` in place.
    static func installScript(staging: URL) -> String {
        """
        set -e
        mkdir -p \(quoted(directory.path)) \(quoted(log.deletingLastPathComponent().path))
        install -o root -g wheel -m 755 \(quoted(staging.appendingPathComponent("DAMLoginAgent").path)) \(quoted(installedAgent.path))
        install -o root -g wheel -m 644 \(quoted(staging.appendingPathComponent("settings.plist").path)) \(quoted(LoginAgentSettings.url.path))
        install -o root -g wheel -m 644 \(quoted(staging.appendingPathComponent("agent.plist").path)) \(quoted(launchAgent.path))
        """
    }

    static let uninstallScript = """
        rm -f \(quoted(launchAgent.path))
        rm -rf \(quoted(directory.path))
        rmdir \(quoted(directory.deletingLastPathComponent().path)) 2>/dev/null || true
        """

    /// `path` in single quotes for sh.
    static func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Installs the agent with `settings`, or updates it; `done` gets nil, or why not, on the
    /// main queue. Cancelling the password dialog counts as why not.
    static func install(_ settings: LoginAgentSettings, done: @escaping (String?) -> Void) {
        guard let bundled = bundledAgent, FileManager.default.isExecutableFile(atPath: bundled.path) else {
            return done("DAM's copy of the login window agent is missing")
        }
        let staging: URL
        do {
            staging = try makeStaging()
            try FileManager.default.copyItem(at: bundled, to: staging.appendingPathComponent("DAMLoginAgent"))
            try settings.data.write(to: staging.appendingPathComponent("settings.plist"))
            try launchAgentPlist().write(to: staging.appendingPathComponent("agent.plist"))
        } catch {
            return done(error.localizedDescription)
        }
        runAsRoot(installScript(staging: staging), prompt: "DAM wants to show the login window on your devices.") { error in
            try? FileManager.default.removeItem(at: staging)
            if error == nil { liLog.notice("installed for \(settings.entries.count) receiver(s)") }
            done(error)
        }
    }

    static func uninstall(done: @escaping (String?) -> Void) {
        runAsRoot(uninstallScript, prompt: "DAM wants to stop showing the login window on your devices.") { error in
            if error == nil { liLog.notice("uninstalled") }
            done(error)
        }
    }

    /// A new folder only this user can write to, for files root then copies.
    private static func makeStaging() throws -> URL {
        var template = Array(FileManager.default.temporaryDirectory.appendingPathComponent("dam-loginagent.XXXXXX").path.utf8CString)
        guard let made = mkdtemp(&template) else { throw CocoaError(.fileWriteUnknown) }
        return URL(fileURLWithPath: String(cString: made), isDirectory: true)
    }

    /// Runs `script` as root after macOS's administrator dialog, in another process so DAM
    /// isn't held while it is up.
    private static func runAsRoot(_ script: String, prompt: String, done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("dam-loginagent-\(UUID().uuidString).sh")
            defer { try? FileManager.default.removeItem(at: file) }
            var result: String?
            do {
                try script.write(to: file, atomically: true, encoding: .utf8)
                let apple = "do shell script \"/bin/sh \" & quoted form of \"\(file.path)\" with prompt \"\(prompt)\" with administrator privileges"
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", apple]
                let errors = Pipe()
                process.standardError = errors
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    result = text.contains("-128") ? "cancelled" : text.trimmingCharacters(in: .whitespacesAndNewlines)
                    liLog.error("as root: \(result ?? "", privacy: .public)")
                }
            } catch {
                result = error.localizedDescription
            }
            DispatchQueue.main.async { done(result) }
        }
    }
}
