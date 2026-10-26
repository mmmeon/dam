# Remote sessions: displays and sound for other apps

*As of 2026-10-19, on branch `feat/remote-sessions`.*

## Summary

DAM can set up the Mac when another app streams it: Sunshine, RustDesk, Parsec, Screen
Sharing, Chrome Remote Desktop, TeamViewer, OpenDisplay, or an app that makes its own display. For each
app, a profile in Settings › Remote Sessions says what to do while one of its sessions is on:

- **Display:**
  - make a streaming display at the client's size or a fixed one;
  - use the display the app makes itself;
  - or leave the displays alone.
- **Placement:** extended, as the main display, or mirrored by every other display.
- **Sound:** switch to an output, and switch back afterwards.
- **Blackout:** turn the Mac's own screens black, leaving the session's display lit.

When the session ends, DAM removes the display it made, which puts the arrangement back. It
also puts the sound output back and lights the screens again. Connections of one app share a
session, which ends when the last one does.

Sessions start in one of three ways:

- through the command line (Sunshine's prep commands, scripts);
- through a `dam://` URL;
- when DAM sees them happen.

The profiles are kept in `~/Library/Application Support/DAM/remote-sessions.json`.

## Changes during a session

When a session ends, the Mac goes back to how it was before the session started, even after
changes made during it: the main display, the arrangement and the sound output. Those changes
are kept instead, in the app's profile, for its next session:

- **Placement:** the session's display made main or mirrored through DAM, or put back to
  extended. Main and mirrored count only when chosen through DAM, not when WindowServer
  applied a layout it saved for the display. Nothing is kept when the display is already gone,
  as when an app removes its own display and so ends the session. Nor when another session's
  display took main or was mirrored: with Parsec and RustDesk both on, both Main, the first
  doesn't learn Extend.
- **Size:** a resolution or refresh rate picked for the display DAM made.
- **Sound:** another output picked while the session was on. An output another session
  switched to, or put back when it ended, doesn't count. When two sessions each switch the
  output and the later ends first, the output goes back to the earlier one's, unless it was
  changed meanwhile; an output picked while both are on is kept by neither.
- **Blackout:** lifting it from the menu turns it off for the next sessions.

A setting picked in Settings › Remote Sessions is locked, and the lock beside it closes.
Changes made during sessions leave a locked setting as it is. Clicking the lock opens it, so
the setting follows those changes again. A change that a request asked for (`--placement`,
`--audio`, `--blackout`) applies to that session only, and isn't kept.

What failed isn't kept either: a change counts only when the end state is neither what was
asked for nor what setting up came to. A display that couldn't be made main stays Main in the
profile; an output that wasn't connected isn't replaced by the one left on; a display that
came at another size than asked keeps the profile's size.

While a session is on, choosing a main display or arranging the displays through DAM no longer
moves the layout that is put back afterwards. Outside remote sessions it still does: a
Moonlight stream's display keeps the arrangement chosen during the stream.

## Sunshine

Upstream Sunshine has signed macOS builds (x86_64 and arm64), but they need macOS 14.2 or
later; on 13 the binary fails to load (`_AVCaptureDeviceTypeExternal`). Before 2026 there is
only a Homebrew formula, and current sources need Xcode 16.2. It is the only host that tells
a hook the client's size. The forks (Apollo, Vibepollo, foundation-sunshine) have no Mac
builds.

1. In Settings › Streaming › Remote Sessions › Sunshine, check **Sunshine hosts Moonlight**.
   DAM's own host stops, so Sunshine can use ports 47984–48010.
2. Add the commands shown there to Sunshine › Configuration › General › Command
   Preparations:

   ```
   do:   /Applications/DAM.app/Contents/MacOS/DAM session start --app sunshine
   undo: /Applications/DAM.app/Contents/MacOS/DAM session end --app sunshine
   ```

   `session start` reads `SUNSHINE_CLIENT_NAME`, `SUNSHINE_CLIENT_WIDTH`, `SUNSHINE_CLIENT_HEIGHT`
   and `SUNSHINE_CLIENT_FPS`. Where they are set, it also reads `APOLLO_CLIENT_UUID` or
   `SUNSHINE_CLIENT_CERT_UUID`. It waits until the display is placed, about 4 s, and prints
   the display's ID last.
3. On macOS, Sunshine's `output_name` is a display ID, and Sunshine reads it only at launch.
   Set it to the ID that `session start` printed.

   On the test Mac, macOS gave the session displays the same ID each time (4128835), but
   that is not guaranteed after a reboot. *Not yet tried with Sunshine itself.*

Upstream runs prep commands when an app starts and stops, not when a client connects or
leaves. So a session lasts from Moonlight's launch to its quit, and pausing keeps the display.

## Command line and URLs

The DAM binary takes commands, which it sends to the running app over
`~/Library/Application Support/DAM/control.sock`. The socket's mode is 0600 and it accepts
only the same user.

```
DAM session start --app APP [--client NAME] [--client-id ID] [--width W --height H] [--fps F]
                  [--display create|adopt|none] [--placement extend|main|mirror]
                  [--audio OUTPUT] [--blackout yes|no]
DAM session end --app APP [--all]
DAM display list
DAM status
```

The exit status is:

| Status | Meaning |
|---|---|
| 0 | Done |
| 1 | DAM said no; the reason is printed |
| 2 | Bad command |
| 3 | DAM isn't running |

The same requests work as URLs, for example
`dam://session/start?app=rustdesk&width=1280&height=800&placement=main`. A URL gets no answer.
Any page or app can open one, so a URL ends and joins only sessions URLs started: it can't end
a session that DAM saw, or that a script or Sunshine started, and it can't join one either,
which would keep it on after the app's own end. Such a URL is refused and logged. Nor can a
URL black out the screens, which would leave whoever is at the Mac in the dark: one with
`blackout=yes` is refused and logged too, and a session a URL starts leaves the screens lit
even when the app's profile blacks out, as `--blackout no` would, and leaves the profile as
it is. Nor can a URL ask for a display to be adopted (`display=adopt`), as it could name one
of the Mac's own screens (`app=retina`) and make it main or mirrored; a profile that adopts
still does.

A session only URLs started is set up again when the app's own start joins it (the command
line or a detector): its display, placement, output and blackout are then the app's profile's,
not the URL's. The URLs' starts carry over, each still ending one, and the app's end ends the
session.

