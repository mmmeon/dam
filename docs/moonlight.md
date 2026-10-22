# Moonlight and web streaming — implementation

*As of 2026-10-14 (merged to `main` on 2026-10-13 in 3aa3588). H.264, and HEVC where
the Mac encodes it as quickly (since 2026-10-22). Mouse, keyboard and text input since 2026-10-20; no
controllers, touch or pen.*

## Summary

DAM is a Moonlight host on its own, without Sunshine. A Moonlight client on the LAN
finds the Mac and pairs with a PIN. It then sees each of DAM's streaming displays as an
app, plus "New Display". Launching "New Display" creates a virtual display at the
client's resolution and frame rate. DAM streams it as H.264 (or HEVC) video with Reed-Solomon FEC
and Opus audio. Cancelling from Moonlight removes the display; resuming keeps it,
changed in place to the size the client asks for now.

Apart from Moonlight, DAM also serves displays to browsers and media players, over HTTP
on port 47995 and HTTPS on 47996. It is turned on and set up on its own: the Browser
Stream menu and Settings › Browser Stream, independent of Moonlight hosting and its
settings.

- `/watch` plays the stream in a browser through Media Source Extensions.
  It keeps the screen awake while it plays (over HTTPS only). It starts the stream again
  when the stream breaks off, ends, or goes 5 s without data, and when the picture stands
  still for 3 s while data keeps coming. Retries come after 1, 2, 4… s, at most five in
  five minutes. A first connection that gets no data within 30 s fails.
  It plays the profile's buffer behind, plus what the browser turns out to need: each stall
  after a stream's first 2 s adds 10 ms (at most every 300 ms), half a minute without one
  gives back 5 ms, and the browser keeps what it learned for its next stream. WebKit needs
  about 100 ms in hand, so a 50 ms target only stalled, every frame. A stream's first play
  waits for 100 ms more than the target, which the decoder starting uses up.
- Every slot of the stream's frame grid gets a frame: a captured frame that would jump over
  empty slots gives them the picture before it first. A hole in the track makes WebKit drop
  every frame after it until the next keyframe.
- Interactive and Balanced send a keyframe at least every 10 s, Viewing every 2 s. The page
  trims played video 25 s back once 40 s is buffered: a browser removes every frame up to the
  next keyframe along with the ones asked for, so the cut needs a keyframe well before what
  plays now.
- Where the browser has WebCodecs, the page decodes Interactive without sound directly:
  it splits the fragmented MP4 into its H.264 samples (`FragmentReader`), hands each to a
  `VideoDecoder` (`optimizeForLatency`) as it lands, and draws the newest picture on a
  canvas at each screen refresh, with no buffer in between. Sound needs Media Source to
  keep it in time, so unmuting switches to it, as does a decoder that fails (once a
  page). Auto takes it only where a canvas can go full screen, which an iPhone's can't;
  Decode › Directly or Media Source (`decoder=`) choose either way. WebKit fails every
  frame unless the configuration has the coded size, so it is taken from the init
  segment's `avc1` box. In WebKit on the Intel test Mac over loopback: 57–112 ms from the
  Mac against about 145 ms through Media Source.
- The page shows how long frames take from the Mac's screen to the browser's: the stream's
  response says when its zero was on the Mac's clock (`X-Stream-Epoch`, milliseconds since
  1970), the page sets its clock against the Mac's from the quickest of its last eight asks
  of `/time` (four as a stream starts, then one every 10 s), and `requestVideoFrameCallback`
  gives each frame's media time as it is shown. A frame's capture is taken as its slot on
  the grid, up to a frame earlier. WebKit on macOS 13 gives every Media Source frame a media
  time of 0 and an expected display time hours off, so there the page uses `currentTime`
  and the callback's own time instead. Measured in WebKit on the Intel test Mac over
  loopback: about 150 ms with 120–140 ms buffered.
- Gaps between arriving data that are too long for the buffer to cover, six or more in
  15 s, most of them the same time apart, between 0.25 and 1.2 s, bring a hint to turn
  off AirDrop: that steady beat is Wi-Fi leaving for AWDL (AirDrop, Handoff, AirPlay), where
  a busy network stops at random. Once a page.
- `/stream.mp4` is an endless fragmented MP4 that mpv, ffplay and VLC play as is.
- `/apps.json` lists the displays.

Who may watch (`WebStreamAccess`):

