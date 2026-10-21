# Moonlight: encrypted video, a private browser stream, several clients at once

*Plan, 2026-10-19. Protocol details are from Sunshine and moonlight-common-c master;
line references below are to those sources and to DAM as of this date.*

**Status, 2026-10-19:** all three done on `feat/moonlight-sessions`; see
`docs/moonlight.md`. The browser stream took the token option, with no localhost
exception. Several clients took port blocks. Encoder test on the test Mac (Intel Iris
Plus 650, 1080p60, low-latency): one to three encoders kept a p90 of 18–24 ms, four
43–83 ms; output was about 41 fps for each whatever the count, the benchmark's limit.
Tried with two real devices on 2026-10-19: the iPad over USB (session 0, its streaming
display the main one) and the Mac's own Moonlight via streamtest (session 1, RTSP 48011,
a display of its own). Both ran at 53–59 fps side by side with no frames lost; quitting
the Mac's ended only its session and display, and the iPad streamed on.

## Summary

DAM streams to one Moonlight client at a time, and sends its video in the clear. Control
is always encrypted (AES-128-GCM) and audio is when the client asks (AES-128-CBC). The
browser stream needs no pairing at all. Stock clients already support everything below,
so all the work is on DAM's side. In order:

1. **Put the browser stream behind pairing.** Small, and the most urgent.
2. **Encrypted video.** Small: one change to DESCRIBE, one to ANNOUNCE, and sealing each
   packet as it is sent.
3. **Several Moonlight clients at once.** Large: a launch and a stream per client, an RTSP
   port per launch, ports or packet routing per session, and capture shared between them.

## 1. The browser stream

`/watch`, `/apps.json` and `/stream.mp4` are answered over plain HTTP on 47989 before any
pairing check (`MoonlightHost.swift:387`). Anyone on the LAN who knows the URL can watch
any listed display, and with none listed `/stream.mp4` makes one (`WebStream.swift:235`).

Options:

- **Serve it over HTTPS on 47984 only, to paired certificates.** Fits mpv and ffplay with
  a client certificate, but browsers would need the certificate installed: awkward.
- **A token.** DAM makes a random token, kept with the host's identity; Settings ›
  Moonlight shows the `/watch?token=…` link (and the copy-link actions use it). Requests
  without it get 403. Players take the same URL. The page and the stream stay plain HTTP,
  so the picture is still readable on the network, but no longer requestable.
- Both: the token over HTTP, and the paired-certificate route over HTTPS.

Recommended: the token, with a "Make a new link" button that replaces it. Optionally a
setting to allow it from localhost only.

## 2. Encrypted video

### Protocol

- Bits in `x-ss-general.encryption*`: `0x01` control v2, `0x02` video, `0x04` audio.
  The host lists what it supports in DESCRIBE (`encryptionSupported`) and may ask for
  some (`encryptionRequested`); the client says what it turned on in ANNOUNCE
  (`encryptionEnabled`). A host that doesn't offer `0x02` never gets encrypted video.
- **Clients turn it on whenever it is offered:** Moonlight on Mac and PC when the CPU has
  fast AES, iOS always, Android with fast AES. Sunshine therefore offers it only to WAN
  addresses by default (`lan_encryption_mode` never, `wan_encryption_mode`
  opportunistic).
- **Packet:** a 32-byte prefix, then the whole packet as DAM sends it now (RTP header, NV
  video header, payload, padding), sealed with AES-128-GCM, no additional data, under the
  launch's `rikey`:
  - bytes 0–11: the nonce. Sunshine uses a 64-bit counter from 0, little-endian, then
    three zero bytes and `'V'`. The client takes the nonce from the packet, so any nonce
    works if it is never reused under the key; the `'V'` keeps it apart from the control
    stream's nonces (`MoonlightProtocol.swift:536`).
  - bytes 12–15: the frame index, little-endian, in the clear. The client drops packets
    of frames older than the current one before decrypting.
  - bytes 16–31: the GCM tag.
- **Order:** FEC first, over the plain packets; then each data and parity packet is
  sealed. The client decrypts before FEC.
- Pings stay plain. Audio encryption doesn't change. Packet size, FEC and minimum parity
  don't change; the client allows for the extra 32 bytes. At the default packet size a
  datagram is 1440 bytes, under a 1500-byte MTU.
- Cost: 32 bytes a packet (2.3%), and about 1–2% of a core at 100 Mbit/s (estimated).

### Changes

1. `MoonlightRTSP.swift:130–134`, DESCRIBE: offer `encryptionSupported:7` when video is
   to be encrypted for this client, else `5` as now.
2. `MoonlightRTSP.swift:154`, ANNOUNCE: accept `0x02` when it was offered. Carry
   `videoEncrypted` in `MoonlightStreamConfig` (`MoonlightProtocol.swift:23`).