Every session has *End and Put Back* in its menu. One that follows another app's display
(OpenDisplay, or a profile that adopts, when DAM saw the session start) also says it ends when
the app stops; ending it by hand puts the output back and lights the screens, and leaves the
app's display and stream as they are. An adopted display stays when its session ends, so
DAM puts back what it made of it: mirroring is undone, and a display made main hands main back
to the one that had it. A session asked to adopt a display that never comes doesn't black out
the screens, as nothing would be left lit.

## Watching for sessions

| App | Signal | Seen working |
|---|---|---|
| RustDesk | `#N Connection opened from IP:port.` / `#N Connection closed` in `~/Library/Logs/RustDesk/RustDesk_rCURRENT.log` | Seen live 2026-10-19 and 2026-10-20 |
| Parsec | `user#id connected.` / `disconnected.` in `~/.parsec/log.txt`; ends too when Parsec's `parsecd` (in Parsec.app, not the system's CoreParsec one) quits | Yes, 2026-10-19: display made 2 s after `connected.`, removed in the same ms as `disconnected.` |
| Screen Sharing | `screensharingd` running; it runs only while someone is connected. The session ends 5 s after it exits. | No (Screen Sharing is off here) |
| Chrome Remote Desktop | `Client connected:` / `Client disconnected:` in `/var/log/org.chromium.chromoting.log`; ends too when `remoting_me2me_host` quits | No (not installed) |
| TeamViewer | `TeamViewer_Desktop` running | No (not installed) |
| OpenDisplay | `capture started: … display ID … mode extend\|mirror … session ID` / `capture ended: session ID` in `~/Library/Logs/OpenDisplay/opendisplay.log` (`OpenDisplay Dev/` for the Debug build, whichever changed last). Ends too when OpenDisplay quits or starts again, and a session already on when DAM starts is taken up while OpenDisplay runs, if its line was written since OpenDisplay started (by the line's time of day), so a crash's leftover isn't. Times of day can't date a line against a start over a day ago, so once OpenDisplay has run that long nothing is taken up (a session on then starts with the next `capture started`); read back from the end, the lines also stop at one later in the day than the line after it, written a day or more before. Extending, the session adopts that display; mirroring, it leaves the displays alone. | Yes, with an iPad over WiFi: extend, mirror, switching between them, and DAM relaunched mid-session |
| Another app's display | A display whose name contains the given text is online | Yes, with a stand-in virtual display |
| An app added in Settings | Its log's lines matching the Opened and Closed patterns; a process running; or a display it makes, as above. A log's app can be given its process too: then its sessions end when that process quits, a line opening a connection counts only while it runs, and what the log shows open when DAM starts watching isn't taken up, as with Parsec | In unit tests only |

Follow the logs from their end, through rotation and truncation. A close for a connection
opened before DAM started watching is ignored. Processes are listed with `sysctl`, which sees
root's processes (`screensharingd`), and names are cut to 16 characters.

## Notes

- **Main or mirror placement:** a streaming display DAM has just placed is held in place
  for 5 s. Making it main or mirrored inside that time now updates the layout being held,
  so the hold no longer undoes it.
- **RustDesk** (1.5.0) streams display 0, the main one, from the connect (`#displays=2,
  current=0`), so its profile defaults to Main as Parsec's does; the client can still switch
  displays in its toolbar. On 2026-10-20 RustDesk started its server again mid-session (a new
  log file, beginning `try start server`) without logging the open connection's close, so the
  session outlived the disconnect. That line, or RustDesk quitting, now ends every connection.
  RustDesk's terminal (and, presumably, its file transfer) is a connection too, with the same
  `Connection opened` line. Desktops are told apart by the lines that follow within ~10 ms:
  `new wakelock, require display on: true` (first connection only), `Option update:
  OptionMessage` and video capture starting; a terminal logs `require display on: false` and
  `terminal_service.rs` lines and makes no session. Only those within 0.5 s of the open
  count at once (a desktop's came 7–22 ms after), as later ones can be another connection's.
  RustDesk may log the open before the login, so one with none by then stays held while a
  password is typed or the host waits for a click: video capture starting makes it a desktop,
  a terminal's line or the next open drops it (no screen: a file transfer). Not yet tried live.
  Tried 2026-10-20 toward streaming an extended display, neither works: RustDesk follows main
  (handing main back to the Lenovo mid-session moved it back to the Lenovo within a second),
  and a display picked in the client's toolbar (`current=1`) went back to display 0 at the
  next display change, 3.5 s later. DAM learns of a session only once it is open and its
  display takes ~3 s, so it is always too late for the app's own choice: Main it is, for
  RustDesk and Parsec. A display kept for as long as the app runs would work for Parsec
  (`host_output`), but the user ruled it out.
- **A display commit that changes nothing takes 10 s to return** (`CGCompleteDisplayConfiguration`,
  on any thread, seen 2026-10-20). WindowServer often lays a new display out as DAM would
  place it, from a layout it saved for the set, so placing it changed nothing and the
  session waited ~13 s for its display. Placing now skips a commit with nothing to change,
  and makes the display main in that same commit when the profile says Main: 2.6–3.8 s
  from asking to placed, where it was 13 s.
- **Parsec** streams the main display, and follows it when another display is made main
  during the session. Extending leaves the client on the Mac's own screen, so Parsec's
  profile defaults to Main. On this Intel Mac, Parsec's hardware H.265 encoder fails to start
  (`VTSessionSetProperty = -12900`) and it falls back to software, at 4–15 fps, with or without
  DAM. Findings from 2026-10-19 (Parsec 150-105c), toward streaming an empty extended display:
  - Host › Display picks the display, saved as `host_output` in `~/.parsec/config.json`: the
    CGDirectDisplayID in hex (`"3F0043"` is 4128835). Picking DAM's display mid-session
    switches the client to it.
  - Parsec reads `host_output` only as a session starts. DAM's display comes up ~2 s after
    `connected.`, so even when it gets the same ID, Parsec has already fallen back to Display 1
    (and later saved the Lenovo's ID back). macOS picks the ID (4128834 or 4128835 here).
  - An edit to `config.json` mid-session changes nothing.
  - Parsec restarts capture (`capture = screen_capture_kit` in its log) when displays change.
  - Untested: whether Parsec stays on a display after main moves away from it. Making DAM's
    display main from outside DAM was undone within 2 s by DAM's keep-off-main rule.
  - Ways on: make the display main until Parsec captures it, then hand main back (needs the
    test above, with DAM not undoing it); or keep a Parsec display while Parsec runs, so
    `host_output` finds it at connect; or leave it main.
- **Adopting:** a display that WindowServer mirrors as it comes has no screen, so DAM can't
  read its name. DAM can only adopt a display that the app extends.
- **OpenDisplay:** upstream logs no session ID and nothing when a session stops. The lines
  above come from the `dam-session-log` branch of the local fork (`/Users/Shared/opendisplay`).
  Mirroring makes no display: OpenDisplay captures the main display with ScreenCaptureKit, and
  in Extend mode it pulls its display out of any mirror set.
- **Blackout:** it sets gamma to black. The pointer and the backlight stay on, and captures
  are unchanged. Leave it off where the app has its own privacy mode (RustDesk, Parsec),
  since the two would fight.
- **Sound:** some devices, such as Microsoft Teams Audio, can't be the default output.
  `session start` then warns rather than failing.