- **Devices.** Each has a token of its own, kept in `Application Support/DAM/Browser/
  devices.json`, and can be forgotten on its own in Settings. A player gets a link
  (`?token=`) from New Player Link…; Open in Browser uses a link named This Mac.
  `/apps.json` and `/stream.mp4` answer 401 without a known token; the page itself is
  open to anyone in reach.
- **Pairing.** A browser without a link asks to pair: the page shows a four-digit code,
  and DAM asks the user to type it. Right, the browser gets an HttpOnly cookie
  (`dam_watch`, a year; Secure when paired over HTTPS). One code at a time, five minutes
  each; a wrong code ends it. Pair with a QR Code… shows a code a phone scans instead:
  a key in the address that works once, for five minutes. "Allow new browsers to pair"
  turns both off.
- **Reach.** This Mac Only, This Mac's Networks (the default: loopback, link-local, or a
  subnet of the Mac's interfaces), or Anywhere. Out of reach gets a 403 for everything.
- **HTTPS.** DAM makes a certificate authority of its own (20 years) and a server
  certificate it signs for the Mac's `.local` name, host name, `localhost`, loopback and
  IPv4 addresses (800 days, as Apple allows at most 825), made again when those change
  or it nears its end. A device trusts the authority once: mpv with `--tls-ca-file`
  (Export Certificate…), an iPhone or iPad by installing `http://<mac>.local:47995/ca.cer`
  and turning on full trust for it. Without that, players that don't check certificates
  (mpv, IINA, ffmpeg by default) still play over HTTPS, and VLC asks once.
- **Imported certificates** (Settings › Browser Stream › Import Certificate…). It takes PEM
  files (certificates, any chain, and one RSA or EC key in PKCS#1, SEC1 or PKCS#8 form,
  not encrypted) or a .p12 file with its password. A .p12 file is read through the system's
  `/usr/bin/openssl` (LibreSSL), because Security on macOS 13 can't read OpenSSL 3's AES
  files and gives an older file's key only into a keychain. The certificate the key
  belongs to decides how it is used:
  - **A certificate authority** (basic constraints CA) signs DAM's server certificate in
    place of DAM's own, so devices that already trust it (mkcert's root, a home CA) need
    nothing more. The server certificate takes the authority's whole subject as its issuer,
    names its key identifier, is signed with RSA or ECDSA as its key is, ends before the
    authority does, and still follows the Mac's names and addresses. Certificates that came
    with the authority go out after it in the TLS handshake.
  - **Any other certificate** is served as it is, with the chain that came with it (from
    `tailscale cert`, certbot or mkcert, say). It covers only the names it was made for, so
    the HTTPS link uses one of them, and renewing it is up to its maker: import it again.
  The import is kept in `Browser/imported.json` and `imported-key.der`, readable only by the
  user, beside DAM's own files; Use DAM's Own deletes it and goes back. A running server
  starts again with the new certificate, which cuts off anyone watching.
- The stream over HTTP crosses the network unencrypted, and with it the tokens.

Three profiles (Interactive, Balanced, Viewing) set the defaults from Settings › Browser
Stream, which also has its own Show the Pointer. Each client can override profile,
bitrate, frame rate and size in the query string, and turn on low-latency encoding with
`lowlatency=1`.

## How it works

A Moonlight session goes from discovery to UDP streams in eight steps. The browser
stream branches off after encoding.

```mermaid
flowchart LR
    A["1. Discover<br/>Bonjour _nvstream._tcp"] --> B["2. Pair with PIN<br/>HTTP 47989, then HTTPS 47984"]
    B --> C["3. Launch<br/>makes a streaming display"]
    C --> D["4. RTSP handshake<br/>TCP 48010"]
    D --> E["5. ENet control<br/>UDP 47999, AES-GCM"]
    E --> F["6. Capture<br/>ScreenCaptureKit, video + audio"]
    F --> G["7. Encode<br/>VideoToolbox H.264 or HEVC, Opus"]
    G --> H["8. Packetize + FEC<br/>Reed-Solomon parity, paced"]
    H --> I["To Moonlight<br/>UDP 47998 video, 48000 audio"]
    G --> J["Browser or player, HTTP 47995 / HTTPS 47996<br/>fragmented MP4: /watch, /stream.mp4"]
```

### Discovery and pairing

`MoonlightHost`, `MoonlightPairing`, `MoonlightCrypto`:

