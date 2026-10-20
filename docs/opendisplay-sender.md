# DAM as an OpenDisplay sender

DAM can stream a display of its own to an OpenDisplay receiver (the OpenDisplay app on an
iPhone, iPad or Mac), in place of the OpenDisplay Mac app. It speaks the published wire
protocol, pv 3 ([PROTOCOL.md](https://github.com/peetzweg/opendisplay/blob/main/PROTOCOL.md)),
written from the specification alone: OpenDisplay is GPL-3.0 and none of its code is used.

Settings › Streaming › OpenDisplay: **Send to OpenDisplay receivers**, then turn on each
receiver to stream to. A receiver keeps the newest sender that dials it, so DAM dials only
receivers turned on, and takes a receiver from the OpenDisplay Mac app if that is streaming
to it (decided 2026-10-20: DAM always sends).

## How it works

- **Finding:** Bonjour `_opensidecar._tcp` (TXT `id`, `pv`) over Wi-Fi, and usbmuxd's
  attached devices for a cable. A cabled device is known by its UDID until its first `hello`
  gives the receiver's ID, which is then remembered for it.
- **Dialing:** every second for each receiver turned on and found, by cable when there is
  one (a cable plugged in mid-session takes the stream over); Wi-Fi for 30 s after a cable
  fails twice. A dial gets 5 s (one to a withdrawn Bonjour name never ends of itself).
  After `closing` or `sleeping`, 3 s before dialing again.
- **The display:** made from the first `hello`, before any video, so it is never late as
  it is for RustDesk and Parsec. A 2x desktop of the receiver's points (half its pixels
  when it gives none) for a scale of 1.5 or more, else 1x of its pixels; shrunk to fit the
  decode ceiling (`maxEncodeWide/High`, the H.264 `videoCaps` entry) and 4096 pixels; the
  stream is the desktop's pixels, scaled down to the panel's. Named after the receiver, with
  a serial seeded from its ID.
- **The stream:** `welcome` for every `hello`, then `streamConfig` (always H.264: DAM's
  encoder is H.264 only, which the protocol allows) and a keyframe with SPS and PPS, from the
  last picture at once when the screen is still. Frames carry the `{"cap","snd"}` prefix.
  Over half a second of video waiting to go out, frames are dropped until it drains and a
  keyframe follows (`netDrops` in the sender's ping). `kf` gets a keyframe within 250 ms.
- **Input:** `touch` as the left button and drags, `pencil` the same (hovering moves the
  pointer), `scroll` in pixels, through Moonlight's input injector (needs Accessibility).
- **Pointer:** not drawn into the video; `cursor` up to 60 times a second while it is on the
  display (hidden when not), and `cursorImg` when its picture changes. TCP only: the UDP side
  channel is left for later.
- **Liveness:** pings every 2 s, `pong` for the receiver's. Silence over 5 s drops the
  connection; the display waits 10 s for it to come back, then goes.
- **Rotation:** a new `hello` (debounced 300 ms) resizes the display in place.

## Tested

`tools/odreceiver` is a stand-in receiver (Bonjour, `hello` of an iPad, pings, `kf`,
`closing`, optional tap) that checks what comes back: first messages `welcome`,
`streamConfig`, then video starting with an IDR with SPS and PPS; keyframe after `kf` in
60–90 ms; ping round trip 1–2 ms. Seen on this Mac 2026-10-20: the display ready ~2.7 s
after the dial, removed on `closing`; a drop without `closing` and a new connection 5 s
later reuse the display; a drop while the display is being made ends it 12 s later; a
dial racing IPv6 and IPv4 opens two connections, which a receiver sorts out by its
newcomer rule.

With the iPad (OpenDisplay iOS receiver, pv 3), 2026-10-20: over USB and Wi-Fi; touch,
scroll and rotation work (a turn resizes the display in place). Over a dozen cable swaps
the stream moved to USB within 5 ms of usbmuxd reporting the iPad, and back to Wi-Fi
1.5–1.8 s after unplugging, on the one display throughout. The receiver's stats: 40–43 ms
end to end over USB while the screen moves. On a still screen they show ~1 s, an artifact:
the encoder (Intel, plain real-time) holds each frame until the next, so the copy that
nudges the last frame out goes out with the next change, stamped with its old time; it is
the picture the receiver already shows.

Found with it and fixed: Bonjour lists a receiver once for each network it is on, not each
copy with its TXT record, so it showed twice (fixed: IDs win, and are remembered by name,
from TXT and hello). Once after unplugging, dials to the Bonjour name hung for 34 s on a
satisfied Wi-Fi path without resolving; every other dial after a failure now goes to the
address last reached, which hasn't been needed since.
