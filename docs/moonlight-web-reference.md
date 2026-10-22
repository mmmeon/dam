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

DAM's WebStream sends VideoToolbox H.264 to browsers through MSE, and nothing in DAM adds
a VUI. `H264OneReference.swift` already rewrites H.264 headers bit by bit, so this may be
the cheapest delay win for `/watch`.

### 2. Flushing each frame with `VTCompressionSessionCompleteFrames`

moonlight-web calls `VTCompressionSessionCompleteFrames` after every
`VTCompressionSessionEncodeFrame` and waits for that frame's output
(`encode/macos/VtEncoder.mm`). DAM instead waits about 1.25 frames and resubmits the same
picture to push the last frame out of the encoder (the "nudge" in
`MoonlightVideoEncoder.swift`). A flush might replace the nudge, and it would suit web
streams, where a nudge breaks the fixed frame timing. Compare with `tools/streamtest` on
the Intel Mac before changing anything.

### 3. `RealTime` off

moonlight-web turns `kVTCompressionPropertyKey_RealTime` off. In real-time mode the
encoder paces itself to the expected frame rate, which they found doubled each frame's
delay on an M1 Pro and pushed H.264 past the frame period. DAM sets it to true
(`MoonlightVideoEncoder.swift`). Intel's encoder may behave differently, so measure it.

### 4. Marking video packets as DSCP AF41

Packets marked AF41 go into the Wi-Fi video queue. With a download running on the same
access point, a click's picture came back 32–40 ms sooner
(`docs/design/network-latency-findings.md`, 12/10/2026). DAM's Moonlight UDP doesn't
appear to set a traffic class; only the OpenDisplay sender sets `serviceClass`.

One macOS catch: a dual-stack socket refuses `IP_TOS`, and `IPV6_TCLASS` marks only IPv6
packets. Sends to an IPv4-mapped address need the traffic class as per-packet ancillary
data (`backend/third_party/patches/libjuice-macos-diffserv.patch`).

### 5. Pointer acceleration for injected moves

Moves posted with `CGEventPost` skip the HID driver, where all of Apple's acceleration
lives. A streamed mouse then feels much slower than the Mac's own.
`input/macos/MacPointerAccel.*` reads the tracking-speed setting and applies a curve of
the same shape to relative moves. DAM's `MoonlightInputInjector.swift` already handles
modifier flags, click counts and drags, but not acceleration.

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
