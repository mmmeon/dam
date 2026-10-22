# What moonlight-web can teach DAM's streaming

*As of 2026-10-22. Compares DAM's `main` (6398d97) with
[linckosz/moonlight-web](https://github.com/linckosz/moonlight-web) at 0523151.*

## Summary

[moonlight-web](https://github.com/linckosz/moonlight-web) streams a computer to browsers
over WebRTC, and the browser decodes with WebCodecs. It also has its own macOS host:
it creates a `CGVirtualDisplay`, captures it with ScreenCaptureKit and encodes with
VideoToolbox, as DAM does. The project measures latency closely and writes down what it
finds.

Most of the repository is about Windows (D3D12, NVENC) or tuning WebRTC's SCTP, which DAM
doesn't use. The parts below apply to DAM. None of them has been tried in DAM yet.

moonlight-web is GPL-3.0 and DAM is MIT. This document takes ideas and measurements from
it, not code.

## Leads, best first

### 1. A VUI that says the stream has no reordering

VideoToolbox's H.264 SPS carries no VUI. Without `bitstream_restriction` saying there is
no reordering, a browser's decoder holds back a full decoded picture buffer before it
shows a frame. moonlight-web measured 90–105 ms of extra delay on a Mac, and 200 ms in
Chrome's D3D11 decoder; with the flag, decoding took about 1 ms. Their fix rewrites the
SPS ahead of each keyframe (`backend/native-host/src/encode/H264Vui.h`, notes in
`encode/macos/VtEncoder.h`).

**Checked 2026-10-22 on the Intel test Mac (macOS 13.7): not needed there.** Its encoder
writes a VUI with `bitstream_restriction` in every mode DAM uses without reordering. The
SPS was taken from 1920×1080 encodes with DAM's own settings:

| Encoder | `max_num_reorder_frames` | `max_dec_frame_buffering` | References |
|---|---|---|---|
| Low latency (Moonlight; web streams with `lowlatency`) | 0 | 4 | 4 |
| Plain real-time, no reordering (Interactive, Balanced) | 0 | 2 | 2 |
| Reordering (Viewing) | no `bitstream_restriction` | — | 2 |

Viewing reorders frames on purpose and keeps a second of buffer, so it does not need the
flag. moonlight-web's numbers come from Apple Silicon Macs, whose encoder may leave the VUI
out. On such a Mac, check the SPS before adding a rewrite: a VUI that already says 0 must
be left as it is.

The rapid stalling of the Interactive `/watch` page in WebKit (about 120 a second, on
`main` too) therefore has another cause.

### 2. Flushing each frame with `VTCompressionSessionCompleteFrames`

moonlight-web calls `VTCompressionSessionCompleteFrames` after every
`VTCompressionSessionEncodeFrame` and waits for that frame's output
(`encode/macos/VtEncoder.mm`). DAM instead waits about 1.25 frames and resubmits the same
picture to push the last frame out of the encoder (the "nudge" in
`MoonlightVideoEncoder.swift`).

**Already tried in DAM:** the header of `MoonlightVideoEncoder.swift` records that asking
this Intel encoder to complete a frame brings it out at once, but makes the next frame a
keyframe. That is why DAM uses the nudge, or Apple's low-latency rate control, which
hands each frame back on its own. A flush could still be worth trying on Apple Silicon.

### 3. `RealTime` off

moonlight-web turns `kVTCompressionPropertyKey_RealTime` off. In real-time mode the
encoder paces itself to the expected frame rate, which they found doubled each frame's
delay on an M1 Pro and pushed H.264 past the frame period. DAM sets it to true
(`MoonlightVideoEncoder.swift`).

**Measured 2026-10-22 on the Intel test Mac: keep it on.** `tools/streamtest` over
loopback, 1920×1080@60, 20 s runs alternating on and off, read from Moonlight's host
processing latency:

| Encoder | `RealTime` on: average (worst) | off: average (worst) |
|---|---|---|
| Low latency (6 runs each) | 8.7–13.2 ms (48–81 ms) | 12.3–15.1 ms (158–327 ms) |
| Plain real-time (3 runs each) | 24.6–27.6 ms (635–756 ms) | 25.0–26.9 ms (795–906 ms) |

Off is worse with low-latency rate control and makes no difference to the plain encoder.
The plain encoder's worst frames were all repeats: a frame given again to nudge the one
before it out then waits in the encoder for the next picture, through a still screen, and
its wait was reported to Moonlight as host processing latency. Since then a repeat reports
0 ("not known"), which Moonlight leaves out: worst frames 60–103 ms, average unchanged.
On Apple Silicon it may still be worth trying.

### 4. Marking video packets as DSCP AF41

Packets marked AF41 go into the Wi-Fi video queue. With a download running on the same
access point, a click's picture came back 32–40 ms sooner
(`docs/design/network-latency-findings.md`, 12/10/2026). DAM's Moonlight UDP doesn't
appear to set a traffic class; only the OpenDisplay sender sets `serviceClass`.

One macOS catch: a dual-stack socket refuses `IP_TOS`, and `IPV6_TCLASS` marks only IPv6
packets. Sends to an IPv4-mapped address need the traffic class as per-packet ancillary
data (`backend/third_party/patches/libjuice-macos-diffserv.patch`).

**Done 2026-10-22.** DAM's Moonlight sockets are IPv4 only, so `IP_TOS` works and the
dual-stack catch doesn't apply. Video goes out as AF41 with `NET_SERVICE_TYPE_VI`, sound
as EF with `NET_SERVICE_TYPE_VO`; a loopback test reads the DSCP back with `IP_RECVTOS`.
The effect needs a busy Wi-Fi network to show and hasn't been measured on one yet.

### 5. Pointer acceleration for injected moves

Moves posted with `CGEventPost` skip the HID driver, where all of Apple's acceleration
lives. A streamed mouse then feels much slower than the Mac's own.
`input/macos/MacPointerAccel.*` reads the tracking-speed setting and applies a curve of
the same shape to relative moves. DAM's `MoonlightInputInjector.swift` already handles
modifier flags, click counts and drags, but not acceleration.

**Done 2026-10-22,** from Apple's own arithmetic rather than moonlight-web's: IOHIDFamily
is open source (`IOHIDEventSystemPlugIns/IOHIDAccelerationAlgorithm.cpp`), so DAM uses
macOS's parametric curves for a mouse at the Mac's tracking speed, with a test against
values worked out from that code. Not yet tried with a real mouse through Moonlight.

## The /watch page

DAM's page (`WebStreamPage` in `WebStream.swift`) fetches `/stream.mp4` and plays it
through MSE. It keeps playback a chosen buffer behind the newest frame by seeking and
nudging `playbackRate`. moonlight-web's player is much larger, but a few of its ideas fit
DAM's page. In order of value for the effort:

1. **Keep the screen awake.** The page never asks for a wake lock, so a phone or tablet
   used as a display dims and locks in the middle of a stream. moonlight-web takes
   `navigator.wakeLock.request('screen')` while it streams and takes it again when the tab
   comes back to the front, since the browser drops the lock when the tab is hidden
   (`frontend/js/ui/StreamViewFullscreen.js`).

2. **Reconnect by itself.** On "The stream broke off." or "The stream ended." the page
   stops and waits for a reload. It only restarts when a hidden tab comes back to the
   front. moonlight-web reconnects behind a "Reconnecting…" screen, at most twice in five
   minutes, so a stream that keeps failing still ends
   (`frontend/js/stream/CrashRelaunch.js`). A Wi-Fi drop of a second or two shouldn't
   need a reload.

3. **Notice a frozen picture.** If bytes keep arriving but `currentTime` stops moving
   without a `waiting` event, the page shows a frozen frame and says nothing.
   moonlight-web watches for "chunks in, no pictures out" over a time and frame-count
   threshold and restarts the decoder (`frontend/js/stream/SilentDecoderWatch.js`). For
   MSE, the same check would compare bytes appended with `currentTime` and
   `getVideoPlaybackQuality().totalVideoFrames`.

4. **Show the real delay.** "ms behind" is only the browser's buffer: newest buffered time
   minus `currentTime`. It leaves out capture, encoding, the network and decoding.
   moonlight-web stamps each frame with the host's capture time and measures the age of
   each picture as it is shown. DAM's page could do the same with
   `requestVideoFrameCallback` (its `mediaTime` is the frame's media timestamp), if the
   host sends the wall-clock time of media time 0 and the page estimates the clock offset
   with a ping.

   **Done 2026-10-22,** as described: `X-Stream-Epoch` on the stream and `/time` for the
   clock. On macOS 13's WebKit, `requestVideoFrameCallback` gives every Media Source frame
   a `mediaTime` of 0 and a fixed `expectedDisplayTime` hours off, so the page falls back
   to `currentTime` and the callback's own time. Not yet seen in Chrome.

5. **Warn about AWDL.** moonlight-web spots stalls that come at a fixed period, which is
   AWDL's mark, and tells the viewer to turn off AirDrop
   (`frontend/js/stream/PeriodicStallDetector.js`). DAM's page could count its own stalls
   by time and show the same hint. This fits with stop-stutter, the MIT helper that turns
   AWDL off.

   **Done 2026-10-22,** on gaps between arriving data rather than frame times, and only
   gaps longer than the page's buffer, since shorter ones don't show. Checked against
   synthetic arrivals (steady beats hint; random gaps, covered gaps and a 150 ms beat
   don't), not yet on a Wi-Fi network with AirDrop on.

6. **Decode with WebCodecs for Interactive.** MSE keeps a media pipeline and a buffer
   between the bytes and the screen. moonlight-web decodes each frame with a WebCodecs
   `VideoDecoder` (`optimizeForLatency: true`) and draws it as soon as it comes out. It
   keeps only the newest frame when several are ready
   (`frontend/js/stream/VideoDecodeWorker.js`). DAM's server could stay as it is: the
   page can split DAM's own fMP4 fragments (`moof` and `mdat`) into `EncodedVideoChunk`s.
   Audio would need an `AudioDecoder` and an AudioWorklet, or the Interactive profile could
   stay video-only. This is the largest change. A decoder that holds frames back would
   undo it, so on an Apple Silicon Mac, check the SPS first (lead 1).

   **Done 2026-10-22,** video only, for Interactive without sound, as suggested: the page
   splits DAM's fragments itself and the server is unchanged. WebKit's decoder fails every
   frame from an avcC description unless `codedWidth` and `codedHeight` are given. In
   WebKit on the Intel test Mac over loopback, two alternating 30 s runs each: 57–105 ms
   from the Mac directly, 144–149 ms through Media Source. Not yet seen in Chrome or on
   an iPad.

The page can't send input: it is view-only. moonlight-web sends keyboard, mouse, touch and
gamepads to the host. Adding input would make a browser a full client, but that is a
feature decision, not a fix.

## Useful for measuring

- `backend/src/LatencyFlagMac.mm` measures click-to-photon. A listen-only `CGEventTap`
  sees the click, and the event source state tells injected clicks from real ones.
  `tools/streamtest` could add this; today it measures only display-to-display delay with
  QR codes.
- `docs/design/network-latency-findings.md` §3 (06/08/2026) found the same AirDrop/AWDL
  stutter as DAM, diagnosed with `ping -i 0.1`. Spikes at a regular interval mean the
  radio left the channel; random ones mean congestion. §4 and §5 list their model of the
  delay and what they tried that failed.
- `docs/design/glass-to-glass.md` describes a camera method (240 fps phone video). It is
  in French, as is most of `docs/design/native-capture-encoder.md`.
- `frontend/js/stream/VideoDecodeWorker.js` is their WebCodecs decoder. It is the larger
  change, if `/watch`'s Interactive profile ever moves off MSE.

## Nothing new for DAM

- Their virtual display (`platform/macos/MacVirtualDisplay.mm`) works the way DAM's does.
  The one extra is an HDR mode: BT.2020 primaries on the descriptor and transfer function
  1 on the mode. Their HDR capture needs macOS 15.
- They make a display main by moving every display's origin by the same offset in one
  configuration, as DAM does.
