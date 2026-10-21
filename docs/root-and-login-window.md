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

On `feat/loginprobe`. It reports the session and permissions, captures the main display with
`CGDisplayCreateImage`, `CGDisplayStream` and ScreenCaptureKit (PNG and mean brightness, since
a refused capture comes back black), makes and captures a `CGVirtualDisplay`, and posts a
pointer move. `run` tries it in the current session; `install` puts it in as a LoginWindow
LaunchAgent; `results` prints the reports from `/Library/Logs/DAMLoginProbe`.

Run in the user session on 2026-10-20 (macOS 13.7.8, from Ghostty, which has Screen
Recording and Accessibility): all three captures, the virtual display and the pointer move
worked. Not yet run at the login window.

### Order

1. Lock screen: does the user's DAM stream it and take typing? Nothing new to build.
2. `tools/loginprobe` at the login window: which capture API, virtual display, input.
3. Only if both work: the root daemon and the hand-off between the two agents.
