# Connecting trusted displays automatically

*Design, 2026-10-23; decisions made the same day. Part 2 of the login window work: what happens once the user signs in.
Part 1, the login window itself, is in `root-and-login-window.md`.*

## Goal

The user keeps one list of trusted displays, in order of preference: OpenDisplay receivers,
AirPlay displays and Sidecar iPads. When DAM starts at sign-in, and whenever a display on the
list comes within reach, DAM connects the best one available, without a hotkey or a click.

## What DAM does today

Three separate rules, each with its own setting:

| Kind | Today | Where |
|---|---|---|
| OpenDisplay | Dials every receiver turned on, as soon as it is found, by cable when there is one; all of them at once | `OpenDisplaySender.dialWhatIsOn`, `turnedOn` (`opendisplay.receivers`) |
| Sidecar | Connects an iPad on USB when the Mac has no display of its own; once per plug-in, up to 6 tries 10 s apart (Sidecar is often not ready just after login) | `SidecarAutoConnector`, `autoConnectsSidecarWithoutDisplay` |
| AirPlay | Nothing automatic. The connect hotkey skips the choice when only one display is available | `AirPlayQuickConnect`, `autoConnectSingleDisplay` |

The Sidecar rule is the model to follow. Its decision is a pure function, `plan(devices:attempts:hasOwnDisplay:now:)`,
run by a 3 s timer and covered by unit tests.

## Constraints by kind

- **AirPlay**
  - DAM connects by driving Control Center's Screen Mirroring panel through Accessibility
    (`ScreenMirroringPanel.toggle`). The panel opens on the user's screen, one toggle runs at a
    time (`.busy`), and Accessibility must be granted.
  - macOS mirrors to one AirPlay screen at a time.
  - Discovery is Bonjour (`_airplay._tcp`), so a TV that is asleep may not be listed.
- **Sidecar**
  - Only iPads on the same Apple ID, found by Continuity. Not ready for a while after sign-in,
    hence the retries.
  - One iPad at a time.
- **OpenDisplay**
  - Several receivers at once. DAM dials; the receiver app must be open.
  - Each receiver is a streaming display made by DAM. A connection costs an encoder, but
    nothing else.

## The list

One ordered list in Settings, **Connect Automatically**. Each entry:

- **kind and identity:**
  - an OpenDisplay receiver, by its key, as `turnedOn` holds it today;
  - an AirPlay display, by name, as `VisibilityPreferences` already names AirPlay devices;
  - a Sidecar iPad, by name (SidecarCore's identifier may change between OS updates);
  - "any iPad on USB", which carries today's Sidecar rule over unchanged.
- **when:** always, or only while the Mac has no display of its own (today's Sidecar
  condition, `video.hasOwnDisplay()`).

Rows are added from the displays DAM sees now, through the same lists the menu shows, and
moved with ↑ and ↓ buttons (simpler in the form's grid than dragging, and usable with
VoiceOver). The list is the last group of the Devices tab. Nicknames (`VisibilityPreferences.nickname`) show as elsewhere.

## Behaviour

A single `AutoConnector` replaces `SidecarAutoConnector`. Every 3 s, and when discovery
changes, it runs a pure `plan` over what is listed, what is in reach, what is connected, and
its attempts. It then starts at most one connection.

1. **Order.** Go down the list. Take the first entry in reach that isn't connected, isn't
   waiting to retry, and wasn't turned down (rule 4), and whose condition holds.
2. **One of each exclusive kind.** At most one AirPlay display and one Sidecar iPad. An entry
   whose kind is already in use is skipped, unless the policy below says to switch.
3. **Retries.** Kept as in Sidecar: an attempt may take 45 s, then retries 10 s apart, at most 6
   per appearance. AirPlay's `.busy` counts as "try again shortly", not a failure.
4. **Respect a manual disconnect.** A display the user disconnects isn't reconnected until it
   leaves and comes back: unplugged, out of Bonjour, or the receiver app closed. This
   generalises Sidecar's "once per plug-in".
5. **OpenDisplay stays as it is.** Every listed receiver in reach is dialled, in parallel, as now;
   list order only decides which one is dialled first. The list replaces `turnedOn`.
6. **Announcements.** "Connecting to …" as the hotkey does today. Nothing when an attempt fails
   quietly and will be retried.

## Decisions (2026-10-23)

1. **All OpenDisplay receivers, first available across AirPlay and Sidecar.** Every listed
   receiver in reach is dialled, as today. Of AirPlay and Sidecar, DAM stops at the first that
   connects, so an iPad on the list isn't connected when the TV already is.
2. **No switching up.** When a higher entry appears while a lower one of the same exclusive
   kind is connected, the lower one stays: switching would tear down a screen in use.
3. **AirPlay at sign-in is allowed**, but only once Control Center answers Accessibility (asked
   without opening anything) and no key has been pressed for 2 s, since the user may be
   typing. Accessibility is never asked for by the connector.
4. **Migration.**
   - Today's receivers turned on become OpenDisplay entries in their current order (as
     stored: sorted by key).
   - `autoConnectsSidecarWithoutDisplay` becomes "any iPad on USB, only without a display of
     its own".
   - `autoConnectSingleDisplay` stays a hotkey setting.

## When: always, at login, at startup (2026-10-23)

The user wants designated displays connected only if they are there at sign-in or shortly
after, not whenever they come within reach. Each entry has a mode:

| Mode | Connected | Kinds |
|---|---|---|
| Always | whenever it comes within reach | all |
| At login | in the window after DAM starts at sign-in | all |
| At startup | from boot: at the login window (part 1's agent), then in the window after the first sign-in since boot | OpenDisplay only: nothing else can connect before sign-in |

- **The window** is one setting, 2 minutes by default (30 s to 10 min), measured from DAM's
  start. DAM counts as started at sign-in when it starts within the window of the user's console
  login (from the login records). Opened by hand later, there is no window.
- **First sign-in since boot** is when the boot time (`kern.boottime`) differs from the one DAM
  last started at sign-in under.
- **Defaults:** entries added in Settings are At login. Entries migrated from the older settings,
  and receivers turned on from the OpenDisplay page, are Always, which is how they behaved.
- **Once the window closes** nothing at login or startup is dialled or retried. A connection
  already made stays.

## Link to part 1

The login window agent uses the same list, limited to OpenDisplay receivers over USB.
Over Wi-Fi a receiver can't yet prove who it is (`root-and-login-window.md`).

- When the list changes, DAM writes those entries to a root-only file in
  `/Library/Application Support/DAM/`. That asks for an admin password, since the list decides
  who sees the login window.
- At sign-in the agent stops and the user's DAM dials the same receiver first. The iPad sees a
  short reconnect, not a different screen.

## Steps

1. `AutoConnectList`: the entries, stored in `UserDefaults.dam` as an ordered array, with
   migration from the three settings above. Unit tests for migration.
2. `AutoConnector.plan`: pure, with tests carried over from `SidecarAutoConnector.plan` plus
   ordering, the exclusive kinds and manual disconnects.
3. Wire up the three kinds:
   - OpenDisplay: `turnedOn` reads the list.
   - Sidecar: `SidecarManager.connect`, as now.
   - AirPlay: `VideoManager.connectAirPlay(deviceName:)`.
   
   Record manual disconnects from the menu, the hotkey and System Settings changes.
4. Settings: the **Connect Automatically** list (add, remove, reorder, condition), replacing
   the Sidecar checkbox and the per-receiver switches.
5. Live test: sign in with an iPad on USB and the TV awake; then disconnect by hand and check
   nothing reconnects until the display goes and comes back.