- DAM advertises `_nvstream._tcp` over Bonjour.
- Discovery and pairing run over HTTP on 47989. Everything else runs over HTTPS on
  47984, which accepts only paired clients' certificates.
- Pairing follows moonlight-qt's GameStream steps: AES-128-ECB keyed by SHA-256 of the
  salt and PIN, with challenges hashed using each side's certificate signature.
- The host key, its self-signed certificate and the paired-client list are stored in
  Application Support, readable only by the user. The TLS identity is built in memory,
  so the keychain isn't involved.
- HTTP, HTTPS and RTSP together take at most 64 connections at once, 16 from one
  address (`MoonlightConnectionLimits`). One whose request hasn't all come within 10 s
  is closed; answering may take longer, as while the user types a PIN.

### Several devices

Each paired device has a session of its own, from /launch until /cancel, up to four at
once (`MoonlightHost.maxSessions`). A fifth gets a 503.

- Session *n* (0 to 3) has RTSP on TCP 48010 + *n*, given in /launch's `sessionUrl0`, and
  its stream on UDP 47998–48000 + 100 × *n*, given in the SETUP replies. The first
  session's are GameStream's, which port forwards are set up for.
- `/serverinfo` and `/cancel` are the asking device's own: a device sees its own launch
  as running and the host free otherwise, so Moonlight never asks it to quit another
  device's app.
- Each stream has its own encoder, bitrate, keyframes, FEC and encryption. Streams of one
  display at one size, rate and pointer setting share one capture (`SharedScreenCapture`),
  sound included; one that joins gets the last picture at once.
- A display made for one device that another device streams too stays until both are
  done.
- The menu lists the devices streaming, each with End Stream.
- On the test Mac (Intel Iris Plus 650), three 1080p60 encoders at once kept their
  frames within 25 ms (p90); with four, the slowest tenth took 43–83 ms.

### RTSP and control

`MoonlightRTSP`, TCP 48010 (and one port on per further session):

