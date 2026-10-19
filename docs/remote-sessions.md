# Remote sessions: displays and sound for other apps

*As of 2026-10-18, on branch `feat/remote-sessions`.*

## Summary

DAM can set up the Mac when another app streams it: Sunshine, RustDesk, Parsec, Screen
Sharing, Chrome Remote Desktop, TeamViewer, or an app that makes its own display. For each
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

## Sunshine

Upstream Sunshine has signed macOS builds (x86_64 and arm64), but they need macOS 14.2 or
later; on 13 the binary fails to load (`_AVCaptureDeviceTypeExternal`). Before 2026 there is
only a Homebrew formula, and current sources need Xcode 16.2. It is the only host that tells
a hook the client's size. The forks (Apollo, Vibepollo, foundation-sunshine) have no Mac
builds.

1. In Settings › Moonlight, set **Host** to **Sunshine**. DAM's own host stops, so Sunshine
   can use ports 47984–48010.
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

## Watching for sessions

| App | Signal | Seen working |
|---|---|---|
| RustDesk | `#N Connection opened from IP:port.` / `#N Connection closed` in `~/Library/Logs/RustDesk/RustDesk_rCURRENT.log` | Lines from real sessions parsed; a live session is still to be tried |
| Parsec | `user#id connected.` / `disconnected.` in `~/.parsec/log.txt` | No (format from Parsec's binary) |
| Screen Sharing | `screensharingd` running; it runs only while someone is connected. The session ends 5 s after it exits. | No (Screen Sharing is off here) |
| Chrome Remote Desktop | `Client connected:` / `Client disconnected:` in `/var/log/org.chromium.chromoting.log` | No (not installed) |
| TeamViewer | `TeamViewer_Desktop` running | No (not installed) |
| Another app's display | A display whose name contains the given text is online | Yes, with a stand-in virtual display |

Follow the logs from their end, through rotation and truncation. A close for a connection
opened before DAM started watching is ignored. Processes are listed with `sysctl`, which sees
root's processes (`screensharingd`), and names are cut to 16 characters.

## Notes

- **Main or mirror placement:** a streaming display DAM has just placed is held in place
  for 5 s. Making it main or mirrored inside that time now updates the layout being held,
  so the hold no longer undoes it.
- **Adopting:** a display that WindowServer mirrors as it comes has no screen, so DAM can't
  read its name. DAM can only adopt a display that the app extends.
- **Blackout:** it sets gamma to black. The pointer and the backlight stay on, and captures
  are unchanged. Leave it off where the app has its own privacy mode (RustDesk, Parsec),
  since the two would fight.
- **Sound:** some devices, such as Microsoft Teams Audio, can't be the default output.
  `session start` then warns rather than failing.