3. `MoonlightStream.swift:577–581`: give `MoonlightVideoSender` the key; it keeps a
   `SymmetricKey` and the nonce counter.
4. `MoonlightVideoSender`'s send (`MoonlightStream.swift:273–284`): seal each packet just
   before `socket.send`, data and parity alike, after the parity packets' headers are
   filled in (`MoonlightProtocol.swift:189–205`). Pace on the sealed size.
5. Tests: a sealed packet opens with the key to the original, its prefix carries the frame
   index, nonces never repeat. Then a real test with Moonlight on the test Mac.
6. Update `docs/moonlight.md`'s RTSP section.

### Setting

Settings › Moonlight › "Encrypt video": **Off the local network** (default, as Sunshine),
**Always**, **Never**. "Off the local network" means a peer outside the Mac's own subnets
and not link-local; USB links (`docs/usb.md`) count as local. Off the local network
offers it, as Sunshine's opportunistic mode; Always also asks for it in DESCRIBE
(`encryptionRequested:2`) and refuses an ANNOUNCE that leaves video plain, as Sunshine's
mandatory mode.

## 3. Several Moonlight clients at once

### What clients already do

- They connect to the RTSP port in `sessionUrl0`'s URL, not only 48010 (since 2021).
- They use the `server_port` from each RTSP SETUP reply for video, audio and control
  (since 2021), falling back to 47998, 48000 and 47999.
- They tag their first packets: the `X-SS-Ping-Payload` from /launch in every video and
  audio ping, and `X-SS-Connect-Data` as the ENet connect data (since 2023). Sunshine
  sorts sessions sharing the fixed ports by these.
- Moonlight asks the user to quit the running app before launching another only when
  `/serverinfo` says the host is busy with a different app. DAM answers `/serverinfo`
  over HTTPS with the client's certificate, so it can show each client only its own
  session; other clients see the host free.

### Changes

1. **A launch per client** (`MoonlightHost.swift:158–159`): a map from the client's
   certificate to its launch and stream. `launchApp` already has the certificate (`:459`).
   A launch ends only that client's stream (`:464`, `:492`, `:520`); `/cancel` ends only
   its launch. `/serverinfo`'s `state` and `currentgame` (`:633`) are the asking client's.
2. **An RTSP port per launch**, handed out in `sessionUrl0` (`:468`). RTSP has no session
   token before SETUP, and two clients can share an address behind NAT, so routing by
   address would not do. A small pool (say 48010–48019), each listener tied to its
   launch.
3. **UDP ports.** Either:
   - **A block per session** (47998–48000 for the first, then 48100–48102, …), returned in
     SETUP (`MoonlightRTSP.swift:139–146`). Simplest; each session keeps its own sockets
     as now. Remote use needs the range forwarded.
   - **Shared fixed ports**, sorted by ping payload, with one ENet host taking several
     peers by connect data (today it takes one, `MoonlightStream.swift:487`). Works with
     the usual port forwards, as Sunshine does, at the cost of a router in front of the
     senders.

   Start with blocks; move to shared ports if remote use needs it.
4. **Capture and encoding.** One capture per display, one encoder per client, as
   Sunshine does. Each client keeps its own bitrate, keyframes, reference-frame
   invalidation, FEC and low-latency rewriting, and a lossy client doesn't cost the
   others. A shared encoder (as `WebStream` does) would be cheaper but bring every client
   down to the weakest one's bitrate and keyframes; not worth it for Moonlight.
   `MoonlightScreenCapture` becomes shared, fanning frames out to each stream's encoder,
   and stops when its last stream ends.
5. **Audio.** One capture of system audio, fanned out; Opus encoding and encryption per
   client (bitrates and keys differ).
6. **Displays.** "New Display" makes a display per client, up to the four streaming
   displays (`VideoManager+StreamingDisplay.swift:114`); a fifth gets a 503 with a clear
   message. A client resuming a display another client is streaming streams it at its
   current size instead of resizing it (`MoonlightHost.swift:497–507`).
7. **Status.** The menu and Settings show each client streaming, by device name, with a
   way to end one.
8. **Input.** Every client's input goes to the Mac, unless its Allow Input setting is
   off; no arbitration (see moonlight.md, Input).

### Cost of each extra client

A hardware H.264 session, a packetising and pacing thread, an Opus encoder, and its own
copy of the bandwidth; a new virtual display only for "New Display". Capture is per
display, not per client.

How many hardware encode sessions a Mac runs at once is undocumented: base M1/M2 have one
media engine, Max and Ultra two or more. **Test first:** two to four `MoonlightVideoEncoder`s
at 1080p60 on the test Mac, watching encode time and dropped frames, before building the
rest.

## Order of work

1. Browser stream token.
2. Encrypted video, with the setting.
3. Encoder test for several sessions.
4. Several clients: per-client launches and `/serverinfo`, RTSP and UDP port blocks, then
   shared capture and audio, then displays and status.