- DESCRIBE offers the launch's codecs: H.264, and HEVC as Settings › Moonlight › HEVC
  says (see Codecs below), by `sprop-parameter-sets=AAAAAU` as GameStream did. It supports encrypted control and audio, and encrypted
  video when Settings › Moonlight › Encrypt Video says so for the client's address: Off
  the Local Network (the default, as Sunshine's), Always or Never. "Local" is loopback,
  link-local, or a subnet of one of the Mac's interfaces. Only Always requires it
  (`encryptionRequested`); otherwise a client without fast AES may leave video plain.
- Only the address that made the /launch or /resume is answered; any other gets a 403,
  as SETUP hands out the stream's tokens.
- ANNOUNCE is parsed for size, fps, packet size, bitrate, minimum FEC and audio
  settings. It is refused if the client asks for a codec it wasn't offered, for encrypted video
  that wasn't offered, for plain video under Always, or for values no client sends
  (sizes beyond 8192, rates beyond 480, packets beyond one datagram); a bitrate over
  1 Gbit/s is taken as 1 Gbit/s. A launch is announced once: another ANNOUNCE would
  start video again under the same key and counter, so it gets a 455, and a stream that
  starts again comes with a /resume and a new key.
- Video and audio go wherever the ping with the launch's payload last came from. A bare
  "PING", from clients without the payload, counts only from the launching address.
- Control runs on UDP 47999 over vendored ENet 1.3.18, with AES-128-GCM messages.
  Keyframe requests, reference-frame invalidation, frame FEC status, input and
  termination are handled; the rest (pings, loss stats) are dropped.

### Input

Moonlight sends input as control message 0x0206 (`MoonlightInput.swift`). With the
whole control stream encrypted, the packets inside are plain, as moonlight-common-c
sends them to a Sunshine host (DAM reports 7.1.431.-1). `MoonlightInputInjector` posts
them as HID events, one injector per stream:

- **Pointer:** absolute moves map from the client's picture onto the streamed display's
  points, undoing a turned display's rotation and allowing for bars around a display of
  another shape. Relative moves (Moonlight's captured mouse) carry on from where they put the
  pointer while they follow closely, and from where it is after a tenth of a second
  without one (it may have been moved at the Mac), kept on that display. Buttons carry a click count, and moves while a button is held
  are drags.
- **Acceleration:** relative moves are sped up as macOS speeds up a mouse plugged into
  the Mac, at the tracking speed set for mice (`com.apple.mouse.scaling`; negative turns
  it off). Posted events skip the HID system, where macOS does this, so without it each
  step the mouse reports is a point at any speed. `MoonlightPointerAcceleration` uses
  IOHIDFamily's parametric curves and arithmetic, with macOS 13's curves for a mouse that
  brings none, and takes the client's steps as a 400 dpi mouse's, as macOS takes a
  mouse that doesn't state its resolution. macOS measures speed in steps per report;
  Moonlight's moves come at no fixed rate, so speed is measured over the last 24 ms, at
  125 reports a second. At the default speed a slow move goes about a quarter of a point
  per step and a fast one up to about two. "Speed up the mouse as this Mac does" in
  Settings › Moonlight turns it off, at once. Absolute moves (touch, and Moonlight's
  "optimize mouse for remote desktop") are not accelerated.
- **Scrolling:** whole wheel notches scroll a line each; finer amounts, from trackpads and
  touch screens, scroll by pixels. Horizontal scrolling is a Sunshine extension clients
  send DAM.
- **Keys:** Windows virtual-key codes map to the Mac's at a US keyboard's places. Ctrl is
  Control, Alt is Option and the Windows key is Command, so a PC's Ctrl+C is not ⌘C.
  As on a Mac keyboard, modifiers go as flag changes with their side's flag, and the
  arrows, the keys above them, the function keys and the keypad carry Fn and keypad
  flags.
  Text from a phone's keyboard is typed as it is, whatever the layout.
- **Permission:** posting events needs Accessibility access. Without it the input is
  dropped and the stream goes on as it would without input; streams don't ask for it, the
  Allow Input setting does when turned on. Input starts within a second of access being
  given. Each paired device has that setting, on by default, which takes effect at once.
  Events are posted on a queue of their own, so they never hold up the control stream. Whatever a stream holds down is let
  go when it ends or input is turned off.
- **Not handled:** controllers (macOS has no way for an app to make a virtual gamepad
  without a driver Apple must entitle), and touch and pen (DESCRIBE's feature flags stay
  0, so clients send taps as mouse events). Every client streaming a display may move its
  pointer; there is no arbitration.

### Video

`MoonlightScreenCapture` → `MoonlightVideoEncoder` → `MoonlightPacketizer` /
`MoonlightFEC` → UDP 47998:

- **Capture:** ScreenCaptureKit captures in 4:2:0 at the stream's size and rate, with a
  queue depth of 6, shared between streams that want the same.
- **Encoding:** VideoToolbox hardware H.264 (High profile, CABAC, real time, no frame
  reordering, keyframes only on request), or HEVC Main when the client chose it.
- **Codecs:** what differs between codecs is in `VideoCodec` (MoonlightVideoEncoder.swift):
  the encoder's type and profile, how NAL units name their type, the order of the
  parameter sets (HEVC: VPS, SPS, PPS, which Moonlight requires at each keyframe), and
  Moonlight's numbers for it (ServerCodecModeSupport bit, ANNOUNCE `bitStreamFormat`).
  What the Mac's encoder does with each is probed once, by making a session (hardware,
  and low-latency rate control). Settings › Moonlight › HEVC is Automatic, On or Off; HEVC
  is offered only where the Mac encodes it in hardware, and serverinfo then also gives
  Sunshine's `MaxLumaPixelsHEVC`, without which Moonlight won't take HEVC. Moonlight on
  Auto takes HEVC whenever it's offered and the device decodes it in hardware, so
  Automatic (the default) offers it to a device only where it streams as quickly as H.264
  would for that device: its encoder holds back no more frames before handing one back
  (none with low-latency rate control, so a device with Low-Latency Encoding on gets HEVC
  only where HEVC has it too, or holds none), and encodes at least half as many a second.
  Both are measured at 1080p, in the background when hosting starts (about a second
  here), once for the Mac as it is: the result is kept with the Mac's model, macOS build
  (the encoders come with it) and the encoders VideoToolbox lists (another GPU would add
  one), and measured again only when one of those changes, or when it couldn't be kept
  because an encoder failed to measure. Measured, as no property tells: H.264's session here takes MaxFrameDelayCount and still
  holds one frame. The encoder's ID (`kVTCompressionPropertyKey_EncoderID`) would name it
  (`hevc.gva` here: Intel's), but names differ by Mac and macOS. Settings' tooltip shows
  what was measured. Measured here, three runs: H.264 124–144 frames a second, 1 held;
  HEVC 36–37, 2 held, so Automatic offers H.264 only. On the Intel test Mac (Kaby Lake, 2026-10-22) HEVC is
  hardware but slow: about 40 frames a second at 1080p in a tight loop (H.264: 165), each
  frame held until two more are in, encoded synchronously, no low-latency rate control
  (-12902), and MaxFrameDelayCount, AllowOpenGOP and MaxKeyFrameIntervalDuration refused
  (-12900). Streamed to the local Moonlight: 1080p60, 30 fps, 205 ms host processing, a
  280 ms picture delay (H.264 at the same time: 46 fps, 10 ms, 30 ms); 720p60 HEVC, 48 fps
  and 48 ms. Its keyframes are CRA, which Moonlight takes. Not yet: 4:4:4 (asked-for
  4:4:4 and 4:2:2 come out 4:2:0 here), and AV1, which no Mac encodes in hardware (Apple
  Silicon from M3 only decodes it). The browser stream and OpenDisplay stay H.264.
- **HDR10 (since 2026-10-22):** HEVC Main10 in BT.2020 with PQ, for a client whose own
  HDR setting is on (moonlight-qt sends `hdrMode=1` with /launch then). Offered where the
  Mac makes Main10 in hardware, unless Settings › Moonlight › HEVC is Off; such a launch
  is offered HEVC whatever Automatic says, so serverinfo then gives the HEVC and Main10
  bits (0x0300) and `MaxLumaPixelsHEVC` to every device, and DESCRIBE, per launch, gives
  the HEVC marker only to launches that are to have HEVC: without it Moonlight takes
  H.264, however serverinfo read. The app list says `IsHdrSupported` 1. ANNOUNCE asks
  with `x-nv-video[0].dynamicRangeMode:1`, refused unless the launch asked and the codec
  is HEVC. Once Moonlight connects to the control stream it is sent the HDR mode message
  (0x010e, Sunshine's): enabled, then the metadata, 27 bytes little-endian; the encoder
  writes the same metadata into the stream's SEI (`MoonlightHDRMetadata`). moonlight-qt's
  renderer takes PQ from the stream and the metadata from the message, and has macOS
  tone-map by it. **Picture:** macOS's virtual displays are SDR only (no HDR setting in
  CGVirtualDisplay; BetterDisplay and Sidecar have the same limit), so a streaming display
  carries an SDR picture in HDR10. Real HDR needs one of the Mac's own displays showing it
  and ScreenCaptureKit's `captureDynamicRange` (macOS 15, set by name, as the SDK here is
  13's; HDR as a canonical display would show it); Settings › Moonlight › List this Mac's
  own displays (off by default) lists them, as app IDs 1000 plus the display's unit
  number, streamed as they are, never resized or removed. Before macOS 15 the display is
  captured as SDR. `HDR10Converter` turns frames into 10-bit 4:2:0 PQ with Core Image
  (about 6 ms a 1080p frame here), putting SDR white at 203 nits (BT.2408): macOS puts it
  at 100 nits in PQ, which moonlight-qt showed dim (white 173 against SDR's 240 in a
  recording of its window). With SDR captured, the metadata says 203 nits at most
  (`MoonlightHDRMetadata.sdr`), as with 1000 macOS's tone-mapping dims white to leave
  room for highlights; with HDR captured, a 1000-nit BT.2020 display. Measured on the
  test Mac (macOS 13, SDR Lenovo, the local Moonlight with HDR on): 1080p60 New Display,
  Main 10 decoded, 36 fps, 175 ms host processing, 274 ms delay (HEVC's encoder here);
  white 219 and the wallpaper close to SDR's; the Lenovo listed as "lenovo" (app 1002),
  720p60 HDR10 at 42 ms host processing, its mode unchanged. Not tested: HDR capture on
  macOS 15, and whether SDR white also sits at 100 nits there (the conversion assumes so).
- **Nudge:** the encoder holds each frame until the next one arrives. So if no new frame
  follows within 1.25 frame times, DAM resubmits the last picture to flush it, again
  every 1.25 frame times while the frame is still held (HEVC on the test Mac needs two).
- **Low-latency encoding (default for Moonlight):** Apple's low-latency rate control returns each frame
  as soon as it is encoded, so no nudge is needed. On the Intel test Mac it marks frames
  long-term and predicts from them, which FFmpeg (Moonlight everywhere, mpv, ffplay, VLC)
  can't follow with the one reference frame Moonlight allows. The long-term frame is always
  the one just before, so DAM rewrites those slice headers into plain ones that decode to
  the same pictures (`H264OneReference.swift`). It is on for every paired device unless
  turned off per device in Settings › Moonlight; on the test Mac it cut the median delay from 84 to
  56 ms. A browser stream asks for it with `lowlatency=1`, and the Viewing profile
  ignores it.
- **Sending:** a separate thread paces packets at 6× the bitrate, between 60 and
  400 Mbit/s. Encoded frames are never dropped. When the sender falls behind, capture
  skips a frame before encoding it.
- **Marking:** video packets carry DSCP AF41 and the interactive-video service type,
  sound EF and interactive voice, as Sunshine marks them. The service type picks the
  Wi-Fi queue the Mac sends from; the DSCP lets an access point queue them the same way on
  the way to the client. macOS writes a service type's DSCP only on networks it knows
  follow DiffServ, so DAM sets the DSCP itself (`IP_TOS`; the sockets are IPv4 only).
- **FEC:** each frame is split into up to four blocks, each with 20% Reed-Solomon parity
  (nanors-compatible), or more if the client asks for it.
- **Encryption:** when the client turned it on, each packet, data and parity alike, is
  sealed after parity is worked out: AES-128-GCM under the launch's key, sent behind a
  32-byte prefix of the nonce (a packet counter, three zeros and "V"), the frame index in
  the clear, and the tag (`MoonlightVideoCrypto`).
- **Still screen:** the last picture is resent every 0.5 s.
- **Keyframe requests:** at most one keyframe per 0.25 s. A request is skipped while the
  keyframe asked for is still to be sent, or when it arrives less than a round trip (at
  most 0.3 s) after a keyframe went out. Moonlight asks again for every frame it loses
  while it waits, so on a lossy link answering each request kept the stream in a run of
  keyframes.
- **Bitrate:** set from the client's losses, which it reports for each frame it could not
  rebuild from parity (Sunshine's 0x5502) and by asking for keyframes. Two or more losses
  in a second cut it by 30% if a frame came four or more packets short in the last 10 s
  (lost in a run, as an overflowing link drops them; random loss leaves them one to three
  short); ten or more losses of any kind halve it, then it holds for 2 s. Five
  seconds without a loss, and with no more than two frames rebuilt from parity a second,
  raise it by 15%. It stays between the client's bitrate and a quarter of it (no less than
  2 Mbit/s). Cuts are judged on the 10 s after them: unless losses fell by half against
  the 10 s before, it goes back to the bitrate before them, and only ten or more losses a
  second cut it for the next 30 s. That is for random loss, which a lower bitrate does not
  lessen and fewer parity packets per frame make worse. The first 3 s of a stream, when
  Moonlight asks for a keyframe and loses frames as it starts, count for nothing. Turning off
  "Adapt the bitrate to the network" in Settings › Moonlight keeps the client's bitrate throughout.

### Audio

UDP 48000. System audio at 48 kHz stereo, without DAM's own sounds.

- It is encoded to constant-bitrate Opus in 5 ms packets, at 512 or 96 kbit/s depending
  on the client.
- Packets can be encrypted, with parity after every fourth packet. They are paced from a
  queue of at most 40 ms, and silence fills the gaps.

### Streaming displays

`VideoManager+StreamingDisplay`: standalone `CGVirtualDisplay`s, at most four, each with
its own name and serial.

- A stream up to 2560 px wide gets a 1x display of its size. A wider one gets a HiDPI
  display at half the size.
- DAM places each display to the right of the others. It puts back any resolution
  WindowServer changes on other displays, and hands "main" back if the streaming display
  took it.

### Browser and player stream

`WebStream`, `MP4Fragmenter`, TCP 47995 and 47996 (`WebStreamServer`, listeners of its
own): one MP4 fragment per frame, H.264 plus AAC at 48 kHz.

- Viewers of the same display with the same settings share one capture and one encoder.
- A new viewer starts at a keyframe. A viewer more than 1 s behind skips ahead to the
  next keyframe.
- Frames snap to a fixed grid, and slots where the screen didn't change repeat the last
  picture. Browsers stall on any gap, so this stream never nudges the encoder. Silence
  keeps the audio within 50 ms of the video.
