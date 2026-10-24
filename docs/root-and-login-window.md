# Root, AWDL and the login window

*Notes, 2026-10-20. Nothing here is built into DAM yet; `tools/loginprobe` is the first test.*

## Summary

- [burakgon/stop-stutter](https://github.com/burakgon/stop-stutter) holds AWDL off while a
  streaming client runs, to cut Wi-Fi jitter. It is MIT, so its code can be reused with
  attribution (OpenDisplay, being GPL-3.0, can only be learnt from).
- DAM's Wi-Fi streams (OpenDisplay to the iPad, the Moonlight host) can suffer the same
  jitter, but holding AWDL off breaks wireless Sidecar and peer-to-peer AirPlay, and needs a
  root helper.
- DAM could probably work at the login window without a root daemon: a LaunchAgent limited
  to the LoginWindow session runs there as root. Whether it can capture, make a virtual
  display and post input there is what `tools/loginprobe` finds out.

## stop-stutter

Cloned at `/Users/Shared/stop-stutter`.

**What it does.** AWDL (`awdl0`, Apple Wireless Direct Link) is the peer-to-peer link
AirDrop uses. It shares the Wi-Fi radio with the connection to the router, and its schedule
takes the radio onto other channels, so packets to and from the router wait. A stream with
plenty of bandwidth still stutters when frames arrive late. stop-stutter:

- clears `awdl0`'s `IFF_UP` flag with `SIOCGIFFLAGS`/`SIOCSIFFLAGS` ioctls, as
  `ifconfig awdl0 down` does but without a fork (`SystemAWDLDriver.swift`). Setting the flag
  needs root;
- listens on a routing socket (`PF_ROUTE`) for `RTM_IFINFO`, which the kernel sends on every
  interface's `IFF_UP` change, and turns AWDL back off within ~20 ms when macOS revives it
  (`InterfaceMonitor.swift`). `wifip2pd` revives it often, for Continuity and widgets; they
  logged episodes of 455–826 ms when they corrected only on a 1 s timer;
- writes the flag only when it is wrong: every write makes the kernel broadcast a change to
  the Wi-Fi daemons, even when nothing changed;
- runs the privileged part as an `SMAppService` daemon, reached over XPC. Each end checks
  the other's exact identifier and signing team (`PeerTrust.swift`); ad-hoc builds fail
  closed.

They measured interface behaviour only, not stream quality.

**For DAM.** A per-profile "hold AWDL off during this session" would fit the remote-sessions
profiles, and DAM's own Wi-Fi sends. It can't be on while wireless Sidecar is in use
(`SidecarManager.swift`'s WiFiP2P flag) or peer-to-peer AirPlay; OpenDisplay over USB is
unaffected either way. Before building it, check that AWDL is the cause:

    sudo ifconfig awdl0 down    # during an OpenDisplay session over Wi-Fi; compare
    sudo ifconfig awdl0 up      # put it back

**Patterns worth borrowing, AWDL or not:**

- A "restore owed" marker, written *before* the first change and cleared only once the
  restore is verified, so a restart after a crash knows to restore first. DAM's gamma
  blackout and display placement have the same risk.
- Leases renewed by a heartbeat (10 s, renewed every 2 s), timed with `mach_continuous_time`,
  which counts through sleep and ignores clock changes. A frozen client can't hold the
  change forever.
- `RTM_IFINFO` could also tell OpenDisplay at once when the iPad's Wi-Fi or USB path comes or
  goes, instead of on the next dial.
- After an update the helper notices its executable was replaced (clients then fail its
  code-signature check with `errSecCSNoSuchCode`), restores, and exits for launchd to start
  the new one.

## What root would unlock

- AWDL, as above.
- A headless or closed-lid host: `pmset disablesleep 1` (lid closed on battery),
  `pmset schedule wake`. Keeping the Mac awake otherwise needs no root (`IOPMAssertion`).
- Display overrides in `/Library/Displays/Contents/Resources/Overrides`: custom modes and
  HiDPI on physical displays.
- Restarting root-owned daemons: `coreaudiod`, a stale `replayd`.
- Installing an audio driver in `/Library/Audio/Plug-Ins/HAL`.
- `pf` rules; firewall exceptions for DAM's ports.
- Turning on Screen Sharing (ARD `kickstart`) or auto-login as a fallback; rebooting the host.

What root does **not** unlock: TCC (Screen Recording, Accessibility; its database is
SIP-protected), anything else under SIP, private entitlements (see `airplay-api-notes.md`),
or rotating virtual displays.

## The login window

With FileVault off (as on this Mac), macOS boots to the login window and third-party code
can run there. RustDesk, TeamViewer and Jump Desktop stream it this way:

- A LaunchAgent in `/Library/LaunchAgents` with `LimitLoadToSessionType = LoginWindow`.
  launchd starts it as root in the login window's GUI session, and stops it at sign-in, when
  the user's DAM takes over. Installing the plist needs an admin once; nothing stays running
  as a daemon.
- Capture: those tools use `CGDisplayStream`. Whether ScreenCaptureKit works there is unknown.
- Input: `CGEventPost` from that agent reaches the login window, which is how they let you
  type the password.
- Hand-off: the stream breaks at sign-in unless a root daemon holds the Moonlight or
  OpenDisplay connection and passes it from one agent to the other, as RustDesk does.
- With FileVault on, nothing third-party runs before the disk is unlocked (that screen is
  pre-boot).
- The login window shows on physical displays; a headless Mac may need a dummy plug, or a
  virtual display made early.

The lock screen is different: the user is still signed in and DAM keeps running. Capturing
it generally works; typing into it meets secure input.

### tools/loginprobe

It reports the session and permissions, captures the main display with `CGDisplayCreateImage`
and `CGDisplayStream` (PNG and mean brightness, since a refused capture comes back black),
makes and captures a `CGVirtualDisplay`, moves the pointer four ways, and last tries
ScreenCaptureKit. `run` tries it in the current session; `install` puts it in as a
LoginWindow LaunchAgent; `results` prints the reports from `/Library/Logs/DAMLoginProbe`. The
build signs it with an Apple Development identity when there is one, so TCC grants survive
rebuilds (unsigned, every rebuild lost them).

Run in the user session on 2026-10-20 (macOS 13.7.8, from Ghostty, which has Screen
Recording and Accessibility): all three captures, the virtual display and the pointer move
worked.

**At the login window, 2026-10-23** (macOS 13.7.8, FileVault off, one 1920×1080 display):

- It runs there as root, console user `loginwindow`, and launchd removes it at sign-in.
- TCC applies to it as to any app: with no grants every capture was refused and nothing
  moved. Screen Recording and Accessibility granted to its binary in System Settings work
  there.
- **Capture works** with `CGDisplayCreateImage` and `CGDisplayStream`: a clean frame of the
  login window.
- **ScreenCaptureKit crashes the process** every time: ReplayKit calls
  `NSApplication.shared` on a background queue, and the LaunchServices check-in under it
  segfaults (`_LSScheduleNotificationFunction`). `CGDisplayStream` it is.
- **A virtual display works**: made, online, captured by both. It lists as 1×1 for the
  first moment and is 1920×1080 by 2 s.
- **Posted mouse events do not move the pointer**, to the HID tap or the session tap, with
  every permission granted. `CGWarpMouseCursorPosition` does. A
  `CGEventSource(stateID: .hidSystemState)` was made, but posting an event from it hung the
  probe until sign-in.
- **Streaming works**: `loginprobe install stream` serves the main display as MJPEG on port
  8090 (`CGDisplayStream` → `CIContext` JPEG → HTTP). Watched from another device at the login
  window: ~9 fps captured and sent while the pointer moved (capture is capped at 15 fps and
  only delivers on change), 21 ms per 1920×1080 JPEG, 64–90 KB a frame. launchd stops it at
  sign-in. No authentication: a test, not something to leave installed.
- **AirPlay and Sidecar can't be started there** (`install devices`): Bonjour finds AirPlay
  receivers and `AVRouteDetector` sees routes, but Control Center, `SidecarRelay`,
  `rapportd-user` and `sharingd` are Aqua-only agents, so there is nothing to drive and
  SidecarCore lists no iPads (it listed none in the user session either: no iPad on that
  Apple ID nearby).
- **Hardware H.264 works as root** (`install checks`): 90 frames of 1920×1080 in 0.54 s
  (165 fps), hardware encoder confirmed.
- **usbmuxd reaches the receiver**: it lists the iPad on USB, and with the OpenDisplay app open
  on it, dialing port 9000 as root at the login window connected (second run, 2026-10-23).
- **The login window follows the main display**: with a virtual display made main
  (`CGConfigureDisplayOrigin` to 0,0) the user list moved onto it and the physical display
  showed only wallpaper. With the physical display turned off (`CGSConfigureDisplayEnabled`,
  for the probe only) the virtual display alone carried the login window. So an agent can
  put the login window on the display it streams, and a Mac without a screen of its own can
  show it on a virtual one.
- Clicks and keys not tried: remote input at the login window is out of scope (decided
  2026-10-23). The password field holds secure input (`kCGSSessionSecureInputPID`) anyway.

### Order

1. Lock screen: does the user's DAM stream it and take typing? Nothing new to build.
2. `tools/loginprobe` at the login window: done (above). Capture, a virtual display and an
   MJPEG stream work; no remote input wanted there.
3. Only if both work: the root daemon and the hand-off between the two agents.

## The login window agent

`DAMLoginAgent`, which DAM carries and installs from Settings (`LoginAgentInstaller.swift`),
runs at every login window as root and shows it on a display of its own to:

- **OpenDisplay receivers** set to connect At startup, which it dials over USB (`auto-connect.md`).
- **Moonlight devices** allowed with "Login window" in Settings › Moonlight (2026-10-24):
  - It runs DAM's own host with a copy of its key, certificate, ID and the devices allowed,
    so a device finds the host it paired with and needs no new pairing. The key goes in a
    folder only root may read (`LoginWindow/Moonlight`); `settings.plist` holds only what is public.
  - Cable only. It serves connections from USB NCM links alone (`CableLinks.swift`) and
    advertises over Bonjour on those links alone, so Wi-Fi devices never see it. The Mac's
    Touch Bar link (iBridge) is USB NCM too, and is left out.
  - Each cable's service names a host of its own, `<name>-enX.local`, whose one address is
    the cable's (`CableAdvertiser.swift`). Moonlight takes the first IPv4 address a service
    resolves to, and under the Mac's own name that was often Wi-Fi's: the iPad then tried Wi-Fi
    alone, was refused, and showed the host offline. A link with only IPv6 isn't advertised,
    as Moonlight drops a link-local address's scope.
  - Moonlight still tries the Wi-Fi address it remembers from the user's session first, so
    the host can show offline for under a second before the cable answers.
  - No pairing, no input, no sound and no HDR (its capture is `CGDisplayStream`, SDR).
  - Moonlight connects, not the agent, so the device's user taps the host. At sign-in the
    stream ends, and a second tap reaches the user's DAM.
  - Tried in the user session with DAM quit, the iPad on USB-C and its Wi-Fi on: the iPad
    found the host on the cable and streamed a new display, 2.3 s from launch to picture.
    Wi-Fi and loopback connections were cut, and pairing was refused.

**Boot (2026-10-24):** started before the window server takes virtual displays, the agent's
displays never come online. A display that doesn't is released and the agent exits, and
launchd's new one works: 6 s from the first start to the iPad streaming. A process that fails
this way never recovers, even minutes later, so within 5 minutes of boot the agent first makes
a small display and lets it go, and exits at once if it doesn't come online, before any device
asks for one. At a real login window this restarted it 6 s after boot, and a Moonlight tap
streamed at once.
