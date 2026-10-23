//
//  main.swift
//
//  DAM's login window agent: run by launchd, as root, while the login window is up, it
//  connects the OpenDisplay receivers DAM lists to connect at startup, over USB only, and
//  shows them the login window on a display of their own (docs/root-and-login-window.md).
//  launchd stops it at sign-in; the user's DAM then connects them again.
//
//    DAMLoginAgent [--settings file] [--not-main]
//
//  --not-main leaves the main display where it is, for trying the agent in a signed-in
//  session without moving the user's menu bar and windows.
//
//  Without a file, or with no receivers in it, it has nothing to do and exits.
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
guard !settings.entries.isEmpty else {
    say("no receivers to connect at startup; nothing to do")
    exit(0)
}

say("starting as uid \(getuid()) for \(settings.entries.count) receiver(s); "
    + "screen recording \(CGPreflightScreenCaptureAccess() ? "allowed" : "NOT allowed")")

let displays = AgentDisplays(makesMain: !arguments.contains("--not-main"))
let sender = OpenDisplaySender(store: settings.store())
sender.makeDisplay = { mode, identity, done in displays.make(mode, identity, done: done) }
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
    sender.stop()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
}
termination.resume()

sender.start()
// A run loop, not dispatchMain: the sender's timers are on it.
while true { RunLoop.main.run() }
