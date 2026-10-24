//
//  main.swift
//
//  DAM's login window agent: run by launchd, as root, while the login window is up, it
//  connects the OpenDisplay receivers DAM lists to connect at startup, over USB only, and
//  serves DAM's Moonlight host to the paired devices allowed, over a cable only. Each is
//  shown the login window on a display of its own (docs/root-and-login-window.md). launchd
//  stops it at sign-in; the user's DAM then connects the receivers again, and Moonlight
//  devices connect to it.
//
//    DAMLoginAgent [--settings file] [--not-main]
//
//  --not-main leaves the main display where it is, for trying the agent in a signed-in
//  session without moving the user's menu bar and windows.
//
//  Without a file, or with nothing in it, it has nothing to do and exits.
//

import CoreGraphics
import Foundation
import os

let agentLog = Logger(subsystem: AppIdentity.bundleID, category: "LoginAgent")

/// To the unified log and to stderr, which launchd keeps in the agent's log file.
func say(_ text: String) {
    agentLog.notice("\(text, privacy: .public)")
    FileHandle.standardError.write(Data((ISO8601DateFormatter().string(from: Date()) + "  " + text + "\n").utf8))
}

var arguments = Array(CommandLine.arguments.dropFirst())
var settingsURL = LoginAgentSettings.url
if let i = arguments.firstIndex(of: "--settings"), i + 1 < arguments.count {
    settingsURL = URL(fileURLWithPath: arguments[i + 1])
}

let settings: LoginAgentSettings
do {
    settings = try LoginAgentSettings.read(from: settingsURL)
} catch {
    say("no settings at \(settingsURL.path) (\(error.localizedDescription)); nothing to do")
    exit(0)
}
guard !settings.isEmpty else {
    say("no receivers to connect at startup and no Moonlight devices; nothing to do")
    exit(0)
}

say("starting as uid \(getuid()) for \(settings.entries.count) receiver(s), "
    + "\(settings.moonlight?.clients.count ?? 0) Moonlight device(s); "
    + "screen recording \(CGPreflightScreenCaptureAccess() ? "allowed" : "NOT allowed")")

let displays = AgentDisplays(makesMain: !arguments.contains("--not-main"))
let sender = OpenDisplaySender(store: settings.store())
var moonlight: MoonlightHost?
var advertiser: CableAdvertiser?

func stopAll() {
    sender.stop()
    moonlight?.stop()
    advertiser?.stop()
}

/// Makes a display as `displays.make` does, or, when none comes, starts again. Started early
/// in boot, before the window server took virtual displays, a process never sees one come
/// online, however often it tries (2026-10-24); launchd starts a new one, which does.
func makeDisplay(_ mode: StreamingDisplayModes.Mode, _ identity: StreamingDisplayIdentity,
                 done: @escaping (CGDirectDisplayID?) -> Void) {
    displays.make(mode, identity) { id in
        guard id != nil else {
            say("couldn't make a display; restarting")
            stopAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(1) }
            return
        }
        done(id)
    }
}

sender.makeDisplay = { mode, identity, done in makeDisplay(mode, identity, done: done) }
sender.removeDisplay = { id in displays.remove(id) }
sender.resizeDisplay = { id, mode, done in displays.resize(id, to: mode, done: done) }
sender.hasOwnDisplay = { displays.hasOwnDisplay() }
var lastStatus = ""
sender.onChange = {
    let status = sender.receivers.map { "\($0.name): \($0.status)" }.joined(separator: "; ")
    guard status != lastStatus else { return }
    lastStatus = status
    say(status.isEmpty ? "no receivers found" : status)
}

// launchd sends SIGTERM at sign-in: the receivers are told the stream ended, and the
// displays go with the process.
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    say("stopping")
    stopAll()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
}
termination.resume()

/// Started near boot, a process may never see its displays come online (see makeDisplay);
/// checked at once, so launchd's next one is up before a device needs it. After a log-out,
/// the window server long ready, nothing is checked: the check's display would flicker.
func checkDisplays(then start: @escaping () -> Void) {
    guard ProcessInfo.processInfo.systemUptime < 5 * 60 else { return start() }
    displays.check { works in
        guard works else {
            say("can't make displays yet; restarting")
            exit(1)
        }
        start()
    }
}

/// Starts the sender and the Moonlight host, as the settings ask.
func startAll() {
    if !settings.entries.isEmpty { sender.start() }

    if let settings = settings.moonlight {
        // DAM's host, as DAM keeps it, so devices find the host they paired with; its settings
        // registered, not written, as they are DAM's.
        UserDefaults.dam.register(defaults: (settings.defaults as? [String: Any] ?? [:])
            .merging([MoonlightHost.uniqueIDKey: settings.uniqueID]) { $1 })
        // Next to the settings, as the installer puts it: LoginAgentSettings.moonlightDirectory.
        let directory = settingsURL.deletingLastPathComponent()
            .appendingPathComponent(LoginAgentSettings.moonlightDirectory.lastPathComponent, isDirectory: true)
        let host = MoonlightHost(directory: directory, advertises: false)
        host.pairs = false
        host.admits = CableLinks.admits
        let identity = StreamingDisplayIdentity(name: "Moonlight", seed: "moonlight.loginwindow")
        host.makeDisplay = { width, height, fps, done in
            makeDisplay(StreamingDisplayModes.forStream(width: width, height: height, fps: fps), identity, done: done)
        }
        host.removeDisplay = { id in displays.remove(id) }
        host.resizeDisplay = { id, width, height, fps, done in
            displays.resize(id, to: StreamingDisplayModes.forStream(width: width, height: height, fps: fps), done: done)
        }
        var lastMoonlight = ""
        host.onChange = {
            let streaming = host.streamingClients.map(\.name)
            let status = host.lastError ?? (streaming.isEmpty ? "waiting for a device on a cable"
                                                              : "streaming to \(streaming.joined(separator: ", "))")
            guard status != lastMoonlight else { return }
            lastMoonlight = status
            say("Moonlight: \(status)")
        }
        host.start()
        let cable = CableAdvertiser(name: MoonlightHost.hostName, type: MoonlightHost.serviceType, port: host.httpPort.rawValue)
        cable.start()
        moonlight = host
        advertiser = cable
    }
}

checkDisplays(then: startAll)
// A run loop, not dispatchMain: the sender's timers are on it.
while true { RunLoop.main.run() }
