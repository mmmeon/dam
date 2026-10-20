# OpenDisplay: control from DAM (ideas, undecided)

*As of 2026-10-19. Nothing here is built. Waiting on tests of other apps before deciding.*

## Why

DAM follows OpenDisplay's sessions by reading its log (the fork's `dam-session-log` lines; see
remote-sessions.md). DAM can't end one: the display and the stream are OpenDisplay's. So the
menu shows "Ends when OpenDisplay stops" in place of "End and Put Back".

The fork (`/Users/Shared/opendisplay`, remote `fork` = mmmeon/opd) has no way in from outside:
no URL scheme, AppleScript, notifications or socket.

## What the fork already has inside

| Control | In the fork | Note |
|---|---|---|
| Stop a session | `SenderController.end(_:)` (private), `disconnect(_:)` | `end` alone: auto-connect redials a remembered WiFi device within seconds. `disconnect` forgets the device until it is clicked again. DAM needs a third: stop, and don't redial until the device reconnects or the user acts. |
| Start a session | `connect(to:userInitiated:)`, devices from `deviceEntries` | By device name or session ID (`wifi:iPad`). |
| Extend / Mirror | `controller.mode` + `restartAll()` | One setting for all devices. |
| Display size | `DeviceSession.setDisplaySize(_:)` | Larger Text, Default, More Space, Native; per device. |
| Quality | `controller.quality` | Global. |
| Status | `sessions`: id, name, status, mode, transport | The virtual display's ID needs an accessor on `MacSender`. |

## Ways in

1. **Distributed notifications for events and status.** OpenDisplay posts e.g. `opendisplay.session`
   with `{session, device, mode, display, state}` on start, end and change, and answers a
   "status please" notification with its sessions. Replaces DAM's log reading: no parsing,
   rotation or catch-up guesswork, and a display ID that changes after a restart comes through.
   About 40 lines in the fork.
2. **A URL scheme for commands**, e.g. `opendisplay://stop?session=wifi:iPad`. One-way; launches
   OpenDisplay if it isn't running; also usable from Shortcuts and scripts, so likeliest to be
   taken upstream. Results show up through the notifications in 1.
3. **A Unix socket** like DAM's `control.sock`. Real replies and errors, but the most code and the
   least likely upstream. Only if DAM must wait for an answer.

Leaning: 1 and 2 together. DAM would then offer "End and Put Back" for OpenDisplay again, and
could offer Extend/Mirror and display size in its session menu.

## Precedent

- Events: Apple's music player (`com.apple.iTunes.playerInfo`), Spotify
  (`com.spotify.client.PlaybackStateChanged`, with AppleScript for the state at startup), VLC,
  and macOS itself (`com.apple.screenIsLocked`, the appearance change).
- Commands: rarer. BetterDisplay offers CLI, URL scheme, HTTP, notifications and Shortcuts, each
  switched on or off in its settings, with replies over notifications and a command to check it
  is listening. Its notification names and payloads aren't documented publicly.
  https://github.com/waydabber/BetterDisplay/wiki/Integration-features,-CLI

## Risks and limits

- Any process can see the notifications (device names, session IDs) and post them. Commands
  need an opt-in in OpenDisplay, off by default ("Allow other apps to control OpenDisplay"),
  with "start" limited to remembered devices. Stop and status are harmless.
- A sandboxed sender can't attach a payload. Neither app is sandboxed now.
- Nothing is queued for an app that isn't running: DAM still asks for status at launch.
- OpenDisplay is a menu bar app: it should observe with immediate delivery, or macOS can hold
  notifications back while it is in the background.

## Open question

Whether other remote-session apps (RustDesk, Parsec, Jump, Splashtop, …) offer a way to end or
query a session from outside, which would decide whether DAM wants one general mechanism or a
per-app one.
