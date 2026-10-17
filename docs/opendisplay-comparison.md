# DAM's streaming compared with OpenDisplay

*As of 2026-10-16. Compares DAM's `main` (925d21e) with
[peetzweg/opendisplay](https://github.com/peetzweg/opendisplay) at b9eec1f.*

## Summary

[OpenDisplay](https://github.com/peetzweg/opendisplay) turns an iPhone, iPad or spare Mac
into an extended display for a Mac. Like DAM's streaming displays, it creates a
`CGVirtualDisplay`, captures it with ScreenCaptureKit and encodes it with VideoToolbox.

The two apps differ in how the video reaches the other device. DAM uses existing clients:
Moonlight, browsers and media players. OpenDisplay ships its own receiver apps, which
lets it work over USB and send touch input back to the Mac.

OpenDisplay is GPL-3.0 and DAM is MIT. This document takes ideas and measurements from it,
not code.

## Design

| | DAM | OpenDisplay |
|---|---|---|
| Receiver | Existing Moonlight clients, browsers, mpv/VLC | Its own iOS app and Mac receiver app |
| Who connects | The client connects to the Mac (GameStream roles) | The Mac connects to the device; the device listens on TCP 9000 |
| Transport | Moonlight: UDP with Reed-Solomon FEC, plus RTSP and ENet. Browser/player: fragmented MP4 over HTTP | One TCP connection, with each message prefixed by its 4-byte length |
| USB | No | Yes, through macOS's built-in `usbmuxd` (`Mac/Usbmux.swift`) |
| Security | PIN pairing, TLS, AES-GCM control | None (planned in their issue #16) |
| Codec | H.264 only | H.264, or HEVC if the receiver offers it |
| Input | None yet | Touch, scroll, Pencil with pressure and tilt, cursor sent separately |
| Audio | Opus (Moonlight), AAC (web) | Only on the Mac receiver |
| Display size | Picked from Moonlight's menu or the URL | The receiver sends its exact panel size and scale in `hello` |

OpenDisplay reverses the usual roles on purpose. Its `PROTOCOL.md` §1 calls this "the
most load-bearing decision". Because the device listens, the Mac reaches it the same way
over WiFi (an address found through Bonjour) and over USB (a port tunnelled through
`usbmuxd`).

DAM can't add USB while it plays Moonlight's host role, because Moonlight clients always
connect to the host.

## Ideas worth bringing into DAM

1. **Frame-rate cap.** `MoonlightScreenCapture.swift` sets `minimumFrameInterval` to
   exactly 1/fps. OpenDisplay found that exactly 1/60 makes ScreenCaptureKit skip frames
   that arrive slightly early, and measured about 51 fps instead of 60. It asks for 1/120
   on a 60 Hz display instead.

   *Done on `fix/opendisplay-findings`.* On the Intel test Mac (macOS 13.7), a 60 fps
   capture of a 60 Hz virtual display skipped 11–12 frames per 5 s with the exact limit and
   none with the loose one. A loose limit lets extra frames through when the stream is slower
   than the display (39 fps for a 30 fps stream at 0.8/30), so DAM loosens it only when the
   display's refresh rate is at most the stream's, and `FramePacer` drops frames that come
   sooner than 0.75 frame times in case the display's rate rises during a stream.
2. **Low-latency rate control instead of the nudge.** OpenDisplay creates its encoder with
   `kVTVideoEncoderSpecification_EnableLowLatencyRateControl`. VideoToolbox then outputs
   each frame immediately rather than holding it until the next one arrives. If the encoder
   doesn't support it (AMD-only Macs), OpenDisplay retries without it. DAM works around the
   held frame by resubmitting it 1.25 frame times later.

   *An option on `fix/opendisplay-findings`.* DAM used this setting for every stream until
   18cf928 (2026-10-13). On the Intel test Mac the encoder accepts it but predicts from
   long-term reference frames while its SPS allows only one. FFmpeg, which Moonlight
   decodes with on Linux and Windows, rejects those frames until the next keyframe.
   OpenDisplay doesn't hit this because its receiver decodes with VideoToolbox. So it is
   now off by default, and can be turned on per paired device in the Moonlight menu, or
   with `lowlatency=1` for a browser stream. Since 2026-10-16 DAM rewrites the long-term
   slices into plain ones (`H264OneReference.swift`), so FFmpeg plays the stream too.
   If the encoder refuses it, DAM falls back to the plain encoder, as OpenDisplay does.
3. **Keep enforcing the display mode.** OpenDisplay saw macOS restore an old saved mode for
   a display's serial number seconds after creating it. So it re-checks the mode every
   200 ms until it settles, then every 2 s. DAM sets the start mode once, in
   `placeStreamingDisplay` (`VideoManager+StreamingDisplay.swift`), and puts the layout,
   modes included, back for 5 s after.

   *Not needed on macOS 13.7.* On the Intel test Mac, a virtual display with a different
   mode saved for its serial (1x or HiDPI, either way round) came online in a 1×1 mode,
   took the mode set for the session, and kept it for the 20 s watched. Enforcing the mode
   for the display's lifetime would also undo resolutions the user picks, which DAM
   allows and OpenDisplay doesn't. Worth testing again on a newer macOS.
4. **Resize in place instead of recreating.** OpenDisplay reserves an 8K maximum size when
   it creates the display, then calls `apply(settings)` to change modes. Removing and
   re-adding a display makes WindowServer move every window, and on DAM's test Mac it takes
   about 13 s. This helps if DAM ever changes a stream's size during a session.

   *Done on `fix/opendisplay-findings`, for resumes.* Moonlight sends the size again when
   it resumes a stream, but DAM kept the display it had made at the old size, so the
   capture scaled the picture to the new one. A display DAM made for the stream now takes
   a new mode list with `apply(settings)` and switches to the new size, keeping its ID and
   windows. On the test Mac, the new list applied in 5 ms and the switch took under a
   second. If the size is bigger than the display was made for, DAM makes a new one as
   before. Displays the user made stream at their own size, as before.
5. **Input injection, for when DAM adds Moonlight input.** OpenDisplay's
   `Mac/InputInjector.swift` notes that synthetic clicks need a real
   `CGEventSource(.hidSystemState)` and a non-zero `clickState`. Without them, menus open
   but then break and leave dead menu windows on the screen.
6. **Cursor sent separately.** OpenDisplay leaves the cursor out of the video and sends its
   position and image up to 120 times a second, so it moves at input speed instead of
   video speed. Moonlight has no way to carry this, so it only matters for a DAM-specific
   receiver.

Both apps already drop frames before encoding rather than throwing encoded frames away.
OpenDisplay's limits are 1 encode and 3 sends in flight.

## Where DAM is ahead

- Encryption and pairing.
- FEC over UDP. OpenDisplay's TCP connection stalls on WiFi packet loss.
- Audio.
- Browser playback with no install.
- Several viewers sharing one encoder.

## Next steps

Items 1–3 are small changes that can be tested with a Moonlight client.

USB, or iPhone touch at native resolution, would need a DAM-specific receiver that uses
OpenDisplay's reversed roles, which is a much bigger project. Moonlight's iOS app already
covers an iPad on a different Apple ID over WiFi.
